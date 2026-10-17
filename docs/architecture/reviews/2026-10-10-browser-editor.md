# Official-source browser editor review

Date: 2026-10-10. Decision: [ADR-0153](../decisions/0153-official-source-browser-editor.md),
accepted and partially implemented under the user's explicit source-comparison,
patch/package, guest embedding and Marshall browser-opening request. Work is in
the isolated `overalls-vscode-web` worktree. Host activation is recorded below;
host activation alone does not establish a production editor journey.

The historical package/component/standalone/NixOS acceptance below precedes
integration with main `e4d5b6cc` and its independent-observability cutover. Merge
reconciliation preserves ADR-0149: Marshall's retired diagnostic readers and
telemetry modules remain deleted, browser numeric recordings stay independent,
and editor catalogs/spans join the shared reviewed schema. Current fleet readiness
uses authenticated v4 physical `guest_ready: true`; the guest helper separately
proves the current confined boot and host-local Provisioning journal. Historical
NixOS physical/event correlation remains evidence for its earlier revision,
and does not prove execution of the merged query. The later merged component,
handbook renderer, complete corrected NixOS fleet and deployment results are
recorded separately below; complete Ubuntu execution remains required.
The merged source review preserved primary generic Audi privacy, closed editor
`int64` bounds, the existing shared catalog and schema, and Marshall's editor
audit/configuration union. Regenerated trace-schema check, changed-file formatting,
contract syntax and Audi/Marshall logging gates passed. The focused actual Audi
Privacy suite passed eleven checks (one property, ten tests) using the installed
primary privacy filter and compiled shared observability library. Merged full
component and native results remain separate from that bounded acceptance.
Nix merge reconciliation preserves independent observability recovery bindings
and adds a guarded browser-observations Grafana table. Diagnostic panel IDs derive
after all duration/objective IDs from the same rosters, preventing the old fixed
58/59 values from colliding after two browser sources are added. The merged fleet
query requires an actual JSON boolean `guest_ready`, valid sequence, exact current
physical observation and matching immutable start identity. Source/declaration
checks establish these corrections; the corrected merged NixOS run below
additionally executes the physical readiness query after actual stop/start.

## Boundaries reviewed

The cloned official repository was inspected at stable 1.141.0 commit
`2a59476c9bfcb90b3ddc372c36762471b7dfad1c`; the OpenVSCode Server clone was inspected
at `2bfb814c5215c51a10e80c2cb1b58ed91068ad8b`. The research trees are
`/tmp/openvscode-research.sCXhVy/vscode` and
`/tmp/openvscode-research.sCXhVy/openvscode-server`, with a separate patch tree at
`/tmp/vscode-overalls-patches-20261010`. OpenVSCode's Open VSX product configuration
and source-built REH layout informed the package. Its downstream release binaries
are not inputs.

Official Code OSS already supplies REH-web, native server extensions, PTYs,
watching, search and language tools. The package takes official Microsoft source
as its sole upstream source and applies the maintained
[patch](../../../nix/domains/artifacts/vscode-web/patches/0001-overalls-browser-editor.patch).
OpenVSCode is comparison material. The
[recipe](../../../nix/domains/artifacts/vscode-web/default.nix) builds dependency inputs and
native bindings offline, checks TypeScript and preserves license notices. Product
configuration omits optional agent/Copilot entry points, sets Open VSX and pins
gallery signing keys. Gallery VSIX verification precedes extraction and settings
cannot bypass it. Local VSIX imports retain their different trust boundary.

Marshall Editor is separate from ordinary Ingress web authority. Reviewed
[authority](../../../marshall/lib/marshall/editor/authority.ex) locks current
service/host/VM/account/login facts through ledger commit, verifies exact approved
image capability and binds a thirty-second lease to the complete account/execution
tuple. Current write is required. Customer requires exact ownership even against
an elevated administrator. Single-use browser exchange stores only hashes;
redirect hosts are derived from canonical authority. Per-account origins prevent
shared origin storage from merging two writers' browser state. Exact Origin checks
protect unsafe requests and WebSockets from same-site sibling origins.

Control refusals distinguish stale or missing browser authentication from current
permission denial and unavailable execution. A safe request with a stale cookie
returns to the fixed Marshall sign-in/approval path; current account, ownership or
write denial stays forbidden. Missing routes and execution remain unavailable.
Fresh ordinary sign-in can replace the host cookie without reviving the stale
credential or lease.

Review also found that `Login.present` collapsed unanswered token lookup into
stale authentication. Editor now uses `Login.check`, preserving definite refusal
as authentication-required and an unanswered lookup as infrastructure unavailable
under ADR-0140. A deterministic actual SQL-sandbox regression separates a current
login, a caller without database ownership and a deleted stored login. The editor
and lookup selection passed 20 checks (1 property, 19 tests), seed `908561`,
5.1 seconds; logging validation passed. This is application/database custody scope,
not a native outage experiment.

[Audi admission](../../../audi/lib/audi/http/editor.ex) and
[browser adaptation](../../../audi/lib/audi/http/editor_browser.ex) use these grants
instead of guest-supplied HTTP identity. A dedicated Lilly connector binds the
gateway source and a typed preface. Generic ingress and peer routes refuse port
4444. The guest broker checks boot/release/account/source before startup and
delegates roster reconciliation to the existing helper. Personal systemd workers,
Unix sockets and data directories are distinct from the root broker. Existing
passwordless sudo means this is not OS confidentiality against another writer.
Worker processes survive broker loss; relay revocation is not process termination.

[Asset receipts](../../../marshall/lib/marshall/ingress/editor_assets.ex) expire in
five seconds and bind service generation, host connection and approved immutable
package. DNS only advertises matching healthy gateways; it never authorizes use.
Webview hash origins are separate from account origins and have immutable local
bootstrap files. Both Nix modules declare the exact approved tuple. Both guest
builders include editor identity in manifest v3 and retain v2 as non-editor.

Redacted transition versions enter existing bounded ninety-day audit retention.
Operational cleanup is seven-day and batch-bounded. Reviewed catalog events follow
the outer ledger commit; nested action success followed by rollback produces no
authority outcome. The Control room audit read policy remains current-user
`admin_read`, consistent with the existing Cedar contract.

The [recurring browser module](../../../nix/domains/system/otel-fleet/browser-probes.nix)
declares independent Overalls NixOS/Ubuntu supervisors with private real operator
storage state and closed guest fixtures. The
[shared journey](../../../nix/domains/system/otel-guest/browser_journey.py) is also used by
full fleet acceptance; success requires actual Marshall opening, expected origin,
saved/read-back Markdown, isolated preview and personal terminal UID/guest OS.
Separate durable recorders/exporters carry numerical outcomes under distinct
producer/read/collector custody. The sixty-second child deadline, five-minute
interval, idle heartbeats and skipped-slot gaps preserve unknown coverage rather
than fabricate health. Two provisional 99% seven-day objectives retain the existing
sample/coverage/burn guards and source-specific histogram. Fixed-window diagnostics
mean three failures without success in fifteen minutes or no completion in ten
minutes, under guarded warmup; they are not a consecutive-failure counter.
The original Marshall browser-card parser assertions are historical component
evidence only; main's ADR-0149 retires that reader. Current diagnostic queries and
presentation remain in independent Prometheus/Grafana, without granting Marshall
account or editor authority.

The shared journey gives Chromium private writable configuration/cache directories
without changing HOME or inherited data paths, preserving the native tester's
actual NSS trust database. Its wrapper supplies pinned Fontconfig and DejaVu even
on a headless host. The wrapper/closure derivation passed, exit zero, in seven
seconds at `/nix/store/272a971ljfcdhgsrwipx5jaqq10gx6fw-overalls-browser-editor-journey`.
That establishes assembly of the real helper and font closure, not an authenticated
recurring journey. The package-only startup fixture separately owns its temporary
trust bypass; that fixture cannot establish the verified TLS trust of native tests.
At this historical revision, native and shared helpers wait for the matching command/file picker row,
open upstream's actual workspace-trust editor through its ordinary command or
Restricted Mode statusbar entry, grant the reviewed fixture workspace trust when
untrusted, wait for the current trusted class and close the editor. That class
records current UI trust, not completion of extension-host transition participants;
actual subsequent extension/preview/terminal operations establish readiness.
They inject neither trust database state nor Marshall authority. Pinned all-file
Python format/lint/type checks passed after this repair, including the final source
checker and native helpers; actual native/fleet execution remains separately scoped.
The final shared helper also bounds command-picker reopening while contributions
restore, retains the sixty-second supervisor deadline and supports later already
trusted journeys. Its final pinned wrapper/closure derivation passed, exit zero,
in five seconds at
`/nix/store/0n91vv8crr0v0qlpgfq86qczva6kw68g-overalls-browser-editor-journey`.
That revision waits for the active terminal textarea before inspecting its
accessibility tree, enables screen-reader accessibility only when that tree is
absent, and waits for the tree before checking output. Pinned Python format,
lint and type checks passed. This readiness correction came from source review,
not an observed fleet terminal failure; current-helper fleet execution remains
separate from closure assembly.

## Scoped execution

Review identified four actionable ADR-0153 boundaries and reconciled their code:

- Medium: blanket `DENY` in Audi blocked upstream's same-origin extension-worker
  iframe. The reviewed correction permits `SAMEORIGIN` only for an admitted
  GET/HEAD at the grant's exact stable commit path, retaining `DENY` elsewhere.
  Its proxy/control regression passed 4 checks (1 property, 3 tests), including
  foreign commit, unversioned/suffix paths and forged platform-cookie refusal.
  This establishes local relay scope; actual browser activation remains native
  acceptance. Final before-send enforcement removes every guest framing header
  and writes exactly one platform-selected value. The final four-check regression
  passed with deliberate conflicting guest `DENY` and `SAMEORIGIN` headers;
  generic guest web policy is unaffected.
- Medium: statically present assets and supervisor ordering did not prove a
  nested HTTPS acceptor was serving them. A suspended listener could keep DNS
  advertised from a fresh receipt. Before each receipt, the repaired publisher
  now requires a fresh verified TLS HEAD through the configured local IPv4
  listener, using operator roots, canonical hash SNI/Host and the current immutable
  release path. Its 1.5-second deadline and bounded headers require exactly the
  expected 200 HTML/nosniff/immutable-cache response without cookies or redirects.
  The actual healthy, wrong-release, wrong-SNI and suspended-listener regression
  passed in 8 Audi front checks. This establishes real local TLS listener scope;
  native multi-gateway discovery and fleet acceptance remain separate.
- Medium: `Login.present` erased the distinction between a removed stored login
  and an unanswered lookup. `Login.check` now preserves infrastructure
  unavailability under ADR-0140; the actual SQL ownership/removal regression and
  twenty-check editor selection passed as recorded above.
- Low: Marshall's generic single-label zone validation could return an editor
  origin that the shared protocol/native broker refused. Editor authority now
  uses the shared canonical multi-label validator, explicit runtime configuration
  and Nix service assertions refuse the mismatch, and Audi applies that validator
  when editor assets are configured. The module-configuration Nix evaluation
  passed acceptance/refusal and disabled-editor compatibility cases. The actual
  editor zone/lookup selection passed 21 checks (1 property, 20 tests), seed
  `163227`, 4.8 seconds, including real launch refusal and allocation rollback;
  Actual `mix app.config` also refused the explicit single-label editor runtime
  setting before application startup. Configured Audi preflight remains under
  final native execution; its final 197-check component gate and forced Dialyzer
  were repeated successfully after the conditional zone guard.

Verification review separately found two fixture issues. An early one-time trust
dialog observation did not establish the native workspace's trust state; pinned upstream
inspection also showed the actual Trust button's accessible name appends its
keyboard shortcut, so an exact `Trust` role name cannot match it. The correction
must use the actual scoped button semantics and wait for current trusted state,
without injecting storage. The native diagnostic contract also promised private
artifacts while screenshot/JSON creation relied on default permissions and a later
chmod. The corrected fixture creates both files exclusively at mode 0600 and adds
native mode assertions; its helper format/lint/type gate passed in six seconds.
Review also found that HTTP-only diagnostic redaction left complete WebSocket and
other URL schemes; the corrected fixture redacts its bounded known URI schemes
under that same private-artifact contract. Actual native artifact mode assertions
passed for both files. The later complete native acceptance is recorded below.
These findings preserve product authority decisions; passing final native execution
is still required.

Marshall editor focused execution passed 19 checks: 1 property and 18 tests,
seed `131414`, 5.0 seconds, with warnings-as-errors in the pinned development
shell. Paths are
[authority](../../../marshall/test/marshall/editor_test.exs),
[publication](../../../marshall/test/marshall/editor_publication_test.exs) and
[controller](../../../marshall/test/marshall_web/editor_controller_test.exs).
The role property exercises current web/viewer/operator/manager/revoked roles;
only current operator/manager write passes. Fixed histories cover exact account
origins, cross-account cookie/approval refusal, Customer exact-owner refusal,
single-use exchange, email-local-part changes, retirement, login/grant revocation,
execution/release change, lease expiry and outer-rollback audit/event suppression.
Publication tests withhold Customer editor and neutral webview DNS without live
assets and after expiry; wrong release, wrong service role and stale credentials
cannot attest readiness. This is SQL-backed application scope, not native isolation.

The implementation team reports protocol focused execution passed 21 checks
(10 properties, 11 tests), Lilly ingress/network passed 34 (6 properties, 28 tests),
and Audi editor/privacy passed 14 (2 properties, 12 tests). These are component
checks, not the complete authenticated service chain. Their later full component
gates are recorded below, including Marshall's full distributed gate.

The later expanded Marshall editor/ordinary-ingress selection passed 32 checks
(6 properties, 26 tests), seed `331776`, 8.7 seconds. It adds reserved-port refusal
with no web authority rows and unchanged endpoint projection. The final focused
editor/ingress/browser-SLO selection passed 50 checks (13 properties, 37 tests),
seed `367030`, 12.2 seconds, with warnings-as-errors. New fixed assertions verify
retention of referenced credentials and independent audit versions, refusal of
replaced host sessions/gateway generations, guarded browser diagnostic booleans
and the full bounded 132-field evidence projection. Contract structure and its
19 validator regression checks passed; this is not semantic compliance proof.
Logging validation then found the missing `kind` formatter key and stateless
token-minter exemption. The correction preserves after-outer-commit authority
events. The latest editor/ingress/browser-SLO selection passed 52 checks
(13 properties, 39 tests), seed `772286`, 9.9 seconds, with warnings-as-errors.
It additionally verifies normalized control refusal classes and fresh sign-in
recovery while the stale cookie remains authentication-required. The logging
gate passed with 162 catalogued events, and Ash migration snapshot generation
reported no missing migration.

Protocol's final full component gate passed 265 checks (104 properties, 161 tests),
seed `184030`, 420.4 seconds; Lilly's passed 519 checks (104 properties, 415 tests);
Audi's passed 196 checks (54 properties, 142 tests). That Audi execution precedes
the later iframe and listener-readiness repairs. Audi's final full component gate
passed 197 checks (54 properties, 143 tests), including those repairs; its forced
Dialyzer gate reported zero errors. All three earlier forced Dialyzer
gates also reported zero errors. The actual `audi-ingress-network` NixOS check
passed the dedicated editor mark/gateway and generic-web/peer refusal assertions;
this establishes its packaged Linux veth network scope, not Firecracker acceptance.
The Ubuntu guest normalization, default guest toolset and private guest-service
evaluation gates passed (`ubuntu-guest-unit`, `guest-toolset`,
`private-services-guest`). They check builder/unit/property scope; they do not
establish image assembly or native browser acceptance of a later editor revision.
Pinned all-file Python format/lint/type checks passed. The native telemetry recorder
package passed 43 library tests and 3 integration tests with Clippy, including
browser timing/coverage properties; this does not establish actual browser or
recurring production execution. Its latest gate passed 44 library tests and
3 integration tests with Clippy. The final native Linux descendant cleanup gate
then passed 45 library tests and 3 integration tests with Clippy. Its dedicated
subprocess regression starts a middle process and detached leaf in separate
process groups, kills the middle and verifies that subreaper adoption, kernel-owned
child selection, SIGKILL and reaping leave no owned child. Every browser settlement
uses that cleanup; failed retirement cannot become successful completion. This is
actual Linux subprocess scope, not a NixOS/Firecracker recurring browser run.
Prometheus objective/candidate/latency fixtures
and the existing minimum-twenty-sample burn guards passed. Diagnostic validation
checked 232 rules and both browser sources' failure, idle, success, collector
outage, stale, warmup and gap histories. These are rule and state-machine scopes,
not actual browser or recurring production execution.
The current exported broker is
`/nix/store/08cngz71aj6s5zwkbh42sx44wn66pkin-overalls-vscode-web-broker-static-x86_64-unknown-linux-musl-0.1.0`,
built with the flake's Rust 1.97.1. Its gate passed eight library and six main
tests and Clippy; one intentionally ignored subprocess fixture is exercised by
the bounded metadata deadline test. The retained source is byte-identical to the
current broker. Earlier eleven-test results and the Rust 1.95.0 artifact retain
their historical scope. Pure parser/account/release near-miss histories do not
establish Linux socket, native worker or guest execution custody.

The official-source client and selected built-in extension/media TypeScript,
bundled REH-web build and native ELF fixup completed in the package work. The
initial install check failed because its direct compiled helper lacked the
package NLS bootstrap. Corrected build seven then passed full client/built-in/media
TypeScript, REH-web assembly, ELF fixup and signature/origin/socket/framing/CSP
runtime checks at
`/nix/store/v8a7xmikdvns613p8fcad75s95fb6vdb-overalls-vscode-web-1.141.0`.
Review found its release identity did not yet bind concrete runtime/toolchain
derivation paths. The corrected build eight passed at
`/nix/store/fikl416ay8dzf0jn5jcs08xahrrl52ni-overalls-vscode-web-1.141.0`, with
editor protocol 1 and release
`ff20286227c40abe269339952b23c5ae768fe6594fb553f63b18272a0c399bfb`.
Build seven's result is retained for its earlier recipe only. Build eight passed
the packaged verifier and runtime checks, including refusal of untrusted signing
keys. Both builds precede the final no-agent onboarding and empty trusted-extension
auth-grant corrections. Build nine's evaluated release is
`a4f6257edc95ad5b43016b4ffa5e9c9bb45fb43d093332f37406af7f8b540c53`;
its source compilation completed but the packaged Chromium bootstrap fixture
refused an unwritable crashpad path in the Nix build environment. The corrected
fixture gives Chromium private XDG configuration/cache paths and the new check
also refuses build eight's earlier workbench startup defect. Build ten's evaluated
release is `27e2807b1321b1eb3c097122167d9664ddad97420937a955c17964fb0f2141e6`;
its source compilation and bundle completed but its private browser fixture
timed out before visible workbench initialization. Build eleven's checker drains
buffered TLS reads before waiting on the socket, retains the bounded fixture
lifetime and captures bounded no-account failure evidence. Its evaluated release
is `07286ea9689b0eb5f9e7388862b983cc7563b4fd51716922f02a960bedf2dcbd`;
its actual packaged Chromium initialization was not accepted. Build twelve was
cancelled while repairing early-exit fixture cleanup. The subsequent source repair
guards both no-agent onboarding and default-account initialization: absent optional
product configuration yields an undefined provider and a settled initialization
barrier, without creating a fake account/backend. Normal gallery and uninstall
paths are guarded consistently. The maintained source-bundled asynchronous
[no-account regression](../../../nix/domains/artifacts/vscode-web/check-no-account.mts)
exercises get, refresh, sign-in and sign-out settlement plus provider absence.
Build thirteen passed source/checker typing, that regression and assembly, then
failed sandbox Chromium startup with a Fontconfig/font-tree SIGABRT. Its later
manual normal-user and sanitized-builder initialization passed outside the
derivation; neither is package acceptance. A pinned tiny sandbox reproduction
passed after adding a build-only Fontconfig/DejaVu closure.

Definitive build fourteen passed, exit zero, at
`/nix/store/hwi07xkfb4h3vyqci1bpp65bdc7lpz7h-overalls-vscode-web-1.141.0`, with
official source `2a59476c9bfcb90b3ddc372c36762471b7dfad1c`, editor protocol 1 and
release `48825ace38095ccad1904c141e498a566f427e7b0772809fa0388af091355ca2`.
It passed full client/selected extension/media TypeScript with zero errors,
strict checker typing, maintained no-account regression, REH-web/native assembly,
packaged signature/origin/socket/framing/CSP checks and actual installed Chromium
workbench initialization inside the Nix sandbox. The build-only pinned fonts
enter recipe identity without shipping additional editor fonts. Package acceptance
does not establish personal native worker custody or the full Firecracker boundary.

The packaged production verifier also accepted the genuine Open VSX
`vscodevim.vim` 1.32.4 VSIX: 772,717 bytes, SHA-256
`0faab122afd25bc94f5ef9cf9678e64cbd554d6dc88fe87ffe11bba623814168`.
Its registry key ID matches the packaged PEM/SPKI, while runtime trust ignores
metadata-supplied keys. This establishes authenticity verification, not actual
workbench gallery installation or signing-key rollout.

The full Marshall gate initially found an older burn-reader test fixture with
forty generated states while the current twenty-two objectives require forty-four
rules. The repaired fixture derives its count and generated indexes from the
catalog and both windows. Its focused execution passed 4 checks (3 properties,
1 test), seed `399130`, 0.1 seconds.
That first full test phase finished in 1537.7 seconds with 1524 of 1528 checks
passing, four pre-repair burn-fixture failures and two invalidated roster checks
after peer setup failed. It is failing evidence. The later forced Dialyzer phase
overlapped a targeted recompilation and lost a transient consolidated beam file;
that invalid attempt establishes no type result. An explicit distributed roster
retry passed both tests, seed `854324`, in 5.0 seconds with eight runner schedulers
and no roster source change. It does not establish the cause of the earlier
invalid setup. The final gate ran without concurrent Marshall compilation and
passed, exit zero: 1,532 checks (256 properties, 1,276 tests, two excluded), seed
`734543`, in 1,383.7 seconds. Runtime, ADR, HLDD, contracts and validator
regressions, logging, warnings-as-errors compiler and browser-state gates passed.
Forced Dialyzer rebuilt the dependency PLT, then reported zero errors, skipped
warnings or unnecessary skips in 40.98 seconds of project analysis. Dependency
`xmerl` missing-spec warnings during PLT construction are separate from that
project result. This resolves current application acceptance; full native browser
and Firecracker execution remain separate.

ADR structure/link, generated option reference, scenario coverage and Ash/deployment
view checks passed. The NixOS `hldd-browser` check passed, exit zero, in 339 seconds
including its source-built Marshall release. It exercises the individual domain
and topology pages, renderer and navigation boundary; those tested sections were
unchanged by the subsequent monitoring/security execution-evidence edits. These
governance checks establish maintained documentation/rendering scope, not editor
runtime or physical host availability.

## Native and operational gaps

The [NixOS machine fixture](../../../nix/verification/tests/machines/vscode-web/default.nix) is
present. It uses the actual source-built package and Rust broker, trusted TLS,
browser formatting, diagnostics, search, Git, Markdown preview/local resources
and terminal UID, plus a browser-only extension's activation marker and real
Extensions UI uninstall followed by personal-UID CLI absence. It also asserts
foreign epoch/placement/release/account/name/gateway
refusal, broker restart continuity and worker-loss recovery. Its roster authorizer
and HTTP bridge are explicitly synthetic; it does not exercise Marshall grants,
Audi lease renewal, Lilly packet marks, guest boot trust, Firecracker or Ubuntu.
The final strengthened native check passed, exit zero, in 60 seconds. Its log is
`1791610821497-3078787-0.jsonl` under the local Nix build-log directory; the VM
script took 43.08 seconds and the workbench/tool/custody subtest 28.71 seconds. It passed
foreign tuple/source and kernel wrong-peer refusal, actual workspace-trust UI,
WEB-only extension activation with personal-UID marker ownership, real Uninstall
reload reason followed by Extensions Refresh and independent personal-UID CLI
absence, actual JSON diagnostic and saved multiline formatting preserving the
exact parsed object, Search README, Git output, isolated Markdown/local image on
a separate hash host and personal terminal UID. Broker restart preserved the
same live worker PID and saved data; worker loss started a positive different
PID and retained data. Changed admitted zone/port was observed in the actual
HTML remoteAuthority/webviewEndpoint, required a fresh worker PID, and restoring
the origin required another fresh PID while preserving personal data. Root-owned
systemd launch identity hashes UID/name/protocol/commit/release/origin without
putting raw origin or account metadata in its Description. Bounded private
metadata failure and foreign socket custody refuse before replacement; successful
stop precedes replacement of a legitimate changed worker. The metadata child
leader remains unreaped while stdout remains open, preventing a process-group
signal after reaping; adversarial descendant-retained stdout remains source-review
scope rather than a dedicated native assertion.

The cold first terminal used the production creation helper immediately after
real workspace trust, before extension/search/Git/preview or earlier terminals.
It selected the exact command, guarded its visible connected focused input and
submitted creation once; actual UID and a split output marker passed. Captured
terminal closure/detachment left zero wrappers. A separate regression preserved
two preexisting terminals in different editor groups. Playwright actions use an
eight-second default in that regression; ordinary `expect` assertions retain
their five-second default, and first terminal creation has one bounded
twenty-five-second wait. This establishes the complete standalone Linux fixture
scope above. It does not establish a genuine public-gallery UI installation or
the full authenticated service/Firecracker chain.
The earlier 77/75/67-second acceptances retain their prior helper revisions. The
60-second run covers the final guarded-terminal behavior; subsequent helper edits
add fixed workbench substages/failure categories only, with no changed wait or
assertion behavior. Their static gate is recorded in
`/tmp/overalls-editor-helper-stages-static-final.log`; they have no new native
execution result at this point.
The first build-fourteen native run passed broker authority/foreign-peer refusals
and loaded the actual workbench and extension-worker iframe, then failed because
the WEB fixture command was unavailable, with the workspace still in Restricted
Mode. That context is not a proved cause: pinned upstream grants pure WEB extensions
without `main` untrusted-workspace support by default. The fixture's early one-time
trust-dialog observation had not established
workspace trust. Explicit actual Manage Workspace Trust transition and local
gallery fixture preflight corrections are under test; that initial run is failing
evidence, not native acceptance.
The next trust-transition run failed in 94 seconds before a Trust click because
the matching Manage Workspace Trust command-palette row was absent. That result
does not establish whether command eligibility or selector behavior caused the
absence; investigation remains open. Its failure record is
`1791601649129-1999147-0.jsonl`, following the initial Restricted Mode record
`1791601264183-1947448-0.jsonl` in the local Nix build-log directory.
The later 66-second run established actual Restricted Mode statusbar entry,
scoped Trust action, trusted UI state and browser-only fixture activation, then
failed because QuickOpen Enter preceded the requested file's result row. Its
record is `1791602092762-2015227-0.jsonl`. Both private diagnostic artifact mode
assertions passed at 0600. Exact file-row waits were then added. The observed UI
path and activation do not establish
the original omission's root cause, or terminal refusal under denied trust:
pinned upstream explicitly allows remote terminals in remote workspaces.
The next 69-second run passed real trust UI, WEB activation and file selection,
then actual **Format Document** reported that no JSON formatter was installed.
The client/server bundle files are present, which does not establish native
extension-host registration or operation. A later 68-second run first observed
the real JSON **Value expected** diagnostic, then actual multiline **answer: 42**
formatting passed. Pinned-source inspection confirms file opening does not await
`onLanguage` activation, while Format Document queries the current provider
registry. The fixture now waits for the actual diagnostic before formatting;
package source remained unchanged. That run failed next at the Search accessible
name selector; the complete native check had not passed at that stage.
The later 99-second run passed actual Search README, Git output, isolated Markdown
preview/local image on a separate host and terminal command execution. Actual
Uninstall entered its reload-required state, then the helper failed while waiting
for the stale installed-list row to disappear. Pinned source retains that row
until a real Extensions refresh; the corrected fixture uses the actual uninstalled
UI state and fresh query, followed by independent personal-UID CLI absence.
The later passing run above covers the corrected browser, CLI and worker-restart
assertions.
The Ubuntu fleet driver/image preparation built in 355 seconds; this is dependency
assembly scope, not execution of the authenticated fleet assertions.
The corresponding NixOS driver/image preparation built in 252 seconds with the
same distinction; neither result establishes a running Firecracker editor journey.

Both full fleet checks are also present via
[fleet composition](../../../nix/verification/tests/machines/fleet/default.nix) and
[editor driver](../../../nix/verification/tests/machines/vscode-web/fleet.py). They use real
ordinary browser account state and actual Marshall→Audi→Lilly→Firecracker images,
verify manifest/default shape/2 GiB writable headroom, invoke the shared browser
journey, inspect native personal worker custody, and repeat broker restart,
worker loss and guest stop/start with saved data. A private Audi startup preflight
loads the real immutable runtime configuration as the Audi UID, refuses a mode-0600
clone changing only the editor zone to one label, then reloads the original without
printing private configuration. The first NixOS fleet execution failed at that
private startup preflight before browser login or provisioning. The fixture's
same-UID environment read was denied despite ambient capability; the corrected
root wrapper extracts exactly one bounded immutable configuration path, rechecks
the PID, and delegates actual configuration/listener validation to the Audi UID
inside its live mount namespace. A later two-host preflight passed. The exact
pinned Python provides Playwright, replacing an unavailable bare-python import.
The editor-only enrolled cap became 4 GiB on physical 6 GiB hosts so the normal
1 GiB overhead and 2 GiB plus 64 MiB editor shape fit; production reservations and
Budget are unchanged, and a fresh headroom preflight checks this constraint.

The lifecycle fixture was corrected to accepted ADR-0113/0133 semantics: ordinary
stop/start preserves placement and execution epoch, advances logical generation,
and changes physical boot challenge and guest boot UUID. Exact owned confined
VMM observation and rechecked current intent precede root-private hashed boot
capture under the actual placement lock; no production journal is changed. The
current-generation physical-running and Provisioning-ready rows must match the
same host/placement/epoch/generation. Host is derived through current placement,
because the VM host_id is an Ash calculation rather than a persisted SQL column.
Read-only EXPLAIN preflights both exact queries against the real migrated database;
actual matching rows remain required after restart. An earlier wrong epoch
assumption and nonexistent SQL column are failing fixture evidence. A later
terminal-controls failure has no proved runtime cause; bounded palette preparation
and the guarded single submission/first-profile wait are the reviewed correction.
Boot capture also required the existing immutable native-tool PATH ordering;
the corrected wrapper supplies host ZFS, current-system tools and Lilly host tools.

The complete NixOS fleet check passed, exit zero, in 510 seconds, log
`1791611757794-3157594-0.jsonl`; its VM script took 467.38 seconds and the real
stop/start subtest 57.22 seconds. It passed ordinary Marshall browser image
creation and manifest/default shape/headroom, real Audi startup/service
authentication and Marshall→Audi→Lilly→Firecracker editor handoff. Actual personal
edit/save/readback, isolated Markdown, terminal UID/OS, native worker custody,
broker restart and worker-loss repeated browser journeys passed. Real stop/start
kept placement/epoch, advanced generation, changed both physical boot digests,
matched current-generation committed physical running and Provisioning readiness,
and preserved saved data/current custody.

The Ubuntu fleet execution failed in 361 seconds, log
`1791612296178-3245733-0.jsonl`. Provisioning passed in 161.44 seconds, and the
authenticated handoff reached the expected editor origin; the initial shared
journey then failed at WORKBENCH in roughly six seconds. Visibility assertions
use Playwright's five-second default. The precise substage/failure category was
unobserved in that revision, so no package, missing-library or timing cause is
claimed. Fixed closed substages/categories have since been added for a diagnostic
rerun, without changing waits/assertions. Ubuntu complete browser/recovery/
revocation acceptance remains unresolved.
The [authorization driver](../../../nix/verification/tests/machines/vscode-web/authorization.py)
additionally checks actual Audi refusal of missing/sibling/null Origin for unsafe
requests and upgrades, then ordinary browser sign-out, closure of established
editor WebSockets within thirty seconds, fixed-origin 303 authentication recovery
and the real sign-in page. All these assertions passed in the NixOS fleet check;
the Ubuntu execution failed before reaching them.
The successful journey alone does not provide complete cross-account or
signing-key rotation evidence.

Required remaining evidence includes the complete Ubuntu authenticated
Marshall→Audi→Lilly→Firecracker browser/recovery/revocation journey. Broader stale
account and mismatched immutable image histories remain separately scoped.
Existing guest disks do not gain the feature through host
activation. Multi-gateway failover, signing-key rotation rollout, active-extension
idle behavior and independent physical host faults remain separate acceptance.

## Standalone manifest loader correction and rollout

Dungarees activated merged revision `0fcab4f6` healthy with zero updater failures.
Overalls remained on its prior revision: its build stopped before activation when
`overalls-default-image-id` validated the editor-bearing v3 manifest without
loading `OverallsProtocol.EditorRelease`. Local reproduction is retained in
`1791614504999-3715300-0.jsonl`; the concrete failure is undefined
`EditorRelease.decode/1`, not a guest or browser failure. Full Mix compilation
loads that module, so earlier protocol/package/native results did not exercise
this standalone deployment entrypoint.

The focused correction loads `EditorRelease` before `ImageManifest` in every
missed standalone loader, including Overalls default-image derivation and the
Inception fixture. Identity still comes from the shared validator and exact
installed manifest; no image ID algorithm, guest bytes, capability or retained
disk is changed. The exact corrected Overalls default-image evaluation passed,
exit zero, returning
`sha256:ac6fa09aa3dd6ac0b488ec4a40807b520c2f3145432e5ebc81ff741630cc110a`.
All four repository standalone loaders were scanned; the other two already load
the dependency. Both changed Nix files parse and the diff check passed. This
establishes the corrected default-image target, not full Overalls bundle/activation
or execution of the Inception machine. The later corrected full local Overalls
deployment bundle passed, exit zero, in 309 seconds, log
`1791614687746-3756570-0.jsonl`. Dungarees subsequently activated loader correction
`849d80228bfd916874ae92ed258fe4250368c43f` healthy with zero updater failures;
active, last healthy and `/run/current-system` matched
`/nix/store/01rqpy997f8jx9wyhdknv5741jxkc7ra-nixos-system-dungarees-26.05.20260914.c3eea5b`.
Overalls subsequently activated the same `849d8022` revision healthy with zero
updater failures; active, last healthy and `/run/current-system` matched
`/nix/store/di9750p3i17a954n5plhg959zc4fv9l5-nixos-system-overalls-26.05.20260914.c3eea5b`.
An anonymous production machine-code request returned the fixed sign-in redirect,
establishing the deployed route's unauthenticated behavior only. Bundle acceptance
and healthy hosts do not establish an authenticated production editor journey.
Both hosts later activated `af01b4b9cb35ef377a9555522e6f05cc809622b9` healthy
with zero updater failures. Overalls' active system hash was
`hrwxwhjb71aphqwga9icl3mpda52m6mb`; Dungarees retained the same `01rqpy997...`
system closure above with the updated revision. A fresh current-image user VM's
credential and active leases were inspected without printing their private
values. Neither this authority inspection nor host health establishes a
browser-visible production workbench.

## Merged component and handbook verification

After integration with independent observability, Protocol's full gate passed
258 checks (100 properties, 158 tests) in 417.9 seconds and forced Dialyzer with
zero errors. Lilly's full gate passed 543 checks (105 properties, 438 tests) and
forced Dialyzer with zero errors. These replace no historical result: they record
the merged component scopes. Audi's merged full gate also passed 197 checks
(54 properties, 143 tests) and forced Dialyzer with zero errors.
Marshall's subsequent full feature `mix precommit` passed, exit zero, with
1,424 checks (237 properties, 1,187 tests; two excluded), seed `309061`, in
1,324.4 seconds (28.8 asynchronous, 1,295.6 synchronous), log
`/tmp/overalls-editor-ui-marshall-precommit.log`. Its runtime and ADR/HLDD checks,
structural contract coverage of 2,686 maintained source files and logging catalog
check for 164 events passed, together with Node's 19 contract, 32
browser-state and four metrics checks. Final forced Dialyzer reached actual
analysis and passed with zero errors, zero skips and zero unnecessary skips in
32.68 seconds. The complete suite exercised the eligibility/authority source
before the later cosmetic toolbar body; that body has separate component
verification. These application results do not establish native or production
browser acceptance.

The merged NixOS `hldd-browser` check passed, exit zero, in 339 seconds, log
`1791614674732-3750008-0.jsonl`; its VM script took 68.02 seconds. The ordinary
persisted reader rendered every section, including current domain/resource and
deployment topology views, removed previous section diagram hooks, exercised
history/theme/mobile/print behavior and lost revoked mounted/fresh-request login
authority. This is current renderer acceptance after `0fcab4f6`, not execution of
the later editor eligibility control or a production guest browser journey.

The first merged NixOS editor fleet run failed during terminal preparation,
before opening the editor, log `1791614486036-3713210-0.jsonl`. The fixture waited
for the literal `root@lilly-guest` prompt, while incoming main now uses Starship.
This is an inspected cosmetic prompt assumption in the fixture, not package or
editor acceptance. The correction submits a fresh-nonce identity command and
requires exact root UID output within the same 120-second bound. The earlier
510-second native record retains its original revision and scope; corrected
execution is recorded below.
The fresh `849d8022` Ubuntu snapshot also stopped at the old terminal preparation
stage before the first browser editor, log `1791614898447-3834293-0.jsonl`, total
build plus native execution 868 seconds. It passed boot/capacity/gateway/query
preflights (61.74/81.42/1.70/0.18 seconds) before the same obsolete prompt wait.
It does not reproduce or resolve the earlier initial WORKBENCH failure. Both
families were subsequently rerun with the new nonce/root-UID console proof, whose
fixed `root_shell` stage withholds terminal bytes and retains current-boot
authority. No new decision or timeout relaxation is introduced.
The subsequent corrected Ubuntu run passed the executed root-UID proof and
ordinary provisioning in 115.89 seconds, then real launch/authenticated handoff
reached the expected editor origin. The initial workbench visibility assertion
failed again before workspace navigation, category `assertion`, log
`1791616004224-4117424-0.jsonl`, total build plus execution 610 seconds, exit one.
This reproduces the initial workbench symptom on the merged corrected fixture;
no backend/bootstrap probes ran and the runtime cause remains unproved.

The corrected merged NixOS fleet passed, exit zero, in 742 seconds total build
plus native execution, log `1791616028937-4121486-0.jsonl`. Its snapshot was
`849d8022` plus the eligibility/SSH projection/root-UID fixture diff later
committed as `af01b4b9`; this is not a postcommit or production execution. The
native stages passed boot (58.93 seconds), capacity (96.54), gateway (2.14), query
schema (0.18), provisioning (118.83), first real editor/personal UID/isolated
webview (35.46), broker-restart browser journey (31.25), worker-loss recovery
(23.72), saved stop/start with new physical execution (61.36) and foreign-Origin
refusal/sign-out/WebSocket closure (9.59). Stop/start preserves placement and
execution epoch, advances generation and rotates the physical boot challenge and
guest boot UUID. These assertions establish complete NixOS acceptance for the
captured merged snapshot; Ubuntu, recurring probes and physical host faults
retain their separate gaps.

The later frozen diagnostic diff adds passive main-document status, fixed
bootstrap performance/DOM booleans and error/connection observations to the
browser helper. It emits no messages, URLs, headers, cookies, document text or
WebSocket payloads. On failed fleet execution a bounded read-only guest fixture
first verifies current native boot and executed root UID, then reports fixed
broker/worker/socket/commit/personal-Node and broker-refusal booleans. Console
checks share one 30-second deadline and never start an editor. Diagnostic failure
preserves the original browser exception; assertion waits are unchanged. No
native run of this later diagnostic revision or discovered Ubuntu cause is
claimed. Ruff formatting/lint passed for both changed Python files, and pinned
Python 3.13 `ty` passed the standalone browser helper against actual Playwright.
Pinned Elixir 1.20.4/OTP 29 compiled the actual FleetTerminal and
EditorGuestFixture APIs without application startup or build-tree writes. Nix
parsing, scoped contract format/discovery and whitespace checks passed. Contract
tooling is structural only; fleet-fragment type checking on the Nix-composed
driver and native execution of this diagnostic revision remain pending.

## Machine-page immutable image eligibility correction

The prior machine header offered the editor based on write/profile permission and
observed running state without checking its retained immutable image. A running
legacy v2 VM could therefore display **Open VS Code** even though fresh Editor
authority correctly refused it. Restart, resize and clone preserve the original
image; host activation cannot upgrade that disk. The supported path is a separate
current-image VM at its manifest-derived shape, selected-file transfer through
authorized guest SSH, verification and retention of the original VM.

[Image.editor_capability/2](../../../marshall/lib/marshall/compute/image.ex)
now owns the common pure check: validated configured protocol/commit/release,
validated manifest and exact stored image identity. A valid legacy or different
release returns `unsupported_image`; missing, malformed or wrong-identity
image/configuration returns `unavailable`. Catalog `enabled` affects new VM
admission, not the editor capability of a retained running matching image.
[Compute.Views](../../../marshall/lib/marshall/compute/views.ex) calls it only
after ordinary VM read authorization and exposes the three finite statuses,
without the tuple or manifest. It neither allocates GuestAccounts nor mutates
images. [Editor.Authority](../../../marshall/lib/marshall/editor/authority.ex)
reuses it and retains the existing `image_unavailable` refusal and fresh
stored-login/write/account/execution checks.

[The machine header](../../../marshall/lib/marshall_web/components/workspace_components.ex)
requires current projected write/profile permission, Customer ownership,
available image status and both desired and observed running state. Unsupported
images display a disabled control and current NixOS/Ubuntu image guidance;
unavailable or missing status fails closed. The rendering helper reads no
resources and grants no launch authority. Reviewed ancestor/local code contracts
remain coherent with these callers; no contract violations were found in this
focused helper/view/authority/component scope. This is a consistency correction
within accepted ADR-0153, not a new architectural decision or image upgrade.
The consumer scan found SSH `ls`/`show` serialize the full view; their typed wire
projection removes `editor_image_status` and exact key-set regression assertions
preserve both command response schemas. Agent CLI responses already project
thread/turn fields. The new status stays workspace presentation only.

The [capability property/unit tests](../../../marshall/test/marshall/compute/image_editor_capability_test.exs)
generate complete exact releases, toggle catalog enabled status, change each
release digest and corrupt content-bound manifest identity. Fixed cases cover
valid legacy, missing/malformed images and malformed configuration. The
[workspace tests](../../../marshall/test/marshall_web/editor_workspace_test.exs)
exercise real authorized SQL-backed get/resolve/list views and LiveView refresh,
no image/account mutations, disabled-catalog launch, legacy guidance, changed
release and missing configuration, stopping with still-running observation,
writer downgrade, stored-login revocation and safe missing-status rendering.
The final focused selection passed 58 checks (five properties, 53 tests), seed
`369052`, in 19.9 seconds with warnings treated as errors, log
`/tmp/overalls-editor-ui-focused-final.log`. It includes the new one-property/
one-unit capability module, eight workspace cases and existing Editor authority,
controller and SSH command tests. An initial assertion compared Ash action
metadata across configure/read; the final regression compares all persisted image
attributes instead. No implementation refusal was weakened. Compiler and contract
syntax/19 regression checks passed, as did 164 logging checks. The final forced
Dialyzer check passed with zero errors, zero skips and zero unnecessary skips in
38.26 seconds, log `/tmp/overalls-editor-ui-dialyzer-final.log`. The complete
feature Marshall gate subsequently passed as recorded above. These scoped tests do not
establish native guest isolation, production sign-in or migration.
Pinned Elixir 1.20.4/OTP 29 formatting and actual FleetTerminal/EditorGuestFixture
module compilation passed for the root-UID fixture correction. The first forced
Dialyzer attempt stopped at artifact analysis with unusable Core Erlang for
existing Marshall BEAM files despite their debug-info chunks; no application type
finding was reached. Its record is `/tmp/overalls-editor-ui-dialyzer.log`. A complete
569-module rebuild corrected the artifact failure without a source workaround;
the final check reached actual analysis and established Marshall typing acceptance.

The [console correction](../../../nix/verification/tests/machines/vscode-web/guest.exs) satisfies
`editor-fixture-executed-root-shell`: the printed fresh nonce is split in the
submitted command, so input echo cannot provide the exact newline-delimited
success result. Success additionally requires executed `id -u` to equal zero.
The existing matcher removes carriage returns, retains at most 512 bytes and
keeps the 120-second bound; failures expose only the closed `root_shell` stage.
`FleetTerminal.connect/1` still authenticates the persisted current boot and
creates the isolated fixture PTY. Local and ancestor contracts were reviewed
through this call and the write/read path; no violation was found in this scope.
Module compilation and Marshall typing remain separate from the scoped native
executions recorded above; the complete corrected NixOS pass has its own captured
snapshot scope.

The final component/CSS diff groups the editor and power controls into one
toolbar, uses the existing neutral button and packaged icons, preserves visible
focus and wraps below the title on narrow screens. Available/disabled/hidden
editor branches, lifecycle predicates, fixed new-tab link and event payloads
are unchanged. Ancestor component/asset contracts and the domain-authorized
callers were reviewed; no scoped violation or architectural impact was found.
It introduces no new decision or authority and does not close native/production
verification gaps.
The frozen toolbar body passed compiler warnings-as-errors and formatting checks,
then its eight existing workspace/domain/controller cases in 2.6 seconds, seed
`389386`. Root separately compiled and rendered the actual component with an
isolated endpoint and synthetic assigns, without application startup or database
access. These results establish component behavior for the inspected cosmetic
diff; full application and native snapshot records retain their separate scopes.

## Architecture assessment

The compiled 128-case policy matrix and direct native service checks passed.
These checks run actual upstream configuration, Chat, participant and
language-model services plus refused policy writes after setting reviewed product
metadata before import. The exact-pin full upstream TypeScript check and clean
two-patch application also passed. Current explicit four-version updater check
passed with structured JSON `outcome: current` and unchanged selected ID/version
results against all four universal downloads using the actual source-bundled
maintenance verifier, upstream engine validator and reviewed
Ed25519 key. Hash, manifest, platform, dependency and bounded archive validation
ran at the same boundary. Automatic stable selection for rust-analyzer also
passed with the same current result, exercising the live universal query's
208-version pagination. These scoped developer checks do not establish a final
Nix package, native guest, rollout or production browser result.

The extension maintenance suite passed all 19 tests without skips in 1.239 seconds
under Python3.13.15. Generated archive paths and nightly-page histories exercise
containment and stable selection. Fixed cases cover wrong identity/platform/engine,
undeclared dependencies, malformed archives, changed bytes, wrong signatures even
with recomputed checksums, byte-preserving extraction and exact Elixir adapter
arguments/missing-tool refusal. The actual source-bundled Node verifier and
upstream engine boundary were exercised with compatible and incompatible engines.
Partial resolution, observed concurrent edits and prepublication synchronization
failure retain old bytes; postrename parent synchronization failure retains a
complete new lock and returns a distinct durability-unknown result. CLI results
contain structured closed outcomes. Focused Ruff formatting/lint and actual ty
analysis passed; all-files Ruff lint and ty also passed inside devenv. The captured
test and typing logs are `/tmp/overalls-vscode-extension-maintenance-tests.log` and
`/tmp/overalls-vscode-extension-maintenance-typing.log`. This is developer execution
of the frozen helpers with the exact source-bundled validator, not execution of
the final installed package or native language extensions.

Final semantic review traced the immutable policy through upstream configuration,
native participants, language models/tools, sessions and editor restoration. It
found and corrected remote session acquisition reaching a content-provider callback
before the policy assertion. The compiled actual-service regression now refuses
local and remote restoration before callbacks. The frozen policy patch SHA-256 is
`bf28090d665b50da08a466d319600fa1327b312edb32bde9b41e39ce0a375356`.
Full upstream native TypeScript checking passed, including the root maintenance
entry under its generated configuration; compiled policy checks and exact-pin
patch application passed. Final read-only review found no further scoped mismatch
in the package recipe, maintenance entry/CLI, signature/key extraction boundary
or offline Elixir fixture launcher.

All three all-files Python hooks passed inside devenv after the fixtures froze:
Ruff format, Ruff lint/annotations and actual ty analysis. ADR structure/local
links, generated option reference, scenario coverage and Ash/deployment views
checks also passed. Code-contract format/discovery covered 124 CONTRACTS files,
2,628 native notes, 248 parsed source files and 2,704 maintained source files;
these are structural results, not semantic or native proof. Captured output is
`/tmp/overalls-vscode-extension-final-governance.log`.

The final specialized Nix package passed, exit0, in 234 seconds. Output is
`/nix/store/iz3b2l7iqmdwpnhhi0r94xglf6zd8g59-overalls-vscode-web-1.141.0`, with
release ID `6bc2197a6d4f5b2183a7274ae2c967eee1f95b4f0ccd10f5a71fbbd472b16e8d`.
Execution is recorded in
`/home/ghuntley/.local/state/nix/build-logs/1791629634342-2003989-0.jsonl`.
Actual upstream native TypeScript checking included the maintenance entry;
compiled policy checks, complete signed builtin extraction and installed
signature/origin/Unix-socket/Chromium workbench and PTY checks passed in the
sandbox. This establishes the reviewed package build and its synthetic local
runtime fixture. The final standalone NixOS and both Firecracker guest-family
journeys, rollout and authenticated production browser acceptance remain separate.

The Nix extension-maintenance check then passed in nine seconds using the final
package's installed validator, running all 19 tests without skips plus Ruff/ty.
Output is `/nix/store/1r8wiqv3zq1nbngky52ys7xx167mp31j-overalls-vscode-extension-maintenance`,
recorded in `1791629952881-2052915-0.jsonl`. An initial fixture-layout attempt
failed import ordering because flat copies changed Ruff's first-party discovery;
the corrected sandbox preserves the repository layout and original configuration.
The packaged maintenance wrapper's explicit four-pin network check also returned
structured `outcome: current`, all `changed: false`, exit0, recorded in
`/tmp/overalls-editor-specialization-updater-wrapper-final.log`. This verifies the
actual installed maintenance boundary; native extension activation remains separate.

Marshall's ordinary complete selection passed 1,257 checks (224 properties and
1,033 tests), with 169 excluded, in 1,015.5 seconds, recorded in
`/tmp/overalls-editor-specialization-marshall-runtime.log`. Forced typing and the
full precommit including distributed execution retain separate scope. The forced
Dialyzer analysis subsequently passed with zero errors, skips or unnecessary
skips in 32.67 seconds on this premerge snapshot. These results do not establish
native or postintegration acceptance.

The final standalone composed NixOS driver/type gate passed in 45 seconds,
recorded in `1791629862116-2039093-0.jsonl`. Final native/fleet helper Ruff/ty
artifacts passed in nine seconds in `1791629862116-2039094-0.jsonl`. The native
policy and independent inert lower/newer EditorConfig VSIXs each compiled in
eight seconds (`1791629821310-2030526-0.jsonl`,
`1791629821309-2030528-0.jsonl`, `1791629821310-2030529-0.jsonl`). These gates
establish actual fixture typing/builds. The lower/newer packages exercise version
selection only; they do not modify signed builtin bytes or prove EditorConfig
behavior. Native machine execution and language diagnostics remain separate.
The subsequent final standalone native attempt failed in
`1791629876989-2040455-0.jsonl`: the real browser's first terminal proof passed,
then the new Native Policy stage failed. The initial capture did not identify
the failing assertion. Diagnostic replay of that built driver subsequently
showed `Native fixture native-policy passed` and Spaces3 in its private screenshot;
EditorConfig's log confirmed tabSize3/insertSpacestrue. All native API/default,
tool-invocation and restoration assertions precede that marker. The screenshot
showed no visible AI UI, but the exact failed browser assertion remains unknown.
Neither attached-node counts nor notification locator strictness are established
causes. The later replay of the split fixture also reached the policy marker;
marker completion proves only preceding native assertions, not the next browser
selector. Full native failures remain unresolved pending a passing rerun.
Replay is recorded in `/tmp/overalls-editor-native-diagnostic-execution.log`; the
private screenshot is excluded. The fixture must assert absence of visible native
AI UI immediately after each guarded action. Corrected fixture and complete
passing rerun remain required; this is a failed native attempt with scoped replay
observations, not full extension or language acceptance.

The test-only real ElixirLS0.31.1 server/dependency closure compiled offline using
pinned Elixir1.20.4/OTP29.0.6 and a fixed-output dependency hash. Its launcher loads
immutable BEAM files directly without Mix.install and passes an EOF startup smoke.
Its actual launcher additionally returned capabilities for a framed LSP initialize
request, replied to shutdown and exited0 with empty stderr. The private protocol
transcript is excluded. This proves fixture startup/protocol compatibility only.
Real language diagnostics through the guest extension remain native acceptance;
the fixture closure is excluded from production images.

The approved specialization keeps existing Editor admission, personal UID,
execution fencing, asset publication, audit and independent SLO/SLI boundaries.
ADR-0153 now explicitly records immutable built-in AI policy, automatic guest
workspace trust, four signed/hash-pinned Open VSX builtins and project-provided
language tooling. This changes package behavior and significant dependencies,
without adding domains, authority or global language runtimes. Review and runtime
evidence for this new package remain separate from historical records above.
Settings-only hiding, per-user mutable seeding and modified signed payloads were
rejected. The updater shares packaged signature/upstream engine validation and
publishes only after all selected candidates pass; no key rotation, dependency
expansion or runtime bootstrap is authorized through registry metadata. The
complete temporary file is synchronized before rename and the parent directory
afterward. Failures before rename preserve the old lock. If the postrename
parent operation fails, exit2 reports `outcome: durability_unknown` and
`reason: publication_durability_unknown`; complete new bytes may already be
visible and require review/revalidation. Atomic visibility does not prove crash
durability, and the updater does not claim rollback after publication.

The Ubuntu failure was traced to two closure assembly defects: `/nix/store` did
not exist before the first copied path, flattening the broker package, and copied
configuration retained UID/GID65534 rather than root custody. The correction
creates the destination before copying and normalizes trusted closure ownership,
with explicit path/custody assertions. Broker custody checks remain enforced.
Post-fix native Ubuntu acceptance is required; this diagnosis does not establish
workbench success. Diagnostic output is limited to allowlisted finite booleans,
including broker executable/configuration observations.

The regenerated frontend bundle contains both toolbar icon rules. The actual
component rendered with fresh CSS passed 1280px/390px light/dark alignment,
viewport bounds and keyboard focus checks; rendered screenshots were inspected.
This is presentation acceptance with synthetic assigns, not a production session.

This changes domain boundaries, browser/protocol authority, persisted credentials,
guest isolation/capability, fixed network admission and significant packaging.
ADR-0153 preserves ADR-0094's default tools/offline closure rationale and all
ADR-0135/0069 cache/isolation obligations, replacing only their affected Ubuntu
application and Customer editor ingress restrictions. Their historical evidence
and gaps remain in place. The decision is partial: complete NixOS service/
Firecracker acceptance is recorded, while Ubuntu failed at initial workbench
visibility. Production rollout, recurring credentials/history, broader faults,
gallery/key rotation and cross-writer OS confidentiality remain separately scoped;
the two healthy host activations establish rollout of that revision, while an
authenticated production editor journey is still required.

## Integration with pool preparation and guest boot profiling

The initial specialization was committed as `0bde95b8` with hooks passing. Its
frozen HLDD Nix check passed, exit0, in 12 seconds, recorded in
`1791630318314-2102677-0.jsonl`; that result belongs to the premerge snapshot.
The later merge includes origin `80c68cdb` and `0a72fada`, preserving
[ADR-0152](../decisions/0152-lean-pool-locked-preparation.md)'s accepted/partial
PoolSnapshot decision and [ADR-0154](../decisions/0154-guest-boot-profile.md)'s
boot timing and measured reductions. Their native trace, clone, rotation and
boot-profile records retain their original scope and production measurement
gaps. The merged scenario ledger contains every ID from both sides and is
regenerated from that union.

The reviewed automatic Nix merge preserves Ubuntu's complete hashed closure
paths, root-custodied configuration and placement assertions alongside prebuilt
platform roots/digest, quiet console and boot-report installation. Editor package,
maintenance and both fleet checks coexist with the boot-profile checks. No new
Ash domain, admission authority, protocol, isolation or audit/SLO decision follows
from this integration; ADR-0153 retains its authorized specialization and existing
fences. The boot report remains observation only, and boot trust still precedes
networking, DNS, roster sync and SSH. Current merged component/static gates and
native editor acceptance must be recorded separately from both historical branches.

The merged fixture correction changes evidence only. It separates the four public
Chat/editor/quick/inline actions and three restoration resources into individual
native commands. Each requires the actual guarded result and its success marker,
then checks absence of visible Chat, Debug and inline UI before another action
can obscure it. Closed attached/visible selector counts preserve diagnostic scope;
the native API also checks empty model selection. EditorConfig inspection runs
separately. Scoped notification-marker selection, canonical local restore URI and
closed stage/count observations help isolate the next assertion. This preserves
the original failed Native Policy browser stage and replay record rather than
presenting fixture compilation as a passing native rerun.

Merged static checks passed: ADR structure/local links for 152 decisions, generated
options, union scenario coverage, Ash/deployment views, conflict-marker refusal
and all-files Ruff format/lint/annotations and actual ty analysis inside devenv.
Contract structure/discovery covered 124 CONTRACTS files, 2647 native notes,
251 parsed source files and 2711 maintained source files. These are scoped
structural/static results, not runtime acceptance; output is captured in
`/tmp/overalls-editor-merged-governance.log`.

The merged frozen Nix HLDD gate passed, exit0, in nine seconds, recorded in
`1791631027438-2173986-0.jsonl` and
`/tmp/overalls-editor-merged-final-nix-hldd.log`. Its evaluated snapshot was the
then-uncommitted merge subsequently committed as `058f13d8`; it does not establish
application or native acceptance.

The incoming source/document review found no new trust-authority, readiness or
isolation blocker. It reconciled ADR-0152's logical snapshot and implemented
claim/verification arities with the existing consecutive native consistency reads.
A low-severity implementation gap remains under ADR-0154: completion polling's
30 s deadline does not cancel the current tool's 20 s timeout; a controlled runner
waited 40.25 s. The accepted at-most-30-second requirement remains intact.
ADR-0154 is partial until a timeout-budget correction and scoped regression
enforce it. No unrelated runtime change is introduced.

The verified-current trust predicate checks the marker, ordered managed regular
files, bundle root membership and direct per-root PEM links. It does not inspect
OpenSSL subject-hash links or hook outputs. The recorded native rotation journey
does verify CApath after real rebuilds; independent drift in those uninspected
outputs is outside the no-op predicate's proven scope. Changed delivered sets
still run `update-ca-certificates --fresh`; the existing rationale is preserved.

## Postmerge native and fleet verification

Marshall's full merged `mix precommit` passed, exit0, with 1,424 checks (237
properties, 1,187 tests; two excluded), seed505818, in 1,432.7 seconds. Forced
Dialyzer reached actual analysis and passed with zero errors, skips or unnecessary
skips in 30.7 seconds. Output is captured in
`/tmp/overalls-editor-merged-marshall-precommit.log`. This is merged application
verification, separate from the earlier 1,257-check premerge ordinary selection
and from native/production acceptance.

The default live maintenance command
`nix run .#update-vscode-extensions -- --check` passed, exit0, after publication of
`058f13d8109e3e1b061ec66981367414f1de600c`. It selected latest compatible stable
versions through bounded pagination and validated whole signed artifacts with
the actual package verifier. Its structured result was `outcome: current`, with
all four extension versions unchanged. This adds default automatic selection
evidence beyond the earlier explicit-pin check; it does not change the lock,
Code OSS pins or deployed images. Output is captured in
`/tmp/overalls-editor-specialization-updater-latest-check.log`.

The corrected per-action standalone native rerun used the frozen snapshot
`/tmp/overalls-editor-merged-native-fixed.U1LA6t`, subsequently included in
`058f13d8`. It failed, exit1, in 111 seconds, recorded in
`1791630808836-2155554-0.jsonl`, after passing the original cold terminal/editor/
webview/browser-extension journey in 33.06 seconds (line2942) and Alice's
outside-HOME policy stage in 10.64 seconds (lines2944–2993). Bob's HOME defaults
stage failed before invoking the fixture: lines3075–3083 report an absent
`Overalls Fixture: Native Policy` command-palette
row after a 30-second visibility wait. These are separate scoped observations
from the earlier unknown assertion in `1791629876989-2040455-0.jsonl`; no cause for
that earlier failure is established. Subsequent diagnostic discovery found both
users' CLI extension listing and expected fixture directory present, which does
not prove frontend command registration or activation. Complete two-account
controls, version selection and real language diagnostics remain unverified.

The complete guest-family checks then executed an archived exact
`058f13d8109e3e1b061ec66981367414f1de600c` snapshot
`/tmp/overalls-editor-058f-fleets.FAv5fB`. Both failed: NixOS in 806 seconds, log
`1791631239081-2195760-0.jsonl`, and Ubuntu in 1,335 seconds, log
`1791631239081-2195759-0.jsonl`. Both passed their initial cold editor/terminal/
custody subtest: NixOS in 35.12 seconds (line30639), Ubuntu in 32.10 seconds
(line27901). This uses the shared actual Marshall opening, save/readback, personal
terminal identity and isolated Markdown journey plus native custody verification.
Both then failed the real-guest policy phase (NixOS lines31453–31455; Ubuntu
lines28701–28703). The logs report absent visible UI after the guarded AI actions
and restoration commands before the later refusal, without exposing private
state. Exact remaining substage/cause and complete policy/control/recovery scope
are unproved. The earlier passing NixOS fleet and failed Ubuntu workbench records
retain their original revisions. Fresh complete acceptance remains open.

## Postpublication host activation

The deployment trigger at `058f13d8` was followed by newer main revisions
`e08f5d74` and `50021c04`, which contain that editor merge. Status-only checks
through the pinned administrative SSH transport observed both hosts settled
healthy on exact `50021c046cfaee28453840f6ba89b45d68d3f8e9` at
2026-10-10 11:59:27 UTC. Each reported that exact candidate, lastHealthy and
activatedCandidate, `failure: null`, `failures: 0`, and an inactive/dead updater
with successful result. Active, lastHealthy and `/run/current-system` paths agreed:

| Host | Generation | Observed system closure |
| --- | --- | --- |
| Overalls | 380 | `/nix/store/j0k1kyp0iljr0x64v448nnfa97jcmsfi-nixos-system-overalls-26.05.20260914.c3eea5b` |
| Dungarees | 188 | `/nix/store/lsfgssb8gy7j5s62dxjirwpkj583wzfb-nixos-system-dungarees-26.05.20260914.c3eea5b` |

An earlier separate Dungarees inspection at 11:23:03 UTC observed exact
`058f13d8109e3e1b061ec66981367414f1de600c` healthy, generation186, with active,
lastHealthy and `/run/current-system` equal to
`/nix/store/wircnny1bh5c2v1gfs665903l7qzkqzl-nixos-system-dungarees-26.05.20260914.c3eea5b`,
failure null and zero failures. Lilly, Audi public/DNS/private and Ziggy were
active/running with successful result. No intermediate Overalls `058f13d8`
activation was independently observed; the later `50021c04` result cannot prove
one. These checks establish host activation only.

The subsequent read-only Overalls closure inspection at 12:00:46 UTC belongs to
current `50021c04`. Its active closure contains the previously built package
`/nix/store/iz3b2l7iqmdwpnhhi0r94xglf6zd8g59-overalls-vscode-web-1.141.0`.
The installed descriptor/product and both manifest-v3 image declarations agree
on protocol1, official source `2a59476c9bfcb90b3ddc372c36762471b7dfad1c` and release
`6bc2197a6d4f5b2183a7274ae2c967eee1f95b4f0ccd10f5a71fbbd472b16e8d`:

| Guest family | Installed declared image |
| --- | --- |
| NixOS | `/nix/store/fg3isp80x7dnln2lv758bw5wbj7vsd5b-lilly-nixos-x86_64` |
| Ubuntu | `/nix/store/5kfcdy96k97ms4irldi2iv6f3gr4jpal-lilly-ubuntu-26.04-x86_64` |

Installed extension manifests match all four exact reviewed universal pins, and
the immutable product defaults retain disabled built-in AI/trust and project
language-tool selection. At 12:01:07 UTC the public readiness route returned200
with verified TLS; Marshall, Lilly, Porsche and Audi public/DNS were running.
All four private recurring fixture/session files were absent. Supervisors were
in auto-restart/exit-code state, while both independent recorder/exporter pairs
were running with separate source/read-group custody and private supervisor
stdio/UMask/hardening. No credentials, private attempt logs or impersonation were
used. This verifies deployed immutable declarations and outer service status,
not new guest startup, authenticated production browser execution, recurring
credentials or retained seven-day history.

## Current milestone review

ADR-0153 remains accepted/partial. The official-source package, signed extension
maintenance boundary and merged Marshall gate have recorded passes. The corrected
startup-release snapshot now passes both complete Firecracker family scripts,
including policy, personal controls and recovery. Complete standalone version and
real-language acceptance remains open: the fresh lower-version install expectation
is invalid, the newer personal permission correction has a passing actual package
but native version selection/reversion remains open, and both initial actual
language diagnostics failed. Later Elixir-only scratch success retains its scope.
The current host activation is
recorded separately from production browser execution and recurring coverage.
Independent observability remains governed by ADR-0149; recurring credentials/
history, cross-writer operating-system confidentiality, broader faults and
gallery-key rotation retain their existing limits. Exact historical failures and
the newer scoped outcomes are preserved below.

This follow-up changes verification evidence within ADR-0153's accepted package
policy and existing authority boundaries. It introduces no new architectural
decision, protocol, permissions, runtime dependency or image capability.

Contract review also reconciled stale recurring-probe trust prose. The current
shared `trust_workspace` helper positively verifies
`enableWorkspaceTrust === false` in the actual workbench bootstrap. It performs
no trust-storage injection or trust UI action; native policy acceptance separately
asserts `workspace.isTrusted`. Historical UI-trust runs above retain their tested
revision. Disposable file review and explicit direnv approval remain separate.

## Startup and walkthrough preferences

The requested follow-up defaults `workbench.startupEditor` to `none` and
`workbench.welcomePage.walkthroughs.openOnInstall` to `false`. Both remain ordinary
user-overridable configuration. This changes first-window and extension-install
presentation within ADR-0153; it introduces no new architectural decision, audit
event, authorization, protocol, extension custody or runtime dependency.
The three-patch application check passed in
`/tmp/overalls-editor-startup-defaults-patch-check.log`. The actual new package
passed, exit0, in 217 seconds:
`/nix/store/3zzcx1nf4fkmqnva7x8hvfwssphxvs7q-overalls-vscode-web-1.141.0`, log
`1791634204167-2491944-0.jsonl`. Its full client TypeScript compilation,
compiled 128-case policy/service checks, installed Chromium and PTY checks
passed. Direct installed-product inspection confirmed the two defaults and the
descriptor tuple: protocol 1, official source
`2a59476c9bfcb90b3ddc372c36762471b7dfad1c`, release
`73ad577f1102eaf74ba05f0c6dbd310ee8896d852c36860ff4761271fc700fff`.
The new installed-validator extension-maintenance check passed, exit0, in 28
seconds: `/nix/store/3ayi9qysxik3f00l560vyppz7hxvr912-overalls-vscode-extension-maintenance`,
log `1791634398697-2516469-0.jsonl`.

A separate manual fresh-profile browser smoke passed, exit0, against that exact
new package. Temporary drivers are
`/tmp/overalls-startup-absence.sAwi1o/check-runtime.mts` and
`/tmp/overalls-startup-absence.sAwi1o/check-browser.py`. The isolated private
TLS/Unix fixture added `--enable-smoke-test-driver` only for this invocation,
awaited actual `window.driver.whenWorkbenchRestored()`, then observed
`.gettingStartedContainer` count 0 and Welcome/Get Started/Walkthrough startup-tab
labels count 0. The assertion output was: `Fresh packaged workbench restored;
getting-started panels=0 and welcome/walkthrough startup tabs=0.` Existing
signature/origin/socket/browser assertions also passed. The command's captured
tool output ended exit0 in exec session69793; no separate log file was written.
No repository helper was
changed and no production probe ran. Initialization completion in a fresh profile
does not establish removal of a saved Welcome editor, actual extension-install
walkthrough behavior, user override execution or a native/production editor
journey. These results remain separate from the older package, native failures
and `50021c04` activation; the new release has no recorded host activation here.

Review of the rebased `50021c04` source also reconciled HLDD05's native-read prose
with ADR-0152: the shared logical snapshot retains the existing consecutive native
consistency reads and identity checks. The chapter now describes the incoming
owned interrupted-template remount, unconfigured-incarnation startup sweep and
120-second default ZFS mutation bounds, preserving exact-record, exclusive-lease,
pool-lock and ordinary native retirement refusals under ADR-0130. New native
subtests are present without an additional passing execution claim.

## Fixture registration and browser profile custody

The frozen native helper follow-up refreshes the command palette's action
snapshot while registration is pending, within its original 30-second deadline.
It requires a visible contributed command row and submits exactly once; no
command execution is retried. The extension search now uses the actual Monaco
input and exact accessible Disable/Enable labels. EditorConfig disablement uses
the actual **Developer: Reload Window** action, whose upstream expected-shutdown
path awaits storage flushing, instead of raw browser reload. Standalone policy
invocations retain an origin-keyed private Chromium profile across calls; exact
synthetic origin allowlisting, hashed child directories and parent/child mode
0700 custody preserve separation. Upstream disable state belongs to that browser
profile on the account's separate editor origin; installed extensions and server
data remain in account-owned guest directories. The README and HLDD now correct
that custody distinction. This tests retained enablement in one browser profile,
without establishing per-account backend or cross-device persistence.

The inert gallery now supplies CORS only for the two exact local account origins
and varies on Origin. Fleet failure output contains only a closed policy stage
and the reviewed shared failure category; exception text, credentials and
authenticated state remain withheld. Contract review found no violation in the
frozen helper diff, including the shared failure classifier and both policy
callers. These are fixture/client-custody corrections under ADR-0153; no new
production persistence protocol, authority, policy or architecture is introduced.

The composed standalone and fleet helper build passed Ruff/ty in six seconds,
log `1791634949810-2561298-0.jsonl`. Earlier scoped diagnostic probes include the
fresh Bob five-second delayed palette pass
(`/tmp/overalls-editor-bob-delay-fresh-execution.log`, line1960) and rediscovery
execution of HOME/outside-HOME Policy, all seven guarded AI actions in each, and
explicit direnv approval
(`/tmp/overalls-editor-bob-rediscovery-execution.log`, lines2041–2101).
The latter then reached the real EditorConfig editor but failed at its old
Disable label. These observations support a registration-readiness hypothesis;
they do not establish the cause of every historical failure. The subsequent
workbench-reload probe passed actual native Disabled:
`/tmp/overalls-editor-bob-workbench-reload-execution.log`, line2127
(`Bob rediscovery probe disabled passed`), after HOME/outside-HOME/AI/direnv
assertions, then failed Overrides. Fixture investigation identified EACCES on
personal `Machine/settings.json`: both native fixture seed paths copied the
immutable0444 source. The final five-file source freeze instead installs that
personal settings file with mode0600, using the validated UID/GID in the fleet
guest adapter. Review traced the existing current-boot root-PTY helper and
validated guest identity; typespecs, native fencing, API assertions and finite
diagnostics remain intact, with no new event emission or production configuration
change.

The earlier full standalone/NixOS/Ubuntu snapshot
`/tmp/overalls-editor-final-native-fleets-289hxd2l` has separate outcomes.
Standalone failed in 85 seconds, log `1791635022542-2569792-0.jsonl`, during
fixture nginx startup: the newly introduced exact-origin map could not fit its
long keys in the default hash bucket. The fixture now sets
`map_hash_bucket_size 128`. Its owning agent canceled the older NixOS and Ubuntu
runs after 227 seconds before acceptance, preserving logs
`1791635022542-2569794-0.jsonl` and `1791635022542-2569793-0.jsonl`.
This introduced fixture configuration error is separate from prior
registration/policy failures. None establishes completed acceptance. Fresh full
checks follow the final mode/hash-bucket-corrected freeze separately. Full
acceptance remains unrecorded, and no new cross-device or production persistence
claim follows from the source review, scoped disablement pass or helper build.

The next corrected snapshot `/tmp/overalls-editor-corrected-native-fleets-fls4bybc`
also failed standalone in 80 seconds, log `1791635372071-2632879-0.jsonl`:
the raw hash-bucket directive duplicated the NixOS module's generated directive.
The final frozen fixture uses `services.nginx.mapHashBucketSize = 128` and removes
the raw directive. The actual evaluated gateway option returned128, exit0; a
fresh standalone run remains required. The snapshot's NixOS and Ubuntu runs,
logs `1791635372070-2632880-0.jsonl` and `1791635372071-2632881-0.jsonl`, retain
mode0600 guest settings and continue separately: neither imports the standalone
gallery configuration. No completed fleet result or production acceptance is
inferred from these fixture corrections.

Review also inspected incoming `db88cb48` against ADR-0130/0152. The owned
template remount path skips chmod when the root already has private permissions,
allowing sealed read-only templates to retain their mode; interrupted roots
still restore mode0700. The native sweep source separately covers sealed
unconfigured and interrupted-unmounted templates. Its trace probe retries only
`storage_busy` with a fresh trace, so command counts and held time describe one
successful preparation instead of accumulated failed attempts. These incoming
source/test corrections preserve the accepted ownership/refusal and snapshot
rationale. No new native execution or timing acceptance is claimed.

The subsequent merged `c4732a35` schedules template sweeps ten minutes after each
completed sweep. The existing GenServer serializes retries; initial prewarming
can delay a queued attempt. Each incarnation retains the same image lease,
pool lock, exact record reread and native ownership/refusal path; configured
templates and independent VM disks remain excluded. The reviewed Events catalog
adds an atom stage, and emission follows the completed sweep result with only
pool UUID, outcome and first failing stage. Source review traced the records,
lease normalization and storage-lock contracts: the stage comes from fixed
operation tags or controlled contention/unconfirmed atoms, with no native error
text or paths. This extends operational retry within ADR-0130's existing recovery
authority, without changing a decision or adding capacity/deletion permission.
HLDD05/14 and the provisioning scenario now describe the cadence, delay and
diagnostic boundary. Periodic contention retry has no newly recorded native or
property execution; a real contended-lease retry/retirement scenario remains
preferred follow-up.

## Completed startup-release fleet execution

The corrected NixOS fleet passed, exit 0, in 805 seconds total build plus native
execution. The corrected Ubuntu fleet passed, exit 0, in 829 seconds total build
plus native execution. Both use the immutable snapshot
`/tmp/overalls-editor-corrected-native-fleets-fls4bybc` and startup package
`/nix/store/3zzcx1nf4fkmqnva7x8hvfwssphxvs7q-overalls-vscode-web-1.141.0`, release
`73ad577f1102eaf74ba05f0c6dbd310ee8896d852c36860ff4761271fc700fff`.
Their logs are in `/home/ghuntley/.local/state/nix/build-logs/`:
`1791635372070-2632880-0.jsonl` for NixOS, run 44514, and
`1791635372071-2632881-0.jsonl` for Ubuntu, run 75664. Both terminal JSONL
completion statuses were independently inspected and are zero.

| Executed stage | NixOS logical event lines | Ubuntu logical event lines |
| --- | --- | --- |
| Real Marshall opening, personal browser tools and custody | 27859–28921 | 25738–26780 |
| Native trust/defaults, direnv and personal controls | 28922–29951 | 26781–27795 |
| Independent worker survival across broker restart | 29952–30956 | 27796–28826 |
| Fresh authorized recovery after worker loss | 30957–31994 | 28827–29900 |
| Saved-data VM stop/start and exact current physical readiness | 31995–34132 | 29901–32676 |
| Unsafe/foreign Origin refusal and sign-out closes current authority | 34133–34456 | 32677–32959 |

These are full-script passes through actual Marshall, Audi, Lilly and the selected
Firecracker images. The snapshot includes command-palette rediscovery, workbench
reload, separate private origin profiles and personal settings mode 0600. It
predates the incoming template changes described above; these runs establish
neither their sealed-root/sweep changes nor periodic contention retries. The
recorded VM script durations are 530.30 seconds for NixOS and 546.50 seconds for
Ubuntu; those durations exclude the preceding dependency/build work.
Standalone version precedence and real Rust/Elixir responses are separate fixture
scope. Production browser journeys and recurring supervisors/recorders were not
executed by these fleet runs. Earlier failures retain their revisions and observed
scope rather than acquiring a retrospective cause from these successful reruns.

## Standalone personal and actual-language gaps

The fresh startup-package standalone run 17627 failed in
`1791635660699-2711380-0.jsonl`; no total duration is claimed. Its original
browser/terminal/custody subtest passed in 44.50 seconds, the all-folder trust and
both-account immutable-default subtest passed in 47.73 seconds, and explicit direnv
approval passed in 9.04 seconds. The personal-version stage then attempted a fresh
EditorConfig 0.18.1 local VSIX against System 0.18.2 with --force and received the
stable builtin Incompatible refusal before language/recovery stages.

The install task's subsequent bundled semver guard intentionally refuses a fresh
lower-than-System installation even with --force. The lower/equal precedence test
must instead seed bounded disposable historical personal profile state without
editing signed System payloads. Source review separately found that the initial
stable builtin guard also prevents the newer personal override required by
ADR-0153 and `editor-builtin-personal-control`. The narrow four-ID permission
candidate is an implementation correction under the accepted decision, not a
classification, visibility, uninstall or authority change. No candidate execution
is claimed here.

The scoped writable-settings Bob diagnostic passed, exit 0, in
`/tmp/overalls-editor-bob-writable-settings-execution.log`. It uses an older
immutable VM/package and current helpers with temporary mode 0600 matching the
corrected fixture. HOME, outside-HOME, explicit direnv, disable/reload and user
server overrides passed. This is scoped browser-profile/personal-control evidence,
not complete version, language, family or recovery acceptance. It does not explain
the older unknown policy assertion or establish cross-device disable state.

Actual project-server language execution remains failed. The initial scoped
run 39454, exit 1, is retained in
`/tmp/overalls-editor-scoped-real-languages-execution.log`: Rust's success notice
was absent and Elixir was not run. The independent both-stage run 5169, exit 1,
is retained in `/tmp/overalls-editor-scoped-language-artifacts-execution.log`;
Rust and Elixir browser statuses were false at physical lines 1947 and 2023.
Private backend artifacts remain outside the repository.

The test owner traced actual rust-analyzer startup with incomplete offline
sysroot metadata and a weak missing-free-function/checkOnSave=false oracle.
Actual ElixirLS attempted a Hex prompt in clean Bob HOME, broke LSP Content-Length
transport and repeatedly exited. The next fixture must require a real Cargo
type-mismatch diagnostic attributed to the actual server and provide a pinned
immutable fixture-only Hex/MIX_HOME closure. Neither source inspection nor
server startup establishes positive language responses; no passing real-language
result was recorded at that diagnostic boundary. Fixture repairs must preserve
project-selected tools and must not add production global servers or bootstrap
installers.

A subsequent scratch fixture-only repair produced scoped Elixir success in
run 8791: `Scoped actual elixir browser status zero: True` at physical line 1981
of `/tmp/overalls-editor-fixed-scoped-language-artifacts-execution.log`. The
native subtest took 9.77 seconds and then checked the marker's Bob UID and absence
of Bob's installer cache. Its original immutable driver is
`/nix/store/q6f5i91b0iq47hwc6ihap5rir76fsa7a-nixos-test-driver-overalls-vscode-web-native`,
with configuration/artifacts under
`/tmp/overalls-editor-fixed-scoped-language-artifacts-yc45bsyj` from the first
`/tmp/overalls-editor-language-closure-candidate.96KrZu` build. That driver build
passed in 41 seconds, log `1791637149162-2864829-0.jsonl`.
The pinned immutable Hex/MIX_HOME fixture closure removes the clean-home Hex
prompt without changing production defaults. The same scoped run still exited 1:
Rust's actual Cargo check received duplicate --offline arguments. This supplies
one scoped real Elixir response, not both-language or final-branch acceptance;
the complete current standalone execution remained required at that boundary.
Earlier language failures retain their original scope.

The final scoped scratch language run 29678 subsequently passed both actual
servers, exit 0, with a 36.61-second driver script. Its log is
`/tmp/overalls-editor-rust-code-observations-execution.log`, immutable driver
`/nix/store/4r5909mdhvpqb5fwgrcqwbc4w8sbmx0v-nixos-test-driver-overalls-vscode-web-native`,
and configuration/artifacts
`/tmp/overalls-editor-rust-code-observations-5wdr9cwl/`. It uses the corrected
private candidate source named above and old startup package 3zz, not final 7fdh.
Rust and Elixir browser statuses are true at physical lines 1913 and 1951, with
both-stage settlement at 1963. Both personal marker UID 200002 checks ran, and
Elixir's installer-cache absence assertion remained. Rust now requires an actual
published rustc Error E0308; arbitrary intrinsic errors cannot supply success.
The failure-only bounded diagnostic collector was not copied into shipped fixture
source. This establishes the corrected fixture/language setup, not final-package
standalone or fleet acceptance.

## Startup checkpoint host activation

At 13:00 UTC on 2026-10-10, independent read-only inspection confirmed both
Dungarees and Overalls healthy on exact revision
`63a1443cf490312df50b3a43af55d92fd7afc263`. Both updater states had candidate,
lastHealthy and activatedCandidate equal to that revision, phase healthy,
failures 0 and failure null; active system matched lastHealthySystem and
`/run/current-system`. Selected actual-role services were active/running and
both updaters were idle. The postdeployment fetch/rebase completed cleanly on
that same checkpoint before this follow-up source change.
The retained `/tmp/overalls-editor-startup-63a-production-20261010.json` is
explicitly a structured transcription of captured allowlisted tool output,
not an original redirected raw log. It records each observation's timestamp
and scope.

| Host | Activated system |
| --- | --- |
| Overalls | `/nix/store/gnc8w93xfv2axp8001qmrr8ldx9bdlnq-nixos-system-overalls-26.05.20260914.c3eea5b` |
| Dungarees | `/nix/store/x44br48k3qvr5g9v5jk3yafmfz0jax2s-nixos-system-dungarees-26.05.20260914.c3eea5b` |

Immutable inspection confirmed editor package 3zz, protocol 1, official source
`2a59476c9bfcb90b3ddc372c36762471b7dfad1c` and release 73ad in its descriptor
and product. StartupEditor was none, walkthroughOpenOnInstall false and the
forced-auto-update roster empty. Both new manifest-v3 guest images carry that
same tuple:

| Image | New immutable artifact |
| --- | --- |
| NixOS | `/nix/store/rk3n4hr3zn6wh45y5xr8h8j7nh131py8-lilly-nixos-x86_64` |
| Ubuntu | `/nix/store/kgm9bm75lp2zhmp46waxwrsg8784r14i-lilly-ubuntu-26.04-x86_64` |

This proves host activation and installed immutable identity. It does not upgrade
retained guest disks or prove authenticated production opening, saved-state/user
override behavior, a configured recurring fixture, completed recurring journeys
or seven-day SLO history. The earlier 12:01 inspection at revision 50021c04
found the recurring fixture/session files absent. A separately authorized exact
existence-only inspection at 13:06:33 confirmed all four files absent on current
63a1443c; both browser supervisors were activating/auto-restart and both request
exporters active/running. No file contents, sessions or private logs were read.
Current recurring coverage remains unestablished. Service activation and
recorders/exporters cannot manufacture browser coverage.

The required Marshall precommit attempt at the startup checkpoint failed before
tests because the worktree PostgreSQL was not running; its captured output is
`/tmp/overalls-editor-startup-latest-marshall-precommit.log`. The supported devenv
PostgreSQL startup subsequently reached readiness. A final full gate must run
after reviewed source/receipt freeze; no new passing startup-checkpoint full gate
is inferred from database readiness or earlier historical passes.

## Narrow personal bundle update correction

The [0004 patch](../../../nix/domains/artifacts/vscode-web/patches/0004-overalls-personal-bundled-updates.patch)
adds a typed immutable product roster for only EditorConfig, vscode-direnv,
ElixirLS and rust-analyzer. The source-reviewed helper validates its unknown
runtime roster and permits only exact lowercase literal IDs; input IDs normalize
to lowercase. Non-array metadata and unrecognized/core IDs grant no permission.
Invalid entries in an otherwise usable array are ignored, without granting those
entries rights. The product interface retains the exact four-ID literal union.

All six helper call sites were traced together with scanner, abstract install,
CLI and Workbench action consumers. No evidenced contract violation was found
in the inspected scope. Native installation keeps the following bundled semver
floor and all signature/engine/target/allowed-extension guards. The scanner still
selects newer valid versions and System on a tie. Matching System installs retain
isBuiltin and application scope. Workbench Uninstall and builtin visibility are
unchanged; effective personal User builtin removal uses existing CLI --force,
while System removal refuses even with --force. The retracted visibility concern
produced no visibility patch.

The Web forced builtin route excludes these managed IDs from both its metadata
check and install selection. Ordinary shouldAutoUpdateExtension behavior keeps
global and explicit extension/publisher opt-ins, pinning, delay, metered refusal,
disable state and consent. A global-off zero-install fixture must have no explicit
opt-ins. No ordinary automatic update preference was rewritten. Product roster
and maintained patch are bound into release identity; the upstream forced roster
remains empty. These are source review conclusions, separate from actual
Workbench execution.

The new actual package passed, exit 0, in 226 seconds:
`/nix/store/3bc7nmbs9lsh0j7ilsy7ypicvzfhvn57-overalls-vscode-web-1.141.0`.
Log `1791637585887-2919312-0.jsonl` has terminal completion status 0. It ran full
client TypeScript, the strict typed membership checker against the actual compiled
helper, existing policy/service checks, and installed Chromium/PTY runtime.
The compiled helper passed 344 decisions covering all configured roster subsets,
case normalization, foreign/core IDs and malformed/missing metadata. The checker
contract explicitly limits those results to membership, without claiming
Workbench preference, personal installation, disablement, signatures or VM scope.

Independent installed-product and descriptor inspection confirmed protocol 1,
official source `2a59476c9bfcb90b3ddc372c36762471b7dfad1c`, release
`8efe4c8af6e30ffde6d614135deb86bb77968f13a8376ce23a2a01ad629ef627`, exactly the
four lowercase personal-update IDs, an empty forced roster, startupEditor none
and walkthroughOpenOnInstall false. The source type change and checker preserve
explicit types without unchecked casts. Native newer install/scanner/reversion,
core/System refusal, historical lower/equal state and actual Workbench global-off
behavior remain separately required. The recorded release73ad fleet and
production activation evidence does not validate this new release.

The final identity build additionally binds the new membership checker content
hash into release inputs. It passed, exit 0, in 236 seconds at
`/nix/store/7fdh6cfldywpb1rhvdibvlmnxwscp5jd-overalls-vscode-web-1.141.0`, log
`1791637930578-2962122-0.jsonl`. Independent descriptor/product inspection
confirmed protocol 1, the same official source, release
`7d2415fecdd209b1cad571f2fd95a22fa4829f5fa4ed50e8688bd08d25f2d9a6`, exact
four-ID roster, empty forced roster and startup defaults. Full client TypeScript,
344 compiled-helper decisions, existing policy/service and installed Chromium/
PTY checks passed. The earlier 8efe build retains only its historical identity.

The final installed-validator maintenance derivation passed in seven seconds,
exit 0, at
`/nix/store/x15yw8i6nycvhp8hxpq1nrs65bji4gg3-overalls-vscode-extension-maintenance`,
log `1791638208201-3013005-0.jsonl`. Both final guest image builds passed in
99 seconds, exit 0, log `1791638302262-3019810-0.jsonl`:

| Final image | Built artifact |
| --- | --- |
| NixOS | `/nix/store/07csd3x7rm9q3mczffyq6ccynly4kzpn-lilly-nixos-x86_64` |
| Ubuntu | `/nix/store/9gw67q57r1miip062kj1vagw6c37i1pq-lilly-ubuntu-26.04-x86_64` |

Direct manifests are v3 and match protocol 1, source 2a594 and release 7d2415. Image
build/identity evidence does not establish final-release native fleet runtime,
production activation or an upgrade of retained guest disks. The final full
standalone snapshot `/tmp/overalls-editor-final-package-native-zc02xyjx` used
package 7fdh in run 28874, log `1791638451076-3032388-0.jsonl`. It failed after
116 seconds at the lower-import refusal oracle. The actual CLI printed the
specific expected downgrade refusal at logical line 3129, while `guest.fail`
returned stdout and the refusal was on stderr. Admission, personal UID, browser,
both-account defaults and direnv stages passed before the assertion. This is a
fixture capture defect; it does not establish the subsequent version/core/language
or recovery stages.

The narrow fixture correction captures stderr with stdout for lower/core installs,
asserts their nonzero statuses and the same specific refusal messages, and captures
the existing System-removal refusal without changing its success-status contract.
No product or package source changed. Reviewed final default.nix SHA256 is
`288e4c0fea15aeb4c771031a4b568986966f00b5c35787d29f531e5efe2dc64f`.
The corrected immutable snapshot
`/tmp/overalls-editor-final-captured-native-c829s4f5` launched as run 70655,
log `1791638687980-3055020-0.jsonl`; no passing result is claimed at this boundary.

Source/contract review of the five frozen fixture files found no substantive
violation. Fresh lower import now asserts the actual semver refusal rather than
requiring installation; newer override/reversion still uses actual native APIs.
A closed inert newer core VSIX must be refused, and effective System uninstall
must leave the immutable builtin present. Rust uses scoped offline Cargo/rustc
and compiled standard libraries with source-library discovery disabled; Elixir
uses pinned immutable Hex/Mix state without requiring caller-HOME bootstrap.
Neither adds a global production guest toolchain. Historical lower/equal on-disk
scanner state remains a distinct unexecuted case. The frozen contract format
gate passed 124 CONTRACTS, 2655 native notes, 252 parsed files and 2712 maintained
source files; syntax/discovery do not replace the semantic review or runtime scope.

## Actual Workbench method regression scope

All 36 ordinary preference cases passed against the actual compiled
`shouldAutoUpdateExtension` method in the frozen scratch fixture
`/tmp/overalls-manual-update-design.R1u4KW/check-workbench-methods.mts`.
For each managed ID, automatic updates off without opt-ins refused; on permitted;
pinning, per-ID/global/workspace disablement refused; explicit ID/publisher opt-ins
while off permitted, and an explicit negative ID overrode a publisher opt-in.
The actual `autoUpdateBuiltinExtensions` method also excluded all four managed
outdated+builtin fixtures from forced installation, retained a synthetic core
outdated+builtin fixture, ignored an independent nonbuiltin and refused query and
install under metered conditions. Its `checkForUpdates` collaborator was a stub
that verified arguments `(undefined, true)`; real forced metadata filtering was
not runtime-proved.

Pinned tsc6 passed with zero diagnostics and the runtime rerun exited 0. Raw logs
are `workbench-methods-typecheck-final.log` and `workbench-methods-runtime.log` in
that directory; `workbench-methods-provenance.txt` records inputs and commands.
Replay of patch 0004 SHA256
`2e2b2cd3028507c1e070343a890603a05f6ce0b69086f5946540473877f8c7ba`
matched the candidate sources; compiled Workbench bundle SHA256 is
`e775c40e22849bef61a14bf869df0675a3ed42d12f65b6ea43618b6d53a8c31c`.
The fixture uses actual upstream types and validated unknown boundaries with
finite mocked collaborators. Constructor Web scheduling, real metadata filtering,
core outdated getter, gallery/native installation, scanner and full Workbench UI
remain separate. This scratch evidence adds no production browser claim.

## Complete final-package standalone execution

The corrected final-package standalone native check passed, exit 0, in 342 seconds
total build plus execution. Its driver script took 323.30 seconds. Run 70655 used
immutable snapshot `/tmp/overalls-editor-final-captured-native-c829s4f5`, driver
`/nix/store/vy7r67bazjbc67lb2r176xcihgh4rxz9-nixos-test-driver-overalls-vscode-web-native`
and final package 7fdh/release 7d2415. Log
`/home/ghuntley/.local/state/nix/build-logs/1791638687980-3055020-0.jsonl`
has independently inspected terminal completion status 0.

| Executed standalone stage | Logical event lines |
| --- | --- |
| Exact admission refusals and personal UID custody | 2550–2593 |
| Native browser tools, terminal and webviews | 2594–2879 |
| Both-account HOME/outside-HOME defaults and explicit direnv | 2880–3042 |
| Fresh lower refusal, actual newer override and forced personal reversion | 3043–3139 |
| Core builtin update and System removal refusal | 3140–3163 |
| Independent personal disablement and server overrides | 3164–3261 |
| Actual Rust diagnostic: rustc Error E0308 | 3262–3293 |
| Actual offline ElixirLS response | 3294–3333 |
| Broker continuity, origin replacement and lost-worker recovery | 3334–3407 |

The version/reversion, core refusal and personal-control stages took 44.29,
11.66 and 69.37 seconds respectively. Rust took 56.57 seconds and Elixir 33.86;
both marker UID 200002 assertions and Elixir installer-cache absence passed.
Project-scoped Cargo/rustc and immutable Hex/Mix fixtures supplied actual language
responses without adding a production global toolchain or bootstrap installer.
This is complete native package/broker/HTTPS/personal-UID acceptance. The local
authorizer and TLS relay are fixture adapters; it does not establish Marshall,
Audi, Firecracker family images, final-release production runtime or recurring
browser coverage. The earlier complete family passes retain startup release 73ad.
Historical lower/equal on-disk scanner state and the broader Workbench/gallery,
idle/retirement, multi-writer and fault histories remain separate.

The initial reviewed documentation gates passed: ADR structure/links for 152
decisions, conflict markers across 4275 files, HLDD receipts/options/coverage/views
and Nix HLDD in 24 seconds, log `1791638882167-3097750-0.jsonl`. All-files prek
then passed, exit 0, in `/tmp/overalls-editor-followup-final-prek.log`, including
Events catalogs, HLDD, Ruff formatting/linting and ty. These gate records precede
the final native-outcome documentation reconciliation. Concurrent devenv startup
raced local GC-root/load-exports setup on initial attempts; serial retries passed.
No application test or source defect is attributed to those setup failures.

## Integration with stopped-only relocation

The integration combines editor follow-up
`7788f347a4ed2d459e39e8b8d01976f361edeb37` with incoming `0b619353`, whose
`7a583604` parent introduces accepted/partial ADR-0155. It supersedes the pre-copy
clauses of ADR-0037/0061/0072 while preserving fenced placement, cancellation,
readiness and cleanup authority. No editor package, worker, broker, image assembly
or EditorConnect source changes in the incoming range. No new editor decision,
domain, resource or host placement is introduced by this merge.
The incoming trace-schema regeneration admits the already-catalogued
`lilly.template_sweep_finished` event and fixed `remount`, `retire_unconfigured`
and `sweep` atoms. It preserves independent ADR-0149 diagnostic custody and adds
no relocation or editor authority; no separate schema-check execution record was
captured for incoming `0b619353`.

Incoming relocation evidence separately records Protocol 259, Lilly 554 and
Marshall 1432 checks with forced Dialyzer, plus final stopped-only relocation-fleet
20 subtests in 4018 seconds; the earlier 19-subtest pass took 3991 seconds. Its
[review](2026-10-10-stopped-only-relocation.md) retains native transfer successes,
base-reproduced source-export/native-zfs failures and remaining clone/Audi/
evacuation acceptance. The incoming ADR/ledger summaries lagged those final
records; this merge reconciles them without relabeling historical pre-copy runs.
The final editor package/standalone pass, earlier startup-release editor fleets
and incoming relocation gates retain their respective revisions. The original
feature Marshall gate is running on the isolated premerge worktree; none of these
records establishes a complete merged component/native or production rerun.

One concrete incoming contract mismatch remains outside the editor behavior:
`transfer-journal-migration-never-blocks` in
TransferJournalMigration (`lilly/lib/lilly/control/transfer_journal_migration.ex` at overalls revision `9fe1e493`, repository deleted)
requires refusing scans above 16,384 candidates, but `pool_candidates/1` enumerates
all candidate paths and reads legacy markers before `migrate/1` checks their count.
The current limit bounds rewrites, not scanning. This is a bounded-scan gap with
no over-limit native evidence; no startup/authority failure was demonstrated and
no source or contract was weakened in this merge. Bound discovery before marker
reads and test the boundary in a separate scoped correction.
