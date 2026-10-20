// Ways out of failed and empty lists, read markers shared with the thread
// lists, and the notifications device list's refresh and labels, through the
// real screens and the fake Porsche.
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mila/app.dart';
import 'package:mila/features/notifications/device_label.dart';
import 'package:mila/features/notifications/push_controller.dart';
import 'package:mila/features/routes.dart';
import 'package:mila/features/session.dart';
import 'package:mila/features/sign_in_screen.dart';
import 'package:mila/transport/fake_porsche.dart';
import 'package:mila_core/mila_core.dart';
import 'package:mila_transport/mila_transport.dart';

const String _host = 'overalls.example';
const Deployment _deployment = Deployment(_host);
const String _box = '0d9cc041-9db2-4e4c-b28b-1e41d7f472c1';
const String _thread = '019a0f71-aaaa-4bbb-8ccc-ddddeeeeffff';
const String _pushKey = 'pk_live_secret-push-key';

final class _Push implements PushPlatform {
  @override
  DevicePlatform get device => DevicePlatform.ios;

  @override
  Future<PushEnvironment> environment() async => PushEnvironment.development;

  @override
  Future<String> token() async => 'apns-device-token-0123456789abcdef';

  @override
  Stream<String> get tokenChanges => const Stream.empty();
}

final class _PokeKeys implements PokeKeyStore {
  final Map<String, Uint8List> keys = {};

  @override
  Future<Uint8List> publicKeyFor(String host) async =>
      keys.putIfAbsent(host, () => PokeKeyPair.generate(Random(host.length)).publicKey);

  @override
  Future<void> delete(String host) async => keys.remove(host);
}

final class _Susan implements SusanTransport {
  @override
  Future<SusanHttpResponse> post(Uri uri, List<int> body) async => SusanHttpResponse(
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

final class _App {
  _App(this.fake, this.router, this.opened);
  final FakeDeployment fake;
  final GoRouter router;
  final List<Uri> opened;
}

Future<_App> _signedIn(WidgetTester tester, {List<Override> overrides = const []}) async {
  tester.view.physicalSize = const Size(1200, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final fake = FakeDeployment(_host, approved: true, machines: [FakeMachine(_box, 'dev-box')]);
  final opened = <Uri>[];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        connectorProvider.overrideWithValue(FakePorscheConnector({_host: fake})),
        openExternalProvider.overrideWithValue((uri) async => opened.add(uri)),
        ...overrides,
      ],
      child: const MilaApp(),
    ),
  );
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const Key('deployment-host')), _host);
  await tester.tap(find.byKey(const Key('add-deployment')));
  await tester.pumpAndSettle();
  await tester.pumpAndSettle();
  final container = ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
  return _App(fake, container.read(routerProvider), opened);
}

Future<void> _go(WidgetTester tester, _App app, String path) async {
  app.router.go(path);
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(Key(key)));
  await tester.tap(find.byKey(Key(key)));
  await tester.pumpAndSettle();
}

void main() {
  group('failures offer Try again', () {
    for (final (name, command, path, failed, retry) in [
      ('recent threads', 'thread ls', threadsPath(_deployment), 'recent-failed', 'recent-retry'),
      (
        'machine threads',
        'thread ls',
        machineThreadsPath(_deployment, _box),
        'threads-failed',
        'threads-retry',
      ),
      (
        'terminals',
        'terminal ls',
        machineTerminalsPath(_deployment, _box),
        'terminals-failed',
        'terminals-retry',
      ),
      ('web', 'web show', machineWebPath(_deployment, _box), 'web-failed', 'web-retry'),
    ]) {
      testWidgets('$name reads again and recovers', (tester) async {
        final app = await _signedIn(tester);
        if (command == 'web show') app.fake.webs[_box] = FakeWeb(_box);
        app.fake.failing.add(command);
        await _go(tester, app, path);
        expect(find.byKey(Key(failed)), findsOneWidget);

        app.fake.failing.clear();
        final before = app.fake.received.where((l) => l.startsWith(command)).length;
        await _tap(tester, retry);
        expect(app.fake.received.where((l) => l.startsWith(command)).length, greaterThan(before));
        expect(find.byKey(Key(failed)), findsNothing);
        await _go(tester, app, machinesPath(_deployment));
      });
    }

    testWidgets('a thread that failed to load reads again', (tester) async {
      final app = await _signedIn(tester);
      app.fake.threads[_thread] = FakeThread(_thread, 'Fix the build', machineId: _box)
        ..add('prompt', {'prompt': 'Why does CI fail?'});
      app.fake.failing.add('thread show');
      await _go(tester, app, machineThreadPath(_deployment, _box, _thread));
      expect(find.byKey(const Key('thread-failed')), findsOneWidget);

      app.fake.failing.clear();
      await _tap(tester, 'thread-retry');
      expect(find.byKey(const Key('thread-failed')), findsNothing);
      expect(find.text('Why does CI fail?'), findsOneWidget);
      await _go(tester, app, machinesPath(_deployment));
    });
  });

  testWidgets('an empty Recent list says where threads start and opens that page', (tester) async {
    final app = await _signedIn(tester);
    await _go(tester, app, threadsPath(_deployment));
    expect(find.byKey(const Key('recent-empty-hint')), findsOneWidget);
    await _tap(tester, 'recent-start-browser');
    expect(app.opened.last, Uri.parse('https://$_host/threads/new'));

    await _go(tester, app, machineThreadsPath(_deployment, _box));
    expect(find.byKey(const Key('threads-empty-hint')), findsOneWidget);
    await _go(tester, app, machinesPath(_deployment));
  });

  testWidgets('reading a thread clears its unread count in the open list at once', (tester) async {
    final app = await _signedIn(tester);
    app.fake.threads[_thread] = FakeThread(_thread, 'Fix the build', machineId: _box)
      ..add('prompt', {'prompt': 'Why does CI fail?'})
      ..add('assistant', {'text': 'A missing import.'});
    await _go(tester, app, machineThreadsPath(_deployment, _box));
    expect(find.byKey(const Key('thread-unread-$_thread')), findsOneWidget);
    final listReads = app.fake.received.where((l) => l.startsWith('thread ls')).length;

    // The list stays alive underneath while the thread is pushed over it.
    unawaited(app.router.push(machineThreadPath(_deployment, _box, _thread)));
    await tester.pumpAndSettle();
    expect(app.fake.threads[_thread]!.readSequence, 2);
    app.router.pop();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('thread-unread-$_thread')), findsNothing);
    expect(app.fake.received.where((l) => l.startsWith('thread ls')).length, listReads);
    await _go(tester, app, machinesPath(_deployment));
  });

  group('notification devices', () {
    testWidgets('register with this device\'s label, show it, and refresh on request', (
      tester,
    ) async {
      final app = await _signedIn(
        tester,
        overrides: [
          pushPlatformProvider.overrideWithValue(_Push()),
          pokeKeyStoreProvider.overrideWithValue(_PokeKeys()),
          susanClientProvider.overrideWithValue(SusanClient(transport: _Susan())),
          deviceLabelProvider.overrideWithValue('Studio Mac'),
        ],
      );
      await _go(tester, app, notificationsPath(_deployment));
      await _tap(tester, 'push-on');
      final register = app.fake.received.singleWhere((l) => l.startsWith('device register'));
      expect(register, contains('Studio Mac'));
      final device = app.fake.devices.values.single;
      expect(device.label, 'Studio Mac');
      expect(find.byKey(Key('device-label-${device.id}')), findsOneWidget);

      // A device registered elsewhere appears on refresh.
      app.fake.devices['a1b2c3d4-0000-4000-8000-0000000000ff'] = FakeDevice(
        'a1b2c3d4-0000-4000-8000-0000000000ff',
        'android',
        'key',
        label: 'Pixel',
      );
      final lists = app.fake.received.where((l) => l == 'device ls --json').length;
      await _tap(tester, 'notifications-refresh');
      expect(app.fake.received.where((l) => l == 'device ls --json').length, lists + 1);
      expect(find.text('Pixel'), findsOneWidget);
      await _go(tester, app, machinesPath(_deployment));
    });
  });

  group('device labels', () {
    test('host names drop .local and placeholders', () {
      expect(deviceLabelFromHostname('Studio-Mac.local'), 'Studio-Mac');
      expect(deviceLabelFromHostname('localhost'), isNull);
      expect(deviceLabelFromHostname('  '), isNull);
    });

    test('labels fit the catalog rule: one line, at most 64 bytes, whole characters', () {
      expect(deviceLabel('a\nb\tc'), 'a b c');
      expect(deviceLabel('\u0000'), isNull);
      final long = deviceLabel('é' * 40)!;
      expect(utf8.encode(long).length, lessThanOrEqualTo(64));
      expect(long, 'é' * 32);
      for (final label in ['Studio Mac', long]) {
        expect(
          validateCommand(
            PorscheCommand(
              'device register',
              options: {'platform': 'ios', 'push-key': '-', 'enc-pubkey': 'x' * 43, 'label': label},
            ),
          ),
          isNull,
        );
      }
      expect(
        validateCommand(
          PorscheCommand(
            'device register',
            options: {
              'platform': 'ios',
              'push-key': '-',
              'enc-pubkey': 'x' * 43,
              'label': 'a' * 65,
            },
          ),
        ),
        isNotNull,
      );
    });
  });
}
