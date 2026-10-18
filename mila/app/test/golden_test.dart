import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mila/app.dart';
import 'package:mila/features/session.dart';
import 'package:mila/features/settings_screen.dart';
import 'package:mila/transport/fake_porsche.dart';
import 'package:mila/ui/theme.dart';

const String _host = 'overalls.example';

Future<void> _loadFonts() async {
  final loader = FontLoader('JetBrains Mono');
  for (final weight in ['500', '500-italic', '600', '800']) {
    final bytes = File('assets/fonts/jetbrains-mono-$weight.ttf').readAsBytesSync();
    loader.addFont(Future.value(ByteData.sublistView(Uint8List.fromList(bytes))));
  }
  await loader.load();
}

Future<void> _machines(
  WidgetTester tester, {
  required Appearance appearance,
  Locale? locale,
}) async {
  tester.view.physicalSize = const Size(420, 860);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  if (locale != null) {
    tester.platformDispatcher.localesTestValue = [locale];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
  }
  final fake = FakeDeployment(
    _host,
    approved: true,
    machines: [
      FakeMachine('0d9cc041-9db2-4e4c-b28b-1e41d7f472c1', 'dev-box'),
      FakeMachine(
        '6f1e2d3c-4b5a-4987-8a6b-5c4d3e2f1a0b',
        'scratch',
        desired: 'stopped',
        observed: 'stopped',
      ),
      FakeMachine('9a8b7c6d-5e4f-4a3b-9c2d-1e0f9a8b7c6d', 'broken', observed: 'failed'),
    ],
  );
  fake.machines[1].pinned = true;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        connectorProvider.overrideWithValue(FakePorscheConnector({_host: fake})),
      ],
      child: const MilaApp(),
    ),
  );
  await tester.pumpAndSettle();
  ProviderScope.containerOf(tester.element(find.byType(MaterialApp)))
      .read(appearanceProvider.notifier)
      .set(appearance);
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const Key('deployment-host')), _host);
  await tester.tap(find.byKey(const Key('add-deployment')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('sign-in-start')));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(_loadFonts);

  testWidgets('machines, light', (tester) async {
    await _machines(tester, appearance: Appearance.light);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/machines_light.png'));
  });

  testWidgets('machines, dark', (tester) async {
    await _machines(tester, appearance: Appearance.dark);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/machines_dark.png'));
  });

  testWidgets('machines, Arabic', (tester) async {
    await _machines(tester, appearance: Appearance.light, locale: const Locale('ar'));
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/machines_ar.png'));
  });
}
