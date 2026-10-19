import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

/// Porsche locales that Flutter's Material and Cupertino catalogs lack, mapped
/// to the catalog whose script and direction they share. Mila's own strings
/// stay in each locale's ARB catalog; only framework strings (tooltips,
/// dialog buttons) borrow from the base.
const Map<String, Locale> frameworkFallbacks = {
  'arz': Locale('ar'),
  'ha': Locale('en'),
  'pcm': Locale('en'),
};

/// Languages written right to left that Flutter's widgets catalog does not
/// already treat as such.
const Set<String> _extraRightToLeft = {'arz'};

/// Resolves a locale to one the framework catalogs support.
@visibleForTesting
Locale frameworkLocale(Locale locale) => frameworkFallbacks[locale.languageCode] ?? locale;

/// Material strings for every Mila locale, borrowing for [frameworkFallbacks].
final class FallbackMaterialLocalizationsDelegate
    extends LocalizationsDelegate<MaterialLocalizations> {
  const FallbackMaterialLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) =>
      GlobalMaterialLocalizations.delegate.isSupported(frameworkLocale(locale));

  @override
  Future<MaterialLocalizations> load(Locale locale) =>
      GlobalMaterialLocalizations.delegate.load(frameworkLocale(locale));

  @override
  bool shouldReload(FallbackMaterialLocalizationsDelegate old) => false;
}

/// Cupertino strings for every Mila locale, borrowing for [frameworkFallbacks].
final class FallbackCupertinoLocalizationsDelegate
    extends LocalizationsDelegate<CupertinoLocalizations> {
  const FallbackCupertinoLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) =>
      GlobalCupertinoLocalizations.delegate.isSupported(frameworkLocale(locale));

  @override
  Future<CupertinoLocalizations> load(Locale locale) =>
      GlobalCupertinoLocalizations.delegate.load(frameworkLocale(locale));

  @override
  bool shouldReload(FallbackCupertinoLocalizationsDelegate old) => false;
}

/// Text direction for every Mila locale, including right-to-left languages
/// the framework catalog does not list.
final class FallbackWidgetsLocalizationsDelegate
    extends LocalizationsDelegate<WidgetsLocalizations> {
  const FallbackWidgetsLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<WidgetsLocalizations> load(Locale locale) =>
      _extraRightToLeft.contains(locale.languageCode)
      ? SynchronousFuture<WidgetsLocalizations>(const _RightToLeft())
      : GlobalWidgetsLocalizations.delegate.load(frameworkLocale(locale));

  @override
  bool shouldReload(FallbackWidgetsLocalizationsDelegate old) => false;
}

final class _RightToLeft extends DefaultWidgetsLocalizations {
  const _RightToLeft();

  @override
  TextDirection get textDirection => TextDirection.rtl;
}

/// The framework delegates Mila installs after its own catalog.
const List<LocalizationsDelegate<Object?>> frameworkDelegates = [
  FallbackMaterialLocalizationsDelegate(),
  FallbackWidgetsLocalizationsDelegate(),
  FallbackCupertinoLocalizationsDelegate(),
];
