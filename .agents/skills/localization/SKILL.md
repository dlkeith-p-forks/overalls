---
name: localization
description: Implement or review localization of Elixir, Phoenix, browser, documentation, and terminal user-facing text using the repository's approved Elixir Localize integration, including locale negotiation, catalogs, formatting, and bidirectional UI behavior.
metadata:
  short-description: Localize user-facing strings safely
---

# Localization

Use this skill whenever changing a user-facing string, adding a locale, changing locale selection, or reviewing localization in Marshall, Porsche, or shared protocol presentation code. Read the repository's architecture and component guidance first, then inspect the pinned Localize dependency and its documentation before choosing APIs. Do not invent a translation-key or formatting abstraction when Localize/Gettext already provides one.

## Discovery and boundaries

- Inventory human-facing text across HEEx, LiveView modules, mailers, browser JavaScript, CLI/SSH presentation, and public documentation before editing. Keep logs, telemetry, protocol field names, command names, JSON keys, and other machine contracts language-neutral unless the task explicitly changes them.
- Find existing Gettext domains, locale configuration, catalog generation, interpolation conventions, and tests. Preserve established domains and identifiers; use stable source identifiers supplied by Localize/Gettext rather than ad-hoc atoms or translated strings.
- Treat translations as typed interfaces: every placeholder, plural/select variable, markup boundary, and format option must remain valid in every locale. Validate external locale tags before using them.

## Locale policy

- Define one central, typed policy for supported BCP 47 tags, canonicalization, `Accept-Language` negotiation, fallback, and text direction. Use the product's documented precedence (explicit user override, then browser preference, then default) and ensure an override is authorized and isolated to that user/session.
- Keep locale data bundled and deterministic in production. Unsupported, malformed, oversized, or ambiguous input must fall back safely without raising from request rendering.
- Derive `lang` and `dir` from the validated locale. Use logical CSS properties and semantic direction-aware layout; test both LTR and RTL with long strings and interpolated user data. Isolate interpolated values where the formatter supports bidi isolation.

## Catalog and implementation workflow

1. Extract or identify source messages and assign them to the existing catalog/domain. Preserve source context and placeholders.
2. Use the approved Localize API for new messages and structured formatting; retain legacy Gettext calls when compatibility requires them. Prefer CLDR-backed number, date, time, list, plural, and relative-time formatting over hand-built strings.
3. Add all supported locale catalogs (including English source/fallback) and translations or explicit reviewed fallbacks. Check PO syntax, duplicate/context collisions, placeholder parity, plural rules, and catalog completeness in CI.
4. For JavaScript, expose only validated locale data and generated catalogs from the server's build pipeline. Never embed secrets, arbitrary user input as code, or an unvalidated locale in a script.
5. For Porsche or protocol-facing human output, carry a validated locale only in a versioned, backward-compatible envelope. Keep machine/JSON output stable and default old clients/versions to the documented fallback locale.

## Verification

- Add focused tests for canonicalization, quality-weighted browser negotiation, fallback, persistence/reset, authorization and cross-session isolation, direction, and malformed input.
- Test every catalog for syntax, coverage, nonempty messages where required, placeholder/plural parity, and compilability. Test representative long and mixed-script strings.
- Run the relevant Elixir formatter/compiler/test/type and contract checks, plus Marshall's Monospace Web and browser probes for presentation changes. Run architecture/HLDD maintenance checks when behavior, configuration, protocols, operations, or verification evidence changes. Report missing native-language review honestly.

For detailed repository-specific locale lists or Localize API usage, consult the current localization ADR and any focused references added beside this skill; do not copy stale API examples into application code.
