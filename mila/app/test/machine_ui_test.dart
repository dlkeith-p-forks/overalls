import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mila/app.dart';
import 'package:mila/features/routes.dart';
import 'package:mila/features/session.dart';
import 'package:mila/features/settings_screen.dart';
import 'package:mila/transport/fake_porsche.dart';
import 'package:mila_transport/mila_transport.dart';

const String _host = 'overalls.example';
const String _box = '0d9cc041-9db2-4e4c-b28b-1e41d7f472c1';
const String _other = '1e0dd152-0eb3-4f5d-a39d-2f52e8a583d2';
const String _absent = '2f1ee263-1fc4-4a6e-b4ae-3a63f9b694e3';

Future<FakeDeployment> _signedIn(WidgetTester tester, {int pageSize = 50}) async {
  tester.view.physicalSize = const Size(900, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final fake = FakeDeployment(
    _host,
    approved: true,
    machines: [FakeMachine(_box, 'dev-box'), FakeMachine(_other, 'zz-box')],
  )..pageSize = pageSize;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        connectorProvider.overrideWithValue(FakePorscheConnector({_host: fake})),
      ],
      child: const MilaApp(),
    ),
  );
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const Key('deployment-host')), _host);
  await tester.tap(find.byKey(const Key('add-deployment')));
  await tester.pumpAndSettle();
  await tester.pumpAndSettle();
  return fake;
}

Future<void> _go(WidgetTester tester, String path) async {
  ProviderScope.containerOf(tester.element(find.byType(MaterialApp))).read(routerProvider).go(path);
  await tester.pumpAndSettle();
}

Iterable<String> _sent(FakeDeployment fake, String prefix) =>
    fake.received.where((line) => line.startsWith('$prefix '));

void main() {
  testWidgets('the machine list loads further pages on request', (tester) async {
    final fake = await _signedIn(tester, pageSize: 1);
    expect(find.text('dev-box'), findsOneWidget);
    expect(find.text('zz-box'), findsNothing);
    await tester.tap(find.byKey(const Key('machines-more')));
    await tester.pumpAndSettle();
    expect(_sent(fake, 'ls'), contains(contains('--after=$_box')));
    expect(find.text('zz-box'), findsOneWidget);
    expect(find.byKey(const Key('machines-more')), findsNothing);
  });

  testWidgets('a machine beyond the loaded page is read with show', (tester) async {
    final fake = await _signedIn(tester, pageSize: 1);
    await _go(tester, machinePath(const Deployment(_host), _other));
    expect(_sent(fake, 'show'), [contains(_other)]);
    expect(find.byKey(const Key('machine-id')), findsOneWidget);
    expect(find.text(_other), findsOneWidget);
    expect(find.text('zz-box'), findsOneWidget);
  });

  testWidgets('a machine the deployment does not show says so', (tester) async {
    await _signedIn(tester);
    await _go(tester, machinePath(const Deployment(_host), _absent));
    expect(find.text('This machine is not available.'), findsOneWidget);
  });

  testWidgets('the Info tab shows hidden fields and offers lifecycle actions', (tester) async {
    final fake = await _signedIn(tester);
    await _go(tester, machinePath(const Deployment(_host), _box));
    expect(find.text('x86_64'), findsOneWidget);
    expect(find.text('Yours'), findsOneWidget);
    expect(find.text('2026-10-01 09:30 UTC'), findsOneWidget);
    await tester.tap(find.byKey(const Key('action-stop-$_box')));
    await tester.pumpAndSettle();
    expect(_sent(fake, 'stop'), hasLength(1));

    await tester.tap(find.byKey(const Key('action-delete-$_box')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-delete')));
    await tester.pumpAndSettle();
    expect(_sent(fake, 'rm'), hasLength(1));
    expect(find.byKey(const Key('machines-refresh')), findsOneWidget);
    expect(find.text('dev-box'), findsNothing);
  });

  testWidgets('a failed machine shows its reason on the list row', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    final fake = await _signedIn(tester);
    fake.machines.first
      ..observed = 'failed'
      ..failureReason = 'image_unavailable';
    await tester.tap(find.byKey(const Key('machines-refresh')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('machine-failure-$_box')), findsOneWidget);
    expect(find.text('Failure: image_unavailable'), findsOneWidget);
  });

  testWidgets('a failed clone can be retried, naming the original request', (tester) async {
    final fake = await _signedIn(tester);
    fake.failClones = true;
    await _go(tester, machinePath(const Deployment(_host), _box));
    await tester.tap(find.byKey(const Key('machine-clone')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('machine-form-name')), 'copy');
    await tester.tap(find.byKey(const Key('machine-form-submit')));
    await tester.pumpAndSettle();
    final clone = _sent(fake, 'clone').single;
    final original = RegExp(r'--request-id=(\S+)').firstMatch(clone)!.group(1)!;
    expect(find.text('The request failed.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('request-retry-$_box')));
    await tester.pumpAndSettle();
    final retry = _sent(fake, 'request retry').single;
    expect(retry, endsWith(' $original'));
    expect(retry, isNot(contains('--request-id=$original')));
    expect(fake.machines.map((m) => m.name), contains('copy'));
    expect(find.byKey(const Key('request-retry-$_box')), findsNothing);
  });

  testWidgets('the new machine form sends a chosen image and team', (tester) async {
    final fake = await _signedIn(tester);
    await tester.tap(find.byKey(const Key('machine-new')));
    await tester.pumpAndSettle();
    expect(find.text('DEFAULT'), findsOneWidget);
    await tester.tap(find.byKey(const Key('machine-form-image-2')));
    await tester.tap(find.byKey(const Key('machine-form-team-1')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('machine-form-submit')));
    await tester.pumpAndSettle();
    final line = _sent(fake, 'new').single;
    expect(line, contains('--image=sha256:${'b' * 64}'));
    expect(line, contains('--team=platform'));
  });

  testWidgets('the default choices send neither image nor team', (tester) async {
    final fake = await _signedIn(tester);
    await tester.tap(find.byKey(const Key('machine-new')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('machine-form-submit')));
    await tester.pumpAndSettle();
    final line = _sent(fake, 'new').single;
    expect(line, isNot(contains('--image')));
    expect(line, isNot(contains('--team')));
  });

  testWidgets('settings are reachable from the machine list and machine pages', (tester) async {
    await _signedIn(tester);
    await tester.tap(find.byKey(const Key('machines-settings')));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    await _go(tester, machinePath(const Deployment(_host), _box));
    expect(find.byKey(const Key('machine-refresh')), findsOneWidget);
    await tester.tap(find.byKey(const Key('machine-settings')));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
  });
}
