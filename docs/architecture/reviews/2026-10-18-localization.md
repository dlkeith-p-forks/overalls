# Localized human surfaces (2026-10-18)

Scope: [ADR-0200](../decisions/0200-localized-human-surfaces.md). Reviewed
against the requested Marshall web, Porsche interactive output, Localize
integration, locale preference and RTL behavior.

## Findings

1. **Boundary:** Localization is a presentation and protocol-envelope concern.
   It introduces no Ash domain, host, placement or execution authority.
2. **Authority:** A persisted language override is self-only and validated;
   browser negotiation is untrusted input and cannot grant access. Session
   locale is scoped to the authenticated browser/session.
3. **Transport:** The protocol carries a bounded canonical locale for human
   rendering. Older peers default to English. JSON, status codes, identifiers,
   logs and terminal byte streams remain language-neutral.
4. **RTL/bidi:** Direction comes from CLDR, with logical CSS and explicit bidi
   isolation around interpolated values. Arabic and Urdu are the RTL cases;
   all other supported locales are LTR.
5. **Evidence gap:** This review is source/design evidence until catalog,
   browser, protocol compatibility and Porsche tests execute. Translation
   quality needs native review after structural completeness passes.

## Required verification

- Negotiation, malformed headers, override/reset, fallback and cross-user
  isolation tests.
- Catalog placeholder/completeness checks for every supported locale.
- Browser checks in English, Japanese, Hindi, Filipino, Estonian, Finnish,
  Swedish, Portuguese and Arabic, including both themes and RTL layouts.
- Porsche tests for locale transport, old-version fallback and unchanged
  machine-readable output.
