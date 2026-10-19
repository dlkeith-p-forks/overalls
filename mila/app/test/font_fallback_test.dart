import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mila/ui/font_licences.dart';
import 'package:mila/ui/tokens.dart';
import 'package:mila/ui/widgets.dart';

import 'support/fonts.dart';

/// A script's code-point ranges, as Marshall's `assets/css/fonts.css`
/// assigns them to a fallback face with `unicode-range` (ADR-0207).
typedef ScriptRanges = ({String family, List<(int, int)> ranges});

const List<ScriptRanges> _scripts = [
  (
    family: 'Overalls Noto Arabic',
    ranges: [
      (0x0600, 0x06FF),
      (0x0750, 0x077F),
      (0x0870, 0x08FF),
      (0xFB50, 0xFDFF),
      (0xFE70, 0xFEFF),
    ],
  ),
  (family: 'Overalls Noto Devanagari', ranges: [(0x0900, 0x097F), (0xA8E0, 0xA8FF)]),
  (family: 'Overalls Noto Bengali', ranges: [(0x0980, 0x09FF)]),
  (family: 'Overalls Noto Telugu', ranges: [(0x0C00, 0x0C7F)]),
  (family: 'Overalls Noto Tamil', ranges: [(0x0B80, 0x0BFF)]),
  (
    family: 'Overalls Noto CJK',
    ranges: [
      (0x1100, 0x11FF),
      (0x2E80, 0x31FF),
      (0x3200, 0x9FFF),
      (0xAC00, 0xD7FF),
      (0xFF00, 0xFFEF),
    ],
  ),
];

/// Format characters that select shaping or direction and draw nothing.
bool _invisible(int c) =>
    c <= 0x20 || (c >= 0x200B && c <= 0x200F) || (c >= 0x2066 && c <= 0x2069) || c == 0xFEFF;

/// Every translated string's characters, per ARB file.
Map<String, Set<int>> _catalogRunes() {
  final result = <String, Set<int>>{};
  for (final entity in Directory('lib/l10n').listSync()) {
    if (entity is! File || !entity.path.endsWith('.arb')) continue;
    final Object? decoded = jsonDecode(entity.readAsStringSync());
    if (decoded is! Map<String, Object?>) fail('${entity.path} is not an object');
    final runes = <int>{};
    for (final MapEntry(:key, :value) in decoded.entries) {
      if (key.startsWith('@') || value is! String) continue;
      runes.addAll(value.runes.where((c) => !_invisible(c)));
    }
    result[entity.uri.pathSegments.last] = runes;
  }
  return result;
}

void main() {
  late final Set<int> primary;
  late final Map<String, Set<int>> faces;
  setUpAll(() {
    primary = cmap(File('assets/fonts/jetbrains-mono-500.ttf').readAsBytesSync());
    faces = {
      for (final face in notoFaces)
        face.family: cmap(File('assets/fonts/noto/${face.file}').readAsBytesSync()),
    };
  });

  /// The face Flutter's per-character fallback draws [c] with.
  String? resolve(int c) {
    if (primary.contains(c)) return MonoScale.fontFamily;
    for (final family in MonoScale.fontFamilyFallback) {
      if (faces[family]!.contains(c)) return family;
    }
    return null;
  }

  test('the theme falls back through every bundled face, in the documented order', () {
    expect(MonoScale.fontFamilyFallback, [for (final face in notoFaces) face.family]);
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final families = RegExp(r'- family: (.+)').allMatches(pubspec).map((m) => m.group(1)!.trim());
    expect(families, [MonoScale.fontFamily, ...MonoScale.fontFamilyFallback]);
  });

  test('the bundled faces are exactly the ones Marshall pins, each with its licence', () {
    final Object? manifest = jsonDecode(
      File('assets/fonts/noto/noto-fonts.json').readAsStringSync(),
    );
    if (manifest is! Map<String, Object?>) fail('manifest is not an object');
    final Object? fonts = manifest['fonts'];
    if (fonts is! List<Object?>) fail('manifest has no font list');
    final stems = <String>{};
    for (final font in fonts) {
      if (font is! Map<String, Object?>) fail('manifest entry is not an object');
      final Object? file = font['file'], licence = font['license_file'];
      if (file is! String || licence is! String) fail('manifest entry lacks a file or licence');
      stems.add(file.replaceAll('.woff2', ''));
      expect(File('assets/fonts/noto/$licence').existsSync(), isTrue, reason: licence);
      expect(
        bundledFontLicences.map((l) => l.asset),
        contains('assets/fonts/noto/$licence'),
        reason: licence,
      );
    }
    expect({for (final face in notoFaces) face.file.split('.').first}, stems);
    for (final licence in bundledFontLicences) {
      expect(File(licence.asset).readAsStringSync(), contains('SIL OPEN FONT LICENSE'));
    }
  });

  test('every character of every translation is drawn by a bundled face', () {
    for (final MapEntry(key: file, value: runes) in _catalogRunes().entries) {
      final missing = [
        for (final c in runes)
          if (resolve(c) == null) 'U+${c.toRadixString(16).toUpperCase()}',
      ];
      expect(missing, isEmpty, reason: file);
    }
  });

  test('each script reaches the face Marshall assigns it, not an earlier one', () {
    for (final MapEntry(key: file, value: runes) in _catalogRunes().entries) {
      for (final c in runes) {
        for (final script in _scripts) {
          if (script.ranges.any((r) => c >= r.$1 && c <= r.$2)) {
            expect(resolve(c), script.family, reason: '$file U+${c.toRadixString(16)}');
          }
        }
      }
    }
  });

  // The web table has two code points JetBrains Mono lacks. The reconnect
  // arrow now has a bundled face, as on the web; no bundled face draws the
  // copy glyph, which is why Mila never renders either (Glyph.inFont).
  test('the symbol face draws the reconnect arrow; nothing bundled draws the copy glyph', () {
    expect(Glyph.values.where((g) => !g.inFont), [Glyph.refresh, Glyph.copy]);
    expect(resolve(Glyph.refresh.char.runes.single), 'Overalls Noto Symbols');
    expect(resolve(Glyph.copy.char.runes.single), isNull);
  });
}
