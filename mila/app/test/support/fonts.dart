import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mila/ui/tokens.dart';

/// The code points a TrueType or OpenType font maps, from its cmap format 4
/// and 12 tables.
Set<int> cmap(Uint8List font) {
  final data = ByteData.sublistView(font);
  final tables = data.getUint16(4);
  var table = -1;
  for (var i = 0; i < tables; i++) {
    final record = 12 + 16 * i;
    if (String.fromCharCodes(font.sublist(record, record + 4)) == 'cmap') {
      table = data.getUint32(record + 8);
    }
  }
  if (table == -1) throw ArgumentError('the font has no cmap table');
  final points = <int>{};
  final subtables = data.getUint16(table + 2);
  for (var i = 0; i < subtables; i++) {
    final offset = table + data.getUint32(table + 4 + 8 * i + 4);
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

/// A bundled fallback face: its family name and its file under `assets/fonts/noto`.
typedef NotoFace = ({String family, String file});

/// The fallback faces in [MonoScale.fontFamilyFallback] order.
const List<NotoFace> notoFaces = [
  (family: 'Overalls Noto Mono', file: 'noto-mono.ttf'),
  (family: 'Overalls Noto Arabic', file: 'noto-arabic.ttf'),
  (family: 'Overalls Noto Devanagari', file: 'noto-devanagari.ttf'),
  (family: 'Overalls Noto Bengali', file: 'noto-bengali.ttf'),
  (family: 'Overalls Noto Telugu', file: 'noto-telugu.ttf'),
  (family: 'Overalls Noto Tamil', file: 'noto-tamil.ttf'),
  (family: 'Overalls Noto Symbols', file: 'noto-symbols.ttf'),
  (family: 'Overalls Noto CJK', file: 'noto-cjk.otf'),
];

Uint8List _bytes(String path) => File(path).readAsBytesSync();

/// Loads JetBrains Mono and every fallback face into the test engine, so
/// goldens draw the shipped glyphs instead of the test font's boxes.
Future<void> loadBundledFonts() async {
  final mono = FontLoader(MonoScale.fontFamily);
  for (final weight in ['500', '500-italic', '600', '800']) {
    mono.addFont(
      Future.value(ByteData.sublistView(_bytes('assets/fonts/jetbrains-mono-$weight.ttf'))),
    );
  }
  await mono.load();
  for (final face in notoFaces) {
    final loader = FontLoader(face.family)
      ..addFont(Future.value(ByteData.sublistView(_bytes('assets/fonts/noto/${face.file}'))));
    await loader.load();
  }
}
