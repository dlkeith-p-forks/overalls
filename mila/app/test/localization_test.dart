import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mila/l10n/app_localizations.dart';

/// The Porsche gateway's locales; Mila ships exactly the same set.
const List<String> _porscheLocales = [
  'ar', 'bn', 'de', 'en', 'es', 'et', 'fi', 'fil', 'fr', 'hi', 'id', 'ja', 'ko', 'mr', 'pcm', //
  'pt_BR', 'pt_PT', 'ru', 'sv', 'ta', 'te', 'tr', 'ur', 'vi', 'zh_Hans',
];

Map<String, Object?> _arb(String locale) =>
    jsonDecode(File('lib/l10n/app_$locale.arb').readAsStringSync()) as Map<String, Object?>;

Set<String> _messages(Map<String, Object?> arb) =>
    arb.keys.where((k) => !k.startsWith('@')).toSet();

Set<String> _placeholders(String message) =>
    RegExp(r'\{(\w+)[,}]').allMatches(message).map((m) => m.group(1)!).toSet();

void main() {
  final template = _arb('en');

  test('every Porsche locale has a complete catalog with the same placeholders', () {
    for (final locale in _porscheLocales) {
      final arb = _arb(locale);
      expect(_messages(arb), _messages(template), reason: locale);
      for (final key in _messages(template)) {
        final english = template[key]! as String;
        final translated = arb[key]! as String;
        expect(translated.trim(), isNotEmpty, reason: '$locale $key');
        expect(_placeholders(translated), _placeholders(english), reason: '$locale $key');
      }
    }
  });

  test('every template message is documented for translators', () {
    for (final key in _messages(template)) {
      final meta = template['@$key'];
      expect(meta, isA<Map<String, Object?>>(), reason: key);
      expect((meta! as Map<String, Object?>)['description'], isA<String>(), reason: key);
    }
  });

  test('every supported locale resolves to its own catalog', () async {
    for (final locale in MilaLocalizations.supportedLocales) {
      final l = await MilaLocalizations.delegate.load(locale);
      expect(l.appTitle, 'Mila', reason: '$locale');
      expect(l.deploymentHostHint, 'overalls.example', reason: '$locale');
      expect(l.cpuCount(5), contains('5'), reason: '$locale');
    }
  });

  testWidgets('Arabic and Urdu lay out right to left', (tester) async {
    for (final code in ['ar', 'ur']) {
      late TextDirection direction;
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(code),
          supportedLocales: MilaLocalizations.supportedLocales,
          localizationsDelegates: const [
            MilaLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: Builder(
            builder: (context) {
              direction = Directionality.of(context);
              return Text(MilaLocalizations.of(context).machinesTitle);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(direction, TextDirection.rtl, reason: code);
    }
  });
}
