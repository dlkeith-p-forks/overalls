import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mila/app.dart';
import 'package:mila/features/routes.dart';
import 'package:mila/features/session.dart';
import 'package:mila/features/sign_in_screen.dart';
import 'package:mila/transport/fake_porsche.dart';

const String _host = 'overalls.example';
const String _box = '0d9cc041-9db2-4e4c-b28b-1e41d7f472c1';

Future<FakeDeployment> _pumpApp(WidgetTester tester, {bool approved = false}) async {
  final fake = FakeDeployment(
    _host,
    approved: approved,
    machines: [
      FakeMachine(_box, 'dev-box'),
      FakeMachine(
        '6f1e2d3c-4b5a-4987-8a6b-5c4d3e2f1a0b',
        'scratch',
        desired: 'stopped',
        observed: 'stopped',
      ),
    ],
  );
  _opened.clear();
  final opened = _opened;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        connectorProvider.overrideWithValue(FakePorscheConnector({_host: fake})),
        openExternalProvider.overrideWithValue((uri) async => opened.add(uri)),
      ],
      child: const MilaApp(),
    ),
  );
  await tester.pumpAndSettle();
  return fake;
}

final List<Uri> _opened = [];

Future<void> _addDeployment(WidgetTester tester, String host) async {
  await tester.enterText(find.byKey(const Key('deployment-host')), host);
  await tester.tap(find.byKey(const Key('add-deployment')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('an invalid host is refused before any connection', (tester) async {
    final fake = await _pumpApp(tester);
    await _addDeployment(tester, 'Not A Host!');
    expect(find.text('Enter a host name such as overalls.example.'), findsOneWidget);
    expect(fake.received, isEmpty);
  });

  testWidgets('browser approval leads to the machine list, pinned first', (tester) async {
    final fake = await _pumpApp(tester);
    fake.machines.last.pinned = true;
    await _addDeployment(tester, _host);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('sign-in-fingerprint')), findsOneWidget);
    expect(fake.received.single, 'whoami --json');
    expect(_opened, hasLength(1), reason: 'adding a deployment opens its approval link once');
    expect(_opened.single.scheme, 'https');
    await tester.tap(find.byKey(const Key('sign-in-open')));
    expect(_opened, hasLength(2), reason: 'the button reopens the same link');
    expect(_opened.last, _opened.first);

    fake.approved = true;
    await tester.pump(approvalPollInterval);
    await tester.pumpAndSettle();
    expect(find.text('Machines'), findsOneWidget);
    expect(find.text('[running]'), findsOneWidget);
    expect(find.text('[stopped]'), findsOneWidget);
    final scratch = tester.getTopLeft(find.text('scratch'));
    final devBox = tester.getTopLeft(find.text('dev-box'));
    expect(scratch.dy, lessThan(devBox.dy));
    expect(fake.received, contains('ls --json'));
  });

  testWidgets('a lifecycle action is submitted once with a request id', (tester) async {
    final fake = await _pumpApp(tester, approved: true);
    await _addDeployment(tester, _host);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('action-stop-$_box')));
    await tester.pumpAndSettle();
    final stops = fake.received.where((line) => line.startsWith('stop '));
    expect(stops, hasLength(1));
    expect(stops.single, matches(RegExp(r'--request-id=porsche-[0-9a-f]{32}')));
    expect(stops.single, contains('--no-wait'));
    expect(find.text('Done.'), findsOneWidget);
    expect(find.text('[stopped]'), findsNWidgets(2));
  });

  testWidgets('deleting asks for confirmation and cancelling sends nothing', (tester) async {
    final fake = await _pumpApp(tester, approved: true);
    await _addDeployment(tester, _host);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('action-delete-$_box')));
    await tester.tap(find.byKey(const Key('action-delete-$_box')));
    await tester.pumpAndSettle();
    expect(find.text('Delete dev-box and its disk? This cannot be undone.'), findsOneWidget);
    await tester.tap(find.text('CANCEL'));
    await tester.pumpAndSettle();
    expect(fake.received.where((line) => line.startsWith('rm ')), isEmpty);
  });

  testWidgets('a host with no deployment is reported unreachable, not as an expired link', (
    tester,
  ) async {
    await _pumpApp(tester);
    await _addDeployment(tester, 'not-a-deployment.example');
    await tester.pumpAndSettle();
    expect(find.text('The deployment cannot be reached.'), findsOneWidget);
    expect(find.byKey(const Key('sign-in-expired')), findsNothing);
    expect(_opened, isEmpty, reason: 'no approval link, so no browser');
  });

  testWidgets('an untrusted host certificate stops sign-in without fallback', (tester) async {
    final fake = await _pumpApp(tester);
    fake.untrusted = true;
    await _addDeployment(tester, _host);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sign-in-failed')), findsOneWidget);
    expect(fake.received, isEmpty);
  });

  testWidgets('removing a deployment asks first, then forgets it', (tester) async {
    await _pumpApp(tester, approved: true);
    await _addDeployment(tester, _host);
    await tester.pumpAndSettle();
    final router = GoRouter.of(tester.element(find.byType(Scaffold).first));
    router.go(settingsPath);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('remove-deployment-$_host')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('CANCEL'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('remove-deployment-$_host')), findsOneWidget);

    await tester.tap(find.byKey(const Key('remove-deployment-$_host')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-deployment-remove')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('remove-deployment-$_host')), findsNothing);
    router.go(deploymentsPath);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('deployment-$_host')), findsNothing);
  });

  testWidgets('dark appearance applies the dark tokens', (tester) async {
    await _pumpApp(tester);
    await tester.tap(find.byKey(const Key('open-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('appearance-dark')));
    await tester.pumpAndSettle();
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    final theme = Theme.of(tester.element(find.byWidget(scaffold)));
    expect(theme.brightness, Brightness.dark);
    expect(theme.scaffoldBackgroundColor.toARGB32(), 0xFF000000);
  });
}
