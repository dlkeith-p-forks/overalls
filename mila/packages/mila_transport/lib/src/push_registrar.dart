// Carries out the steps `PushRegistration` asks for: the platform token,
// the relay's push key and the Porsche `device` commands. Each step returns
// the event its outcome produces; the state machine decides what follows.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:mila_core/mila_core.dart';

import 'poke_keys.dart';
import 'porsche.dart';
import 'susan.dart';

/// The device platform a deployment records for a registered device. macOS
/// shares APNs with iOS, so the provider alone does not name the platform.
enum DevicePlatform {
  ios('ios', PushProvider.apns),
  android('android', PushProvider.fcm),
  macos('macos', PushProvider.apns),
  windows('windows', PushProvider.wns);

  const DevicePlatform(this.wire, this.provider);

  /// The `device register --platform` value.
  final String wire;

  /// The relay provider this platform's tokens belong to.
  final PushProvider provider;
}

/// The platform's push service.
abstract interface class PushPlatform {
  /// Which platform this is; its relay provider follows from it.
  DevicePlatform get device;

  Future<PushEnvironment> environment();

  /// Asks for permission the first time, then returns the current token.
  /// Throws [PushPermissionDeniedException] or [PushUnavailableException].
  Future<String> token();

  /// Tokens the platform issues later, after rotation.
  Stream<String> get tokenChanges;
}

final class PushPermissionDeniedException implements Exception {
  const PushPermissionDeniedException();
}

final class PushUnavailableException implements Exception {
  const PushUnavailableException();
}

/// One device registered on a deployment, as `device ls` lists it.
final class RegisteredDevice {
  const RegisteredDevice({required this.id, required this.platform, required this.enabled});
  final String id;

  /// `ios`, `android`, or `unknown` for a platform this client does not know.
  final String platform;
  final bool enabled;
}

/// Decodes a `device ls --json` result, tolerating unknown keys and skipping
/// rows without a canonical id. Returns null for a malformed listing.
List<RegisteredDevice>? decodeDeviceList(Map<String, Object?> result) {
  final items = result['items'] ?? result['devices'];
  if (items is! List<Object?>) return null;
  return [
    for (final item in items)
      if (item is Map<String, Object?> &&
          item['id'] is String &&
          isCanonicalUuid(item['id']! as String))
        RegisteredDevice(
          id: item['id']! as String,
          platform: pushPlatforms.contains(item['platform'])
              ? item['platform']! as String
              : 'unknown',
          enabled: item['enabled'] != false,
        ),
  ];
}

/// The device id in a `device register` receipt, wherever a server puts it.
String? deviceIdFromResult(Map<String, Object?> result) {
  final device = result['device'];
  final candidates = [
    result['id'],
    result['device_id'],
    if (device is Map<String, Object?>) device['id'],
  ];
  for (final candidate in candidates) {
    if (candidate is String && isCanonicalUuid(candidate)) return candidate;
  }
  return null;
}

/// Maps a refusal reason from a device command onto the machine's failures.
PushStepFailure deviceFailure(String? error, {required bool notAdmitted}) => switch (error) {
  _ when notAdmitted => PushStepFailure.transient,
  'push_disabled' => PushStepFailure.pushDisabled,
  'not_found' || 'device_not_found' || 'device_revoked' => PushStepFailure.revoked,
  'temporarily_unavailable' || 'transport_error' => PushStepFailure.transient,
  _ => PushStepFailure.refused,
};

/// Drives one deployment's registration steps. The platform token and the
/// issued push key live only in this object's memory.
final class PushRegistrar {
  PushRegistrar({
    required this.deployment,
    required this.platform,
    required this.susan,
    required this.pokeKeys,
    Random? random,
    this.pollBackoff = const Backoff(base: Duration(milliseconds: 500), cap: Duration(seconds: 5)),
    this.maximumPolls = 60,
  }) : _random = random ?? Random.secure();

  final Deployment deployment;
  final PushPlatform platform;
  final SusanClient susan;
  final PokeKeyStore pokeKeys;
  final Random _random;
  final Backoff pollBackoff;
  final int maximumPolls;

  String? _token;
  IssuedPushKey? _key;

  /// Forgets the in-memory token and push key.
  void forget() {
    _token = null;
    _key = null;
  }

  /// Performs [action]; returns the event to apply, or null when there is
  /// none (nothing to do, or the platform has no push service: then
  /// [unavailable] is set).
  Future<PushEvent?> perform(PushAction action, PorscheSession? session) async {
    switch (action) {
      case PushWait():
        return null;
      case PushRequestToken():
        try {
          final token = await platform.token();
          _token = token;
          return PushTokenReceived(pushTokenDigest(token));
        } on PushPermissionDeniedException {
          return const PushPermissionDenied();
        } on PushUnavailableException {
          unavailable = true;
          return null;
        }
      case PushIssueKey(:final operation):
        // After a restart the token is fetched again; it is never saved.
        final String token;
        try {
          token = _token ??= await platform.token();
        } on PushPermissionDeniedException {
          return PushKeyFailed(operation, PushStepFailure.refused);
        } on PushUnavailableException {
          unavailable = true;
          return PushKeyFailed(operation, PushStepFailure.refused);
        }
        final outcome = await susan.issueKey(
          PushKeyRequest(
            provider: platform.device.provider,
            token: token,
            environment: await platform.environment(),
            deployment: deployment.host,
          ),
        );
        switch (outcome) {
          case PushKeyGranted(:final key):
            _key = key;
            return PushKeyIssued(operation, keyId: key.keyId, expiresAt: key.expiresAt);
          case PushKeyRefused(:final failure, :final retryAfter):
            return PushKeyFailed(operation, failure, retryAfter: retryAfter);
        }
      case PushRegisterDevice(:final operation):
        final key = _key;
        if (key == null || session == null) {
          return PushRegisterFailed(operation, PushStepFailure.transient);
        }
        final public = await pokeKeys.publicKeyFor(deployment.host);
        final poll = await _mutate(
          session,
          PorscheCommand(
            'device register',
            options: {
              'json': true,
              'platform': platform.device.wire,
              'push-key': '-',
              'enc-pubkey': encodeBase64UrlUnpadded(public),
            },
          ),
          stdin: utf8.encode('${key.pushKey}\n'),
        );
        if (poll.phase == PollPhase.succeeded) {
          final id = deviceIdFromResult(poll.result);
          return id == null
              ? PushRegisterFailed(operation, PushStepFailure.protocol)
              : PushRegistered(operation, id);
        }
        return PushRegisterFailed(operation, _failure(poll));
      case PushRemoveDevice(:final operation, :final deviceId):
        if (session == null) return PushRemoveFinished(operation, removed: false);
        final poll = await _mutate(
          session,
          PorscheCommand('device rm', arguments: [deviceId], options: const {'json': true}),
        );
        final failure = poll.phase == PollPhase.succeeded ? null : _failure(poll);
        // A device the deployment no longer has is as removed as it gets.
        final removed = failure == null || failure == PushStepFailure.revoked;
        if (removed) {
          forget();
          await pokeKeys.delete(deployment.host);
        }
        return PushRemoveFinished(operation, removed: removed);
    }
  }

  /// Set once the platform reports it has no push service.
  bool unavailable = false;

  PushStepFailure _failure(RequestPoll poll) => switch (poll.phase) {
    PollPhase.refused => deviceFailure(poll.error, notAdmitted: poll.error == 'request_not_found'),
    PollPhase.failed => PushStepFailure.refused,
    // Still unknown after every poll: the next step decides afresh.
    _ => PushStepFailure.transient,
  };

  /// Submits [command] once under a new request id and polls `request show`
  /// until it is terminal or [maximumPolls] run out.
  Future<RequestPoll> _mutate(
    PorscheSession session,
    PorscheCommand command, {
    List<int>? stdin,
  }) async {
    final requestId = allocateRequestId(_random);
    final submitted = PorscheCommand(
      command.name,
      arguments: command.arguments,
      options: {...command.options, 'request-id': requestId},
    );
    var poll = RequestPoll.submitted(
      requestId,
    ).observe(await session.exec(submitted, stdin: stdin));
    while (!poll.terminal && poll.attempts < maximumPolls) {
      final next = poll.next as PollAgain;
      await Future<void>.delayed(pollBackoff.delay(next.attempt, _random));
      poll = poll.polled().observe(
        await session.exec(
          PorscheCommand('request show', arguments: [requestId], options: const {'json': true}),
        ),
      );
    }
    return poll;
  }

  /// Lists the deployment's registered devices for this account.
  Future<List<RegisteredDevice>?> listDevices(PorscheSession session) async {
    final outcome = await session.exec(PorscheCommand('device ls', options: const {'json': true}));
    final reply = outcome.reply;
    return reply is ReadReply && outcome.exit == PorscheExit.ok
        ? decodeDeviceList(reply.result)
        : null;
  }

  /// Turns notifications for [deviceId] on or off on the deployment.
  Future<bool> setEnabled(PorscheSession session, String deviceId, {required bool enabled}) async {
    final poll = await _mutate(
      session,
      PorscheCommand(
        'device prefs',
        arguments: [deviceId],
        options: {'json': true, 'enabled': '$enabled'},
      ),
    );
    return poll.phase == PollPhase.succeeded;
  }

  /// Removes another of the account's devices.
  Future<bool> remove(PorscheSession session, String deviceId) async {
    final poll = await _mutate(
      session,
      PorscheCommand('device rm', arguments: [deviceId], options: const {'json': true}),
    );
    return poll.phase == PollPhase.succeeded;
  }
}
