# Browser launcher and source2 architecture review

Date: 2026-10-10. Worktree: `/home/ghuntley/src/overalls-browser`, branch
`feature/browser-launcher`, base `63a1443c`, feature `a3d2b69c`, merged main
`bee03919`. This review covers the committed
browser port, public distribution, source2/manifest4 cutover, authentication resume
and their actual consumers. The user authorized all four providers, explicit
server configuration, unsigned packages and cross-tab magic-link resume.
[ADR-0157](../decisions/0157-multi-provider-authenticated-repository-launch.md)
supersedes ADR-0128; [ADR-0156](../decisions/0156-browser-launcher-distribution.md)
adds package distribution. ADR-0156 is accepted/implemented after its final
immutable packaging and browser checks; ADR-0157 is accepted/implemented after
both complete captured feature native families passed all twelve subtests and all
twenty provider/revision combinations. Exact captured-source scopes and separate
merged-main/live-provider/production limits are retained below.

## Source comparison and final boundaries

Weaver was cloned at `b211e71b9c86aeca507323baab7650218688e9c9` in
`artifacts/weaver` in this worktree (initial inspection clone `/tmp/weaver-inspect`).
Its browser implementation uses native shared modules,
generated Chrome/Firefox assets, Node tests, Chromium smoke and web-ext lint.
Upstream Cargo version synchronization and Git/build-time metadata are separate
from Overalls' package.json authority, maintained-source digest and fixed ZIP epoch.
The port preserves explicit toolbar configuration, supported-provider state,
fragment launch, configuration context menu and developer archive installation.
It adds strict native JSDoc checking, hash-verified offline Nix build inputs,
deterministic package descriptors and independent immutable public downloads.

Public capture is input storage only. CSRF-protected HTTP staging validates a
canonical source, 128-bit visit and thirty-minute server expiry into the existing
signed cookie. It invokes no domain mutation and grants no login/MFA authority.
Sign-in in another same-browser tab observes that cookie; valid pending input has
a fixed `/launch` return through MFA. Connected admission rechecks ordinary current
account/login/Cedar authority. Its actor/source/visit idempotency joins the stored
source and complete allocation transaction. A post-commit signed completion receipt
returns through HTTP CSRF, fresh login and owner/read authority; matching clear
preserves a newer capture. SessionStorage stores only the per-tab nonce value under
the minimized source key. Source queries/fragments are removed before extension
transmission, capture storage or the POST, and URL user information refuses before
storage/submission. Raw manual-capture authority/path stays unchanged for backend
port/traversal/escape refusal. There is no localStorage authentication bridge or
pending database resource.

The sole source2 parser owns finite provider and revision variants in both
languages. GitLab namespaces retain all components. Guest-only named reference
resolution chooses the longest advertised branch/tag prefix and branch ties,
including hexadecimal branch names. Only without an advertised match does a
7–64-hex first path component select a commit; a following file path is ignored.
Bitbucket `/src/NAME` accepts advertised tags without a separate tag route;
GitHub/GitLab change refs and bounded Codeberg/Bitbucket API heads select checkout
without changing immutable source identity. API clone URLs cannot cross provider
HTTPS origin, use credentials or redirects. Guest git/API responses remain outside
diagnostics and control-plane availability.
Advertised-ref capture bounds stdout to 1 MiB and thirty seconds, cancels the
entire owned git process group before its reader join, and permits hexadecimal
fallback only after a valid listing with no matching advertised reference.
Checkout format remains internal: accepted 64-hex or advertised SHA256 objects
initialize a matching fetch-only repository, abbreviated objects use negotiated
clone, and mixed listings refuse. No source wire/database field changes.

Manifest4 uses one current decoder and ordered identity including source capability
and optional exact editor release. NixOS capability follows the evaluated enabled
multi-user receiver, including overlays; Ubuntu follows its receiver enablement
branch. Admission requires current manifest/catalog identity and source2 capability.
Initial Lilly start repeats the guard before lock/disk/intent effects. Retained
restart/adoption retains portable-bundle custody and does not consult staged image
availability. A new source-bearing command snapshot checks the durable image
identity/capability even for retained starts, preventing an upgraded source row
from dispatching to an obsolete receiver. Unsourced starts and disabled current
capable images retain their existing custody. The cutover converts source rows once and disables obsolete image
entries; old manifests, execution snapshots and receiver/lifecycle records are
never relabeled or rewritten. Obsolete source-bearing retained guests require a
current image/recreation, not an implicit reader adapter.

Final consumer review found that Resize supplied a command snapshot directly,
omitting the stored source and bypassing the new durable-image guard. Newly
validated snapshots now normalize source authority from the VM's durable record,
retaining resize sizes and identity. An unsourced VM cannot gain source authority
from a supplied snapshot. Supplied commands must also match the VM's retained
immutable image; checking capability on that image cannot authorize a caller's
different executable image. Existing snapshots remain immutable.
The same review found that a capability refusal during automatic restart could
roll back an otherwise valid crash/resize observation or the next host report.
Recovery and resize now preflight the same read-only durable capability before
creating restart intent, with final snapshot enforcement retained. Unavailable
recovery releases confirmed stopped compute while retaining disk and address.
A confirmed resize commits its outcome and target sizes, completes with
`workspace_source_unavailable` and releases only confirmed compute. Completion
permits ordinary cleanup; an active retryable request would otherwise block even
deletion of an obsolete recreation-only sourced guest. Unknown effects and their
holds keep the existing fencing rules. This implements ADR-0157 without changing
ADR-0140's treatment of late telemetry or introducing new execution authority.

Browser distribution introduces no new Ash domain/resource, host, listener or
service identity. Marshall's existing HTTPS service serves only two fixed regular
artifacts from its selected canonical Nix-store package plus their bounded
distribution manifest/checksums. The CLI distribution schema stays independent.
The exact selected root and `bin` parent must be real directories; symlink roots,
parents and artifact files, malformed descriptors and length mismatches refuse.
The nullable Nix option disables downloads without granting a runtime mutable
artifact path. The wrapper resets inherited release selection after environment
files, so a service environment cannot bypass null or the selected package.
Deployment/topology inventories remain unchanged; maintained views
describe the new client/package interaction and existing failure boundaries.

## Findings and verification limits

- **Both captured feature family journeys passed (ADR-0157).** NixOS and Ubuntu
  passed local four-provider Git/API checkout, cross-tab magic-link resume, required
  MFA, retained restart, immutable downloads and real packaged CLI. NixOS predates
  the diagnostic-only ZFS addition; Ubuntu captured `a3d2b69c`. The earlier Ubuntu
  startup failure's predicate remains unproven; the passing diagnostic capture
  emitted no identity-probe failure. Merged-main native execution, live provider
  network and Brady TLS interception remain separate. Historical ADR-0128 native
  GitHub results retain their old schema/revision only.
- **Retained cutover is explicit (ADR-0157).** Old command/receiver documents have
  no current reader. Disable obsolete images for new create and recreate sourced
  machines requiring source2. Migration rollback requires a pre-cutover backup;
  deployment must select matching current application/images together.
- **Concurrent pending captures remain a singleton (ADR-0157).** A matched
  completion cannot clear a newer observed capture, but browser cookie response
  ordering is not a queue or cross-tab serialization guarantee.
- **Firefox runtime has bounded manual evidence (ADR-0156).** Firefox 155.0.1
  temporary unsigned installation, settings persistence and version metadata passed.
  Four-provider toolbar actions passed against fixed local TLS pages with browser
  certificate bypass; public provider network, permanent signed installation and
  Android remain open.
- **Production remains unverified.** No host activation, production public download or current
  authenticated launch/guest journey was established by this change's local checks.

## Executed evidence

Pinned focused protocol manifest/editor checks passed 14 checks (5 properties,
9 tests), seed `233630`. They exercise exact capability fields, unsupported old
versions, resource bounds, identity changes, encoder round trips and an independent
compact JSON/SHA-256 manifest4 vector. This is pure codec evidence.

Pinned focused Lilly image/catalog/initial-start checks passed 8 checks (2 properties,
6 tests), seed `923028`. Actual production driver refuses malformed, absent,
obsolete or identity-mismatched source capability before host files or native
operations. Local read-only artifact validation and catalog histories establish
only synthetic filesystem scope.

Pinned focused Lilly source/spec/lifecycle/guard checks passed 13 checks (6 properties,
7 tests). The current source2 fixtures cover all providers, bounded delivery
encoding and real Unix-socket fake-guest histories with old-boot/lost-ack/conflict
refusals, plus journal edge tables. They do not execute a Firecracker guest.

Actual Nix evaluation returned `nixos_base=false`, `ubuntu_base=false`,
`nixos_private=true`, `ubuntu_private=true`, `nixos_disabled=false` for receiver
capability. This validates declaration/overlay scope without building or booting
complete images. Code-contract structural checking passed 126 CONTRACTS files,
2667 native notes and 2733 covered maintained files at that intermediate source
snapshot. The final checker results are recorded separately after integration.

The first Marshall admission-test attempt stopped before tests because the local
PostgreSQL template was SQL_ASCII while the database required UTF8. A separate
UTF8 test cluster is used for current application results; setup failure is not
passing admission evidence. Broad final component and handbook checks remain
pending until their exact results are recorded below.

Current source2 protocol checks passed 5 checks (4 properties) in the pinned runtime.
Rust `cargo test` passed all 114 tests and all-target Clippy passed. After the final
advertised-ref/deadline/stale-done/parser changes, focused Rust checks passed 16 tests
(10 library tests, 5 receiver tests and 1 open CLI test), and Clippy passed again. These include
validating an obsolete stored source before observing a done marker. Logs are
`artifacts/rust-all.log` and `artifacts/rust-source-final.log`; fake git/API and
local filesystem properties do not establish provider or Firecracker acceptance.

Current Marshall source2/authentication/admission/SSH checks passed 80 checks
(9 properties, 71 tests) in an isolated UTF8 PostgreSQL cluster. The focused set
covers canonical public capture without domain mutation, full-cookie budget,
malformed/expired input, required MFA continuation, revoked authority, visit
deduplication, source/image capability refusal before allocation and SSH results.
Two additional authentication-privacy tests passed, including malformed captured
credentials absent from HTTP diagnostics. Together these are 82 focused checks;
they do not boot a guest or use a real browser. Compilation was refreshed after
generating the finite `workspace_source_unavailable` trace vocabulary.

Browser strict TypeScript checking passed and all 9 Node tests passed. Mozilla
addons-linter 10.13 reported zero errors, warnings or notices. npm audit reported
zero vulnerabilities among 197 locked build-tool dependencies. Deterministic
packaging and both archive integrity checks passed. The Nix browser package and
`checks.x86_64-linux.browser` both built successfully: the sandbox check loaded
the actual extension in Chromium 151, exercised options persistence and all four
provider action fragments, and refused an unsupported page. The check pins its
DejaVu fontconfig so Chromium requires no ambient fonts. A separate local smoke
also passed in Chromium 153. Output roots are
`/nix/store/jr42nx8lqlfffximx660xyhdgryjzk18-overalls-browser-0.1.0` and
`/nix/store/8dsdyg53463fwalbr90dlqhy6im95a4d-overalls-browser-check-0.1.0`.

Firefox 155.0.1 temporary installation, settings persistence and metadata passed
with pinned geckodriver 0.36.0 and the same immutable XPI. The manual script installed
the unsigned add-on temporarily, saved the configured server, reloaded options and
checked the retained value and version. Its scratch script passed ruff formatting,
lint and ty. `artifacts/browser-firefox-smoke-result.json` and
`artifacts/browser-firefox-smoke.py` retain the scoped result and procedure.
This establishes neither provider toolbar navigation, permanent signed installation,
Firefox Android nor extension-to-authentication/guest composition.

The final module-configuration check passed, including evaluated three-replica
wrappers with deliberately conflicting inherited store paths: selected package
and explicit null remained authoritative (`browserFinalSelection=true`,
`browserFinalDisabled=true`). An intermediate NixOS source2 image built successfully at
`/nix/store/2bzpky13d465aciphp5758pdim5r7pca-lilly-nixos-x86_64`; image construction
does not establish a booted current provider/MFA journey.

Final source2 guest artifacts also built after the Rust contract-comment correction:
NixOS `/nix/store/0xs7vlwlr1ydabq16dns2facf9an484q-lilly-nixos-x86_64` and Ubuntu
`/nix/store/g33cp32wbkkd93jrk8qjm0aypj72mg5j-lilly-ubuntu-26.04-x86_64`.
Both inspected manifests are version4 with source2 capability, 512 MiB memory and
no editor field. Rootfs lengths are 3774873600 and 2013265920 bytes respectively.
These are artifact-build observations; no Ubuntu runtime result follows.

Five immutable-package download controller tests passed. They compare public
manifest, bytes and checksums; enforce the closed selectors; refuse mutable or
traversing roots, symlink ancestors and malformed/length-mismatched files; and
avoid creating login state on public downloads. These
host filesystem/HTTP tests do not establish deployed HTTPS download availability.

The NixOS repository-launch journey now contains all-provider default/ref/tag/
commit/change fixtures, new-tab magic-link resume, a subsequent real WebAuthn MFA
ceremony and public download metadata checks. Current machine evidence is present
with failed initial captures on both guest families; neither completed the expanded
provider/guest journey. Those captures and diagnostic recaptures are scoped below.
Earlier `e2384877` native GitHub source1 runs remain historical evidence only.

An actual isolated PostgreSQL migration probe passed at the current cutover
source: all four historical source revision kinds converted, obsolete images
disabled, immutable operation snapshots unchanged, and a second migration call
reported already-up without conversion. The disposable database was removed.
`artifacts/source-cutover.log` records the probe; production backup, coordinated
rollout and restoration remain unverified.

The final sourced-start admission file passed 7 checks (3 properties, 4 tests),
seed `427770`, after adding the actual lifecycle cutover regression. Obsolete,
capability-absent and identity-altered durable images refuse a fresh sourced start
with VM, reservation and existing operation snapshots unchanged. Unsourced starts
on an obsolete disabled image and sourced starts on a disabled current capable
image remain permitted. This is SQL-backed authority/rollback evidence, not a
native retained-bundle start or custody result.

The final real-process/ref-output regression file passed 6 cases in 0.20 seconds
(three boundary regressions plus three conditional subprocess fixture helpers).
It exposed and now verifies two corrected defects: an exited git parent could
leave a descendant holding stdout so cancellation blocked at reader join; and
malformed/oversized advertised output could incorrectly permit hexadecimal
commit fallback. The tests require prompt deadline/overflow refusal, termination
of the actual owned descendant, valid-listing fallback and hexadecimal branch
precedence. This is real local Linux subprocess scope, without provider network
or guest isolation acceptance.

The final pinned protocol precommit passed 260 checks (101 properties, 159 tests),
seed `271899`, including forced Dialyzer with zero errors. Its log is
`artifacts/protocol-final-precommit.log`; this is component validation, not guest
or provider acceptance.

The first broad Lilly run passed 548/549 checks (all 108 properties and 440/441
tests); forced Dialyzer reported zero errors. The sole failure was the unchanged
HistoricalFenceTest assumption that this developer host cannot have a healthy
empty `lilly.slice`. The exact test failed identically at detached base `63a1443c`
(0/1 passed, exit2), recorded in `artifacts/lilly-baseline-fence.log`.
The test now invokes explicit unknown-unit and failed-scan utility fixtures in a
separate BEAM, validates the fixed ID-only scan arguments, and changes no shared
PATH, production implementation or host cgroup. The focused fence file passed
10 checks (3 properties, 7 tests) before the final full rerun. Its fixture scope
does not establish native cgroup ownership or historical fleet reactivation.

The final Lilly precommit passed 549 checks (108 properties, 441 tests), seed
`191280`, and forced Dialyzer reported zero errors with exit 0. Its log is
`artifacts/lilly-final-precommit.log`. This final run includes exact scan argument
validation and the isolated fence fixture. All source2 initial-start/delivery and
catalog checks remain within their component/fake-guest scope.

Handbook review, generated options, scenario coverage, Ash/topology views,
ADR structure and conflict-marker checks passed. The intermediate code-contract
gate passed 126 CONTRACTS files, 2672 native notes, 254 parsed source files and
2735 covered maintained files, with all 19 checker regression tests. The Nix
`checks.x86_64-linux.hldd` gate passed in 22 seconds. These verify maintained source
and evaluated placement, not the real handbook diagram renderer or guest runtime.
Final receipts/checks after late fixture/checkout corrections are recorded separately.

Final Rust checkout checks passed 19 focused tests plus all-target Clippy. The
new pinned real-local-Git test constructs both SHA1 and SHA256 repositories and
uses the production resolver/plan to check exact HEAD for full commits, branches,
forty-digit SHA256 abbreviations and dedicated GitHub/GitLab change refs. A
separate test refuses mixed advertised formats. The provider URL is replaced with
the disposable local repository after source resolution; there is no provider
HTTP/TLS, browser or guest claim. This closes the concrete accepted64/default-init
format mismatch discovered during review. `artifacts/rust-object-format-final.log`
records the focused run; the pinned Git repeat also passed.

Native repository-launch contract discovery now places the fixture/ref, exact
provider HEAD/capacity and real CLI invariants in an ancestor `CONTRACTS` file.
The pinned parser did not attach the earlier Python inline comments. Format/list
discovery passed for all three contracts; this is enforceable discovery metadata,
not execution of the native journeys.

Final Rust full-suite execution passed all 123 tests, followed by all-target
Clippy with warnings denied. Seventeen Rust contracts were converted to native
documentation comments after discovery showed ordinary comments were not attached;
the pinned parser now lists the changed declarations. Contract format and the
subsequent all-target Clippy both passed. Logs are `artifacts/rust-complete-final.log`,
`artifacts/rust-documented-final-clippy.log`, `artifacts/contracts-rust-discovery.log`
and `artifacts/contracts-rust-block-final.log`. This correction changes discovery
metadata and does not upgrade local Git/receiver tests to native guest evidence.

The observability final precommit passed 11 tests, seed `331070`, and forced
Dialyzer reported zero errors with exit 0 (`artifacts/observability-final-precommit.log`).
This validates the generated finite diagnostic vocabulary/component; no source,
URL, token, payload or receipt becomes diagnostic metadata.

The final Marshall editor-capability/public-root fixture corrections passed
6 checks (1 property, 5 tests), seed `319479` (`artifacts/marshall-fixture-focus.log`).
The earlier broad Marshall run overlapped recompilation from that focused process,
invalidating distributed-peer setup; it supplies no final broad passing result
or independent product defect conclusion. The required full gate is rerun serially.

The source2-era NixOS `hldd-browser` check passed, exit 0, in 388 seconds
(`artifacts/hldd-browser.log`). Its actual release/browser journey visits all 22
sections, including maintained/generated Ash ownership and topology diagrams,
and checks chapter switching, previous-hook removal, browser history, themes,
ordinary reader identity and revoked mounted/fresh-request refusal. This captured
source precedes the final ADR renumbering, Firefox evidence edits and editor
publication SQL correction; unchanged renderer assertions supply scoped handbook
presentation evidence without establishing guest/provider or production acceptance.

Final integration also corrects the existing editor DNS publication SQL predicate
from manifest3 to manifest4 and the corresponding native fixture assertion.
The broad editor-publication test exposed that stale consumer; the correction
preserves matching editor release, current VM/asset/session/readiness and snapshot
authority. This follows the accepted sole manifest4 cutover under ADR-0157 and
does not introduce new editor authority. The passing focused serialized result
below includes editor publication; no new native editor execution follows.

The final pinned all-files Python gates passed ruff-format, Ruff and ty
(`artifacts/python-static-final.log`). Import sorting initially failed in unchanged
`vscode-web/policy.py` because vendored `browser/node_modules/flatted/python`
changed namespace discovery. A temporary baseline passed without that directory
and failed with it. The explicit isort first-party classification for the copied
native `browser` helper and one import regroup stabilize checkout and packaged
configuration contexts. The imported helpers, policy/profile invariants and
runtime behavior are unchanged; this is static checking, not new editor execution.

Five new SQL-backed regressions passed for supplied-source normalization,
sourced resize on disabled capable images, obsolete-source resize proof/size/
snapshot/address preservation and ordinary deletion, obsolete-source crash
commit/replay, and stale-crash-to-fresh-report refusal without lost evidence.
The earlier focused set passed 38 checks (3 properties, 35 tests), seed `75165`,
in 6.1 seconds with exit 0. The final expanded focused Marshall
source/snapshot/editor set passed 39 checks (3 properties, 36 tests), seed `15084`,
in 4.6 seconds with exit 0. The log is
`artifacts/marshall-source-guard-focused.log`. It includes lifecycle, resize,
workspace-source admission and the corrected editor publication. These tests
establish no native guest/provider or retained-bundle acceptance; the passing
broad Marshall gate is recorded below.

A real Firefox action probe exposed a permission deadlock: before granting
provider-origin access, Firefox can withhold `tab.url`; disabling the unknown
action prevented the click that would grant activeTab. The reviewed correction
keeps unknown state enabled without transmission, retains disabled known
unsupported state and validates the click's observed URL before opening Overalls.
An unsupported explicit click retains Weaver's fixed red `!` and **Unsupported
page** feedback, then clears after three seconds and refreshes the actual tab
state. No page URL enters feedback or diagnostics.
It broadens no permission, setting or source schema. The current local browser
gate passed strict TypeScript and all 10 Node tests, deterministic archive tests,
Mozilla lint with zero errors/warnings/notices, real Chromium four-provider
actions and unsupported-click refusal when the URL was initially withheld,
exit 0 (`artifacts/browser-active-tab-check.log`). Final immutable Nix package
and full Firefox provider-toolbar results are recorded below.

The current local Firefox four-provider toolbar probe passed with exit 0
(`artifacts/browser-firefox-toolbar.log`). Pinned Firefox 155.0.1 and geckodriver
0.36.0 temporarily installed the final local unsigned XPI, retained settings and
version metadata, and received actual WebDriver clicks on each provider's action
button after foregrounding its source tab. Fixed local TLS pages used
`acceptInsecureCerts=true`; this does not establish public provider network,
Overalls authentication, guest checkout, signing or Android. The scratch procedure
passed Ruff and ty. The current Nix package and browser sandbox check also passed,
exit 0 in 11 seconds (`artifacts/browser-active-tab-nix.log`); the final provenance
package was rebuilt after the README correction, with its final result below.

A further authority review found that a valid caller snapshot could select an
image differing from the capability-checked VM image. Command authority now
includes the retained `image_id`. A sixth new SQL regression passed for a
valid source-bearing start with a current but source-incapable alternate image;
enqueue refuses without VM or operation mutation. It is included in the final
39-check serialized revalidation above.

Both initial expanded native captures failed. The NixOS capture completed its
browser sign-in/MFA launches, then failed the first guest checkout helper; Ubuntu
reached connected launch and refused `insufficient_capacity`. Neither completed
the provider/guest journey. The fixture now retains fixed assertion/stage/exit/
closed-status diagnostics, immediate nonzero refusal and a bounded read-only
admission predicate/Budget preflight. It changes no production admission, guest
authority or capacity. Current diagnostic recaptures require separate results;
no passing native acceptance is inferred from the fixture repair or type gates.

The Ubuntu diagnostic recapture also failed. Its read-only image/host/pool/Budget
preflight was eligible and the authenticated/MFA launch/deduplication browser stage
passed in 27.37 seconds. The guest shell became ready, then checkout assertion 1
exited 1 with closed clone status `waiting`; no clone had begun. This narrows the
failure to delivery/readiness rather than proving a Git checkout failure. Captured
run log `1791642990462-4181175-0.jsonl`, derivation
`s8151m8xhpsgzn907sj0ybr637vsh67l`, and output `83v5cyclv5ln87c1qn96njyfgin308g3`
predate the final snapshot/recovery correction. No complete native journey passed.

Read-only inspection traced the waiting receiver to Lilly.Executor's
provisioning-readiness and Inception success paths, which returned running without
the existing supervised source handoff. The correction routes those successful
paths through `running_with_source`, preserving the exact running observation and
the provisioning `guest_ready` field. Guest trust/readiness still precedes handoff;
asynchronous delivery failure cannot alter the completed observation or delay
fencing. Component and current native reruns must establish their own result.

The pre-minimization final immutable browser package and sandbox check passed in 13 seconds,
exit 0 (`artifacts/browser-final-nix.log`). Outputs are
`/nix/store/vz6gs8685n20j7ajf7pqnw31pqx3jbn2-overalls-browser-0.1.0` and
`/nix/store/srbq9d3ws30hjhhf1fq94ap38xwqwrv4-overalls-browser-check-0.1.0`.
The sandbox repeats strict typing, all 10 Node tests, deterministic packaging,
zero-error/warning/notice Mozilla lint and real Chromium four-provider actions
with withheld-URL unsupported-click refusal. The final maintained source SHA-256
is `97ae5506ef65ee39f02c67d081b7a81cad88e956f89aeee1de2d5b9bbdc05113`.
A fresh pinned developer build/package matched both immutable archives and the
manifest byte for byte (`artifacts/browser-local-store-match.log`).

The pre-minimization final immutable Firefox four-provider toolbar probe passed, exit 0
(`artifacts/browser-firefox-final-immutable.log`). The formatted, Ruff/ty-checked
procedure installed the exact final XPI, preserved settings and metadata and
performed all four actual provider action-button clicks. Its local fixed-host TLS
proxy and `acceptInsecureCerts=true` retain the earlier bounded scope; no public
provider network, authentication, guest checkout, signing or Android is claimed.

These immutable package/Firefox/byte-match results precede the final URL privacy
correction. They remain historical evidence for unchanged toolbar, configuration,
packaging and scope; replacement packages and runtime results are recorded separately.

The corrected Lilly final precommit passed 549 checks (108 properties, 441 tests),
seed `582375`, in 68.5 seconds, exit 0; forced Dialyzer reported zero errors in
12.58 seconds (`artifacts/lilly-readiness-final-precommit.log`). The existing
readiness/delivery helper focus passed 11 checks (5 properties, 6 tests), seed
`98534`, in one second (`artifacts/lilly-readiness-source-focus.log`). These
component checks do not prove the successful executor branch handoff by themselves.
The read-only observability schema check passed on current finite vocabulary,
without regeneration (`artifacts/observability-schema-current.log`).

The corrected Ubuntu native capture has passed cross-tab sign-in/required MFA,
the initial four launches plus deduplication (24.51 seconds), four exact requested
GitHub HEAD/shallow checkouts (20.93 seconds), and stop/start with retained
checkout, done marker and local probe surviving without re-clone (47.26 seconds).
Log `1791644174703-146859-0.jsonl` captures the corrected snapshot/recovery and Lilly
handoff runtime, preceding the final frontend URL-minimization and relevant
source-comment corrections.
The full provider/revision matrix, CLI, public downloads and complete NixOS family
remain pending; these passed subtests do not imply a completed native gate.

Final source prose now names public provider sources and ADR-0157 in
Lilly.WorkspaceSource, `<repository-url>` in Lyra open_cli and ADR-0157 in the guest
receiver module. Preserved ADR-0128 links still explain unchanged asynchronous
delivery/readiness invariants. These are comments only: runtime, schema, arguments,
logging and accepted rationale are unchanged. Earlier executed packages predate
these documentation bytes, with runtime evidence scope retained.

At this milestone ADR-0156 is implemented: maintained browser modules, explicit
permissions/configuration, reproducible unsigned packages, immutable module
selection and public route implementation have concrete code and passing package,
runtime and HTTP evidence. Signing/store publication is intentionally outside its
accepted scope. Public provider network and production HTTPS activation are
validation gaps rather than missing distribution code. ADR-0157 remains partial
while both complete current native families remain pending.

The final privacy review found that the extension transmitted source query/hash
fields and manual capture used that raw URL as a sessionStorage nonce key and POST
value, although the backend discarded those fields for checkout interpretation.
Such fields can carry credentials without contributing to source identity. The
extension now validates the supported source and transmits only its provider
origin/path. Direct capture lexically removes query/hash before storage/submission,
refuses URL user information and preserves raw authority/path: URL canonicalization
must not erase explicit `:443`, literal traversal or encoded escapes before the
strict backend refusal. Four-provider sentinel regressions and real Chromium source
pages exercise privacy minimization; final typed/capture/package results follow.
The browser URL privacy local gate passed strict typing and all 10 Node tests,
build/package and Mozilla lint with zero errors/warnings/notices
(`artifacts/browser-sanitized-check.log`). The replacement Nix sandbox check must
exercise actual sentinel-bearing source tabs with query/hash-free launches; the
preceding runtime archives do not establish that new behavior.
The four pure capture security tests passed (62.46 milliseconds)
(`artifacts/repository-launch-capture-privacy-tests.log`): all four providers retain
revision paths without query/hash sentinels, nonempty and empty URL user information
refuses, explicit `:443`/literal `../`/encoded `%2e%2e` remains raw for backend refusal,
and malformed/non-HTTPS input refuses. Source workspace strict TypeScript, separate
strict test TypeScript and code-contract format checks passed (`artifacts/repository-launch-capture-privacy-types.log`,
`artifacts/repository-launch-capture-test-types.log`,
`artifacts/repository-launch-capture-contracts.log`). This proves the pure minimizer
and types; DOM/sessionStorage/form composition remains separately scoped.
This repairs client privacy without changing source2, backend grammar, authentication,
guest checkout or accepted admission authority. The final guest receiver binary's
moduledoc also now says public provider/ADR-0157; this additional prose-only change
does not alter runtime or require repeating captured guest execution.

The final Marshall precommit passed 1,454 checks (239 properties, 1,215 tests),
with four excluded, seed `80297`, in 1,595.6 seconds; the complete gate exited 0
(`artifacts/marshall-precommit.log`). Terminal JavaScript passed 32 tests and
dashboard JavaScript passed four; strict workspace TypeScript passed on the
privacy-fixed source. Forced Dialyzer reported zero errors, zero skipped and zero
unnecessary skips in 34.61 seconds. After that completed gate, `workspace.check`
was extended to run the four capture regressions before the existing strict source
type check. Its exact final invocation passed all four privacy tests in 44.23
milliseconds and strict TypeScript (`artifacts/repository-launch-workspace-final.log`).
Separate strict test typing, contract format and diff checks also passed. This
verification-only Mix alias change adds no application/runtime behavior; the full
application evidence remains at the same tested implementation bytes.

The replacement minimized browser package and sandbox check passed in 10 seconds,
exit 0 (`artifacts/browser-private-source-nix.log`), with outputs
`/nix/store/i5syrkrzq1b7lz0bwnid0chmkglazjlz-overalls-browser-0.1.0` and
`/nix/store/hcz8wwg0qnhrrv1rs779fv0rmsd0cqkd-overalls-browser-check-0.1.0`.
Maintained source SHA-256 is
`169e6262de73efa3659cdcd6eb0084f4f09171f017df73ba4772400987e9b2c9`.
Actual Chromium actions on all four provider tabs carried fixed query/hash
sentinels and produced only origin/path launch URLs. The exact replacement XPI
also passed all four real Firefox toolbar actions with sentinel-bearing source
tabs and sanitized launch URLs, settings and metadata, exit 0
(`artifacts/browser-firefox-minimized-immutable.log`). The formatted/linted/typed
probe retains the fixed local TLS/certificate-bypass scope and establishes no
public provider network, authentication, guest or signing acceptance. Fresh pinned
developer archives and manifest matched the replacement immutable package byte
for byte, exit 0 (`artifacts/browser-minimized-store-match.log`).

The corrected Ubuntu native run terminated with failure after 1,703 seconds,
exit 1 (`1791644174703-146859-0.jsonl`, derivation
`0yvhrnvsg10hymxyyq9cacfaslv5mdaw`; expected output
`jygmxdq3lxzgqf247clqzvrfzljkjn5r` was not built). Nine preceding subtests passed,
including the initial four GitHub default/ref/commit/change checkouts, retained
restart and a fresh same-link browser launch.
Ten of sixteen additional revision cases completed actual exact guest assertions:
GitHub tag; GitLab default/ref/tag/
commit/change; Codeberg default/ref/tag/commit. Codeberg change launched but its
bounded 300-second checkout wait ended at fixed `checkout_assertion` index 1,
exit 1, clone status `cloning`. That observation establishes an incomplete clone;
it does not establish a TLS refusal or provider/API root cause. Bitbucket's matrix,
public downloads and CLI were not reached. NixOS and the repaired complete native
matrix remain pending, so ADR-0157 stays partial.

The bounded fixture diagnosis subsequently reproduced Codeberg API resolution
with exact dnsmasq 2.93 and the production-code musl `fetch_head` client. The
captured `address`/`no-resolv` configuration answered A but returned AAAA REFUSED
(rcode 5), which musl rejected; curl with its GNU resolver had accepted that
configuration. Authoritative `local=/codeberg.org/` returned NOERROR with an empty
AAAA answer and the same musl client succeeded. The probe also used the captured
Ubuntu platform CA bundle plus a fresh fixture root; API schema and fork Git
fixtures matched. This establishes the fixture DNS defect at the focused probe
scope, independently of the failed enclosing guest run. The fixture now declares
all four provider domains local, exercises the two API change cases first while
retaining all sixteen additional cases, and adds bounded guest TLS/schema/fork
diagnostics with only fixed stages, indices, exit codes and clone-status values.
No production resolver, TLS trust, source authority or checkout code changes.
Complete Ubuntu and NixOS native acceptance still requires passing runs.
Safe probe records are `artifacts/codeberg-dns-gnu-existing.log` (exit 0),
`artifacts/codeberg-dns-musl-existing.log` (exit 101, one failed assertion in
1.04 seconds) and `artifacts/codeberg-dns-musl-local.log` (exit 0, one passed
assertion in 0.04 seconds). All musl bundle-read, bundle-parse and client-build
predicates passed in both cases; only production-head acceptance changed. The
ignored production-code adapter built at
`/nix/store/vc10sqbg5mdaspxbv771zwx4r2w4hvby-overalls-native-api-probe-0.1.0`
(`1791647290893-554447-0.jsonl`); its source and namespace configuration are
retained under `artifacts/codeberg-dns-probe/`. These observations establish
bounded namespace DNS/TLS/client behavior, not a completed Firecracker guest.

The independent semantic review of the final frozen fixture found no outstanding
issue. Local DNS rules apply only to repository-launch provider suffixes, including
`api.bitbucket.org`. Private API temporary files, installed guest trust, bounded
curl/Git operations, exact fork/commit shape and Git exit status are preserved.
The original done, exact HEAD, shallow, durable marker and retained-restart
assertions remain authoritative. Four initial GitHub cases plus sixteen unique
additional cases retain all twenty combinations; capacity, sequential deletion
and the 300/360/480-second bounds are unchanged. The source tree equals its staged
fixture bytes. Architecture impact is confined to verification of ADR-0157;
no production boundary or new decision is introduced.

The final exact minimized-package download repeat passed all five tests with
`--include host`, seed `735823`, in 0.2 seconds, exit 0
(`artifacts/browser-controller-minimized-immutable.log`). The selected release was
`/nix/store/i5syrkrzq1b7lz0bwnid0chmkglazjlz-overalls-browser-0.1.0`.
The tests compare public bytes, manifest and SHA-256 responses without login
cookies; they refuse missing releases, mutable/traversing roots, unknown selectors,
root/bin/artifact/manifest symlinks, malformed/oversized manifests and empty or
length-mismatched artifacts. This is host filesystem and Phoenix HTTP evidence;
deployed public HTTPS remains separately scoped.

The final Nix check removes an unnecessary HOME override. Chromium already owns
its temporary profile, so the build preserves inherited HOME. The sandbox check
passed again in 9 seconds, exit 0 (`artifacts/browser-final-profile.log`), including
fresh Chromium sentinel actions, all ten Node tests, strict types, lint and package
checks. Its final output is
`/nix/store/iryvjvgv3j89j9wl8f2nby23y65m7h5y-overalls-browser-check-0.1.0`.
The immutable release remains `i5syrkrzq1b7lz0bwnid0chmkglazjlz`; archive bytes and
maintained-source provenance are unchanged, so the exact XPI/controller evidence
above applies to the same release. This check-only correction changes no runtime
or architectural boundary.

Before these final fixture/check-only edits, the reviewed governance batch passed
ADR, HLDD receipts/references, generated options/coverage/views, conflict-marker
and code-contract checks, including all nineteen contract regressions
(`artifacts/governance-minimized-current.log`). The evaluated Nix HLDD gate passed
in 7 seconds, exit 0 (`artifacts/hldd-minimized-current.log`). Those records establish
their captured documentation/source scope; new review receipts and final governance
checks follow the remaining fixture/evidence reconciliation.

The final frozen-fixture NixOS native journey completed successfully: wrapper
exit 0 in 1,352 seconds, output
`/nix/store/71w1nsvkkv7qdb6hdx7kk0kn7rkc09f1-vm-test-run-overalls-repository-launch`,
log `1791647331524-577956-0.jsonl`. Its test script completed in 854.61 seconds;
all twelve subtests passed:

| Subtest | Seconds |
| --- | ---: |
| Real fleet boot with persistent ZFS and nested KVM | 50.49 |
| Authenticated native admission observations | 70.91 |
| Fixed local TLS provider refs/tags/commits/change heads | 0.59 |
| Owner key and Porsche | 5.96 |
| Cross-tab magic-link, required MFA and four deduplicated launches | 22.00 |
| Initial four exact GitHub guest checkouts | 34.38 |
| Retained restart without re-clone | 16.47 |
| Sequential capacity cleanup | 11.53 |
| Fresh same-link browser visit | 32.68 |
| Remaining sixteen provider/revision cases (twenty total) | 576.29 |
| Public immutable downloads | 0.31 |
| Packaged CLI clone, command and working directory | 32.75 |

The NixOS all-provider matrix passed all twenty cases, including exact source rows,
guest-owned clone status done, expected HEAD, shallow checkout and durable markers.
Codeberg and Bitbucket change cases also passed installed-CA TLS, exact API
schema/head and fork Git probes. The NixOS retained restart preserved checkout,
done marker and its local probe without re-cloning. Public downloads passed fixed
HTTPS artifact/manifest/checksum byte equality and no-cookie assertions. Packaged
`overalls open` reached the real checkout, executed its fixed command and verified
the working directory. Normal fragment capture, clean sign-in navigation, shared
cookie resume and required MFA composed through the final privacy-fixed frontend;
browser assertions for query/hash sentinels, storage contents and sanitized POST
contents remain separate from the four pure minimizer tests.

This is actual colocated NixOS/Marshall/Porsche/Lilly/Firecracker execution against
fixed local provider DNS/TLS/Git/API fixtures. It establishes the exercised guest
family and source/authentication paths, not live provider network, production
public HTTPS/cutover, Brady interception, permanent signing or extension-click to
authentication/guest composition. The current implementation and fixture bytes
were frozen before capture; subsequent evidence-only documentation edits change
no runtime input. Ubuntu captured the same frozen source scope at invocation
(`1791648702376-784409-0.jsonl`); its terminal failure is recorded below. ADR-0157
remains partial until that complete family is recorded as passed.

The current frozen-fixture Nix HLDD check passed in 7 seconds, exit 0
(`artifacts/hldd-fixture-current.log`). ADR154, receipt/reference, generated
options/coverage/views, conflict and structural contract checks passed before
the combined governance command ended with an incorrect final test path
(`artifacts/governance-fixture-current.log`); that combined invocation is not a
passing gate. The corrected nineteen contract regressions passed separately
(`artifacts/contracts-fixture-current-tests.log`). A final clean governance batch
will follow both native outcomes and their documentation reconciliation.

The latest frozen-source Ubuntu capture terminated with exit 1 after 266.734
seconds in the wrapper log, derivation `875kwpx2jjf81l69kx031jjrygjprkx0`, log
`1791648702376-784409-0.jsonl`. Five subtests passed: fleet boot (48.51 seconds),
authenticated admission observations (70.16 seconds), local TLS providers
(0.68 seconds), owner key/Porsche (6.19 seconds) and signed-in launch links
(23.04 seconds). The current browser completed cross-tab sign-in, required MFA,
four source-owned launches and deduplication. The first guest-checkout stage then
refused with fixed `Real profile guest failed to start`; Lilly reported
`execution_failed`. No checkout assertion, retained restart, expanded provider
matrix, public download or CLI stage was reached in this run. This failure does
not establish a source/API/TLS or resolver defect; captured startup diagnosis is
in progress. Runtime and fixture feature bytes are unchanged from the passing
NixOS family. Its complete acceptance remains valid at its recorded local scope;
Ubuntu complete acceptance and ADR-0157 implementation remain partial.

The frozen diagnostic-only refinement adds catalogued
`vm.dataset_identity_probe_failed` to the existing readiness observation. It emits
only a validated placement UUID, `identity_before`/`identity_after` and a closed
rejection reason; ordinary identity inspection, capacity observation and
`staging_identity?` remain quiet. The original canonical mount, policy, accounting,
GUID, root/pool and backing guards retain their order and `unsupported_zfs_pool`
result. Retry bounds and success/refusal/credit behavior are unchanged. The
independent semantic and contract review found no outstanding issue
(`artifacts/zfs-diagnostic-contract-format-review.log`).

`parent_accounting` means the complete parent policy-shape predicate passed but
the original strict parent policy rejected its usage-decomposition conjunct.
The later parent mountpoint equality, root, pool and backing checks have not run
at that rejection; the reason does not establish healthy backing or authorize a
retry. The failed native capture's `identity_after`/`unconfirmed` remains a boundary
observation, not proof of this classified predicate. No native refined-event
evidence has yet established its cause. The earlier
[provisioning review](2026-09-26-provisioning-fastpath.md) likewise kept such
failures unproven and required intact capacity/ownership guards.
[ADR-0017](../decisions/0017-durable-vm-actors-and-host-ownership.md) requires strict
normal readiness/capacity; its independently owned import-deferral exception
cannot supply ordinary success. This change adds diagnostic discrimination only,
with no new architectural decision or production authority.

The diagnostic-only focused set passed 21 checks (7 properties, 14 tests), seed
`523473`, in 1.2 seconds (`artifacts/zfs-identity-diagnostic-focused.log`). The
extended missing-path regression proves unchanged refusal, fixed `canonical_path`
metadata, raw-path/dataset privacy and silence for ordinary/invalid-UUID calls;
it does not prove parent-accounting classification or native storage acceptance.
Full Lilly precommit then passed 549 checks (108 properties, 441 tests), seed
`643895`, in 56.1 seconds, exit 0; forced Dialyzer reported zero errors, skipped
or unnecessary skips in 13.12 seconds
(`artifacts/zfs-identity-diagnostic-lilly-precommit.log`). Observability full
precommit passed 11 tests, seed `765622`, in 2.8 seconds, exit 0, with zero-error/
zero-skip forced Dialyzer in 5.74 seconds and the shared trace-schema check
(`artifacts/observability-zfs-diagnostic-precommit.log`). These gates validate
the frozen diagnostic source. The complete NixOS capture predates these diagnostic
bytes; its source/checkout/authority paths are unchanged, while the next Ubuntu
diagnostic capture must record its own native result.

## Authorized main integration

The user authorized an immediate main merge and push while the immutable Ubuntu
capture continued. The merge combines prior main `f39d509a` and browser feature
`a3d2b69c`, preserving main's stopped-only relocation, personal bundled-editor
updates and shared canonical observability library. Runtime code auto-merged;
both architecture indexes retain their independent entries. The independent
integration review identified the diagnostic `pool_identity` atom missing from
the union trace artifact. Regeneration against the merged production source
restored that single atom without changing diagnostic or storage authority.

Focused merged Lilly execution passed 34 checks (11 properties, 23 tests) in
1.4 seconds, the 104-event logging gate and structural contracts
(`artifacts/overalls-browser-merge-lilly.log`). Observability passed the exact merged
schema check and ten formatter/shared-library tests, seed `957221`, in
0.07 seconds (`artifacts/overalls-browser-merge-observability-regenerated.log`).
Marshall's 164-event logging gate, structural contracts and all nineteen contract
regressions passed (`artifacts/overalls-browser-merge-contract-logging.log`).
These are scoped integration results, not full merged component gates. NixOS and
the continuing Ubuntu native captures retain their captured browser feature source
scope; neither establishes merged-main native or production acceptance. ADR-0156
remains implemented and ADR-0157 remains partial pending complete Ubuntu evidence.
The handbook retains the incoming editor/stopped-copy execution records and
corrects the stale editor-reference summary to their exact captured scopes.

## Complete Ubuntu evidence and final implementation assessment

The final complete Ubuntu capture passed, exit 0, in 1,713 seconds total build
plus execution. Its driver reported `test script finished in 1422.20s`; this is
distinct from the wrapper duration. The immutable result is
`/nix/store/bsw54221aw5n4s5js6d81ar780bzcm08-vm-test-run-overalls-repository-launch-ubuntu-fleet`,
log `/home/ghuntley/.local/state/nix/build-logs/1791650057300-1044641-0.jsonl`,
terminal completion status 0 after all twelve successful subtests. It captured
frozen browser feature `a3d2b69c` before the worktree fast-forward to merged main
`bee03919`; the running store derivation did not rerun the merged source.

| Successful Ubuntu subtest | Seconds |
| --- | ---: |
| Real persistent-ZFS/nested-KVM fleet boot | 58.85 |
| Authenticated admission capacity observations | 86.37 |
| Fixed local TLS Git/API providers | 0.80 |
| Owner key and Porsche availability | 6.88 |
| Cross-tab magic-link, required MFA and deduplicated launch/refusals | 31.21 |
| Initial four guest-owned exact checkouts | 22.10 |
| Retained restart without re-clone | 47.85 |
| Release capacity before later journeys | 114.38 |
| Fresh same-user browser session creates a new machine | 64.77 |
| Sixteen additional provider/revision cases, twenty total | 964.11 |
| Public immutable unsigned downloads and metadata | 0.36 |
| Real packaged CLI command and working directory | 24.28 |

The Ubuntu all-provider matrix passed all twenty cases. Every actual guest
checkout reached its own done marker, exact expected HEAD and shallow repository;
Codeberg/Bitbucket change cases also passed installed-CA API/fork predicates.
The Ubuntu retained restart preserved checkout, done marker and local probe
without a partial checkout or re-clone. The Ubuntu public downloads passed exact
archive/manifest/checksum/length equality, no-login-cookie and unknown-selector
refusal over fixture-CA-verified HTTPS. The Ubuntu packaged CLI passed registered
key/Porsche/Audi creation, the fixed guest command in its expected working
directory and invalid-source refusal without creation. Twenty-three guest probes
include the initial four, retained/fresh/CLI probes and sixteen matrix launches.
These compose ordinary privacy-fixed fragment capture through authentication and
guest creation, with fixed local DNS/TLS/Git/API providers and one colocated KVM
failure domain; they establish neither live-provider nor production acceptance.

No `vm.dataset_identity_probe_failed` marker occurred in this complete diagnostic-
source capture. The earlier startup failure's exact predicate remains unproven;
the success does not identify parent accounting, root/pool/backing health at that
earlier failure or a new retry entitlement. No readiness, capacity, identity guard
or retry behavior was patched. All failed captures retain their original scope.

The separate NixOS complete result remains
`/nix/store/71w1nsvkkv7qdb6hdx7kk0kn7rkc09f1-vm-test-run-overalls-repository-launch`,
log `1791647331524-577956-0.jsonl`, exit 0 in 1,352 seconds total build/execution,
script 854.61 seconds, all twelve subtests/twenty cases. It predates the
diagnostic-only addition; the reviewed source/checkout/authentication guards are
unchanged. The merged-main `bee03919` Nix HLDD check separately passed in seven
seconds, exit 0 (`artifacts/hldd-merged-main.log`), following the scoped merged
component/schema/logging/contracts checks above. Neither native result establishes
merged-main native execution.

ADR-0157 is now accepted/implemented: the complete source2/manifest4 and current
authority paths have component/property evidence, and both native families fulfill
the explicit ref/change, cross-tab sign-in/MFA and retained-restart obligations.
ADR-0156 remains accepted/implemented. This is an implementation-status update,
with no new decision, Ash domain/resource, host/service/listener or runtime
authority. Scenarios remain partial for their broader unexecuted boundaries:
live-provider/API/smart-HTTP and Brady interception, production backup/cutover/
activation/public TLS/download/checkout, installed-extension to authentication/MFA/
guest composition, permanent Firefox signing/Android and generated browser event
histories. Four pure capture minimizer regressions and actual extension sentinel
clicks passed; focused browser sentinel assertions for capture storage and sanitized
POST contents remain unrecorded.
