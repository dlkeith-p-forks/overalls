import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mila/app.dart';
import 'package:mila/features/routes.dart';
import 'package:mila/features/session.dart';
import 'package:mila/transport/fake_porsche.dart';
import 'package:mila_transport/mila_transport.dart';

const String _host = 'overalls.example';
const String _box = '0d9cc041-9db2-4e4c-b28b-1e41d7f472c1';

/// Pumps the app with [links] as the platform's link stream.
Future<(FakeDeployment, GoRouter)> _pump(
  WidgetTester tester,
  StreamController<String> links,
) async {
  final fake = FakeDeployment(_host, approved: true, machines: [FakeMachine(_box, 'dev-box')]);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        connectorProvider.overrideWithValue(FakePorscheConnector({_host: fake})),
        incomingLinksProvider.overrideWithValue(links.stream),
      ],
      child: const MilaApp(),
    ),
  );
  await tester.pumpAndSettle();
  final container = ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
  return (fake, container.read(routerProvider));
}

String _location(GoRouter router) => router.routerDelegate.currentConfiguration.uri.toString();

void main() {
  testWidgets('a platform link opens the machine page once signed in', (tester) async {
    final links = StreamController<String>();
    addTearDown(links.close);
    final (fake, router) = await _pump(tester, links);
    await tester.enterText(find.byKey(const Key('deployment-host')), _host);
    await tester.tap(find.byKey(const Key('add-deployment')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sign-in-start')));
    await tester.pumpAndSettle();
    final sent = List.of(fake.received);

    links.add('overalls://$_host/machines/$_box');
    await tester.pumpAndSettle();
    expect(_location(router), machinePath(const Deployment(_host), _box));
    // Following a link is navigation only: no command was sent for it
    // beyond what the opened page itself reads.
    expect(
      fake.received
          .skip(sent.length)
          .every(
            (line) =>
                line.startsWith('ls') || line.startsWith('show') || line.startsWith('share show'),
          ),
      isTrue,
    );
  });

  testWidgets('links to a deployment not yet signed in reach only its sign-in', (tester) async {
    final links = StreamController<String>();
    addTearDown(links.close);
    final (fake, router) = await _pump(tester, links);
    await tester.enterText(find.byKey(const Key('deployment-host')), _host);
    await tester.tap(find.byKey(const Key('add-deployment')));
    await tester.pumpAndSettle();
    router.go(deploymentsPath);
    await tester.pumpAndSettle();

    links.add('overalls://$_host/machines/$_box');
    await tester.pumpAndSettle();
    expect(_location(router), signInPath(const Deployment(_host)));
    expect(fake.received, isEmpty);
  });

  testWidgets('unknown deployments and malformed links land on the deployment list', (
    tester,
  ) async {
    final links = StreamController<String>();
    addTearDown(links.close);
    final (fake, router) = await _pump(tester, links);
    router.go(settingsPath);
    await tester.pumpAndSettle();
    for (final link in [
      'overalls://elsewhere.test/machines',
      'overalls://$_host/machines/not-a-uuid',
      'overalls://$_host/../settings',
    ]) {
      links.add(link);
      await tester.pumpAndSettle();
      expect(_location(router), deploymentsPath, reason: link);
      router.go(settingsPath);
      await tester.pumpAndSettle();
    }
    expect(fake.received, isEmpty);
  });
}
