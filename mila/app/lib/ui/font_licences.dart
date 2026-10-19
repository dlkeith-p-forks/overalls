import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A bundled typeface and the asset holding its SIL Open Font License notice.
typedef FontLicence = ({String face, String asset});

/// Every typeface Mila bundles (ADR-0207, ADR-0226). The OFL requires its
/// notice to accompany each copy of the fonts, so the notices ship as assets
/// and appear in the licence registry beside the packages' licences.
const List<FontLicence> bundledFontLicences = [
  (face: 'JetBrains Mono', asset: 'assets/fonts/jetbrainsmono-OFL.txt'),
  (face: 'Noto Sans Mono', asset: 'assets/fonts/noto/noto-mono-OFL.txt'),
  (face: 'Noto Sans Arabic', asset: 'assets/fonts/noto/noto-arabic-OFL.txt'),
  (face: 'Noto Sans Devanagari', asset: 'assets/fonts/noto/noto-devanagari-OFL.txt'),
  (face: 'Noto Sans Bengali', asset: 'assets/fonts/noto/noto-bengali-OFL.txt'),
  (face: 'Noto Sans Telugu', asset: 'assets/fonts/noto/noto-telugu-OFL.txt'),
  (face: 'Noto Sans Tamil', asset: 'assets/fonts/noto/noto-tamil-OFL.txt'),
  (face: 'Noto Sans Math', asset: 'assets/fonts/noto/noto-symbols-OFL.txt'),
  (face: 'Noto Sans Mono CJK SC', asset: 'assets/fonts/noto/noto-cjk-OFL.txt'),
];

/// Adds the font notices to [LicenseRegistry], read from [bundle] on demand.
void registerFontLicences(AssetBundle bundle) {
  LicenseRegistry.addLicense(() async* {
    for (final licence in bundledFontLicences) {
      yield LicenseEntryWithLineBreaks([licence.face], await bundle.loadString(licence.asset));
    }
  });
}
