// Notifications, app lock and the offline snapshot through the real
// screens, the fake Porsche and fake platform services.
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:mila/app.dart';
import 'package:mila/features/lock/app_lock_controller.dart';
import 'package:mila/features/machines/machines_controller.dart';
import 'package:mila/features/notifications/push_controller.dart';
import 'package:mila/features/preferences.dart';
import 'package:mila/features/session.dart';
import 'package:mila/features/sign_in_screen.dart';
import 'package:mila/transport/fake_porsche.dart';
import 'package:mila/ui/widgets.dart';
import 'package:mila_core/mila_core.dart';
import 'package:mila_transport/mila_transport.dart';

const String _host = 'overalls.example';
const String _box = '0d9cc041-9db2-4e4c-b28b-1e41d7f472c1';
const String _pushKey = 'pk_live_secret-push-key';
const String _token = 'apns-device-token-0123456789abcdef';

final class _FakePush implements PushPlatform {
  _FakePush({this.denied = false});

  final bool denied;
  final StreamController<String> changes = StreamController<String>.broadcast();

  @override
  DevicePlatform get device => DevicePlatform.ios;

  @override
  Future<PushEnvironment> environment() async => PushEnvironment.development;

  @override
  Future<String> token() async {
    if (denied) throw const PushPermissionDeniedException();
    return _token;
  }

  @override
  Stream<String> get tokenChanges => changes.stream;
}

final class _FakePokeKeys implements PokeKeyStore {
  final Map<String, Uint8List> keys = {};
  final List<String> deleted = [];

  @override
  Future<Uint8List> publicKeyFor(String host) async =>
      keys.putIfAbsent(host, () => PokeKeyPair.generate(Random(host.length)).publicKey);

  @override
  Future<void> delete(String host) async {
    keys.remove(host);
    deleted.add(host);
  }
}

final class _FakeSusan implements SusanTransport {
  final List<Map<String, Object?>> requests = [];
  int status = 200;

  @override
  Future<SusanHttpResponse> post(Uri uri, List<int> body) async {
    requests.add(jsonDecode(utf8.decode(body)) as Map<String, Object?>);
    if (status != 200) return SusanHttpResponse(status, utf8.encode('{}'));
    return SusanHttpResponse(
      200,
      utf8.encode(
        jsonEncode({
          'push_key': _pushKey,
          'key_id': 'key-1',
          'expires_at': DateTime.now().toUtc().add(const Duration(days: 90)).toIso8601String(),
        }),
      ),
    );
  }
}

final class _FakeAuthenticator implements LockAuthenticator {
  bool succeed = true;
  int prompts = 0;

  @override
  Future<LockAvailability> availability() async => LockAvailability.available;

  @override
  Future<bool> authenticate(String reason) async {
    prompts++;
    return succeed;
  }
}

final class _MemorySnapshots implements SnapshotStore {
  final Map<String, MachineSnapshot> saved = {};

  @override
  Future<MachineSnapshot?> read(Deployment deployment) async => saved[deployment.toString()];

  @override
  Future<void> write(MachineSnapshot snapshot) async {
    final key = Deployment(snapshot.host, port: snapshot.port).toString();
    saved[key] = mergeSnapshot(saved[key], snapshot);
  }

  @override
  Future<void> delete(Deployment deployment) async => saved.remove(deployment.toString());
}

FakeDeployment _deployment() =>
    FakeDeployment(_host, approved: true, machines: [FakeMachine(_box, 'dev-box')]);

Future<List<Uri>> _pump(
  WidgetTester tester, {
  required Map<String, FakeDeployment> deployments,
  List<Override> overrides = const [],
  PreferencesStore? preferences,
}) async {
  final opened = <Uri>[];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        connectorProvider.overrideWithValue(FakePorscheConnector(deployments)),
        openExternalProvider.overrideWithValue((uri) async => opened.add(uri)),
        preferencesStoreProvider.overrideWithValue(preferences ?? MemoryPreferences()),
        ...overrides,
      ],
      child: const MilaApp(),
    ),
  );
  await tester.pumpAndSettle();
  return opened;
}

Future<void> _signIn(WidgetTester tester) async {
  await tester.enterText(find.byKey(const Key('deployment-host')), _host);
  await tester.tap(find.byKey(const Key('add-deployment')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('sign-in-start')));
  await tester.pumpAndSettle();
}

Future<void> _openNotifications(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('open-notifications')));
  await tester.pumpAndSettle();
}

String _state(WidgetTester tester) => tester
    .widget<Text>(
      find.descendant(of: find.byKey(const Key('push-state')), matching: find.byType(Text)),
    )
    .data!;

void main() {
  testWidgets('without a push service the screen says so and links to the docs', (tester) async {
    final fake = _deployment();
    final opened = await _pump(tester, deployments: {_host: fake});
    await _signIn(tester);
    await _openNotifications(tester);
    expect(find.text('Notifications are not available on this platform.'), findsOneWidget);
    expect(find.byKey(const Key('push-on')), findsNothing);
    await tester.tap(find.byKey(const Key('notifications-docs')));
    await tester.pumpAndSettle();
    expect(opened, [Uri.parse('https://$_host/docs/notifications')]);
    expect(fake.received.where((l) => l.startsWith('device')), isEmpty);
  });

  testWidgets('turning notifications on registers once; the key stays off the line', (
    tester,
  ) async {
    final fake = _deployment();
    final susan = _FakeSusan();
    final keys = _FakePokeKeys();
    final preferences = MemoryPreferences();
    await _pump(
      tester,
      deployments: {_host: fake},
      preferences: preferences,
      overrides: [
        pushPlatformProvider.overrideWithValue(_FakePush()),
        pokeKeyStoreProvider.overrideWithValue(keys),
        susanClientProvider.overrideWithValue(SusanClient(transport: susan)),
      ],
    );
    await _signIn(tester);
    await _openNotifications(tester);
    expect(_state(tester), contains('off'));
    await tester.tap(find.byKey(const Key('push-on')));
    await tester.pumpAndSettle();

    expect(_state(tester), contains('on'));
    expect(susan.requests.single, {
      'provider': 'apns',
      'token': _token,
      'app_id': 'dev.overalls.mila',
      'environment': 'development',
      'deployment': _host,
    });
    final registers = fake.received.where((l) => l.startsWith('device register'));
    expect(registers, hasLength(1));
    expect(registers.single, contains('--push-key=-'));
    expect(registers.single, matches(RegExp(r'--request-id=porsche-[0-9a-f]{32}')));
    expect(
      registers.single,
      contains('--enc-pubkey=${encodeBase64UrlUnpadded(keys.keys[_host]!)}'),
    );
    expect(fake.pushKeys, [_pushKey]);
    for (final line in fake.received) {
      expect(line, isNot(contains(_pushKey)));
      expect(line, isNot(contains(_token)));
    }
    final device = fake.devices.values.single;
    expect(find.byKey(Key('device-${device.id}')), findsOneWidget);
    expect(find.textContaining('this device'), findsOneWidget);
    // The persisted record holds a digest, never the token or the push key.
    final record = jsonEncode(preferences.values);
    expect(record, isNot(contains(_token)));
    expect(record, isNot(contains(_pushKey)));
    expect(record, contains(device.id));

    await tester.tap(find.byKey(const Key('push-off')));
    await tester.pumpAndSettle();
    expect(fake.devices, isEmpty);
    expect(keys.deleted, [_host]);
    expect(_state(tester), contains('off'));
  });

  testWidgets('a deployment with push disabled is explained, not retried', (tester) async {
    final fake = _deployment()..pushDisabled = true;
    await _pump(
      tester,
      deployments: {_host: fake},
      overrides: [
        pushPlatformProvider.overrideWithValue(_FakePush()),
        pokeKeyStoreProvider.overrideWithValue(_FakePokeKeys()),
        susanClientProvider.overrideWithValue(SusanClient(transport: _FakeSusan())),
      ],
    );
    await _signIn(tester);
    await _openNotifications(tester);
    await tester.tap(find.byKey(const Key('push-on')));
    await tester.pumpAndSettle();
    expect(find.text('This deployment has turned notifications off.'), findsOneWidget);
    expect(fake.received.where((l) => l.startsWith('device register')), hasLength(1));
    await tester.pump(const Duration(minutes: 5));
    await tester.pumpAndSettle();
    expect(fake.received.where((l) => l.startsWith('device register')), hasLength(1));
  });

  testWidgets('denied permission and refused relay keys say why', (tester) async {
    final fake = _deployment();
    final susan = _FakeSusan()..status = 403;
    await _pump(
      tester,
      deployments: {_host: fake},
      overrides: [
        pushPlatformProvider.overrideWithValue(_FakePush()),
        pokeKeyStoreProvider.overrideWithValue(_FakePokeKeys()),
        susanClientProvider.overrideWithValue(SusanClient(transport: susan)),
      ],
    );
    await _signIn(tester);
    await _openNotifications(tester);
    await tester.tap(find.byKey(const Key('push-on')));
    await tester.pumpAndSettle();
    expect(
      find.text('The deployment or the notification relay refused this device.'),
      findsOneWidget,
    );
    expect(fake.received.where((l) => l.startsWith('device register')), isEmpty);
  });

  testWidgets('blocked system permission is explained without contacting anyone', (tester) async {
    final fake = _deployment();
    final susan = _FakeSusan();
    await _pump(
      tester,
      deployments: {_host: fake},
      overrides: [
        pushPlatformProvider.overrideWithValue(_FakePush(denied: true)),
        pokeKeyStoreProvider.overrideWithValue(_FakePokeKeys()),
        susanClientProvider.overrideWithValue(SusanClient(transport: susan)),
      ],
    );
    await _signIn(tester);
    await _openNotifications(tester);
    await tester.tap(find.byKey(const Key('push-on')));
    await tester.pumpAndSettle();
    expect(find.text('Notifications are blocked in the system settings.'), findsOneWidget);
    expect(susan.requests, isEmpty);
    expect(fake.received.where((l) => l.startsWith('device register')), isEmpty);
  });

  testWidgets('a device revoked elsewhere shows as revoked', (tester) async {
    final fake = _deployment();
    await _pump(
      tester,
      deployments: {_host: fake},
      overrides: [
        pushPlatformProvider.overrideWithValue(_FakePush()),
        pokeKeyStoreProvider.overrideWithValue(_FakePokeKeys()),
        susanClientProvider.overrideWithValue(SusanClient(transport: _FakeSusan())),
      ],
    );
    await _signIn(tester);
    await _openNotifications(tester);
    await tester.tap(find.byKey(const Key('push-on')));
    await tester.pumpAndSettle();
    fake.devices.clear();
    final container = ProviderScope.containerOf(tester.element(find.byType(MilaApp)));
    await container.read(pushProvider(const Deployment(_host)).notifier).refreshDevices();
    await tester.pumpAndSettle();
    expect(_state(tester), contains('revoked'));
    expect(find.byKey(const Key('push-on')), findsOneWidget);
  });

  testWidgets('on a platform without biometrics the lock setting says so', (tester) async {
    await _pump(tester, deployments: {});
    await tester.tap(find.byKey(const Key('open-settings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('lock-unavailable')), findsOneWidget);
    expect(find.byKey(const Key('lock-on')), findsNothing);
    expect(find.byKey(const Key('lock-screen')), findsNothing);
  });

  testWidgets('the lock covers Mila after backgrounding and opens on success', (tester) async {
    final auth = _FakeAuthenticator();
    final preferences = MemoryPreferences();
    await _pump(
      tester,
      deployments: {},
      preferences: preferences,
      overrides: [lockAuthenticatorProvider.overrideWithValue(auth)],
    );
    await tester.tap(find.byKey(const Key('open-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('lock-on')));
    await tester.pumpAndSettle();
    expect(auth.prompts, 1);
    expect(preferences.values['lock.enabled'], true);

    final binding = tester.binding;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('lock-screen')), findsOneWidget);
    expect(find.text('App lock'), findsNothing);

    auth.succeed = false;
    await tester.tap(find.byKey(const Key('unlock')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('lock-failed')), findsOneWidget);

    auth.succeed = true;
    await tester.tap(find.byKey(const Key('unlock')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('lock-screen')), findsNothing);
    expect(find.text('App lock'), findsOneWidget);
  });

  testWidgets('a saved lock is closed from the first frame after restart', (tester) async {
    await _pump(
      tester,
      deployments: {},
      preferences: MemoryPreferences({'lock.enabled': true}),
      overrides: [lockAuthenticatorProvider.overrideWithValue(_FakeAuthenticator())],
    );
    expect(find.byKey(const Key('lock-screen')), findsOneWidget);
  });

  testWidgets('deployments persist and the last list shows while offline', (tester) async {
    final fake = _deployment();
    final preferences = MemoryPreferences();
    final snapshots = _MemorySnapshots();
    final overrides = [snapshotStoreProvider.overrideWithValue(snapshots)];
    await _pump(tester, deployments: {_host: fake}, preferences: preferences, overrides: overrides);
    await _signIn(tester);
    expect(find.text('dev-box'), findsOneWidget);
    expect(snapshots.saved[_host]!.machines.single.id, _box);
    expect(preferences.values['deployments'], [_host]);
    // Snapshots hold machine rows only.
    expect(utf8.decode(encodeSnapshot(snapshots.saved[_host]!)), isNot(contains('approval')));

    // Restart with the deployment unreachable.
    await tester.pumpWidget(const SizedBox());
    await _pump(tester, deployments: {}, preferences: preferences, overrides: overrides);
    await tester.tap(find.byKey(const Key('deployment-$_host')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sign-in-saved-list')));
    await tester.pumpAndSettle();
    expect(find.text('dev-box'), findsOneWidget);
    expect(find.byKey(const Key('machines-saved-at')), findsOneWidget);
    expect(find.byKey(const Key('machines-offline')), findsOneWidget);
    final stop = tester.widget<ConsoleButton>(find.byKey(const Key('action-stop-$_box')));
    expect(stop.onPressed, isNull);
  });
}
