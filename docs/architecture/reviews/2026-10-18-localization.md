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

## Account regression and documentation checkpoint

The account/admin focused run based on `953ce2633` recorded **41 passed**, seed
**539767**, using the isolated PostgreSQL fixture. It exercises Japanese SSH key
rename labels, success and overlong-label refusal, preserving the stored key
fingerprint. The Git settings assertion follows the fourth sibling section in
the combined account page. This evidence establishes LiveView behavior, without
claiming browser layout or native-language review.

Commit `cd61e1f3` adds 656 documentation translations: Arabic 250, Korean 250,
Japanese 125 and Finnish 31. PO parsing and protected inline-code, link-target
and placeholder checks passed for those additions. The catalog checker passed
in its non-strict mode; this mode reports remaining empty and source-equal forms
and does not establish translation completeness. Documentation completion,
linguistic review and nonvacuous all-locale browser coverage remain outstanding.

The earlier 45-second Bombadil trace was subsequently audited by aggregating
only locale/application snapshots, allowlisted route paths and violation counts
(token-bearing URLs were excluded). All **256** snapshots reported English and
the application marker; **zero** violations were recorded. This run therefore
does not establish any language transition, persisted override, reset, RTL or
cross-locale coverage. The browser acceptance gap remains open and requires
observed target-language states, rather than successful process exit alone.
The route histogram contains 244 sign-in states and 11 documentation states;
the remaining path was redacted. No authenticated settings state was observed.
The replacement run must assert successful fixture authentication before
exploring settings, then verify each selected locale after navigation/reload.

The older full Marshall `mix precommit` run was interrupted after subsequent
trunk merges made its snapshot obsolete and its distributed test pools exhausted
the scratch PostgreSQL connection limit. It had already reported ordinary and
distributed setup failures, including a known out-of-scope Inception failure;
it produced no passing full-gate result. An initial controller-focused run also
compiled before the last catalog addition and encountered database contention.
Current-tree acceptance requires a fresh scoped run in its own database
partition and a later full gate with bounded pools. Neither interrupted nor
contended execution is counted as passing evidence.

## Porsche human results and refusal guidance

The next renderer audit found raw receipt labels/statuses and pinning guidance
that was present only in machine hints. The human renderer now has explicit
Gettext messages for 50 reviewed refusal reasons, five outer receipt labels and
four receipt statuses. Unknown keys/reasons remain literal identifiers with the
existing escaping boundary; nested result data and the JSON renderer are
unchanged. All 59 new messages have translations in all 25 catalogs. Indonesian,
German and Swedish `Status` are explicitly reviewed same-spelling local words,
not copied English prose.

The focused Porsche tests passed **9/9**, including Japanese/Arabic pin guidance,
translated receipt labels/statuses, exact JSON bytes and literal nested/user
fields. On the pending tree following `c64480791`, pinned Elixir 1.20.4/OTP 29.0.6
`mix precommit` passed **110 tests**, the contract and Covenant gates, and
Dialyzer with **zero errors**. These are BEAM/application results and do not
establish native SSH rendering, linguistic review or packaged fleet acceptance.

## Browser save/reset navigation repair

The authenticated Bombadil investigation exposed the existing locale save/reset
redirect to `/settings#profile`: a fragment-only navigation can disconnect
LiveView without reloading the current document, leaving its old language and
direction visible. Successful persistence now pushes `locale-updated`; the typed
browser listener calls `location.reload()` to obtain a freshly rendered root,
including from fragment URLs and repeated saves. Authority and stored locale
policy remain unchanged. The JavaScript regression recorded **3 passed**; the
corresponding LiveView assertions and guarded browser rerun remain pending.

Earlier scratch browser attempts also lacked built CSS and raced the normal
automatic one-use magic-link form submission. These fixture defects were fixed
before restarting acceptance. They are not recorded as application layout or
authentication failures, and their successful process exits do not establish
locale coverage. Scratch Chromium's missing CJK fallback glyphs are a separate
font-environment limitation, not verified native typography.

## Commit and trunk integration scope

Commit `1e36beb3` passed all configured commit hooks. Native extraction produced
3,800 documentation identities; all 25 catalogs were reconciled exactly, retaining
13,132 existing nonempty translations and adding 25 Reflection title translations.
Retired translations were archived in scratch storage. Catalog validation passed;
remaining empty entries are explicit gaps. Five Porsche wording corrections
followed the recorded full precommit and have catalog/source review only.

Integration of `c91ac4435` preserves upstream Android display and GitHub framing
work. The registered Android display hook lacked an import; integration adds it.
The resulting browser bundle builds and localization JavaScript tests pass 3/3.
The HLDD Nix check passed before this merge; the final Marshall full gate and
post-fix authenticated Bombadil acceptance remain pending. AccountLive assertions
passed in the 59/60 focused run; its sole failure used stale compiled docs404
translations. A forced catalog compilation and fresh focused rerun were still in
progress at commit preparation. No passing full Marshall result is claimed.

A read-only upstream review found a separate GitHub response-header discrepancy:
the newly allowlisted original Link may survive alongside the rewritten Link.
This integration preserves upstream behavior and records the gap rather than
claiming the handbook's no-upstream-hostname assertion is established. ADR0201
remains partial; no localization authority or persistence decision changes.

## Continued documentation coverage and exact invariant reviews

The next batch adds 1,199 documentation entries: Arabic 500, Japanese 350, Korean
250 and Finnish 99. Entries preserve source identities and protected code, links
and placeholders; native-language acceptance remains unrecorded. The native
checker caught and prompted correction of a Japanese bare-URL boundary missed
by a scratch validator. Remaining empty entries remain explicit gaps.

The catalog gate now validates an exact reviewed-source-equality manifest keyed
by application, locale, domain, nullable context, source/plural source and plural
form. Its initial 24 Finnish default records cover individually inspected brands,
units and technical literals. Duplicate, stale, fuzzy or structurally invalid
reviews fail. Raw equality counts stay visible and reviewed invariant coverage
is reported separately. Any unreviewed copied plural form now remains a strict
gap even when another form is translated. Seven standalone ExUnit tests passed,
including a real Expo plural message, identity mismatches and review eligibility.
The strict full-catalog run correctly rejects remaining translation gaps.

A subsequent source audit localizes the malformed SSH approval browser refusal
using the existing generic Unavailable identity. It retains the 404/no-return-path
boundary; new English/Arabic/Japanese assertions await focused execution. Machine
listener and public machine-API refusal bytes remain protocol-facing literals.
A contract metadata separator in upstream Android framing is corrected from
label= to label: without changing any framing behavior. These changes preserve
ADR0201 and introduce no new runtime authority, persistence or domain boundary.

On this continued batch, the refreshed account/controller run passed **60 tests**,
with two excluded, seed532189, in43.3seconds. The previously stale Arabic
documentation404 assertion now passes after the real forced compile. The new
SSH refusal assertion is outside that run. The final non-strict catalog check
passed across all25locales/fourdomains, and current ADR203, scenario/view and
contract checks passed. After adding new maintained files to Git's source
projection, the Nix HLDD gate passed; its earlier unstaged projection had correctly
reported a stale Marshall digest. Full Marshall and authenticated Bombadil
acceptance are still running or pending and are not represented as passed.

## Concurrent trunk integration through `648793477`

A separate detached worktree integrates the completed localization checkpoint
with upstream Antithesis outcome-consistency/same-key retry checks, Android
tooling and relay repairs, Gettext plural-context reconstruction, generated SQL
fixture isolation, and Windows editor-candidate verification inputs. Existing
ADR-0201, ADR-0200 and ADR-0206 decisions and partial acceptance remain unchanged.
The repeated AndroidDisplay import introduced by combining the branches is
removed while retaining the existing hook registration and local-only assets.

The integrated source passes JavaScript syntax and the pinned esbuild bundle;
five standalone plural/relay tests pass, including Arabic's six categories and
viewer attachment. These use pinned Elixir and the existing dependency closure,
without rebuilding the active application. Eleven lifecycle workload tests pass
with the pinned Python/wheel closure, and changed Python static gates pass.
Native governance checks and evaluated Nix HLDD passed before this later merge;
they are rerun for its final source projection. The full Marshall suite,
authenticated browser journeys, native Windows candidate execution and
linguistic acceptance remain separate and are not claimed by this integration.

## Continued translation and authenticated browser evidence

A further catalog batch adds 1,010 documentation translations: Arabic100,
Bengali300, Japanese400, Finnish10 and Swedish200. Entries retain their existing native
Gettext identities; raw-entry replacement preserves all unrelated catalog text.
This preserves ADR-0201 and introduces no architecture, authority or protocol
change. Documentation coverage and linguistic acceptance remain incomplete.

Authenticated Bombadil run15 completed naturally with exit0 and zero violations:
25 saved locales, all25 persisted after actual document reload, and all100
locale/theme/viewport combinations (light/dark,390×844 and1440×1000). It also
verified repeated English saves from `#profile`, browser-default Japanese reset,
computed LTR/RTL direction, code direction and bounded layout. The immutable
runtime ebin SHA256 was
`42397d898baba1715702def9059361f69b6ee15c58efecba1b8c9747adb891d7`;
trace SHA256 was
`d6ef781bd7571959e23a56add4969c2a9df089ae8a1c5aea060cc604614da64a`.
This is settings-journey browser evidence, not all-route, native Porsche or
linguistic acceptance. Scratch Chromium CJK font coverage remains a limitation.

The unchanged100-case Enrico history property passes in isolation in53.6seconds
with a180-second finite execution limit. Its ordinary60-second timeout failed
under the concurrent full-suite load; the isolated pass does not establish a
passing full suite. No property cases or assertions were removed.

The deterministic documentation extractor now matches3805 current source units.
Catalog reconciliation retains two direct messages for3807 identities, adds10
new identities and retires3. All3797 retained entry blocks per locale preserve
metadata, fuzzy flags and translations byte-for-byte; one retired nonempty
translation is privately archived. Native Gettext extraction freshness remains
a separate pending check. The localization skill passes its structural validator.

The publication merge through `3c139bcce` preserves the incoming Antithesis
assertion message as a literal for SDK discovery, without changing its predicate.
Fleet launch-failure diagnostics add process identity inspection using
PID, command name and executable path; they do not print command arguments.
These harness-only changes preserve the existing ownership, topology and
acceptance boundaries. No additional native machine execution is claimed.

## Native extraction and continued translation

Native Gettext extraction completed successfully in isolated fresh builds for
both applications. Marshall's default inventory grows1414→1416 with exactly
`Android display canvas` and `Waiting for display relay.`; browser41,
documentation3807 and errors24 remain unchanged. Porsche's128-message template
is byte-identical. All864 captured source/configuration/catalog hashes stayed
unchanged during those runs. The two new UI identities now have translations
in every policy locale, including the English source catalog.

A subsequent documentation batch adds3,042 translations: Bengali1,600,
Swedish1,000, Japanese400 and Finnish42. A retired Swedish source differing only
by a trailing newline was reviewed and mapped to its otherwise identical current
identity; no changed prose inherited an unrelated translation. Swedish action
Start now reads Starta and its browser live badge reads ● aktiv.

The invariant manifest adds3,360 exact records for140 individually reviewed
code-only configuration-path headings across24 non-English locales;3,356 were
previously empty. These headings contain no natural-language prose. Their exact
Nix identifiers and Markdown code spans remain unchanged. They are reported as
reviewed technical invariants, separately from translated prose, with no wildcard
or locale-wide exemption. The full100-catalog structure/identity/placeholder/
Markdown check passes after these additions. Coverage and linguistic review
remain incomplete; strict completeness is not claimed.

Marshall and Porsche precommit aliases now retain native
`gettext.extract --check-up-to-date` before forced Dialyzer. This detects stale
native source inventories and reference locations, beyond catalog/template
identity equality, and necessarily force-compiles application sources. Porsche's
new freshness command passes and its current catalog tests pass3/3. Marshall's
new freshness run is pending; no complete new Marshall gate is claimed.
The localization skill documents regeneration and native freshness and passes
its structural validator. Existing ADR-0201 remains partial; no domain, authority,
persistence, protocol or production configuration changes arise from this batch.

The existing publications regression timed query detection against a first CTE
that now follows `approved_editor`. Both test matchers now identify the unchanged
`clock AS MATERIALIZED` CTE regardless of its position. The focused suite passes
13 tests with2 ordinary capacity exclusions in18.8seconds, seed0, finite180-second
aggregate limit, using the isolated current native build and database. Production
queries, fixture size, assertions and timeout bounds are unchanged. The older
full Marshall precommit remains running with unrelated failures; this focused
result does not establish a passing full suite.
