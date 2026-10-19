# Mila's multilingual fallback fonts (ADR-0207, ADR-0226). Marshall serves
# WOFF2 conversions of these faces; Flutter's engine reads only TrueType and
# OpenType, so Mila bundles the original upstream bytes Marshall's manifest
# pins (`marshall/priv/static/fonts/noto-fonts.json`), each fetched by its
# recorded SHA-256 and copied beside its OFL notice. Nothing is subsetted or
# converted, and nothing is fetched at run time.
{ pkgs }:
let
  inherit (pkgs) lib;
  marshallFonts = ../../../../marshall/priv/static/fonts;
  manifest = lib.importJSON (marshallFonts + "/noto-fonts.json");
  # `noto-arabic.woff2` from `…/NotoSansArabic%5Bwdth,wght%5D.ttf` becomes
  # `noto-arabic.ttf`; the CJK source is OpenType CFF and keeps `.otf`.
  entry = font:
    let
      stem = lib.removeSuffix ".woff2" font.file;
      extension = lib.last (lib.splitString "." font.source_url);
    in
    {
      name = "${stem}.${extension}";
      licence = font.license_file;
      source = pkgs.fetchurl {
        name = "${stem}.${extension}";
        url = font.source_url;
        sha256 = font.source_sha256;
      };
    };
  fonts = map entry manifest.fonts;
in
# @cc [owner:ghuntley,label:build;localization] mila-pinned-noto-fonts
# Mila's fallback fonts MUST be the exact upstream bytes Marshall's font
# manifest pins, each shipped with its OFL notice; a font without a pinned
# digest or licence MUST NOT enter the bundle.
pkgs.runCommand "mila-noto-fonts" { } (''
  mkdir -p $out
'' + lib.concatMapStrings (font: ''
  cp ${font.source} $out/${font.name}
  cp ${marshallFonts + "/${font.licence}"} $out/${font.licence}
'') fonts + ''
  cp ${marshallFonts + "/noto-fonts.json"} $out/noto-fonts.json
'')
