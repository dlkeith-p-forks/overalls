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
The new `terminal_ar.png` and `thread_ar.png` goldens and the regenerated
machine goldens (the machine list gained a threads button) are **not yet
generated or run**. Remaining: tables.

## Open questions

Whether to correct the web glyph table comment or substitute glyphs on the web.

## Related decisions

[ADR-0161](0161-monospace-web-presentation.md),
[ADR-0201](0201-localized-human-surfaces.md),
[ADR-0220](0220-mila-client-over-porsche-ssh.md).
