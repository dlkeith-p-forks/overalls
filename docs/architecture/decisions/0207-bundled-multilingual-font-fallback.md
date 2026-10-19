# ADR-0207: Bundled multilingual font fallback

- ID: ADR-0207
- Date: 2026-10-19
- Status: accepted
- Implementation: partial
- Components: Marshall Web, browser assets
- Supersedes: ADR-0161
- Superseded by: none

## Context

The authorized localization plan requires readable browser text for all supported
locales, including Arabic, Urdu, Hindi, Bengali, Telugu, Tamil, Chinese, Japanese
and Korean. JetBrains Mono does not contain all their glyphs. ADR-0161's exclusive
typeface clause would leave these translations dependent on fonts installed on
the reader's device. Catalog completeness alone cannot establish readable text.

The same plan retains The Monospace Web presentation and its prohibition on
external resources. This decision replaces only ADR-0161's requirement that
JetBrains Mono be the only typeface; its original rationale remains in that
record. All other presentation and terminal constraints are carried forward.

## Decision

Keep JetBrains Mono as the primary font and the source of the `1ch` layout unit.
Bundle reviewed Noto fallback families for scripts and symbols missing from it.
The initial eight faces are Noto Sans Mono CJK, Noto Sans Mono, Noto Sans Arabic,
Noto Sans Devanagari, Noto Sans Bengali, Noto Sans Telugu, Noto Sans Tamil and
Noto Sans Math. The application-owned `Overalls Noto CJK`, `Overalls Noto
Mono`, `Overalls Noto` and `Overalls Noto Symbols` family aliases preserve their
distinct weight selection. CSS Unicode ranges select the applicable face;
browser requests remain same-origin. The family stack ends with the existing
generic monospace fallbacks.

Preserve native shaping, combining marks and language-specific glyph selection.
Retain complete font glyph and shaping tables when converting the pinned source
fonts to WOFF2. Use the validated HTML language for language-specific forms.
The grid constrains layout boxes, spacing and rhythm; it does not require each
Unicode code point or shaped grapheme to occupy one Latin character cell. Do not
disable joining, split graphemes or force letter spacing to simulate that result.

Keep the original four colour tokens per theme, both themes, semantic HTML and
text glyphs, local resources, stable hooks and identifiers, and renderer-owned
terminal boundaries required by ADR-0161. This decision introduces no new
authorization, durable state, domain, protocol or deployment boundary. The user's
approved multilingual implementation authorizes this narrow presentation change.

Pin each upstream source and licence, record source and output SHA-256 digests,
and keep the licences beside the assets. Font conversion is development tooling;
application builds and requests use checked-in assets without downloading fonts.
Check catalog text and locale autonyms against the actual bundled coverage when
translations or supported locales change. A generic system fallback is not proof
that the bundled fonts cover a supported message.

## Alternatives

- Device fonts alone keep the bundle smaller but make supported-script rendering
  dependent on the user's operating system and installed fonts.
- External font services violate the accepted same-origin resource boundary.
- Replacing JetBrains Mono throughout would unnecessarily change the Latin
  presentation and grid metrics.
- Subsetting by current message characters reduces transfer size but risks
  removing shaping dependencies and glyphs needed by dynamic user data. Complete
  script faces retain those tables at the cost of larger checked-in assets.

## Consequences

The static asset set grows, particularly for CJK. Unicode ranges let browsers
load applicable script faces as needed. Font deployment follows the existing
asset digest and cache path. Translation changes need glyph-coverage checks in
addition to catalog checks. Font hashes and character coverage cannot establish
correct joining, legibility, line breaking or every browser's rendering.

## Invariants and verification

- Every font request stays on the application origin; licence and pinned digests
  match the vendored assets.
- Every supported catalog and locale autonym is covered by the selected bundled
  faces. Newly unsupported characters fail review rather than silently relying
  on a developer's installed fonts.
- JetBrains Mono remains the primary Latin/grid font. Complex scripts retain
  their native shaping and CJK text retains language-specific glyph selection.
- Both themes and mobile/desktop layout remain usable in LTR and RTL. Browser
  evidence must inspect representative script rendering, missing glyphs,
  clipping, overflow and same-origin loading; prefer Bombadil for new probes.
- Existing colour, grid, accessibility, hook and terminal contracts remain in
  force. Static checks do not replace scoped browser evidence.

## Implementation evidence

[Font declarations](../../../marshall/assets/css/fonts.css) select the eight local
script faces and [tokens](../../../marshall/assets/css/tokens.css) keep JetBrains
Mono first in the family stack. The [font inventory](../../../marshall/priv/static/fonts/README.md)
describes the assets and licences; the [manifest](../../../marshall/priv/static/fonts/noto-fonts.json)
pins their sources, conversion tools and digests. The
[vendoring tool](../../../scripts/vendor_localization_fonts.py) reproduces the
conversion and checks asset integrity without changing runtime dependencies.
The [localization review](../reviews/2026-10-19-localization-feature-catalogs.md)
records executed checks separately from outstanding browser evidence.

Implementation remains partial until current packaged browser evidence establishes
the stated script, theme and layout scope. Asset presence and structural catalog
coverage do not establish native-script visual acceptance.

## Open questions

No unresolved product choice. Record current packaged browser rendering and
cross-browser shaping evidence separately from static coverage.

## Related decisions

- [ADR-0161](0161-monospace-web-presentation.md): all requirements except exclusive
  use of JetBrains Mono are carried forward.
- [ADR-0201](0201-localized-human-surfaces.md): supported locales, language
  negotiation, stable catalog identity and bidirectional text.
