# ADR-0226: The Monospace Web on Flutter

- ID: ADR-0226
- Date: 2026-10-18
- Status: accepted
- Implementation: partial
- Components: Mila
- Supersedes: none
- Superseded by: none

## Context

Marshall's browser presentation follows The Monospace Web
([ADR-0161](0161-monospace-web-presentation.md)). Mila should look and behave
like the same product without porting CSS.

## Decision

1. `mila/app/lib/ui/tokens.dart` is the only file with colour literals: four
   tokens per theme, light `#000/#666/#fff/#eee` and dark `#fff/#aaa/#000/#111`.
2. The theme uses JetBrains Mono (500, 500 italic, 600, 800; bundled with its
   licence) at a 1.2 line grid, 2 px borders, zero radius, zero elevation and
   no ink splash, with System/Light/Dark appearance.
3. Icons are text glyphs mirroring the web glyph table; there is no icon font
   (`uses-material-design: false`). Mila never renders glyphs the bundled font
   lacks: `↻` and `⎘` are in the web table but not in JetBrains Mono, so Mila
   uses words for refresh and copy.
4. State is always text, weight or inverse video (`[running]`, bold, italic,
   inverse danger), never colour alone. Identifiers and terminals stay LTR in
   right-to-left locales.

Authorization: the approved Mila plan (2026-10-18).

## Alternatives

- **Material or Cupertino defaults.** Rejected: a second visual language for
  one product.

## Consequences

The web glyph table's comment claiming every glyph renders in JetBrains Mono is
inaccurate for `↻` and `⎘`; browsers fall back to another font for them.

## Invariants and verification

- No colour literal, icon font, rounded corner, shadow, gradient or elevation
  outside the tokens file (structural test).
- Text meets 7:1 and secondary text 4.5:1 contrast on both backgrounds.
- Every glyph Mila may render is in every bundled weight (TrueType cmap test);
  the glyph enum matches `core_components.ex`.
- Goldens for light, dark and Arabic.

## Implementation evidence

`mila/app/lib/ui/{tokens,theme,widgets}.dart`;
[`mila/app/test/design_system_test.dart`](../../../mila/app/test/design_system_test.dart) and `test/golden_test.dart` with
`test/goldens/`; run by the `mila-test` Nix check.

The M2–M4 screens add `Segmented` and `TopTabs` to
[`widgets.dart`](../../../mila/app/lib/ui/widgets.dart) and a terminal theme,
`monoTerminalTheme`, to [`tokens.dart`](../../../mila/app/lib/ui/tokens.dart).
The theme takes its foreground, background, cursor and selection colours from
the tokens and the ANSI palette from xterm's defaults, as the web terminal
does. The terminal view stays left to right under right-to-left locales.
The `terminal_ar.png` and `thread_ar.png` goldens and the machine goldens were
generated and pass in `mila-test` (recorded in the
[M6 review](../reviews/2026-10-19-mila-m6.md)).

**Tables (2026-10-19).** `MonoTable` in
[`widgets.dart`](../../../mila/app/lib/ui/widgets.dart) draws the web table rules
(2 px above the table, under the header and under each row) with a bold header
row. The machine Info tab's sharing panel uses it; the new
`machine_info_light.png` golden shows it.

**Script fallbacks (2026-10-19).** Mila now bundles the
[ADR-0207](0207-bundled-multilingual-font-fallback.md) Noto faces behind
JetBrains Mono, resolving the open question below with the task's
authorization. Flutter reads TrueType and OpenType but not WOFF2, so
[`nix/domains/artifacts/mila/fonts.nix`](../../../nix/domains/artifacts/mila/fonts.nix)
fetches the original upstream bytes that Marshall's
[manifest](../../../marshall/priv/static/fonts/noto-fonts.json) pins, by their
recorded SHA-256, and copies each with its OFL notice and the manifest. The Nix
builds copy that store path into the gitignored `mila/app/assets/fonts/noto`,
and the devenv `mila:fonts` task links it there. `pubspec.yaml` declares one family per face.
`MonoScale.fontFamilyFallback` lists them in an order that stands in for the
web's `unicode-range`: Latin, Arabic, Indic, symbols, then CJK. The theme and
the terminal use this list. `main.dart` registers the OFL notices with the
licence registry
([`font_licences.dart`](../../../mila/app/lib/ui/font_licences.dart)).
[`test/font_fallback_test.dart`](../../../mila/app/test/font_fallback_test.dart)
checks five properties:

- the fallback order matches `pubspec.yaml`;
- the bundled faces match the manifest, each with its licence;
- every character of every ARB catalog has a bundled face;
- each Arabic, Indic and CJK code point reaches the face Marshall's CSS
  assigns it, not an earlier one;
- `↻` reaches the symbol face, while no bundled face draws `⎘`.

The goldens load the same faces, so the Arabic goldens now show shaped Arabic
instead of the test font's boxes. They were regenerated and reviewed.

## Open questions

Whether to correct the web glyph table comment or substitute glyphs on the web.

[ADR-0207](0207-bundled-multilingual-font-fallback.md) later replaced
ADR-0161's exclusive-typeface clause for the browser and bundled Noto fallbacks
there, because browser rendering otherwise depends on the reader's installed
fonts. Whether Mila should also bundle those faces was open here. **Resolved
2026-10-19:** Mila bundles them as fallbacks behind JetBrains Mono (see
Implementation evidence). The bundle grows by 22,297,352 bytes (21.3 MiB), 15.6 MiB of it the
CJK face, and the extra size is accepted, as it is for the web.

Remaining:

- **Weights.** The variable Noto faces render at their default instance;
  Mila does not map 500/600/800 to the `wght` axis, so the engine synthesizes
  bold.
- **Device verification.** Shaping and layout of each supported script on iOS
  and Android devices are untested. The Linux goldens show Arabic only, under
  `flutter_test`'s engine.
- **Two web glyphs.** `↻` now has a bundled face, but Mila keeps using words
  for refresh and copy (decision 3); `⎘` still has none.

## Related decisions

[ADR-0161](0161-monospace-web-presentation.md),
[ADR-0207](0207-bundled-multilingual-font-fallback.md),
[ADR-0201](0201-localized-human-surfaces.md),
[ADR-0220](0220-mila-client-over-porsche-ssh.md).
