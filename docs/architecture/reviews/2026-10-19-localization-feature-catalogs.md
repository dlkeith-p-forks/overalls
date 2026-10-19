# Localization feature catalogs, rendering and handbook boundary

This review covers Marshall and Porsche changes from `97809b51f`, under
ADR-0201, ADR-0161 and ADR-0207, plus the incoming Android display integration
under ADR-0206. Catalog partitioning preserves the accepted localization
architecture: explicit native Gettext domain/context/source/plural identities,
Localize formatting and validated locale preferences. Partitioning introduces no
Ash domain, durable authority, protocol or listener changes. The integrated diff
also bundles script fonts and repairs incoming browser dependency packaging as
described below; those asset changes are distinct from catalog organization.

Marshall assigns rendering calls to feature domains; reusable navigation and
components use `shared`. Porsche separates onboarding, help, management and
sessions. Identical source wording used by different features has independent
domain identities. Catalogs remain in native locale/LC_MESSAGES directories;
there is no new message-key registry. Both applications retain their existing
Gettext backend compilation configuration.

The previous documentation extractor scanned both public guides and handbook
chapters, contradicting the user's explicit scope. Extraction now selects only
public guides and command summaries. Handbook chapter titles and bodies render
from English source with explicit English/LTR attributes, including generated
command references. Reader controls remain localized. This preserves the
authenticated section boundary and does not publish handbook material.

ADR-0207 replaces only ADR-0161's exclusive-typeface clause. JetBrains Mono remains
the primary Latin/grid font; eight local Noto faces cover CJK, Arabic/Urdu,
Devanagari, Bengali, Telugu, Tamil, extended Latin used by Hausa and interface
symbols. Complete fonts retain shaping and
language-specific tables, with pinned upstream sources, OFL notices and output
hashes. CSS Unicode ranges select the applicable local face. Layout boxes retain
the character grid while script text uses native shaping. Colour tokens, themes,
semantic HTML, resource origin, hooks and terminal renderer boundaries remain
unchanged. Static font integrity and character coverage are separate from
packaged browser shaping and legibility. The settings matrix below records its
exact locale, theme and viewport scope; cross-browser shaping remains unverified.

The incoming trunk Android display client imported noVNC without its required
Pako files and used a bundle format that could not retain upstream top-level
await. The integration restores noVNC 1.7.0's exact dependency files and licence
notices from commit `63107bd06d9e1f6136ff21aeda8cd62cbf0d433e`, with a
[provenance and hash manifest](../../../marshall/assets/vendor/novnc/upstream.json).
The application bundle uses `--format=esm` and the root layout loads it with
`type="module"`. There are no patches to vendored upstream files or runtime CDN
imports. This repairs packaged browser dependency loading; it does not establish
native Android display, Firecracker or controller-authority acceptance.

The migration uses a scratch baseline, exact identities and deterministic native
templates. It rejects unexplained translation loss and ambiguous mappings, moves
per-form invariant reviews to their owning domains, and proves removed handbook
identities against source prose. Fresh source identities remain translation gaps
until filled; moving a catalog does not establish linguistic completeness.

The final source audit found a dynamic error-heading path with no extraction
markers and error-page language attributes built from missing assigns. Explicit
native lookups now cover the pinned Plug error status headings; active validated
locale and central direction determine error-page attributes. Machine status
codes and successful protocol responses remain unchanged.

A read-only source audit found all 74 literal TerminalLive message identities
and all 43 literal ErrorHTML identities in their native templates. Across all
28 locales, terminal and error catalogs match their templates' 124 and 67
identities, respectively. Android display labels retain explicit feature-domain lookups.
The handbook compiler has no locale dependency, its content wrappers declare
English/LTR, and documentation extraction selects public guides only. This
establishes source/catalog identity and the handbook boundary, not browser or
native display execution.

Direction lookup now caches only immutable, bundled CLDR-derived metadata under
one fixed key per application. It validates against the supported locale policy
and does not create keys from request input. This removes repeated full CLDR
matching during interpolated rendering without changing direction semantics or
introducing durable state. A focused run passed **55 tests** in 22.2 seconds,
including the unchanged 100-case handbook authority property within its existing
60-second timeout. Twelve standalone migration regressions also passed.

Porsche's full `mix precommit` passed: 114 tests in 180.3 seconds, four Covenant
obligations, native extraction freshness and forced Dialyzer with zero errors or
skips. The final focused Porsche run also passed 19 tests, including command-token
preservation and exact invariant reviews, followed by extraction freshness and
forced Dialyzer with zero errors or skips.

The premerge isolated Marshall source passed the pinned-runtime, architecture,
event-catalog, warning-free compilation, formatting, terminal/workspace assets,
Monospace, offline localization data, public-document structure and native
extraction freshness gates. Code-contract coverage and all 19 scanner
regressions passed. A fresh tagged Covenant run passed all 36 tests in
3.0 seconds with seed `524458`; static and recorded-result checks then confirmed
36 of 36 obligations. These bounded checks do not establish the normal full
suite, native isolation or browser acceptance beyond the receipt below.

On the premerge source, Marshall's forced Dialyzer analysis completed in
3 minutes 19.5 seconds with
nine errors, zero skipped warnings and zero unnecessary skips, exiting two.
All remaining findings concern the incoming Android display-ticket, socket and
terminal paths. The existing compile-time Earmark dependency is now explicit in
the PLT. Its pinned AST specification incorrectly promises a binary; the public
parser capture keeps the foreign result untrusted until the existing recursive
node validator accepts it. This removes the localization diagnostics without
suppression or a cast. All ten localized-Markdown tests passed in 0.1 seconds
with seed `718373`; formatting and documentation extraction freshness passed.
That premerge run did not establish a passing type gate or normal precommit.

Strict catalog coverage passed for all 28 locales after the final prose and exact
invariant reviews: no empty non-English entries, fuzzy flags, invalid bindings
or unreviewed source-equal forms remain. English retains native source fallback.
The independent documentation audit covers 3,528 units across 28 locales, including
protected commands, code, links, headings and parsed emphasis/list structure.
These results establish catalog coverage and structural validity, not independent
native-speaker review. Invalid translated HTTP-header, repository-identity,
integration-name and email examples were restored to valid machine syntax with
exact per-message technical reviews.

The first broad Marshall run was invalidated by a concurrent alias-triggered
recompilation of its test artifacts. It is not passing-suite evidence. The
unchanged operator-boot property subsequently passed 100 cases in 91.5 seconds
(seed 564864) without compilation. Its normal test now has a finite 180-second
aggregate budget for those 100 real BEAM subprocess boots, retaining all cases
and assertions. A clean integrated precommit run remains required.

The next full-suite attempt exposed the default-profile browser history's
60-second aggregate timeout. Source inspection found that its 100 generated
cases shared one ExUnit-owned SQL sandbox, accumulating host, account and VM
fixtures. Repeated catalog reads consequently scanned previous cases' enabled
hosts. The test now uses the existing per-case sandbox helper and registers
each exact LiveView PID for cleanup before its SQL owner, with a five-second
stop deadline. All generated cases, bounded histories and draft/idempotency
assertions remain. All 100 corrected cases passed in the isolated focused run
within the unchanged 60-second aggregate budget.
This enforces ADR-0191's existing case-isolation decision without changing
production behavior. The handbook Reference already describes per-case SQL and
process ownership, cleanup ordering and measured aggregate budgets; this test
fixture correction introduces no new handbook behavior or verification claim.

The recorded Bombadil settings verification passed against an immutable compiled
runtime including the final bundled fonts: exit zero, zero violations, all 28
locales saved and persisted after reload, and all 112 light/dark and 390/1440-pixel
combinations. Reset restored Japanese browser inference after reload; repeated
save from a fragment also passed. The private runtime receipt records BEAM,
JavaScript, CSS and font hashes in the committed
[safe browser receipt](2026-10-19-localization-browser-evidence.json).
This establishes the settings journey and
observed layout, not all-route presentation, cross-browser shaping, native SSH
or independent linguistic review. CSS-aware font coverage separately passed for
2,275 visible codepoints across 138,101 PO string units and all 28 native locale
labels. All eight complete font assets reproduced exactly from pinned sources.

The integrated full suite exposed a missing authorized machine-view projection
for persisted Reflection labels and comment. The repair includes those fields
for browser settings while explicitly excluding them from SSH machine responses;
existing Cedar read authority and the protocol shape are preserved (ADR-0203).
A settings regression covers empty defaults and persisted values. The preexisting
Reflection metadata save action is absent from the authorization action map and
remains a separate ADR-0203 implementation gap; this rendering repair does not
invent mutation authority. The isolated focused run passed 76 of 77 tests in
681.9 seconds with seed `562021`,
covering machine pins, settings, SSH commands, firmware admission and all 100
default-profile histories. Only the earlier MFA source reached its finite
600-second timeout; that run used the environment's default schedulers and
64 maximum ExUnit cases. The final MFA cleanup source was retried with
the four-scheduler configuration used by the main run. That final retry passed
5 of 7 tests in 600.5 seconds with seed `693066`: the updated MFA property again
reached its finite 600-second timeout, and the imported suspension state-machine
property failed `idle_expire` after the generated history
`[idle_expire, tool_call, pin, idle_expire]` retained a running checkpoint.
The suspension test and its source are unchanged by localization. These results
are separate remaining verification gaps; a green normal precommit is not
claimed. The [MFA review](2026-10-19-mfa-property-isolation.md) records its exact
fixture, budget and evidence scope.

The approximately 49-minute broad Marshall run was interrupted after an existing
terminal property stopped the application and caused a repository-unavailable
cascade (`/tmp/localization-marshall-full-test-final.log`, failures 23 onward).
`RemoteTest` kills the application-global `PeerBudget` in each of 100 generated
cases; that permanent child belongs directly to `Marshall.Supervisor`, whose
default restart allowance is three restarts in five seconds. Repeated fast kills
exhaust that allowance and stop the application, including `Marshall.Repo`.
The missing-successor assertion precedes the repository setup failures. This run
does not establish a passing full suite; the unrelated destructive fixture and
production supervisor policy were left unchanged.

Integrating the later trunk account copy required removing one stale duplicate
`msgstr` directive from each of its 28 account catalogs while preserving the
new translation. The optional Android profile also exposed the existing closed
editor-manifest shape check: the repair validates the finite profile choice
first, then removes only that validated optional field before the existing
editor check. New codec regressions cover explicit profile identity and
serialization with and without an editor, and malformed or unknown inputs.
Native template regeneration changed only source-reference lines in `account.pot`
and `terminal.pot`; guarded comparison confirmed unchanged message identities,
translations and all other templates.

On the repaired merged source, all eight Marshall Android tests passed in
0.06 seconds with seed `183005`, covering the registry, relay, ticket and host
bridge fixtures. The display-hook unit passed (1/1), checking the dedicated
noVNC target, canvas replacement and viewer/controller configuration through a
simulated client. Workspace units (12/12) and TypeScript, Monospace and formatting
checks also passed. These BEAM and simulated-client results do not establish a
native guest-to-browser display journey.

After the incoming account-copy update, the final pinned font check again
verified all eight complete assets and OFL notices, totaling 13,815,920 bytes.
CSS-aware coverage includes 2,275 visible codepoints across 137,984 PO string
units and all 28 locale autonyms, using FontTools 4.63 and Brotli 1.2. The font
assets are unchanged; this static result does not extend the immutable browser
receipt to the merged application source.

Final merged-source native extraction freshness, offline localization data,
public-document structure and strict catalog checks all passed after that
regeneration. Code-contract verification passed across 150 `CONTRACTS` files,
3,579 notes, 477 parsed source files and 3,572 covered source files.

The isolated protocol `mix precommit` against `eaca39a46` plus the repairs
committed in `6467bcde` completed successfully: all 382 tests passed in
909.2 seconds with seed `417854` and eight maximum cases. All 14 Covenant
obligations passed, the recorded-result check held, and Dialyzer reported zero
errors, skipped warnings or unnecessary skips. The final Marshall forced
Dialyzer analysis against that snapshot also completed normally in
4 minutes 16.61 seconds with zero errors, skipped warnings or unnecessary skips.
These results precede the later Mila protocol additions. Lilly's isolated
test phase also passed all 652 tests in 1,276.0 seconds with seed `547342`,
and all 15 Covenant obligations passed. After correcting the private scratch-build
layout and rebuilding its PLT, the type-stage continuation passed in
33.36 seconds with zero errors, skipped warnings or unnecessary skips.
The original aggregate precommit command had exited at that private build-path
failure, so no single full Lilly gate completion is claimed. The normal Marshall
full-suite gaps above remain open.

The preceding merged-source, catalog, font and focused-test results describe
that `6467bcde` integration snapshot. The subsequent `aacb4be2c` trunk update
brings the accepted, partially implemented ADR-0220–0228 client, canonical route,
watch, terminal-attach and notification work. These changes retain Marshall's
domain authority, add the Notifications domain and the independent Susan relay,
and introduce shared protocol codecs and the Flutter client. Susan has no fleet
host placement; the generated topology and maintained interaction diagram keep
its database, provider egress and authority separate from Marshall.

The SSH projection conflict was resolved by preserving both accepted obligations:
the caller's own pin and canonical route remain on the client wire, while
Reflection labels and comment stay private to the browser projection. The review
index retains the MFA and all incoming Mila/Susan reviews. Stale ADR gap text
now points to the present approval link, device dispatch and Marshall poke client
and to the historical Mila-Porsche run. Their accepted decisions, partial status,
prior failures and native/device/provider gaps are preserved. The incoming
[M6 review](2026-10-19-mila-m6.md) still records no completed integrated Phase 2
pass. No earlier full-suite, type or browser result establishes the latest tree.

The final static font check against the later trunk catalogs and two added
notification refusals passed for 2,299 visible codepoints across 135,469 PO
string units. All eight complete font assets and OFL notices verified at the
unchanged total of 13,815,920 bytes. The changed PO-unit count reflects incoming
catalog normalization; this check establishes glyph coverage, not linguistic
correctness or a new browser shaping result.

The latest shared contract-scanner regression run passed all 20 tests in
7.36 seconds with no skips or cancellations, including the added Dart, Kotlin
and Swift contiguous-comment case. This verifies scanner behavior and contract
discovery; it does not establish semantic compliance of every client or relay.

The latest source audit found two notification refusals still using the
transport's English hint. `push_disabled` and `device_limit` now use native
`management` domain lookups and translations in all 28 Porsche catalogs;
`device rm DEVICE_ID` remains literal. A regression checks Arabic and Japanese
guidance and byte-equivalent decoded JSON hints. Moving the existing terminal
close helper after the grouped control clauses repairs an incoming compiler
warning without changing its body or behavior.

The final follow-up describes application source integrated through `433a1f570`;
the intervening fixture-build, firewall and recorded-emulator updates do not
change these application snapshots. A final read-only directory comparison
confirmed current Marshall, protocol and Lilly `lib/` trees are byte-identical
to the latest Marshall verification snapshot; Lilly's fixture-only test changes
were separately validated below. The latest protocol `mix precommit` passed:
all 418 tests passed in 913.9 seconds with seed `778386` and eight maximum cases,
all 15 Covenant obligations passed, and both normal and explicit forced Dialyzer
reported zero errors, skipped warnings or unnecessary skips. All current protocol
`lib/`, `test/` and `contracts/` hashes match the validated isolated snapshot.
This closes the ordinary BEAM protocol gate for that source, without extending
native transport or physical isolation evidence.

The latest Lilly consumer follow-up passed 92 focused terminal, control, actor
and Android tests in 61.9 seconds with seed `54471` and eight maximum cases.
Warning-free compilation and formatting passed; forced Dialyzer reported zero
errors, skipped warnings or unnecessary skips in 25.06 seconds. Its initial
focused attempt passed 84 of 92 tests: all eight failures came from handbuilt
stream states missing the required empty `android_channels` map. Seven additions
across five test files align six runtime fixtures and one typespec with production
initialization. Production behavior, assertions, generators and budgets are
unchanged. The earlier 652-test and 15-obligation results retain their historical
snapshot scope; this follow-up is not a fresh full Lilly test suite.

The latest Marshall focused runs passed 72 tests in 68.5 seconds with seed
`333393`, covering `ssh/commands_test.exs`, `ssh/client_commands_test.exs`, all
`notifications/` tests and `ssh_approval_live_test.exs`; and 18 tests in
54.8 seconds with seed `670403`, covering `terminal/host_stream_test.exs` and all
`android/` tests. Both used eight maximum cases. These cover the exact SSH wire
projection, client commands, notification and approval behavior and the bounded
host-stream/Android fixtures. Offline locale data, public-document freshness,
strict catalog coverage, contracts, workspace units and TypeScript, and
Monospace checks also passed. Native extraction freshness passed without
regeneration. The final forced Dialyzer completed normally in 3 minutes
59.42 seconds with zero errors, skipped warnings or unnecessary skips, after
the relocated private PLT rebuilt in 9 minutes 25.25 seconds. The earlier full
Marshall suite failures remain separate from these bounded passes.

The latest Porsche test phase passed 140 of 141 tests in 326.9 seconds with seed
`928886` and eight maximum cases. Only the existing invalid-boot property reached
its 240-second aggregate deadline. An identical isolated rerun of that file
passed both tests in 225.7 seconds with the same seed, preserving all three
exhaustive fixture histories and the unchanged 240-second deadline. All seven
Covenant obligations passed; forced Dialyzer reported zero errors, skipped
warnings or unnecessary skips in 21.35 seconds after its PLT rebuild. The full
precommit still exited nonzero on its earlier timeout; the isolated pass does not
rewrite that outcome. The source, templates and normalized catalogs are unchanged.

The final read-only requirement audit found no additional implementation gap in
the requested localization scope. The accepted architecture and partial ADR
statuses remain unchanged. Structural catalog completeness, finite BEAM gates
and the historical Bombadil settings receipt retain distinct scopes; all-route
and cross-browser shaping, native Porsche/guest journeys and independent
linguistic correctness remain unestablished. Independent native-speaker review
is not a release requirement for this task.
