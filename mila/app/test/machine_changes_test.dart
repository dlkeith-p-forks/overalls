import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mila/app.dart';
import 'package:mila/features/routes.dart';
import 'package:mila/features/session.dart';
import 'package:mila/transport/fake_porsche.dart';
import 'package:mila_transport/mila_transport.dart';

const String _host = 'overalls.example';
const String _box = '0d9cc041-9db2-4e4c-b28b-1e41d7f472c1';
final RegExp _requestId = RegExp(r'--request-id=porsche-[0-9a-f]{32}');

Future<FakeDeployment> _signedIn(WidgetTester tester) async {
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final fake = FakeDeployment(_host, approved: true, machines: [FakeMachine(_box, 'dev-box')]);
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
  await tester.tap(find.byKey(const Key('sign-in-start')));
  await tester.pumpAndSettle();
  return fake;
}

Future<void> _openInfo(WidgetTester tester) async {
  ProviderScope.containerOf(tester.element(find.byType(MaterialApp)))
      .read(routerProvider)
      .go(machinePath(const Deployment(_host), _box));
  await tester.pumpAndSettle();
}

Iterable<String> _sent(FakeDeployment fake, String prefix) =>
    fake.received.where((line) => line.startsWith('$prefix '));

void main() {
  testWidgets('a new machine is created once, with only the values given', (tester) async {
    final fake = await _signedIn(tester);
    await tester.tap(find.byKey(const Key('machine-new')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('machine-form-name')), 'Bad Name');
    await tester.enterText(find.byKey(const Key('machine-form-disk')), '501');
    await tester.tap(find.byKey(const Key('machine-form-submit')));
    await tester.pumpAndSettle();
    expect(find.text('Check this value.'), findsNWidgets(2));
    expect(_sent(fake, 'new'), isEmpty);

    await tester.enterText(find.byKey(const Key('machine-form-name')), 'scratch');
    await tester.enterText(find.byKey(const Key('machine-form-disk')), '20');
    await tester.tap(find.byKey(const Key('machine-form-submit')));
    await tester.pumpAndSettle();
    final line = _sent(fake, 'new').single;
    expect(line, matches(_requestId));
    expect(line, contains('--name=scratch'));
    expect(line, contains('--disk=20'));
    expect(line, contains('--no-wait'));
    expect(line, isNot(contains('--cpu')));
    expect(find.byKey(const Key('request-new')), findsOneWidget);
    expect(find.text('scratch'), findsOneWidget);
  });

  testWidgets('cancelling the new machine form sends nothing', (tester) async {
    final fake = await _signedIn(tester);
    await tester.tap(find.byKey(const Key('machine-new')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('CANCEL'));
    await tester.pumpAndSettle();
    expect(_sent(fake, 'new'), isEmpty);
  });

  testWidgets('resize refuses no change or a smaller disk, then sends once', (tester) async {
    final fake = await _signedIn(tester);
    await _openInfo(tester);
    await tester.tap(find.byKey(const Key('machine-resize')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('machine-form-submit')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('machine-form-nothing')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('machine-form-disk')), '10');
    await tester.tap(find.byKey(const Key('machine-form-submit')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('machine-form-nothing')), findsOneWidget);
    expect(_sent(fake, 'resize'), isEmpty);

    await tester.enterText(find.byKey(const Key('machine-form-disk')), '');
    await tester.enterText(find.byKey(const Key('machine-form-memory')), '8192');
    await tester.tap(find.byKey(const Key('machine-form-submit')));
    await tester.pumpAndSettle();
    final line = _sent(fake, 'resize').single;
    expect(line, matches(_requestId));
    expect(line, endsWith(' $_box'));
    expect(line, contains('--memory=8192'));
    expect(fake.machines.single.memoryMib, 8192);
    expect(find.text('Done.'), findsOneWidget);
  });

  testWidgets('clone sends the source machine and the new name once', (tester) async {
    final fake = await _signedIn(tester);
    await _openInfo(tester);
    await tester.tap(find.byKey(const Key('machine-clone')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('machine-form-disk')), findsNothing);
    await tester.enterText(find.byKey(const Key('machine-form-name')), 'dev-copy');
    await tester.tap(find.byKey(const Key('machine-form-submit')));
    await tester.pumpAndSettle();
    final line = _sent(fake, 'clone').single;
    expect(line, matches(_requestId));
    expect(line, contains('--name=dev-copy'));
    expect(fake.machines.map((m) => m.name), contains('dev-copy'));
  });

  testWidgets('sharing lists grants, adds once and removes after confirmation', (tester) async {
    final fake = await _signedIn(tester);
    fake.shares[_box] = {'viewer@$_host': 'viewer'};
    await _openInfo(tester);
    expect(find.text('owner@$_host'), findsNothing);
    expect(find.text('user@$_host'), findsOneWidget);
    expect(find.text('viewer@$_host'), findsOneWidget);
    expect(find.text('[owner]'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('share-email')), 'not an email');
    await tester.ensureVisible(find.byKey(const Key('share-add')));
    await tester.tap(find.byKey(const Key('share-add')));
    await tester.pumpAndSettle();
    expect(find.text('Enter an email address.'), findsOneWidget);
    expect(_sent(fake, 'share add'), isEmpty);

    await tester.enterText(find.byKey(const Key('share-email')), 'ops@$_host');
    await tester.tap(find.byKey(const Key('share-role-1')));
    await tester.tap(find.byKey(const Key('share-add')));
    await tester.pumpAndSettle();
    final added = _sent(fake, 'share add').single;
    expect(added, matches(_requestId));
    expect(added, endsWith('$_box ops@$_host operator'));
    expect(find.text('ops@$_host'), findsOneWidget);

    final remove = find.byKey(const Key('share-remove-00000000-0000-4000-9000-000000000064'));
    await tester.ensureVisible(remove);
    await tester.tap(remove);
    await tester.pumpAndSettle();
    await tester.tap(find.text('CANCEL'));
    await tester.pumpAndSettle();
    expect(_sent(fake, 'share remove'), isEmpty);
    await tester.tap(remove);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-share-remove')));
    await tester.pumpAndSettle();
    expect(_sent(fake, 'share remove').single, endsWith('$_box viewer@$_host'));
    expect(find.text('viewer@$_host'), findsNothing);
  });

  testWidgets('a refused share is reported, not retried', (tester) async {
    final fake = await _signedIn(tester);
    await _openInfo(tester);
    await tester.enterText(find.byKey(const Key('share-email')), 'someone@elsewhere.example');
    await tester.ensureVisible(find.byKey(const Key('share-add')));
    await tester.tap(find.byKey(const Key('share-add')));
    await tester.pumpAndSettle();
    expect(_sent(fake, 'share add'), hasLength(1));
    expect(find.byKey(const Key('share-change-failed')), findsOneWidget);
  });
}
