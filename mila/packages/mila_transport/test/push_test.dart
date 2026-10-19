import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:hegel/hegel.dart';
import 'package:mila_core/mila_core.dart';
import 'package:mila_transport/mila_transport.dart';
import 'package:test/test.dart';

const String _host = 'control.example.test';
const String _device = '6f1e2d3c-4b5a-4987-8a6b-5c4d3e2f1a0b';
final DateTime _now = DateTime.utc(2026, 10, 18, 12);

final class _RecordingTransport implements SusanTransport {
  _RecordingTransport(this.replies);
  final List<SusanHttpResponse> replies;
  final List<(Uri, Map<String, Object?>)> requests = [];

  @override
  Future<SusanHttpResponse> post(Uri uri, List<int> body) async {
    requests.add((uri, jsonDecode(utf8.decode(body)) as Map<String, Object?>));
    if (replies.isEmpty) throw const SocketException('unreachable');
    return replies.removeAt(0);
  }
}

SusanHttpResponse _granted({String expires = '2027-01-16T12:00:00Z'}) => SusanHttpResponse(
  201,
  utf8.encode(
    jsonEncode({'push_key': 'cHVzaC1rZXk', 'key_id': 'k-2026-10', 'expires_at': expires}),
  ),
);

final class _FakePlatform implements PushPlatform {
  _FakePlatform({this.denied = false});
  bool denied;
  int asked = 0;
  @override
  PushProvider get provider => PushProvider.apns;
  @override
  Future<PushEnvironment> environment() async => PushEnvironment.development;
  @override
  Future<String> token() async {
    asked++;
    if (denied) throw const PushPermissionDeniedException();
    return 'a1b2c3d4';
  }

  @override
  Stream<String> get tokenChanges => const Stream.empty();
}

/// Porsche answering `device` commands, optionally losing the first reply.
final class _FakeSession implements PorscheSession {
  _FakeSession({this.loseFirstReply = false, this.registerError});
  bool loseFirstReply;
  final String? registerError;
  final List<String> lines = [];
  final List<List<int>?> stdins = [];
  final Map<String, ReceiptReply> receipts = {};

  @override
  int get generation => 1;

  @override
  Future<ChannelOutcome> exec(PorscheCommand command, {List<int>? stdin}) async {
    lines.add(encodeCommand(command));
    stdins.add(stdin);
    final requestId = command.options['request-id'] as String?;
    switch (command.name) {
      case 'device register' || 'device rm' || 'device prefs':
        if (registerError != null && command.name == 'device register') {
          return ChannelOutcome(PorscheExit.invalid, ErrorReply(error: registerError!));
        }
        final receipt = ReceiptReply(
          requestId: requestId!,
          status: ReceiptStatus.succeeded,
          operationId: null,
          result: {'id': _device, 'platform': 'ios', 'unknown_future_key': 1},
        );
        receipts[requestId] = receipt;
        if (loseFirstReply) {
          loseFirstReply = false;
          return const ChannelOutcome(PorscheExit.unavailable, null);
        }
        return ChannelOutcome(PorscheExit.ok, receipt);
      case 'request show':
        final receipt = receipts[command.arguments.single];
        return receipt == null
            ? const ChannelOutcome(PorscheExit.invalid, ErrorReply(error: 'request_not_found'))
            : ChannelOutcome(PorscheExit.ok, receipt);
      case 'device ls':
        return const ChannelOutcome(
          PorscheExit.ok,
          ReadReply({
            'items': [
              {'id': _device, 'platform': 'ios', 'enabled': true, 'label': 'phone'},
              {'id': 'not-a-uuid', 'platform': 'ios'},
              {'id': '0d9cc041-9db2-4e4c-b28b-1e41d7f472c1', 'platform': 'tv', 'enabled': false},
            ],
          }),
        );
    }
    return const ChannelOutcome(PorscheExit.invalid, ErrorReply(error: 'invalid_command'));
  }

  @override
  Future<void> get closed => Completer<void>().future;
  @override
  Future<void> close() async {}
}

Future<Directory> _temp() => Directory.systemTemp.createTemp('mila-push-');

void main() {
  group('relay client', () {
    test('requests go only to the fixed origin with exactly five fields', () async {
      final transport = _RecordingTransport([_granted()]);
      final outcome = await SusanClient(transport: transport, clock: () => _now).issueKey(
        const PushKeyRequest(
          provider: PushProvider.apns,
          token: 'a1b2',
          environment: PushEnvironment.production,
          deployment: _host,
        ),
      );
      expect(outcome, isA<PushKeyGranted>());
      final (uri, body) = transport.requests.single;
      expect(uri.toString(), 'https://notifications.overalls.dev/api/push/v1/keys');
      expect(body, {
        'provider': 'apns',
        'token': 'a1b2',
        'app_id': 'dev.overalls.mila',
        'environment': 'production',
        'deployment': _host,
      });
      expect(
        const PushKeyRequest(
          provider: PushProvider.fcm,
          token: 'secret-token',
          environment: PushEnvironment.production,
          deployment: _host,
        ).toString(),
        isNot(contains('secret-token')),
      );
    });

    test('statuses map to retry, refusal or a strictly decoded key', () {
      PushStepFailure? failure(SusanHttpResponse r) => switch (classifyPushKeyReply(r, _now)) {
        PushKeyRefused(:final failure) => failure,
        PushKeyGranted() => null,
      };
      expect(failure(_granted()), isNull);
      expect(failure(const SusanHttpResponse(503, [])), PushStepFailure.transient);
      expect(failure(const SusanHttpResponse(429, [])), PushStepFailure.transient);
      for (final status in [400, 401, 403, 404, 410, 413, 302]) {
        expect(failure(SusanHttpResponse(status, const [])), PushStepFailure.refused);
      }
      expect(failure(_granted(expires: '2026-10-18T11:00:00Z')), PushStepFailure.protocol);
      expect(failure(_granted(expires: '2029-01-01T00:00:00Z')), PushStepFailure.protocol);
      expect(failure(_granted(expires: '2027-01-16T12:00:00+01:00')), PushStepFailure.protocol);
      final extra = SusanHttpResponse(
        200,
        utf8.encode(
          jsonEncode({
            'push_key': 'cHVzaA',
            'key_id': 'k',
            'expires_at': '2027-01-16T12:00:00Z',
            'debug': 1,
          }),
        ),
      );
      expect(failure(extra), PushStepFailure.protocol);
      expect(parseRetryAfter('120'), const Duration(seconds: 120));
      expect(parseRetryAfter('9999999'), isNull);
      expect(parseRetryAfter('Wed, 21 Oct 2026 07:28:00 GMT'), isNull);
    });

    test('a transport failure is transient and nothing is retried in-request', () async {
      final transport = _RecordingTransport([]);
      final outcome = await SusanClient(transport: transport).issueKey(
        const PushKeyRequest(
          provider: PushProvider.fcm,
          token: 't',
          environment: PushEnvironment.production,
          deployment: _host,
        ),
      );
      expect((outcome as PushKeyRefused).failure, PushStepFailure.transient);
      expect(transport.requests, hasLength(1));
    });

    test('the production transport refuses any other origin', () {
      expect(
        () => HttpSusanTransport().post(Uri.parse('https://evil.example/api/push/v1/keys'), []),
        throwsArgumentError,
      );
    });

    property('arbitrary relay replies never throw', (tc) {
      final body = tc.draw(
        oneOf<List<int>>([
          bytes(maxLength: 64),
          text(maxLength: 80).map(utf8.encode),
          tuple3(text(maxLength: 20), text(maxLength: 20), text(maxLength: 30)).map(
            (v) => utf8.encode(jsonEncode({'push_key': v.$1, 'key_id': v.$2, 'expires_at': v.$3})),
          ),
        ]),
        name: 'body',
      );
      final status = tc.draw(integers(min: 100, max: 599), name: 'status');
      expect(classifyPushKeyReply(SusanHttpResponse(status, body), _now), isA<PushKeyOutcome>());
    });
  });

  group('registrar', () {
    late Directory dir;
    setUp(() async => dir = await _temp());
    tearDown(() => dir.delete(recursive: true));

    Future<(PushRegistration, _FakeSession, FilePokeKeyStore)> run({
      _FakeSession? session,
      _FakePlatform? platform,
      List<SusanHttpResponse>? replies,
    }) async {
      final fake = session ?? _FakeSession();
      final keys = FilePokeKeyStore(Directory('${dir.path}/poke'), random: Random(3));
      final registrar = PushRegistrar(
        deployment: const Deployment(_host),
        platform: platform ?? _FakePlatform(),
        susan: SusanClient(
          transport: _RecordingTransport(replies ?? [_granted()]),
          clock: () => _now,
        ),
        pokeKeys: keys,
        random: Random(1),
        pollBackoff: const Backoff(base: Duration(microseconds: 1), cap: Duration(microseconds: 2)),
      );
      var state = const PushRegistration.initial().apply(PushTick(_now)).apply(const PushEnable());
      for (var i = 0; i < 6; i++) {
        final action = state.next;
        if (action is PushWait) break;
        state = state.took(action);
        final event = await registrar.perform(action, fake);
        if (event != null) state = state.apply(event);
      }
      return (state, fake, keys);
    }

    test('registration sends the push key on stdin and the poke public key in the line', () async {
      final (state, session, keys) = await run();
      expect(state.phase, PushPhase.active);
      expect(state.deviceId, _device);
      final line = session.lines.single;
      final public = encodeBase64UrlUnpadded(await keys.publicKeyFor(_host));
      expect(
        line,
        startsWith(
          'device register --enc-pubkey=$public --json --platform=ios --push-key=- --request-id=porsche-',
        ),
      );
      expect(utf8.decode(session.stdins.single!), 'cHVzaC1rZXk\n');
      expect(line, isNot(contains('cHVzaC1rZXk')));
      expect(File('${dir.path}/poke/$_host.json').statSync().modeString(), 'rw-------');
    });

    test('a lost reply is resolved by polling, never by registering again', () async {
      final (state, session, _) = await run(session: _FakeSession(loseFirstReply: true));
      expect(state.phase, PushPhase.active);
      expect(session.lines.where((l) => l.startsWith('device register')), hasLength(1));
      final requestId = RegExp(r'--request-id=(\S+)').firstMatch(session.lines.first)!.group(1);
      expect(session.lines[1], 'request show --json $requestId');
    });

    test('the operator switch and permission denial stop registration', () async {
      final (disabled, _, _) = await run(session: _FakeSession(registerError: 'push_disabled'));
      expect(disabled.phase, PushPhase.failed);
      expect(disabled.failure, PushFailure.pushDisabled);
      final (denied, session, _) = await run(platform: _FakePlatform(denied: true));
      expect(denied.phase, PushPhase.denied);
      expect(session.lines, isEmpty);
    });

    test('a relay outage waits for its backoff without touching Porsche', () async {
      final (state, session, _) = await run(replies: [const SusanHttpResponse(503, [])]);
      expect(state.phase, PushPhase.issuing);
      expect(state.retryAt, isNotNull);
      expect(session.lines, isEmpty);
    });

    test('turning off removes the device and forgets the poke key', () async {
      final (active, session, keys) = await run();
      final registrar = PushRegistrar(
        deployment: const Deployment(_host),
        platform: _FakePlatform(),
        susan: SusanClient(transport: _RecordingTransport([])),
        pokeKeys: keys,
        random: Random(2),
      );
      var state = active.apply(const PushDisable());
      final action = state.next as PushRemoveDevice;
      state = state.took(action);
      state = state.apply((await registrar.perform(action, session))!);
      expect(state.phase, PushPhase.disabled);
      expect(
        session.lines.last,
        matches(RegExp('^device rm --json --request-id=porsche-[0-9a-f]{32} $_device\$')),
      );
      expect(File('${dir.path}/poke/$_host.json').existsSync(), isFalse);
    });

    test('device ls decodes tolerantly and skips rows without a canonical id', () async {
      final registrar = PushRegistrar(
        deployment: const Deployment(_host),
        platform: _FakePlatform(),
        susan: SusanClient(transport: _RecordingTransport([])),
        pokeKeys: FilePokeKeyStore(dir),
      );
      final devices = (await registrar.listDevices(_FakeSession()))!;
      expect(devices.map((d) => d.id), [_device, '0d9cc041-9db2-4e4c-b28b-1e41d7f472c1']);
      expect(devices.last.platform, 'unknown');
      expect(devices.last.enabled, isFalse);
      expect(decodeDeviceList(const {'items': 'x'}), isNull);
    });
  });

  group('owner-only stores', () {
    late Directory dir;
    setUp(() async => dir = await _temp());
    tearDown(() => dir.delete(recursive: true));

    test('poke keys are per deployment, owner-only and refused when readable', () async {
      final store = FilePokeKeyStore(dir, random: Random(9));
      final a = await store.keyPairFor('a.example.test');
      final b = await store.keyPairFor('b.example.test');
      expect(a.publicKey, isNot(b.publicKey));
      expect((await store.keyPairFor('a.example.test')).publicKey, a.publicKey);
      chmodPath('${dir.path}/a.example.test.json', 0x1A4); // 0644
      expect(() => store.keyPairFor('a.example.test'), throwsA(isA<FileSystemException>()));
      // A poke sealed to the stored key opens with it.
      final poke = sealPoke(
        plaintext: Uint8List.fromList(
          utf8.encode('{"kind":"needs_input","route":"/threads","v":1}'),
        ),
        host: 'b.example.test',
        devicePublic: b.publicKey,
        ephemeralPrivate: Uint8List.fromList(List<int>.filled(32, 7)),
        nonce: Uint8List.fromList(List<int>.filled(12, 1)),
      );
      expect(openPoke(poke, host: 'b.example.test', keys: b), isA<PokeOpened>());
      expect(() => store.publicKeyFor('Not A Host'), throwsArgumentError);
    });

    test('snapshots are owner-only, newest wins, and a readable file is discarded', () async {
      final store = FileSnapshotStore(dir);
      final machine = decodeMachine({
        'id': '0d9cc041-9db2-4e4c-b28b-1e41d7f472c1',
        'name': 'dev-box',
        'desired_state': 'running',
        'observed_state': 'running',
        'permissions': {'read': true},
      });
      MachineSnapshot at(int minute, List<Machine> machines) => MachineSnapshot(
        host: _host,
        port: 2222,
        savedAt: _now.add(Duration(minutes: minute)),
        machines: machines,
      );
      await store.write(at(5, [machine]));
      await store.write(at(1, const []));
      final read = (await store.read(const Deployment(_host, port: 2222)))!;
      expect(read.machines.single.name, 'dev-box');
      final file = File('${dir.path}/${_host}_2222.json');
      expect(file.statSync().modeString(), 'rw-------');
      expect(Directory(dir.path).statSync().modeString(), 'rwx------');
      expect(await store.read(const Deployment(_host)), isNull);
      chmodPath(file.path, 0x1A4);
      expect(await store.read(const Deployment(_host, port: 2222)), isNull);
      expect(file.existsSync(), isFalse);
    });
  });
}
