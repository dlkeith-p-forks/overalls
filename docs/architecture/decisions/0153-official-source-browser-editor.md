# ADR-0153: Official-source personal browser editor

- ID: ADR-0153
- Date: 2026-10-10
- Status: superseded
- Implementation: partial
- Components: Marshall, Audi, Lilly, shared protocol, NixOS and Ubuntu guests
- Supersedes: ADR-0094, ADR-0135
- Superseded by: ADR-0158

## Context

[ADR-0158](0158-durable-guest-identities.md) replaces only the email-bound guest
identity clauses below. Immutable GuestAccount UUID/UID/name/home now survive a
same-User email edit, retaining the personal editor origin and current lease.
All remaining package, browser, authorization, execution and recovery decisions
carry forward; the historical verification results below keep their original scope.

The user authorized studying cloned Microsoft VS Code and OpenVSCode Server
repositories, extracting the minimum browser adapters as patches on official
Microsoft source, packaging that source with Nix, embedding the package in both
Firecracker guest images and opening a personal editor from Marshall. Native
NixOS machine tests and meaningful properties are part of that authorization.

Official Code OSS already contains the remote extension host and browser
workbench. OpenVSCode Server provides useful product/build adaptations; its fork
and release binaries need not become our maintained baseline. Browser editor
access carries filesystem, extension-host and terminal write authority. Ordinary
guest web publication and its configurable ports/visibility cannot authorize it.
A shared VM origin would also share browser storage and BroadcastChannel state
across accounts, even with different cookies or URL paths.

ADR-0135 inherits ADR-0069's Customer ingress restriction. ADR-0094 preserves the
Ubuntu archive boundary with specific non-archive tool exceptions. The requested
editor needs narrow exceptions to both. Their existing rationale and historical
evidence remain in those records.

## Decision

Build the pinned MIT-licensed Microsoft Code OSS source directly with a maintained
patch stack. The initial baseline is stable 1.141.0, commit
`2a59476c9bfcb90b3ddc372c36762471b7dfad1c`. Keep OpenVSCode Server as comparison
material, not a source/build dependency. Retain upstream notices, native built-in
language tools, server extension host, file watcher, search and PTYs. Omit desktop
and optional agent/Copilot runtime entry points. Package identity binds the source,
patches, dependencies, native runtime, product/gallery configuration and trust keys.

Permanently disable the bundled built-in AI, Copilot and Chat capability using
typed product policy, immutable configuration policy values and direct service
guards. Conflicting user/workspace/synchronized settings cannot enable it. Keep
generic completion APIs and independent user extension webviews available. Inert
language-model tool registration must not break ordinary ElixirLS activation.
Use upstream `--disable-workspace-trust` for every personal worker: all guest
folders are trusted, including outside HOME. This does not alter Marshall write
admission, guest UID custody, egress policy or explicit direnv approval.

Use ordinary user-overridable defaults `workbench.startupEditor = none` and
`workbench.welcomePage.walkthroughs.openOnInstall = false` so a new window starts without a
startup editor and extension installation does not automatically open a
walkthrough. These preferences do not acquire immutable policy enforcement.

Install four reviewed universal Open VSX VSIXs unchanged as immutable builtins:
ElixirLS `0.31.1`, EditorConfig `0.18.2`, rust-analyzer `0.3.3073` and vscode-direnv
`1.0.0`. Hash-pin both VSIX and signature and verify the entire artifact against
the shipped key ring before bounded extraction. Reject manifest identity, target,
engine, dependency/pack roster or archive-path mismatch. Preserve licenses and
notices. Personal disable state follows upstream browser-profile storage on each
account's separate editor origin, without a cross-device synchronization promise.
Installed extensions and server data remain in account-owned guest directories.
Newer personal versions override the baseline, while equal/older versions retain
it. Baseline uninstall is unavailable; ordinary personal extensions remain
writable.
Use a distinct typed immutable product roster for these four third-party personal
updates, keeping the upstream forced-auto-update roster empty. Ordinary update
preferences, pinning, delay and consent remain upstream; core builtin install
guards and builtin classification/visibility remain. Fresh imports below the
System version refuse even with --force. An effective personal User builtin
override can be reverted using the existing CLI --force uninstall, restoring the
immutable System copy; System uninstall remains refused.

Projects provide language runtimes and servers through devenv. Add no global
Elixir, Erlang, Rust, Cargo or language-server closure. Ordinary user-overridable
defaults choose `rust-analyzer` from PATH and an immutable Elixir adapter directory
that delegates to PATH `elixir`, `elixir-ls` and `elixir-debug-adapter`. Missing
Elixir adapter commands fail with fixed stderr and exit127; absent `rust-analyzer`
retains the direct spawn's ENOENT error. Neither uses an installer fallback.
Keep verified third-party payloads unchanged. Direnv approval remains explicit;
after applying its environment, restart the language server or reload. Concurrent
extension activation does not promise initial PATH ordering.

The typed atomic updater changes extension pins only. Select newest compatible
stable versions using paginated registry metadata, verify signatures using the
actual packaged verifier and engine compatibility using upstream's validator,
then publish one deterministic lock after all selected candidates pass. Failures
before replacement and observed concurrent lock changes preserve the old lock.
Synchronize the complete temporary file before rename and its parent directory
afterward. A postrename parent synchronization failure reports
`durability_unknown` with `publication_durability_unknown`: the complete new lock
may already be visible, while crash durability remains unproved. Review that lock
and rerun validation; partial lock bytes are never published.
No automatic trust-key rotation,
dependency expansion, language bootstrap, official-source update or deployment
is performed by this tool. Lock, validation/extraction recipe, adapters and policy
are release inputs; changes require new matching images without disk migration.

Use Open VSX. Verify a gallery VSIX, including dependency and WEB-targeted installs,
against the package's pinned Ed25519 key ring before extraction. Registry metadata
and user settings cannot replace keys or disable verification. Explicit local VSIX
imports remain a user operation, outside that gallery authenticity claim. Serve
webview bootstrap assets from the approved immutable package on separate hash
origins; no third-party CDN fallback is configured.

Embed this exact Nix package and its Rust broker in NixOS and Ubuntu images. Ubuntu
assembly copies, registers and GC-roots the complete offline Nix closure. This
adds only the editor/broker closure exception to the Ubuntu application boundary;
all ADR-0094 default toolset, offline assembly, pinned input and store-custody
requirements are carried forward unchanged. Manifest v3 includes the editor
protocol/commit/release tuple in immutable image identity. Legacy v2 images remain
valid for their existing capabilities but cannot open an editor. A host activation
does not upgrade retained guest disks.
The authorized machine view exposes a finite editor eligibility status derived
from the same validated immutable image/release check used by Editor authority.
Only a matching machine with desired and observed state both running offers
**Open VS Code** under its existing write/profile and Customer owner policy. A
valid legacy or noncurrent image explains that a new machine from the current
image is required; missing or corrupt image/configuration reports temporary
unavailability. The control never implies an in-place disk upgrade.
This projection grants no editor authority. Image `enabled` remains a new-launch
catalog choice, not a new refusal for an already running matching image.

Marshall owns a separate `Editor` Ash domain with Login, Credential and Lease
resources. Launch and browser approval require a current completed stored login
and current Cedar write authority, allocate the existing permanent GuestAccount
identity and hold locks through the outer ledger commit. Customer additionally
requires the exact current VM owner; administrative elevation is no exception.
Viewer, web and revoked roles cannot open an editor. This is the sole new Customer
ingress exception: an authenticated, fixed-port, owner-only personal editor.
Carry forward all ADR-0135/0069 cache, interception, egress, isolation, attribution,
TLS, storage custody, pressure, budget, privacy and monitoring requirements
unchanged. Ordinary Customer public/private web and arbitrary port ingress remain
refused.

Every personal editor uses the flat HTTPS origin
`e-<full-vm-uuid-base32>-<full-guest-account-uuid-base32>.<editor-zone>`. Both UUIDs
use canonical lowercase RFC4648 base32 without padding. Account UUID pins an
incarnation; a changed email local part or retired account invalidates old
authority before roster reconciliation. A domain-only email change preserves the
account. Different writers on one VM receive different origins and host cookies.
Login tickets, approval codes and cookies are opaque; only hashes persist.
Redirect destinations and callbacks are fixed from current authority, never
caller-supplied forwarded headers or return hosts. Secret-bearing responses are
no-store/no-referrer. Exact editor Origin is mandatory for WebSocket and unsafe
HTTP requests before contacting the guest.

Keep editor responses unframeable except the admitted GET/HEAD of the packaged
browser extension-worker iframe at the grant's exact official commit. That one
response uses `SAMEORIGIN`, retaining sibling-origin refusal while allowing
upstream's local browser extension host. Audi selects exactly one framing header
after guest response processing; guest headers cannot replace that policy.

Classify missing/stale/revoked cookie or stored-login identity as
`authentication_required`, so safe navigation enters the fixed real sign-in flow
and can replace the personal cookie. Current account, profile, write or Customer
owner refusal remains `forbidden`. Missing route/execution remains `unauthorized`
and unavailable to the browser. An unanswered stored-login lookup preserves
infrastructure unavailability under ADR-0140; it cannot begin misleading stale
authentication recovery. A fresh sign-in never revives old credentials.

Audi terminates public TLS and authorizes each HTTP/WebSocket admission through
Marshall. A renewable thirty-second lease binds the account, UID/name, VM,
placement, host connection session, execution epoch/generation, gateway service,
approved release and origin. Current-account, login, write, service and execution
checks apply at renewal. Expired or changed bindings cannot revive. Revocation
hints trigger renewal and the bounded lease is the lost-hint backstop. Closure of
an editor relay does not prove guest process termination.

Lilly alone opens the fixed guest TCP port 4444 through a dedicated packet mark,
binds the profile gateway source address and writes the bounded typed editor
connect preface before opaque relay. Ordinary web/public/peer connectors cannot
target that port. The root guest broker binds the boot's exact IPv4 address and
eth0, admits only its derived gateway source, checks execution/release/account
bindings and reconciles the current roster using the existing Lyra helper.
Caller identity never comes from HTTP headers. The broker starts one systemd
worker under the reconciled UID/home, with owner-only Unix socket, personal data
and extensions directories, and no root fallback.

Workers and their sockets survive broker restart. Native upstream auto-shutdown
governs extension-host lifetime, including its five-minute idle timer and configured
1500-second reconnection grace. It is not an exact timer from the last relay close.
Existing guest writers retain passwordless sudo: personal homes and origins
prevent automatic inheritance, not operating-system confidentiality against
another writer or root. This editor adds no stronger multi-user isolation claim.

Ingress owns short-lived EditorAssetsReceipt readiness, matching current service
generation, host session and exact package. Audi validates all immutable bootstrap
files and proves that its configured local HTTPS listener serves the current
release through a fresh, bounded TLS HEAD with operator roots and exact hash
SNI/Host before refreshing its five-second receipt. Suspended acceptors, wrong
trust/release and missing immutable response headers withhold readiness. DNS publishes internal VM editor
owners and the neutral webview owner only for healthy matching asset gateways;
discovery records do not confer Editor authority. Webview hash names use upstream
JavaScript base32 integer encoding, distinct from UUID origin encoding.

Persist redacted transitions through PaperTrail; expose them through the existing
current-user Control room read policy. Diagnostic events use reviewed Events
catalogs with identifiers/closed outcomes only and follow outer commit. Operational
rows expire through bounded seven-day cleanup; version audit rows follow existing
ninety-day global retention. No credentials, filenames, commands, terminal bytes
or request payloads enter diagnostic/audit metadata.

Add independent recurring NixOS and Ubuntu browser journey sources on Overalls.
They use real completed operator browser storage from private runtime credentials,
fixed guest/UID/origin fixtures and the same typed Playwright journey as native
acceptance. Success requires actual Marshall opening, correct origin, guest
edit/save/readback, personal terminal identity and isolated Markdown. Each
five-minute journey has a sixty-second owned browser deadline and a separate
durable recorder/exporter. The dedicated Linux subreaper adopts detached browser
descendants, selects only kernel-owned children and kills/reaps them before
successful settlement. Five-second producer heartbeats preserve idle coverage;
missed slots or lost recorder authority create gaps rather than fabricated
successes/catch-up requests. The source-specific histogram ends at sixty seconds
without changing older source bounds. Provisional 99% seven-day objectives carry
forward the existing source/warmup/collector and minimum-sample burn guards.
Fixed-window diagnostics expose repeated failure or no recent completion only
under current guarded coverage; missing credentials/coverage remain unknown.
Declared probe placement does not establish credentials, live execution or health.
Under ADR-0149 these measurements and diagnostics stay in the independent
Prometheus/Grafana plane. Marshall retains transactional editor authorization and
redacted security audit; its retired SLO reader is not restored. Editor event
catalogs and HTTP spans join the reviewed shared observability schema without
credential, origin, path or terminal data. Current physical readiness follows
the authenticated v4 start/provision outcome's `guest_ready: true`, while the
guest fixture separately validates the host-local current boot and Provisioning
journal. Diagnostic lifecycle ingestion is not a readiness prerequisite.

## Alternatives

Maintaining the OpenVSCode fork or downloading its binaries was rejected because
the user requested official source plus a reviewable minimal patch stack. A generic
guest HTTP proxy was rejected because it would inherit web-port and visibility
authority instead of filesystem/terminal write authority. A single VM origin or
path-only account separation was rejected because browser storage is origin-wide.
An upstream connection token at a root server was rejected as the principal
boundary; it cannot establish current personal UID, execution or Marshall grants.
First-boot package downloads were rejected because Customer may have no egress
and immutable image capability must be known before admission.
Per-user seeding of baseline extensions was rejected because mutable copies can
drift and do not supply a reliable image capability. Global language toolchains
were rejected in favor of project-selected environments. Modifying signed VSIX
launchers was rejected in favor of ordinary defaults and small external adapters.
Settings-only AI hiding was rejected because direct calls and restored Chat state
could retain capability. Automatic workspace trust is an explicit user-approved
guest product choice; it does not grant `.envrc` approval.

## Consequences

The image closure grows and editor enablement requires a newly assembled matching
image. Package/key updates change release identity and require coordinated gateway,
Marshall and image rollout. Authority loss closes communication within the lease
bound but existing guest processes follow their own native lifetime. Registry key
rotation is a reviewed package update. Account origins and webview origins require
the existing wildcard TLS/DNS custody; publication depends on local asset readiness.

## Invariants and verification

- Official-source patches apply to the pinned unmodified source, compile with
  upstream TypeScript checking and build REH-web offline; no upstream binaries.
- Properties exercise canonical origins, closed manifests/prefaces, malformed
  inputs, exact release/execution binding, role matrices and dedicated port refusal.
- Database tests exercise single-use exchange, cross-account cookies/approvals,
  stale login/grant/account/execution refusal and no audit/event on outer rollback.
- Native NixOS tests run the real package and broker with trusted browser TLS,
  built-in formatting/diagnostics/search/Git/Markdown/terminal behavior, exact UID,
  foreign gateway/release/epoch/account refusal, broker survival and worker recovery.
- Native Ubuntu and full Marshall→Audi→Lilly→Firecracker journeys remain required;
  a synthetic bridge/roster authorizer cannot establish those boundaries.

## Implementation evidence

Both corrected startup-release Firecracker family scripts now passed on the
immutable `/tmp/overalls-editor-corrected-native-fleets-fls4bybc` snapshot:
NixOS 805 seconds and Ubuntu 829 seconds, exit 0. They execute actual Marshall,
Audi and Lilly, real browser policy/personal controls, broker/worker recovery and
saved-data stop/start with exact current physical readiness. The snapshot
predates later incoming template changes; it establishes no periodic sweep
acceptance. Exact logs/stages are in the
[review](../reviews/2026-10-10-browser-editor.md). Earlier failed runs below retain
their own revision/scope. Complete standalone version and real-language
acceptance remained open at that boundary: the fresh lower-version expectation is invalid,
the newer personal permission correction has a passing actual package but native
version selection/reversion remained unexecuted,
and both initial scoped actual language stages failed. A later scratch Elixir
stage passed with fixture-only immutable Hex/MIX_HOME while the same run still
failed Rust's Cargo arguments. The subsequent strict both-language scratch run
passed in 36.61 seconds on old startup package 3zz; complete final-package language
acceptance is separate.
A separate writable-settings
diagnostic passed personal HOME/outside/direnv/disable/override browser checks
on an older immutable package, without establishing complete current acceptance.

The [personal update patch](../../../nix/domains/artifacts/vscode-web/patches/0004-overalls-personal-bundled-updates.patch)
and [compiled membership checker](../../../nix/domains/artifacts/vscode-web/check-bundled-updates.mts)
preserve that accepted behavior with a distinct four-ID product roster. The
earlier new package passed in 226 seconds, exit 0, at release
`8efe4c8af6e30ffde6d614135deb86bb77968f13a8376ce23a2a01ad629ef627`, with full
client TypeScript, 344 compiled-helper membership decisions, existing policy and
installed Chromium/PTY checks. Its installed product retains the exact lowercase
roster, empty forced roster and startup defaults. These local package/helper
results do not establish actual Workbench update preference behavior, personal
newer install/reversion, core native refusal or final language acceptance. The
review records the exact output/log and source/contract review; deployed release
73ad and earlier native snapshots retain their separate identity.
The final checker-hash-bound package then passed in 236 seconds at release
`7d2415fecdd209b1cad571f2fd95a22fa4829f5fa4ed50e8688bd08d25f2d9a6`, with the same
full TypeScript/helper/policy/Chromium/PTY scope. Its installed-validator check
passed in seven seconds and both new guest image builds in 99 seconds, carrying
matching manifest-v3 tuples. These builds do not establish current native fleet
or production runtime; the complete final standalone execution remains separate.
A strict scratch fixture passed 36 actual Workbench update-preference cases and
bounded forced-install filtering, using finite mocked collaborators. Constructor
scheduling, real metadata/core selection, gallery/native installation and full UI
remain separate. The first final standalone attempt reached the correct lower
refusal but failed a stderr-capture oracle. The corrected full rerun then passed
in 342 seconds total build/execution, with actual newer install/reversion,
lower/core/System refusals, independent personal controls, real rustc Error E0308
and Elixir responses, broker continuity, origin replacement and worker recovery.
Its native package/broker/personal-UID/HTTPS scope uses a local authorizer/relay;
final-release Firecracker family and production acceptance remain separate.

Both production hosts subsequently activated exact
`63a1443cf490312df50b3a43af55d92fd7afc263` and release 73ad, independently
observed healthy at 13:00 UTC on 2026-10-10. Installed product/defaults and both
new manifest-v3 guest images match protocol 1/source/release. This is host and
immutable-image evidence, not a production editor journey or retained-disk
upgrade. A separate current existence-only inspection at 13:06:33 confirmed all
four recurring fixture/session files absent, with browser supervisors restarting;
active exporters supply no completed browser coverage. Production opening and
seven-day history remain unestablished. Implementation remains partial.

The [startup-defaults patch](../../../nix/domains/artifacts/vscode-web/patches/0003-overalls-startup-defaults.patch)
and [product configuration](../../../nix/domains/artifacts/vscode-web/default.nix) are a
small follow-up under this decision. The new actual package passed in 217 seconds
and its installed-validator maintenance check passed in 28 seconds. Its release
is `73ad577f1102eaf74ba05f0c6dbd310ee8896d852c36860ff4761271fc700fff`.
A separate fresh-profile manual Chromium smoke awaited the actual workbench
restoration lifecycle and observed no Getting Started panel or startup
Welcome/Get Started/Walkthrough tab. This does not prove removal of an existing
saved editor, actual extension-install walkthrough behavior, personal override
execution, native guest or production acceptance. The review records exact
outputs and temporary fixture provenance; earlier evidence below retains its
prior scope.

[The policy patch](../../../nix/domains/artifacts/vscode-web/patches/0002-overalls-editor-policy.patch),
[extension lock](../../../nix/domains/artifacts/vscode-web/extensions.lock.json),
[validator/extractor/updater](../../../nix/domains/artifacts/vscode-web/extensions.py) and
[maintenance wrapper](../../../nix/domains/artifacts/vscode-web/updater.nix) implement the
authorized specialization. The [maintenance tests](../../../nix/domains/artifacts/vscode-web/test_extensions.py)
passed all 19 tests without skips in 1.239 seconds under Python3.13.15 with the
actual source-bundled Node signature/upstream engine boundary. They include
generated safe-path/nightly-page histories, exact adapters, malformed artifacts,
old-lock preservation before publication and complete-new-lock durability
uncertainty afterward. Both explicit four-version and live automatic
rust-analyzer checks returned structured `outcome: current`. Focused Ruff and ty
passed. These scoped developer results and compiled policy checks are recorded
in the [review](../reviews/2026-10-10-browser-editor.md); they do not establish a
final specialized package build, native NixOS/Ubuntu extensions or production.
Historical package/native records below retain their tested revisions.
The final specialized Nix package subsequently passed, exit0, in 234 seconds,
including actual upstream TypeScript/compiled policy checks, signed extension
extraction and installed Chromium workbench/PTY runtime checks. Its release ID is
`6bc2197a6d4f5b2183a7274ae2c967eee1f95b4f0ccd10f5a71fbbd472b16e8d`; the exact
output/log and synthetic local scope are recorded in the review. Fresh native
standalone and both Firecracker guest-family journeys remain separate acceptance.
The Nix extension-maintenance check subsequently passed in nine seconds with the
final installed validator, all 19 tests without skips and Ruff/ty. The actual
packaged wrapper returned current JSON for all four pins. Its default live
`--check` command subsequently selected latest compatible stable versions through
bounded pagination, validated the complete signed artifacts and returned
`outcome: current`, all four unchanged, exit0. The review records
exact outputs/logs and the initial sandbox-layout correction; native extension
activation and the remaining platform obligations are still partial.
The final standalone native attempt then passed its first browser terminal proof
but failed the new Native Policy stage. Replay showed its policy success marker
and expected EditorConfig indentation with no visible AI UI; the exact failing
browser assertion remains unknown. Node counts and notification-selector
strictness are not established causes.
The corrected per-action fixture subsequently passed the cold terminal/editor/
webview/browser-extension journey and Alice's outside-HOME policy stage, then
failed before invoking Bob's HOME policy command: the command-palette row was
absent for 30 seconds. The exact failed locator and log are recorded separately
in the review; CLI listing and a present fixture directory do not establish
frontend activation. The earlier failed assertion remains unexplained. Full
passing native rerun and complete personal control/language acceptance remain
required.
The premerge specialization's ordinary Marshall selection passed 1,257 checks
(224 properties, 1,033 tests; 169 excluded), followed by forced Dialyzer with zero
errors/skips/unnecessary skips in 32.67 seconds. Its frozen Nix HLDD gate passed
in 12 seconds. The later merge carries origin's ADR-0152 PoolSnapshot and
ADR-0154 guest boot-profile decisions and scoped evidence forward. Merge review
keeps its accepted wait requirement and records an unimplemented in-flight
timeout bound with partial implementation.
The merged Nix HLDD check subsequently passed in nine seconds, exit0, on the
frozen merged snapshot. Marshall's full merged precommit then passed, exit0:
1,424 checks (237 properties, 1,187 tests; two excluded) in 1,432.7 seconds,
followed by forced Dialyzer with zero errors/skips/unnecessary skips in 30.7
seconds. The exact `058f13d8` NixOS and Ubuntu fleet executions subsequently
failed during the real-guest policy phase after their initial cold editor/
terminal/custody journey passed. Their logs and durations are recorded separately
from historical passes; current complete policy/control/recovery acceptance
remains open.
Both production hosts settled healthy on `50021c04`, which contains the editor
merge. Host activation does not establish fresh guest or authenticated browser
acceptance. The review retains exact activation provenance and remaining gaps.

[The package and update procedure](../../../nix/domains/artifacts/vscode-web/README.md),
[recipe](../../../nix/domains/artifacts/vscode-web/default.nix) and
[patch](../../../nix/domains/artifacts/vscode-web/patches/0001-overalls-browser-editor.patch)
implement the official-source build and browser adapters.
[The broker](../../../nix/domains/artifacts/vscode-web-broker/src/main.rs),
[NixOS module](../../../nix/domains/artifacts/guest/vscode-web.nix) and
[Ubuntu assembler](../../../nix/domains/artifacts/guest/ubuntu/default.nix) establish the
declared personal runtime and closure assembly.

[Editor authority](../../../marshall/lib/marshall/editor/authority.ex),
[controller](../../../marshall/lib/marshall_web/controllers/editor_controller.ex),
[Audi admission](../../../audi/lib/audi/http/editor.ex),
[asset publisher](../../../audi/lib/audi/http/editor_assets_publisher.ex),
[Lilly connector](../../../lilly/lib/lilly/network/ingress.ex) and
[protocol](../../../protocol/lib/overalls_protocol/editor_connect.ex) implement the
cross-component fences. [DNS publication](../../../marshall/lib/marshall/ingress/publications.ex)
requires live immutable asset readiness.

[Marshall tests](../../../marshall/test/marshall/editor_test.exs) and
[publication tests](../../../marshall/test/marshall/editor_publication_test.exs)
have scoped passing execution in the
[review](../reviews/2026-10-10-browser-editor.md). The
[image capability property/unit tests](../../../marshall/test/marshall/compute/image_editor_capability_test.exs)
and [workspace/domain tests](../../../marshall/test/marshall_web/editor_workspace_test.exs)
also passed in the focused 58-check selection (five properties, 53 tests), seed
`369052`. Marshall's final forced Dialyzer check reached actual analysis and
passed with zero errors/skips in 38.26 seconds after rebuilding stale artifacts.
The subsequent full feature Marshall gate passed 1,424 checks (237 properties,
1,187 tests; two excluded), seed `309061`, and final forced Dialyzer with zero
errors/skips in 32.68 seconds. It tested the eligibility/authority body before the
later cosmetic toolbar diff; that diff has separate component verification.
The tests establish exact
retained-image status and mounted/fresh launch
refusals, not native isolation or a production editor journey. The
[native fixture](../../../nix/verification/tests/machines/vscode-web/default.nix) passed its
complete Linux browser/UID/socket/refusal and broker/worker recovery assertions;
its synthetic bridge and roster retain their standalone scope. Before observability
integration, the complete NixOS fleet check additionally passed real
Marshall→Audi→Lilly→Firecracker login,
personal tools, broker/worker recovery, saved-data stop/start, current-generation
physical running/readiness, unsafe Origin refusal and sign-out/WebSocket closure
with fresh sign-in recovery. Stop/start preserves placement/execution epoch,
advances generation and rotates physical boot challenge/guest boot UUID.
Definitive official-source packaging, strict source/checker typing,
[no-account async settlement](../../../nix/domains/artifacts/vscode-web/check-no-account.mts),
verifier/runtime checks and actual installed Chromium workbench startup inside
the Nix sandbox have recorded acceptance in that review. All four full application
gates, including Marshall's 1,532 checks and forced Dialyzer, also passed before
integration with main's independent-observability cutover. These records establish
their tested revisions. Merged Protocol/Lilly/Audi full gates subsequently passed
258/543/197 checks respectively with zero-error forced Dialyzer; the current
Marshall full gate passed as recorded above. The corrected merged NixOS fleet subsequently passed
the complete authenticated browser/recovery/revocation journey in 742 seconds
total build plus native execution on `849d8022` plus the eligibility/SSH/root-UID
diff later committed as `af01b4b9`. This is captured-snapshot acceptance, not a
postcommit or production browser run.
Implementation remains partial: Ubuntu image provisioning and expected-origin
handoff passed, but its initial workbench visibility assertion failed before the
complete browser/recovery/revocation journey. Fixed diagnostic substages have been
added without changing waits or assertions; the runtime cause remains unproved.
Dungarees activated merged `0fcab4f6` healthy, while Overalls build initially failed before
activation at a missed standalone `EditorRelease` loader. The focused dependency
loading correction preserves shared manifest identity and this decision. The
corrected full local bundle passed; both hosts activated `849d8022` healthy with
zero updater failures. Host activation and the anonymous deployed route's sign-in
redirect remain separate from authenticated editor runtime acceptance in the
review. Both hosts subsequently activated `af01b4b9` healthy with zero updater
failures. The merged handbook browser renderer also passed. Both first merged
editor fleet runs stopped on the fixture's obsolete literal prompt assumption.
The corrected Ubuntu run then passed root-UID proof, provisioning and authenticated
handoff but reproduced the initial workbench visibility failure; cause remains
unproved. Corrected NixOS completed the first browser/UID/webview, broker-restart,
worker-loss, saved-data stop/start and foreign-Origin/sign-out closure stages.
Subsequent finite browser/bootstrap and current-boot worker probes preserve the
original failure and assertion deadlines. Later Ubuntu diagnostics observed an
initial bad-gateway document without workbench bootstrap, Monaco or WebSocket
startup; optional worker-health output was discarded and cannot establish those
booleans. Source inspection identified missing `/nix/store` creation before closure
copying and retained build-user ownership of trusted configuration. The assembler
now preserves complete store basenames and root custody with explicit assertions.
This correction preserves accepted offline closure requirements; post-fix native
Ubuntu workbench acceptance remains required and is not established by the source
diagnosis.

## Open questions

Complete Ubuntu Firecracker acceptance, multi-gateway failover, upstream idle
lifetime under active extensions and coordinated retained-image rollout require
scoped evidence. Native local tests do not establish confidentiality against sudo
writers or independent physical host availability.

## Related decisions

[ADR-0011](0011-nixos-guest-and-console.md),
[ADR-0068](0068-nix-built-ubuntu-guests.md),
[ADR-0094](0094-default-development-environments.md),
[ADR-0125](0125-fresh-guest-identities.md),
[ADR-0132](0132-seven-day-provisional-fleet-objectives.md),
[ADR-0136](0136-durable-application-request-accounting.md),
[ADR-0135](0135-streaming-public-artifact-cache.md),
[ADR-0140](0140-event-driven-liveness-and-single-writer-views.md),
[ADR-0142](0142-overallsprotocol-control-websocket.md),
[ADR-0148](0148-open-domain-email-eligibility.md).

The integration also carries forward
[ADR-0149](0149-independent-observability.md) and
[ADR-0150](0150-default-guest-starship.md).
