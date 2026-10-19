# ADR-0201: Localized human-facing surfaces

- ID: ADR-0201
- Date: 2026-10-18
- Status: accepted
- Implementation: partial
- Components: MarshallWeb, Porsche, protocol
- Supersedes: none
- Superseded by: none

## Context

Marshall and Porsche expose human-facing text in browser pages, emails,
interactive SSH output and documentation. Users need an explicit language
preference while browser negotiation remains a useful default. Localized output
must not alter machine identifiers, JSON schemas, diagnostic event metadata or
terminal bytes.

## Decision

1. Use the Localize/LocalizeWeb stack with offline, checked-in CLDR data and
   Gettext-compatible catalogs. The supported locale set is the reviewed central policy in
   [Marshall.Localization](../../../marshall/lib/marshall/localization.ex),
   including Japanese, Hindi, Filipino, Estonian,
   Finnish, Swedish and Portuguese variants.
2. Resolve locale as an authorized persisted user override, then session
   locale, then a validated `Accept-Language` choice, then English. Invalid,
   oversized or unsupported values fall back safely. CLDR supplies language,
   number/date formatting and direction; Arabic and Urdu render right-to-left.
3. Keep translation identifiers stable through the library's catalog identity
   (`msgid` plus domain/context). Do not introduce an application-specific
   opaque key registry. Interpolated human text uses bidi-safe formatting.
4. Carry the validated locale in the versioned Marshall-to-Porsche session
   envelope. Porsche localizes interactive prose only; protocol names,
   machine-readable responses remain unchanged. During the converged rollout,
   consumers tolerate an absent locale as English; remove transition-only
   compatibility after convergence under ADR-0159.
5. Persist only the validated override. Authorization, session isolation,
   fallback behavior and translation completeness are tested as contracts.
6. Organize native Gettext catalogs by locale and feature domain. Source strings,
   contexts and plurals retain their identity within the owning feature; reusable
   components own shared messages. Public `/docs/*` prose is localized. Handbook
   chapter contents, titles and generated command references remain English,
   independently of the reader controls' active language.
7. Render supported scripts with the bundled font fallbacks in ADR-0207 while
   retaining native shaping, validated HTML language and the existing presentation
   constraints. Catalog coverage and font character coverage are separate from
   observed browser legibility and layout.

## Consequences

The account settings surface gains a language choice and browser-default reset.
HTML carries `lang` and `dir`; web presentation uses logical CSS properties.
Catalog review and native linguistic review remain ongoing. No new domain,
host or deployment boundary is introduced.

## Alternatives

- An opaque translation-key registry duplicates catalog identity and is rejected.
- Runtime CLDR downloads add deployment dependence and are rejected.

## Invariants and verification

Coverage is recorded in the localization architecture review and HLDD scenario
ledger. Structural catalog checks, browser LTR/RTL checks and protocol tests are
required before implementation is marked complete.

## Implementation evidence

The baseline human surfaces are [AccountLive](../../../marshall/lib/marshall_web/live/account_live.ex) and [Porsche](../../../porsche/mix.exs). These links identify integration points, not completed localization. Implementation remains partial pending final source and executed evidence.

## Open questions

Packaged browser/Porsche execution and complete translation coverage remain
unverified. Native-speaker review is not a release requirement for this task.

## Related decisions

- [ADR-0159](0159-remove-legacy-compatibility.md): converged compatibility lifetime.
- [ADR-0196](0196-single-account-settings-page.md): account settings placement.
- [ADR-0161](0161-monospace-web-presentation.md): presentation constraints carried
  forward by ADR-0207.
- [ADR-0207](0207-bundled-multilingual-font-fallback.md): local script font coverage
  and native shaping.
