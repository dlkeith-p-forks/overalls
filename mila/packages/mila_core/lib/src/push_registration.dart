/// Push registration for one deployment (ADR-0224, ADR-0225), as a pure
/// state machine the app drives from platform, relay and Porsche outcomes.
///
/// Registration takes three steps: the platform's push token, a push key the
/// relay issues for that token and this deployment, and `device register`
/// over Porsche with the push key and the device's X25519 poke key. Rotation
/// re-issues the push key before it expires or when the platform token
/// changes; turning notifications off or a server-side revocation stops it.
///
/// The machine never holds the platform token, the push key or any key
/// material: only an opaque digest of the token, the relay's key id and the
/// server's device id.
library;

import 'dart:math';

import 'backoff.dart';

/// How long before a push key expires Mila re-issues it.
const Duration pushKeyRotationWindow = Duration(days: 14);

/// Retry spacing for relay and Porsche failures that may clear.
const Backoff pushBackoff = Backoff(base: Duration(seconds: 5), cap: Duration(minutes: 30));

/// Where registration stands.
enum PushPhase {
  /// The platform has no push service Mila can use (Linux).
  unsupported,

  /// Notifications are off for this deployment and no device is registered.
  disabled,

  /// Waiting for the platform's push token or permission.
  awaitingToken,

  /// The user denied notification permission in the system settings.
  denied,

  /// Asking the relay for a push key.
  issuing,

  /// Running `device register` over Porsche.
  registering,

  /// Registered: pokes can reach this device.
  active,

  /// Running `device rm` after notifications were turned off.
  removing,

  /// The deployment revoked this device (key removal, `device rm` elsewhere,
  /// or the relay reported the token dead). Only the user re-enables it.
  revoked,

  /// A closed refusal the user must act on, such as push disabled by the
  /// operator.
  failed,
}

/// Why registration failed for good.
enum PushFailure {
  /// The deployment turned notifications off (`push_disabled`).
  pushDisabled,

  /// Porsche or the relay refused the request.
  refused,

  /// A reply could not be understood.
  protocol,
}

/// Inputs from the user, the platform, the relay and Porsche. Outcomes carry
/// the [PushRegistration.operation] they answer; stale ones are ignored.
sealed class PushEvent {
  const PushEvent();
}

/// The user turned notifications on for this deployment.
final class PushEnable extends PushEvent {
  const PushEnable();
}

/// The user turned notifications off for this deployment.
final class PushDisable extends PushEvent {
  const PushDisable();
}

/// The platform issued (or re-issued) a push token. Only its digest enters
/// the machine, to notice rotation.
final class PushTokenReceived extends PushEvent {
  const PushTokenReceived(this.tokenDigest);
  final String tokenDigest;
}

/// The user denied notification permission.
final class PushPermissionDenied extends PushEvent {
  const PushPermissionDenied();
}

/// The relay issued a push key.
final class PushKeyIssued extends PushEvent {
  const PushKeyIssued(this.operation, {required this.keyId, required this.expiresAt});
  final int operation;
  final String keyId;
  final DateTime expiresAt;
}

/// How a step failed.
enum PushStepFailure {
  /// Transport, timeout, 5xx, 429, or a request Porsche never admitted.
  transient,

  /// The deployment disabled push.
  pushDisabled,

  /// Any other closed refusal.
  refused,

  /// The device is no longer registered on the deployment.
  revoked,

  /// An unreadable reply.
  protocol,
}

/// The relay refused or could not be reached.
final class PushKeyFailed extends PushEvent {
  const PushKeyFailed(this.operation, this.failure, {this.retryAfter});
  final int operation;
  final PushStepFailure failure;
  final Duration? retryAfter;
}

/// `device register` reached a terminal success.
final class PushRegistered extends PushEvent {
  const PushRegistered(this.operation, this.deviceId);
  final int operation;
  final String deviceId;
}

/// `device register` reached a terminal refusal, or was never admitted.
final class PushRegisterFailed extends PushEvent {
  const PushRegisterFailed(this.operation, this.failure);
  final int operation;
  final PushStepFailure failure;
}

/// `device rm` finished; [removed] is false for a transient failure.
final class PushRemoveFinished extends PushEvent {
  const PushRemoveFinished(this.operation, {required this.removed});
  final int operation;
  final bool removed;
}

/// The deployment no longer lists this device.
final class PushRevoked extends PushEvent {
  const PushRevoked();
}

/// The clock advanced.
final class PushTick extends PushEvent {
  const PushTick(this.now);
  final DateTime now;
}

/// What the driver should do now. Each step names the operation number its
/// outcome must carry.
sealed class PushAction {
  const PushAction();
}

/// Nothing to send.
final class PushWait extends PushAction {
  const PushWait();
}

/// Ask the platform for a token (and permission, the first time).
final class PushRequestToken extends PushAction {
  const PushRequestToken();
}

/// `POST /api/push/v1/keys` with the current platform token.
final class PushIssueKey extends PushAction {
  const PushIssueKey(this.operation);
  final int operation;
}

/// `device register` with the freshly issued push key, under one new
/// request id that is then only polled.
final class PushRegisterDevice extends PushAction {
  const PushRegisterDevice(this.operation);
  final int operation;
}

/// `device rm <deviceId>`.
final class PushRemoveDevice extends PushAction {
  const PushRemoveDevice(this.operation, this.deviceId);
  final int operation;
  final String deviceId;
}

/// What follows a `device register` already sent when the user or the
/// deployment changes course while it is in flight. The registration may
/// still land, so its outcome is always awaited.
enum PushFollowUp {
  /// Become active.
  none,

  /// The platform token changed: issue a new push key next.
  rotate,

  /// Notifications were turned off or the device was revoked: remove
  /// whatever the registration created.
  remove,
}

/// An immutable registration snapshot.
final class PushRegistration {
  const PushRegistration._({
    required this.phase,
    required this.operation,
    required this.inFlight,
    this.tokenDigest,
    this.keyId,
    this.expiresAt,
    this.deviceId,
    this.failure,
    this.retries = 0,
    this.retryAt,
    this.now,
    this.followUp = PushFollowUp.none,
  });

  /// Registration on a platform with push, starting switched off.
  const PushRegistration.initial()
    : this._(phase: PushPhase.disabled, operation: 0, inFlight: false);

  /// Registration on a platform without push.
  const PushRegistration.unsupported()
    : this._(phase: PushPhase.unsupported, operation: 0, inFlight: false);

  /// Registration as Mila saved it, from [record]'s closed schema: an active
  /// device, a removal still owed, a wish to register, or off. Anything
  /// malformed restores as off.
  factory PushRegistration.restore(Map<String, Object?> record) {
    final wanted = record['wanted'];
    final device = record['device_id'];
    final key = record['key_id'];
    final expires = record['expires_at'];
    final token = record['token_digest'];
    final keys = record.keys.toSet();
    const allowed = {'version', 'wanted', 'device_id', 'key_id', 'expires_at', 'token_digest'};
    if (record['version'] != 1 || !allowed.containsAll(keys) || wanted is! bool) {
      return const PushRegistration.initial();
    }
    final deviceId = device is String && device.length <= 64 ? device : null;
    if (!wanted) {
      return deviceId == null
          ? const PushRegistration.initial()
          : PushRegistration._(
              phase: PushPhase.removing,
              operation: 1,
              inFlight: false,
              deviceId: deviceId,
            );
    }
    if (deviceId != null && key is String && expires is int && token is String) {
      return PushRegistration._(
        phase: PushPhase.active,
        operation: 1,
        inFlight: false,
        deviceId: deviceId,
        keyId: key,
        expiresAt: DateTime.fromMillisecondsSinceEpoch(expires, isUtc: true),
        tokenDigest: token,
      );
    }
    return PushRegistration._(
      phase: PushPhase.awaitingToken,
      operation: 1,
      inFlight: false,
      deviceId: deviceId,
    );
  }

  /// What survives a restart. Never the platform token or push key: only
  /// the user's wish, the server's device id, the relay's key id and expiry
  /// and the token digest.
  Map<String, Object?> get record => {
    'version': 1,
    'wanted': wanted,
    'device_id': deviceId,
    'key_id': phase == PushPhase.active ? keyId : null,
    'expires_at': phase == PushPhase.active ? expiresAt?.millisecondsSinceEpoch : null,
    'token_digest': phase == PushPhase.active ? tokenDigest : null,
  };

  final PushPhase phase;

  /// The current step's number; increases with every new step.
  final int operation;

  /// Whether the current step was handed out and its outcome is pending.
  final bool inFlight;

  final String? tokenDigest;
  final String? keyId;
  final DateTime? expiresAt;

  /// The server's id for this device, once registered.
  final String? deviceId;
  final PushFailure? failure;

  /// Consecutive transient failures of the current step.
  final int retries;

  /// When a transient failure may be retried.
  final DateTime? retryAt;

  /// The latest time the machine has seen.
  final DateTime? now;

  /// What happens once an in-flight registration answers.
  final PushFollowUp followUp;

  /// Whether the user wants notifications from this deployment.
  bool get wanted => switch (phase) {
    PushPhase.awaitingToken || PushPhase.issuing || PushPhase.active || PushPhase.denied => true,
    PushPhase.registering => followUp != PushFollowUp.remove,
    _ => false,
  };

  PushRegistration _copy({
    PushPhase? phase,
    bool? inFlight,
    String? tokenDigest,
    String? keyId,
    DateTime? expiresAt,
    String? deviceId,
    PushFailure? failure,
    int? retries,
    DateTime? retryAt,
    DateTime? now,
    PushFollowUp? followUp,
    bool clearKey = false,
    bool clearDevice = false,
    bool clearToken = false,
  }) => PushRegistration._(
    phase: phase ?? this.phase,
    operation: operation,
    inFlight: inFlight ?? this.inFlight,
    tokenDigest: clearToken ? null : tokenDigest ?? this.tokenDigest,
    keyId: clearKey ? null : keyId ?? this.keyId,
    expiresAt: clearKey ? null : expiresAt ?? this.expiresAt,
    deviceId: clearDevice ? null : deviceId ?? this.deviceId,
    failure: failure ?? this.failure,
    retries: retries ?? this.retries,
    retryAt: retryAt ?? this.retryAt,
    now: now ?? this.now,
    followUp: followUp ?? this.followUp,
  );

  /// Starts a new step: a fresh operation number, nothing in flight, no
  /// pending retry, failure or follow-up.
  PushRegistration _step(
    PushPhase phase, {
    String? tokenDigest,
    String? keyId,
    DateTime? expiresAt,
    String? deviceId,
    PushFailure? failure,
    bool clearKey = false,
    bool clearDevice = false,
    bool clearToken = false,
  }) => PushRegistration._(
    phase: phase,
    operation: operation + 1,
    inFlight: false,
    tokenDigest: clearToken ? null : tokenDigest ?? this.tokenDigest,
    keyId: clearKey ? null : keyId ?? this.keyId,
    expiresAt: clearKey ? null : expiresAt ?? this.expiresAt,
    deviceId: clearDevice ? null : deviceId ?? this.deviceId,
    failure: failure,
    now: now,
  );

  /// The next action. Taking it is recorded with [took].
  PushAction get next {
    if (inFlight) return const PushWait();
    final at = retryAt;
    if (at != null && (now == null || now!.isBefore(at))) return const PushWait();
    return switch (phase) {
      PushPhase.awaitingToken => const PushRequestToken(),
      PushPhase.issuing => PushIssueKey(operation),
      PushPhase.registering => PushRegisterDevice(operation),
      PushPhase.removing when deviceId != null => PushRemoveDevice(operation, deviceId!),
      _ => const PushWait(),
    };
  }

  /// Records that the driver started [action], which [next] returned.
  PushRegistration took(PushAction action) => switch (action) {
    PushIssueKey(:final operation) ||
    PushRegisterDevice(:final operation) ||
    PushRemoveDevice(
      :final operation,
    ) when operation == this.operation && !inFlight => _copy(inFlight: true),
    _ => this,
  };

  bool _answers(int operation, PushPhase phase) =>
      operation == this.operation && phase == this.phase && inFlight;

  /// Applies one event.
  PushRegistration apply(PushEvent event) {
    if (phase == PushPhase.unsupported) {
      return event is PushTick ? _copy(now: event.now) : this;
    }
    return switch (event) {
      PushEnable() => switch (phase) {
        PushPhase.disabled ||
        PushPhase.revoked ||
        PushPhase.failed ||
        PushPhase.denied => _step(PushPhase.awaitingToken, clearKey: true),
        _ => this,
      },
      PushDisable() => _stop(PushPhase.disabled),
      PushRevoked() => _stop(PushPhase.revoked),
      PushPermissionDenied() when phase == PushPhase.awaitingToken => _step(PushPhase.denied),
      PushPermissionDenied() => this,
      PushTokenReceived(:final tokenDigest) => _token(tokenDigest),
      PushKeyIssued(:final operation, :final keyId, :final expiresAt)
          when _answers(operation, PushPhase.issuing) =>
        _step(PushPhase.registering, keyId: keyId, expiresAt: expiresAt),
      PushKeyFailed(:final operation, :final failure, :final retryAfter)
          when _answers(operation, PushPhase.issuing) =>
        // Only the deployment can revoke a device: a relay that reports the
        // platform token dead is a refusal, and any registered device stays
        // for the user to remove or re-enable.
        _failed(failure == PushStepFailure.revoked ? PushStepFailure.refused : failure, retryAfter),
      PushRegistered(:final operation, :final deviceId)
          when _answers(operation, PushPhase.registering) =>
        switch (followUp) {
          PushFollowUp.none => _step(PushPhase.active, deviceId: deviceId)._rotateIfDue(),
          PushFollowUp.rotate => _step(PushPhase.issuing, deviceId: deviceId, clearKey: true),
          PushFollowUp.remove => _step(PushPhase.removing, deviceId: deviceId, clearKey: true),
        },
      PushRegisterFailed(:final operation, :final failure)
          when _answers(operation, PushPhase.registering) =>
        switch (followUp) {
          PushFollowUp.remove =>
            deviceId == null
                ? _step(PushPhase.disabled, clearKey: true, clearToken: true)
                : _step(PushPhase.removing, clearKey: true),
          PushFollowUp.rotate when failure == PushStepFailure.transient => _step(
            PushPhase.issuing,
            clearKey: true,
          ),
          _ => _failed(failure, null),
        },
      PushRemoveFinished(:final operation, :final removed)
          when _answers(operation, PushPhase.removing) =>
        removed ? _step(PushPhase.disabled, clearDevice: true, clearToken: true) : _retry(null),
      PushTick(:final now) => _tick(now),
      PushKeyIssued() ||
      PushKeyFailed() ||
      PushRegistered() ||
      PushRegisterFailed() ||
      PushRemoveFinished() => this,
    };
  }

  /// Notifications stop: the user turned them off ([PushPhase.disabled]) or
  /// the deployment revoked the device ([PushPhase.revoked]).
  PushRegistration _stop(PushPhase target) {
    final revoked = target == PushPhase.revoked;
    return switch (phase) {
      PushPhase.disabled => this,
      PushPhase.revoked when revoked => this,
      // A registration already sent may land: await it, then remove it.
      PushPhase.registering when inFlight => _copy(followUp: PushFollowUp.remove, clearKey: true),
      // A device the deployment already dropped needs no removal.
      PushPhase.removing when revoked => _step(
        PushPhase.disabled,
        clearDevice: true,
        clearToken: true,
        clearKey: true,
      ),
      PushPhase.removing => this,
      _ when revoked => _step(PushPhase.revoked, clearKey: true, clearDevice: true),
      _ when deviceId != null => _step(PushPhase.removing, clearKey: true),
      _ => _step(PushPhase.disabled, clearKey: true, clearToken: true),
    };
  }

  PushRegistration _token(String digest) => switch (phase) {
    PushPhase.awaitingToken || PushPhase.denied => _step(PushPhase.issuing, tokenDigest: digest),
    _ when digest == tokenDigest => this,
    PushPhase.registering when inFlight =>
      followUp == PushFollowUp.none
          ? _copy(tokenDigest: digest, followUp: PushFollowUp.rotate)
          : _copy(tokenDigest: digest),
    // A new platform token needs a new push key; the device id stays.
    PushPhase.issuing ||
    PushPhase.registering ||
    PushPhase.active => _step(PushPhase.issuing, tokenDigest: digest, clearKey: true),
    _ => this,
  };

  PushRegistration _failed(PushStepFailure failure, Duration? retryAfter) => switch (failure) {
    PushStepFailure.transient => _retry(retryAfter),
    PushStepFailure.pushDisabled => _step(
      PushPhase.failed,
      failure: PushFailure.pushDisabled,
      clearKey: true,
    ),
    PushStepFailure.refused => _step(
      PushPhase.failed,
      failure: PushFailure.refused,
      clearKey: true,
    ),
    PushStepFailure.protocol => _step(
      PushPhase.failed,
      failure: PushFailure.protocol,
      clearKey: true,
    ),
    PushStepFailure.revoked => _step(PushPhase.revoked, clearKey: true, clearDevice: true),
  };

  /// Retries the current step later under a new operation number, so a
  /// late duplicate of the failed attempt can never answer the retry.
  PushRegistration _retry(Duration? retryAfter) {
    final at = now;
    // The jitter seed is the step number, so a replayed history agrees.
    final delay = pushBackoff.delay(retries, Random(operation), retryAfter: retryAfter);
    return PushRegistration._(
      phase: phase,
      operation: operation + 1,
      inFlight: false,
      tokenDigest: tokenDigest,
      keyId: keyId,
      expiresAt: expiresAt,
      deviceId: deviceId,
      retries: retries + 1,
      retryAt: at?.add(delay),
      now: now,
    );
  }

  PushRegistration _tick(DateTime now) => _copy(now: now)._rotateIfDue();

  /// An active key inside the rotation window is re-issued now.
  PushRegistration _rotateIfDue() {
    final expires = expiresAt;
    final at = now;
    if (phase == PushPhase.active &&
        expires != null &&
        at != null &&
        !at.isBefore(expires.subtract(pushKeyRotationWindow))) {
      return _step(PushPhase.issuing, clearKey: true);
    }
    return this;
  }
}
