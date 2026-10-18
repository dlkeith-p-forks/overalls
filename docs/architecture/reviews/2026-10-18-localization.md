# Localized human surfaces (2026-10-18)

Scope: [ADR-0201](../decisions/0201-localized-human-surfaces.md). Reviewed
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
5. **Interpolation:** The application-local Gettext interpolation adapters preserve
   legacy source identifiers, placeholder syntax and missing-binding semantics.
   RTL substitutions pass through Localize's MF2 formatter with `bidi: :isolate`;
   this adds no translation-key registry or protocol dependency. LTR substitutions
   retain Gettext behavior. Catalog prose and external data are not evaluated as
   formatter source.
6. **Evidence:** Latest focused localization regression run: **74 passed**, seed
   **727879**, on the working tree based on `28d508dcc239120ec483afb70558fe1f451d7b8c`.
   The pinned Elixir 1.20.4/OTP 29.0.6 run used an isolated PostgreSQL fixture and
   included account/settings, Git preferences, persisted locale and time-zone
   authorization, negotiation/process isolation, all 25 CLDR date/time locales,
   mixed-script bidi interpolation, protected Markdown/SSH tokens, magic-link
   flow, administrative Lilly node labels and administrative job labels. This is
   BEAM/LiveView evidence; it does not establish native browser layout, packaged
   Porsche sessions or linguistic quality. Extraction produced 1,355 default
   catalog identities. Full precommit remains blocked by final review receipts
   and catalog completion; documentation translations remain incomplete.

## HLDD source-group review

The following source-group findings describe the recorded focused snapshot
above. Later integration adds the source changes and evidence gaps described
by the suspension, reflection and fleet reviews; their gates remain separate.

Marshall's reviewed changes keep locale as presentation: saved overrides are
self-only, retired users and foreign targets refuse, browser negotiation is
bounded, and Arabic/Urdu values receive Localize isolation. Git preferences live
inside the combined Account page; the current integration places them in a fourth
anchored section under the same fresh-login gate. Chapter 08 describes CLDR formatting, protected documentation
tokens, catalog validation and the settings location. Chapter 20 retains explicit
authority and native/browser evidence limits. The localization scenario records
the executed bounded tests below without closing its broader gaps.

Protocol, Lilly and deployment have no source changes relative to this working
baseline. Their shared handbook chapter digests changed through presentation and
coverage corrections. The protocol locale envelope and English compatibility
fallback are unchanged; no new host, service, option, transport or native storage
claim is introduced. Source-derived ownership still lists Lilly Checkpoint and
Marshall WakeRequest/WakeRequestKey/Ingress Relay resources already declared in
the baseline; the regenerated inventory repairs omissions without assigning new
authority or deployment placement. The options-reference check also found four
existing `services.audi.relay` declarations missing from chapter 18. Regeneration
restores their declared address/peer constraints, disabled default and port 9445;
this adds reference text without changing fleet configuration.

Porsche's changes configure the same bidi-safe interpolation contract and update
human command summaries/catalogs. Command names, usage, option tokens and JSON
contracts stay literal. The focused Marshall run does not execute Porsche's own
suite. Canonical governance assignments retain localization/Git as ADR-0201/0198, tighten
the localization skill/catalog checker and restore recognition of actual Hegel
property declarations in coverage discovery; historical revised test fixtures
remain `present` unless their exact execution is recorded. No historical native
result is upgraded by these structural checks.

## Required verification

- Negotiation, malformed headers, override/reset, fallback and cross-user
  isolation tests.
- Catalog placeholder/completeness checks for every supported locale.
- Browser checks in English, Japanese, Hindi, Filipino, Estonian, Finnish,
  Swedish, Portuguese and Arabic, including both themes and RTL layouts.
- Porsche tests for locale transport, old-version fallback and unchanged
  machine-readable output.
