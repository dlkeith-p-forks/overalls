// The Monospace Web tokens (ADR-0161, ADR-0226). Every colour Mila renders
// derives from these four tokens per theme; no other file may declare one.
// Values mirror marshall/assets/css/tokens.css.
import 'package:flutter/widgets.dart';

/// One theme's four colour tokens.
@immutable
final class MonoTokens {
  const MonoTokens({
    required this.text,
    required this.textAlt,
    required this.background,
    required this.backgroundAlt,
  });

  final Color text;
  final Color textAlt;
  final Color background;
  final Color backgroundAlt;

  /// Fully transparent, for disabling Material's overlay and splash layers.
  static const Color none = Color(0x00000000);

  static const MonoTokens light = MonoTokens(
    text: Color(0xFF000000),
    textAlt: Color(0xFF666666),
    background: Color(0xFFFFFFFF),
    backgroundAlt: Color(0xFFEEEEEE),
  );

  static const MonoTokens dark = MonoTokens(
    text: Color(0xFFFFFFFF),
    textAlt: Color(0xFFAAAAAA),
    background: Color(0xFF000000),
    backgroundAlt: Color(0xFF111111),
  );
}

/// The type and grid scale: one cell is one character wide and one line tall.
abstract final class MonoScale {
  static const String fontFamily = 'JetBrains Mono';
  static const double fontSize = 14;
  static const double lineHeight = 1.2;

  /// The height of one grid line in logical pixels.
  static const double line = fontSize * lineHeight;
  static const double border = 2;
  static const FontWeight normal = FontWeight.w500;
  static const FontWeight medium = FontWeight.w600;
  static const FontWeight bold = FontWeight.w800;
}
