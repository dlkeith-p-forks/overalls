import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

import 'tokens.dart';

/// The user's appearance choice, mirroring the web appearance selector.
enum Appearance { system, light, dark }

/// The token set in effect, available to every widget below [MonoTheme].
final class MonoTheme extends InheritedWidget {
  const MonoTheme({super.key, required this.tokens, required super.child});

  final MonoTokens tokens;

  static MonoTokens of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MonoTheme>()?.tokens ?? MonoTokens.light;

  @override
  bool updateShouldNotify(MonoTheme oldWidget) => oldWidget.tokens != tokens;
}

/// Builds a Material theme that draws nothing Material-specific: no radius,
/// elevation, splash or tint; 2px borders; JetBrains Mono on the line grid.
ThemeData monoThemeData(MonoTokens tokens, Brightness brightness) {
  final text = TextStyle(
    fontFamily: MonoScale.fontFamily,
    fontSize: MonoScale.fontSize,
    height: MonoScale.lineHeight,
    fontWeight: MonoScale.normal,
    color: tokens.text,
    letterSpacing: 0,
  );
  final heading = text.copyWith(fontWeight: MonoScale.bold);
  final side = BorderSide(color: tokens.text, width: MonoScale.border);
  const square = RoundedRectangleBorder();
  final scheme = ColorScheme(
    brightness: brightness,
    primary: tokens.text,
    onPrimary: tokens.background,
    secondary: tokens.textAlt,
    onSecondary: tokens.background,
    error: tokens.text,
    onError: tokens.background,
    surface: tokens.background,
    onSurface: tokens.text,
    surfaceContainerHighest: tokens.backgroundAlt,
    outline: tokens.text,
    shadow: tokens.background,
    surfaceTint: tokens.background,
  );
  final buttonStyle = ButtonStyle(
    shape: const WidgetStatePropertyAll(square),
    side: WidgetStatePropertyAll(side),
    elevation: const WidgetStatePropertyAll(0),
    splashFactory: NoSplash.splashFactory,
    overlayColor: const WidgetStatePropertyAll(MonoTokens.none),
    textStyle: WidgetStatePropertyAll(text.copyWith(fontWeight: MonoScale.medium)),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: MonoScale.fontSize, vertical: MonoScale.line / 2),
    ),
    minimumSize: const WidgetStatePropertyAll(Size(0, MonoScale.line * 2)),
    backgroundColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.pressed) ? tokens.text : tokens.background,
    ),
    foregroundColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.disabled)
          ? tokens.textAlt
          : states.contains(WidgetState.pressed)
          ? tokens.background
          : tokens.text,
    ),
  );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: MonoScale.fontFamily,
    scaffoldBackgroundColor: tokens.background,
    canvasColor: tokens.background,
    splashFactory: NoSplash.splashFactory,
    highlightColor: MonoTokens.none,
    splashColor: MonoTokens.none,
    hoverColor: tokens.backgroundAlt,
    focusColor: tokens.backgroundAlt,
    dividerColor: tokens.text,
    dividerTheme: DividerThemeData(color: tokens.text, thickness: MonoScale.border, space: 0),
    textTheme: TextTheme(
      displayLarge: heading,
      displayMedium: heading,
      displaySmall: heading,
      headlineLarge: heading,
      headlineMedium: heading,
      headlineSmall: heading,
      titleLarge: heading,
      titleMedium: heading,
      titleSmall: heading,
      bodyLarge: text,
      bodyMedium: text,
      bodySmall: text.copyWith(color: tokens.textAlt),
      labelLarge: text.copyWith(fontWeight: MonoScale.medium),
      labelMedium: text,
      labelSmall: text.copyWith(color: tokens.textAlt),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: tokens.background,
      foregroundColor: tokens.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: tokens.background,
      shape: Border(bottom: side),
      titleTextStyle: heading,
      centerTitle: false,
      toolbarHeight: MonoScale.line * 3,
      actionsPadding: const EdgeInsetsDirectional.only(end: MonoScale.fontSize),
    ),
    filledButtonTheme: FilledButtonThemeData(style: buttonStyle),
    outlinedButtonTheme: OutlinedButtonThemeData(style: buttonStyle),
    textButtonTheme: TextButtonThemeData(style: buttonStyle),
    elevatedButtonTheme: ElevatedButtonThemeData(style: buttonStyle),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.zero, borderSide: side),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.zero, borderSide: side),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.zero,
        borderSide: side.copyWith(width: MonoScale.border * 2),
      ),
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: MonoScale.fontSize / 2,
        vertical: MonoScale.line / 2,
      ),
      labelStyle: text,
      hintStyle: text.copyWith(color: tokens.textAlt),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: tokens.background,
      elevation: 0,
      shape: Border.fromBorderSide(side),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: tokens.text,
      contentTextStyle: text.copyWith(color: tokens.background),
      elevation: 0,
      shape: square,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: tokens.text),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
      },
    ),
  );
}
