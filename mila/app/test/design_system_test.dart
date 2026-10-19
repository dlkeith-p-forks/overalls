import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mila/ui/tokens.dart';
import 'package:mila/ui/widgets.dart';

/// Patterns The Monospace Web forbids outside `lib/ui/tokens.dart`
/// (ADR-0161, ADR-0226): colour literals, icon fonts, rounded corners,
/// shadows, gradients and elevation.
final Map<String, RegExp> _forbidden = {
  'colour literal': RegExp(r'\bColor\(|\bColors\.|Color\.from'),
  'icon font': RegExp(r'\bIcons\.|\bCupertinoIcons\.|\bIcon\('),
  'rounded corner': RegExp(r'BorderRadius\.circular|Radius\.circular|StadiumBorder|CircleBorder'),
  'shadow': RegExp(r'BoxShadow|Shadow\('),
  'gradient': RegExp(r'Gradient\('),
  'elevation': RegExp(r'elevation:\s*[1-9]'),
};

double _luminance(Color c) {
  double channel(double v) => v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

double _contrast(Color a, Color b) {
  final la = _luminance(a), lb = _luminance(b);
  return (max(la, lb) + 0.05) / (min(la, lb) + 0.05);
}

/// The code points a TrueType font maps, from its cmap format 4 and 12 tables.
Set<int> _cmap(Uint8List font) {
  final data = ByteData.sublistView(font);
  final tables = data.getUint16(4);
  var cmap = -1;
  for (var i = 0; i < tables; i++) {
    final record = 12 + 16 * i;
    if (String.fromCharCodes(font.sublist(record, record + 4)) == 'cmap') {
      cmap = data.getUint32(record + 8);
    }
  }
  expect(cmap, isNot(-1));
  final points = <int>{};
  final subtables = data.getUint16(cmap + 2);
  for (var i = 0; i < subtables; i++) {
    final offset = cmap + data.getUint32(cmap + 4 + 8 * i + 4);
    switch (data.getUint16(offset)) {
      case 4:
        final segments = data.getUint16(offset + 6) ~/ 2;
        final ends = offset + 14;
        final starts = ends + 2 * segments + 2;
        final deltas = starts + 2 * segments;
        final ranges = deltas + 2 * segments;
        for (var s = 0; s < segments; s++) {
          final end = data.getUint16(ends + 2 * s);
          final start = data.getUint16(starts + 2 * s);
          final delta = data.getInt16(deltas + 2 * s);
          final range = data.getUint16(ranges + 2 * s);
          for (var c = start; c <= end && c != 0xFFFF; c++) {
            final glyph = range == 0
                ? (c + delta) & 0xFFFF
                : data.getUint16(ranges + 2 * s + range + 2 * (c - start));
            if (glyph != 0) points.add(c);
          }
        }
      case 12:
        final groups = data.getUint32(offset + 12);
        for (var g = 0; g < groups; g++) {
          final group = offset + 16 + 12 * g;
          for (var c = data.getUint32(group); c <= data.getUint32(group + 4); c++) {
            points.add(c);
          }
        }
    }
  }
  return points;
}

void main() {
  test('every glyph Mila may render is drawn by every bundled weight', () {
    for (final weight in ['500', '500-italic', '600', '800']) {
      final points = _cmap(File('assets/fonts/jetbrains-mono-$weight.ttf').readAsBytesSync());
      expect(points.length, greaterThan(1000), reason: weight);
      for (final glyph in Glyph.values) {
        expect(points.contains(glyph.char.runes.single), glyph.inFont, reason: '$weight $glyph');
      }
      // Status labels, box drawing and the ellipsis used in progress text.
      for (final c in '[]─│┌┐└┘…'.runes) {
        expect(points, contains(c), reason: '$weight U+${c.toRadixString(16)}');
      }
    }
  });

  test('no forbidden presentation pattern exists outside the tokens file', () {
    final offences = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.endsWith('ui/tokens.dart') || entity.path.contains('/l10n/')) continue;
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        for (final MapEntry(:key, :value) in _forbidden.entries) {
          if (value.hasMatch(lines[i])) offences.add('${entity.path}:${i + 1}: $key');
        }
      }
    }
    expect(offences, isEmpty);
  });

  test('tokens meet the web contrast floor in both themes', () {
    for (final tokens in [MonoTokens.light, MonoTokens.dark]) {
      expect(_contrast(tokens.text, tokens.background), greaterThanOrEqualTo(7));
      expect(_contrast(tokens.text, tokens.backgroundAlt), greaterThanOrEqualTo(7));
      expect(_contrast(tokens.textAlt, tokens.background), greaterThanOrEqualTo(4.5));
      expect(_contrast(tokens.textAlt, tokens.backgroundAlt), greaterThanOrEqualTo(4.5));
    }
  });

  test('glyphs mirror the web glyph table and are single code points', () {
    final source = File('../../marshall/lib/marshall_web/components/core_components.ex')
        .readAsStringSync();
    final table = RegExp(r'"(\w+)" => "(.)"').allMatches(source).map((m) => m.group(2)!).toSet();
    expect(table, hasLength(Glyph.values.length));
    for (final glyph in Glyph.values) {
      expect(table, contains(glyph.char), reason: glyph.name);
      expect(glyph.char.runes, hasLength(1), reason: glyph.name);
    }
  });

  test('glyph text is excluded from semantics unless labelled', () {
    expect(const GlyphText(Glyph.home).label, isNull);
    expect(const GlyphText(Glyph.home, label: 'Home').label, 'Home');
  });

  test('the type scale keeps the 1.2 line grid', () {
    expect(MonoScale.line, closeTo(MonoScale.fontSize * 1.2, 1e-9));
    expect(MonoScale.border, 2);
  });
}
