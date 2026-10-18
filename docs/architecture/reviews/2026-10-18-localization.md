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

## Public documentation direction follow-up

The standalone public documentation layout now uses LocalePlug language and direction assignments, preserving ADR-0201 and ADR-0161 without changing authority, dependencies or protocol contracts. The docs controller suite recorded **7 passed**, seed **199192**, against the pending change based on `b595f7c2f`. Assertions cover English/Japanese LTR, Arabic/Urdu RTL, Content-Language and absence of session cookies. A 45-second scratch Bombadil rerun exited 0 after the original run exposed the missing documentation direction; exploration coverage has not been audited, so this is not all-locale browser acceptance. Documentation translation completeness and native-language review remain outstanding.

## Porsche catalog repair and full gate

At `1f79f63e6`, Porsche `mix precommit` passed: **108 tests passed**, followed by **zero Dialyzer errors**. The preceding full run exposed 317 missing extracted message identities across 25 locale catalogs; exact POT blocks and faithful translations were appended. `test/localization_catalog_test.exs` then passed all three tests (seed **570510**), checking every locale against the terminal extraction inventory, placeholder parity and Japanese human errors with stable JSON. This is BEAM/catalog evidence, not a native SSH journey or native-speaker review.

## Continued source audit

The attribute/flash audit found a raw SSH key Description label, two rename flashes and four administrative verification/refusal flashes. They now use existing Gettext source identifiers with translations in all 25 locales. The administrative authority checks and their halting behavior are unchanged. French `Description` is an explicitly reviewed identical cognate, not evidence of a translated English prose fallback. The corrected date-component suite recorded **5 passed**, seed **685749**, in the working tree preceding these UI message additions; this establishes component/date behavior only. Full Marshall execution remains separate and has reported failures outside that focused scope.

The continued controller audit identifies remaining untranslated human HTTP errors in repository launch, installer/download, SSH trust, browser sign-in, editor, inference export and raw Git controllers. Their existing pipelines already apply LocalePlug. Successful scripts, archives, manifests, checksums, CSV schemas, raw Git bytes and redirect/session keys must remain language-neutral; only refusal prose is a localization target. This audit is outstanding implementation work, not a claim of complete source coverage.
