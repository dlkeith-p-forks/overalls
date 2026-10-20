import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mila/app.dart';
import 'package:mila/features/routes.dart';
import 'package:mila/features/session.dart';
import 'package:mila/features/sign_in_screen.dart';
import 'package:mila/transport/fake_porsche.dart';
import 'package:mila_core/mila_core.dart';
import 'package:mila_transport/mila_transport.dart';

const String _host = 'overalls.example';
const String _ownKey = '5e1f0000-0000-4000-8000-000000000001';
const String _laptopKey = '5e1f0000-0000-4000-8000-000000000002';
final Deployment _deployment = parseDeployment(_host)!;

Future<FakeDeployment> _pumpApp(WidgetTester tester, {Stream<String>? links}) async {
  final fake = FakeDeployment(_host, approved: true, machines: [FakeMachine(_box, 'dev-box')]);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        connectorProvider.overrideWithValue(FakePorscheConnector({_host: fake})),
        openExternalProvider.overrideWithValue((uri) async {}),
        if (links != null) incomingLinksProvider.overrideWithValue(links),
      ],
      child: const MilaApp(),
    ),
  );
  await tester.pumpAndSettle();
  return fake;
}

const String _box = '0d9cc041-9db2-4e4c-b28b-1e41d7f472c1';

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(MilaApp)));

Future<void> _signIn(WidgetTester tester) async {
  await tester.enterText(find.byKey(const Key('deployment-host')), _host);
  await tester.tap(find.byKey(const Key('add-deployment')));
  await tester.pumpAndSettle();
  expect(_container(tester).read(sessionProvider(_deployment)), isNotNull);
}

void _go(WidgetTester tester, String path) =>
    GoRouter.of(tester.element(find.byType(Scaffold).first)).go(path);

void main() {
  testWidgets('a signed-in deployment opens its machines and shows the account', (tester) async {
    await _pumpApp(tester);
    await _signIn(tester);
    _go(tester, deploymentsPath);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('deployment-$_deployment')));
    await tester.pumpAndSettle();
    expect(
      find.text('dev-box'),
      findsOneWidget,
      reason: 'the row opens machines, not a blank page',
    );

    _go(tester, signInPath(_deployment));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sign-in-account')), findsOneWidget);
    expect(find.text('user@$_host'), findsOneWidget);
    await tester.tap(find.byKey(const Key('sign-in-open-machines')));
    await tester.pumpAndSettle();
    expect(find.text('dev-box'), findsOneWidget);
  });

  testWidgets('a dropped connection can be reconnected without removing anything', (tester) async {
    final fake = await _pumpApp(tester);
    await _signIn(tester);
    final container = _container(tester);
    await container.read(signInProvider(_deployment)).session!.close();
    await tester.pumpAndSettle();
    expect(container.read(signInProvider(_deployment)).flow.phase, SignInPhase.disconnected);
    expect(container.read(sessionProvider(_deployment)), isNull);

    _go(tester, signInPath(_deployment));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sign-in-disconnected')), findsOneWidget);
    expect(find.text('user@$_host'), findsOneWidget, reason: 'the account stays shown');
    final whoamis = fake.received.where((line) => line == 'whoami --json').length;
    await tester.tap(find.byKey(const Key('sign-in-reconnect')));
    await tester.pumpAndSettle();
    expect(fake.received.where((line) => line == 'whoami --json'), hasLength(whoamis + 1));
    expect(container.read(sessionProvider(_deployment)), isNotNull);
    expect(container.read(deploymentsProvider), [_deployment]);
  });

  testWidgets('signing out keeps the deployment and offers sign-in again', (tester) async {
    await _pumpApp(tester);
    await _signIn(tester);
    _go(tester, settingsPath);
    await tester.pumpAndSettle();
    expect(find.byKey(Key('deployment-account-$_deployment')), findsOneWidget);
    expect(find.text('[Signed in]'), findsOneWidget);
    await tester.tap(find.byKey(Key('sign-out-deployment-$_deployment')));
    await tester.pumpAndSettle();
    final container = _container(tester);
    expect(container.read(signInProvider(_deployment)).flow.phase, SignInPhase.idle);
    expect(container.read(deploymentsProvider), [_deployment]);
    expect(find.text('[Offline]'), findsOneWidget);
    expect(find.byKey(Key('sign-out-deployment-$_deployment')), findsNothing);
  });

  testWidgets('SSH keys list this device and revoke another after confirmation', (tester) async {
    final fake = await _pumpApp(tester);
    await _signIn(tester);
    _go(tester, settingsPath);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('ssh-keys-$_deployment')));
    await tester.pumpAndSettle();
    expect(fake.received, contains('ssh-key list --json'));
    expect(find.byKey(const Key('ssh-key-own-$_ownKey')), findsOneWidget);
    expect(find.byKey(const Key('ssh-key-revoke-$_ownKey')), findsNothing);

    await tester.tap(find.byKey(const Key('ssh-key-revoke-$_laptopKey')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('CANCEL'));
    await tester.pumpAndSettle();
    expect(fake.received.where((line) => line.startsWith('ssh-key remove')), isEmpty);

    await tester.tap(find.byKey(const Key('ssh-key-revoke-$_laptopKey')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-ssh-key-revoke')));
    await tester.pumpAndSettle();
    final removes = fake.received.where((line) => line.startsWith('ssh-key remove')).toList();
    expect(removes, hasLength(1));
    expect(removes.single, contains('--request-id=porsche-'));
    expect(find.byKey(const Key('ssh-key-$_laptopKey')), findsNothing);
    expect(find.byKey(const Key('ssh-key-revoke-failed')), findsNothing);
  });

  testWidgets('links that cannot open say why, and an unknown host is offered to add', (
    tester,
  ) async {
    final links = StreamController<String>();
    addTearDown(links.close);
    await _pumpApp(tester, links: links.stream);
    links.add('overalls://other.example/machines');
    await tester.pumpAndSettle();
    expect(find.text('Add other.example as a deployment to open this link.'), findsOneWidget);
    final field = tester.widget<TextField>(find.byKey(const Key('deployment-host')));
    expect(field.controller!.text, 'other.example');

    links.add('https://example.com/');
    await tester.pumpAndSettle();
    expect(find.text('Mila cannot open this link.'), findsOneWidget);
  });
}
