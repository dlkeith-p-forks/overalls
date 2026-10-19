import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mila/app.dart';
import 'package:mila/features/routes.dart';
import 'package:mila/features/session.dart';
import 'package:mila/features/settings_screen.dart';
import 'package:mila/transport/fake_porsche.dart';
import 'package:mila/ui/theme.dart';
import 'package:mila_transport/mila_transport.dart';

const String _host = 'overalls.example';

Future<void> _loadFonts() async {
  final loader = FontLoader('JetBrains Mono');
  for (final weight in ['500', '500-italic', '600', '800']) {
    final bytes = File('assets/fonts/jetbrains-mono-$weight.ttf').readAsBytesSync();
    loader.addFont(Future.value(ByteData.sublistView(Uint8List.fromList(bytes))));
  }
  await loader.load();
}

const String _box = '0d9cc041-9db2-4e4c-b28b-1e41d7f472c1';
const String _term = '019a0f73-1111-4222-8333-444455556666';
const String _thread = '019a0f71-aaaa-4bbb-8ccc-ddddeeeeffff';

Future<FakeDeployment> _machines(
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
      FakeMachine(_box, 'dev-box'),
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
  return fake;
}

Future<void> _go(WidgetTester tester, String path) async {
  ProviderScope.containerOf(tester.element(find.byType(MaterialApp))).read(routerProvider).go(path);
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

  // Right-to-left layout of the M2/M3 screens; the terminal emulator itself
  // stays left to right (Mila plan, section A3).
  testWidgets('terminal, Arabic', (tester) async {
    final fake = await _machines(tester, appearance: Appearance.light, locale: const Locale('ar'));
    fake.terminals[_term] = FakeTerminal(_term, _box)
      ..output.addAll(utf8.encode('dev@dev-box:~\$ ls\r\nREADME.md  src\r\ndev@dev-box:~\$ '));
    await _go(tester, machineTerminalPath(const Deployment(_host), _box, _term));
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/terminal_ar.png'));
    await _go(tester, machinesPath(const Deployment(_host)));
  });

  testWidgets('thread, Arabic', (tester) async {
    final fake = await _machines(tester, appearance: Appearance.light, locale: const Locale('ar'));
    fake.threads[_thread] = FakeThread(_thread, 'إصلاح البناء', machineId: _box)
      ..add('prompt', {'prompt': 'لماذا يفشل CI؟'})
      ..add('assistant', {'text': 'ينقص استيراد في lib/main.dart.'})
      ..plan = {
        'id': '019a0f75-1234-4567-89ab-cdef01234567',
        'text': '1. أضف الاستيراد.\n2. شغّل الاختبارات.',
        'implemented': false,
      };
    await _go(tester, threadPath(const Deployment(_host), _thread));
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/thread_ar.png'));
    await _go(tester, machinesPath(const Deployment(_host)));
  });
}
