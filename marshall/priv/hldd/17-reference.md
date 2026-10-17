# Verification and reference

The multi-OS guest contract keeps native FreeBSD and OmniOS/illumos image
identities explicit while their capability rows fail closed. Their current
artifacts are agentless firmware images: Lilly omits vsock and native manifests
cannot declare a workspace source until a reviewed guest daemon and machine
evidence exist. Arch and AlmaLinux use the generic Linux runtime closure, with
offline evaluation assertions for the packaged Lyra, terminal, trust and SSH
services; those checks do not establish a native boot.

ADR-0179's managed-skill restoration coordinator is implemented in Marshall's
existing agent loop. It advances a bounded round-robin cursor across replacement
machine generations, suppresses duplicate active or terminal restoration
receipts, and emits catalogued failure outcomes before continuing the scan.
Focused authority and restoration scheduling cases pass; native guest restart,
physical reopen and independent-host recovery remain separate acceptance gaps.

The [browser launcher review](repo:docs/architecture/reviews/2026-10-10-browser-launcher.md)
records Weaver source comparison, current source2/manifest4 and authentication
resume evidence. The replacement minimized immutable browser package/check passed in 10 seconds,
including strict typing, all ten Node tests, deterministic archives, Mozilla lint
and real Chromium four-provider actions with query/hash sentinels removed and
unsupported-click refusal when its URL was initially withheld. A fresh pinned developer build matched archives and
manifest byte for byte. Pinned Firefox 155.0.1 temporarily installed the exact final
immutable XPI and passed settings, metadata and four actual toolbar actions on
fixed local TLS pages with query/hash sentinels and browser certificate bypass.
All launches contained only provider origin/path. ADR-0156 is implemented;
public provider network, permanent signing, Android and production activation
remain outside recorded acceptance. The final privacy correction removes source
query/fragment fields before extension transmission or capture storage/POST and
refuses URL user information. Four pure capture security tests and both source
and test strict TypeScript checks passed. The four regressions are now enforced
by `workspace.check`, whose final test/type invocation passed separately after the
full component gate.
The final check-only removal of an unnecessary HOME override passed a fresh
sandbox check in 9 seconds, preserving the same immutable release and archive
bytes. The exact release's five HTTP/host tests passed again, seed 735823,
including public metadata/byte equality and unsafe-file refusal. These checks
do not establish deployed public HTTPS.

The final focused Marshall source/snapshot/editor set passed 39 checks
(3 properties, 36 tests). Pinned protocol precommit passed 260 checks; the corrected
Lilly full gate passed 549 checks, seed 582375, after the readiness handoff fix.
Both forced Dialyzer runs reported zero errors. Observability precommit passed
11 checks and its current finite schema check passed without regeneration. Rust
passed 123 tests and all-target Clippy. These component results retain their
captured scope; final Marshall full validation is separately recorded.
Marshall full precommit passed 1,454 checks (239 properties, 1,215 tests), seed
80297, with four excluded; forced Dialyzer reported zero errors in 34.61 seconds.
Its verification-only capture-test gate addition was directly run and passed.
The later diagnostic-only ZFS refinement passed 21 focused checks (7 properties,
14 tests), seed 523473, then full Lilly 549 checks, seed 643895, and forced Dialyzer
with zero errors/skips in 13.12 seconds. Observability passed 11 tests, seed 765622,
forced Dialyzer with zero errors/skips in 5.74 seconds and its trace-schema check.
The new identity-bracket event preserves all storage guards and retry behavior;
its missing-path regression establishes fixed metadata/privacy and equal refusal,
not parent-accounting or native healthy-backing proof. Native event evidence must
identify the actual failed predicate before any causal conclusion.

The authorized merge combines prior main `f39d509a` with browser feature
`a3d2b69c`, retaining stopped-only relocation, personal bundled-editor updates and
the canonical shared observability formatter. The exact merged finite vocabulary
was regenerated to restore the diagnostic `pool_identity` atom. Focused merged
Lilly checks passed 34 checks (11 properties, 23 tests), its 104-event logging gate
and structural contracts; Observability passed its schema check and ten formatter/
shared-library tests, seed 957221. Marshall's 164-event logging gate and all
nineteen contract regression tests also passed. These are scoped integration
checks. Browser native captures below retain their immutable feature-source scope;
merged-main native and full component acceptance are separate.

The earlier corrected Ubuntu native capture passed cross-tab sign-in/required MFA,
four exact initial GitHub checkouts and retained stop/start without re-clone.
Ten additional GitHub/GitLab/Codeberg revision cases passed before Codeberg change
stalled at clone status `cloning`; the run failed after 1,703 seconds. Bitbucket,
public downloads and CLI were not reached;
historical ADR-0128 GitHub results retain their old schema/revision. The corrected
runtime capture predates final frontend privacy and provider/ADR module-comment
corrections.
An exact dnsmasq 2.93/production-code musl probe isolated the fixture DNS failure:
A succeeded but AAAA returned REFUSED; authoritative local-domain configuration
returned an empty NOERROR AAAA answer and API resolution succeeded with the same
captured Ubuntu CA bundle plus a fresh fixture root. All four fixture domains now
answer locally, and fixed guest TLS/schema/fork diagnostics preserve private
terminal bytes. This focused repair is separate from complete guest acceptance.
The repaired NixOS family completed all twelve subtests, exit 0 in 1,352 seconds
(854.61-second test script): all twenty provider/revision combinations, exact
guest-owned HEAD/shallow/done assertions, installed-CA provider API probes,
cross-tab sign-in/required MFA, retained restart, public immutable HTTPS downloads
and packaged CLI/working directory passed. These are fixed local provider fixtures
on the colocated native fleet. The earlier frozen-source Ubuntu run passed browser
sign-in/MFA/dedupe in 23.04 seconds, then failed initial guest startup before any
checkout assertion, exit 1 after 266.734 seconds. Its exact failed predicate remains
unproven. The final complete feature `a3d2b69c` Ubuntu capture passed all twelve
subtests, exit 0 in 1,713 seconds total build/execution, script 1,422.20 seconds:
cross-tab resume/MFA/dedupe in 31.21 seconds, initial four actual checkouts in
22.10 seconds, retained restart in 47.85 seconds and sixteen additional matrix
cases in 964.11 seconds, twenty total. Installed-CA Codeberg/Bitbucket API/fork
assertions, public immutable downloads in 0.36 seconds and real packaged CLI/
command/workdir in 24.28 seconds passed. No identity-probe failure marker occurred;
no readiness or retry behavior changed. ADR-0157 is implemented. NixOS predates
the diagnostic-only addition; neither capture reran merged main. Its scoped
component/schema/contracts/logging checks and Nix HLDD gate passed separately,
the latter in seven seconds. Live
provider network, production activation, Brady interception and installed-extension
authentication/guest composition remain separate validation limits. Normal fragment
capture composed through the final frontend, while browser assertions of sentinel
removal and capture storage/POST contents remain separately unrecorded.
The source2-era NixOS handbook renderer passed all 22
sections, Ash/topology diagrams, navigation/hook removal, themes and revoked-reader
refusal in 388 seconds, before the final documentation and editor SQL corrections.
Editor DNS publication and its native fixture require the same manifest4 as the shared
decoder; exact editor release and current publication authority remain required.

[The browser editor review](repo:docs/architecture/reviews/2026-10-10-browser-editor.md)
records the official/OpenVSCode source comparison and retained historical failures
under [ADR-0153](repo:docs/architecture/decisions/0153-official-source-browser-editor.md).
The corrected startup-release snapshot passed complete NixOS and Ubuntu
Firecracker family scripts in 805 and 829 seconds total build/execution, including
current physical readiness, policy/controls, recovery and Origin/sign-out refusal.
The later final package `7fdh`/release `7d2415` passed complete standalone native
acceptance in 342 seconds, driver 323.30 seconds, including personal install/
reversion, core/System refusal, actual Rust/Elixir and broker/worker recovery.
Its authorizer and TLS relay are fixture adapters. Family results retain earlier
release `73ad` and their pre-template snapshot; final-release family and this
browser-launcher merge's native integration are separately unrecorded. The
`63a1443c`/release `73ad` host activation establishes installed identity rather
than a production browser journey. Periodic template sweeps, production editor
acceptance and recurring browser history remain separate.
Synthetic package bridge/roster evidence cannot be promoted to full service
authentication or guest isolation. Native veth packet-mark acceptance retains its
Linux network scope. Recurring probe declaration does not prove production
credentials, completed browser journeys or seven-day history.

## Evidence levels

| Evidence | Establishes | Does not establish |
| --- | --- | --- |
| Accepted ADR | Intended architecture and rationale | Implementation or deployment |
| Unit/property tests | Tested invariants over their fixture/model scope | Native isolation or provider acceptance |
| Nix evaluation/build | Configuration validity and build reproducibility | Running-service readiness |
| Native machine tests | The specific exercised kernel, storage and network scenarios | Independent physical failure domains or fleet capacity |
| Deployment acceptance | Observed behavior of an identified deployed revision | Untested recovery, load or future revisions |

Consult current ADRs and their linked reviews for feature-specific acceptance.
Several decisions remain partial. Known boundaries include historical database
reconciliation, pre-existing guest image migrations, provider-specific behavior,
physical failure domains, and unmeasured scale. A newer test count is not a broader
guarantee. This handbook's own checks validate documentation and presentation.

The [user-operation verification campaign](repo:docs/history/ledgers/verification-campaign.md)
tracks incremental property and native machine improvements, missing capabilities,
and external acceptance boundaries. Queue entries are planned work; only explicit
execution records establish passing evidence for their named revision and scope.

### Antithesis harness retirement

The [2026-10-13 reset review](repo:docs/architecture/reviews/2026-10-13-antithesis-reset.md)
records removal of the old `antithesis/` tree before a fresh whole-repository
rebuild. Historical harness, research and local mutation artifacts remain linked
at the full captured baseline revision. Their recorded execution and limits are
preserved; they are not current setup instructions or fresh hosted acceptance.
Lilly's existing generated actor and fake-command properties retain their test
paths and assertion names, using an ordinary test-support fixture. The scenario
ledger therefore retains its bounded property evidence and native gaps.
Fresh research, setup, workload execution, hosted baselines and mutation results
must acquire their own source/build identities and execution records. Emulated
guest journeys, hosted user-space services and native Firecracker/ZFS checks
retain separate verification scopes.

The [native prerequisite review](repo:docs/architecture/reviews/2026-10-13-antithesis-prerequisites.md)
records passing source-built Galileo and Enrico release payload checks and a
separate disposable NixOS ZFS I/O run after its failed probe attempt. It also
records two failed expanded service-role attempts: the first at the cookie
pipeline, the retry after Marshall cookie checks when Lilly startup failed and
its owner file did not appear. The runtime-secret fixture has no passing
role-machine capture. The updater replay assertion and five-second ingress catalog decoder
boundary are source/test changes without new execution evidence in this review.
These are prerequisite checks, not a current hosted harness or guest lifecycle
acceptance. The ledger binds passing and failed attempts to their exact
derivations and source hashes.

### Experimental Antithesis foundation

The [foundation review](repo:docs/architecture/reviews/2026-10-13-antithesis-harness-foundation.md)
describes an isolated control fixture. The graph below is its proposed Compose
layout, not the deployed fleet or evidence that all containers have started.
The hosted campaign admits up to 32 active attempts so every selected Compose profile and its replicas can run concurrently; this operational limit does not establish a production deployment or a passing property result.

```mermaid
flowchart LR
  PG[Disposable PostgreSQL] --> Migration[Marshall migration]
  Migration --> MA[Marshall A]
  Migration --> MB[Marshall B]
  MA --> Operator[Enrollment operator]
  Operator --> Lilly[Controlled Lilly]
  PG --> Oracle[SELECT only oracle]
  MA --> Bootstrap[Single workload bootstrap]
  MB --> Bootstrap
  Lilly --> Bootstrap
  Oracle --> Bootstrap
```

Runtime secrets stay in private fixture volumes; only the operator enrolls
Lilly through Marshall's reviewed CLI. Bootstrap checks both TLS endpoints,
migration and a fresh authenticated host report before one setup signal.
The SQL witness requires a positive report sequence, a report timestamp within
60 seconds and a durable session matching the host's current session ID, host
ID and epoch. It does not read the retired host `protocol_version` column or
infer a wire version from SQL. Production Execution and the real Control
probes enforce wire v4 separately. Historical local boot captures predate this
current-schema witness; local readiness alone does not establish hosted SDK
ingestion or native effects.
The optional `repository-origin` profile adds a second gate before the same
single setup signal: the operator-issued repository manifest must match the
independent fixture ID, the origin fixture must answer an authenticated state
read, the SELECT-only oracle must find the registration row and a
`pending`/`refreshing`/`ready` phase, and Enrico must answer an authenticated
status read for a never-issued attempt. Marshall commits GitHub sources in
canonical lowercase, so the operator publishes `github/fixture/demo` exactly as
registered and the origin fixture serves that path; an earlier mixed-case
manifest and served path never matched the committed row, and Marshall's own
refresh failed against the origin, so setup stayed incomplete. The probe now
reports each distinct unmet prerequisite once per process by condition token,
observation state, HTTP status or phase, never by credential or payload.
The failed-refresh published-head case was never exercised in hosted runs:
the workload image linked Git into its closure but not onto a fixed path, so
the native blob oracle could not run Git and every attempt stopped before the
force push (run `30a420d501d5d6d22527e679a7f00005-65-0`). The image now links
`/opt/overalls/git`, the oracle calls it explicitly, and each early stop logs a
fixed `Enrico published-head case unexercised` reason.
The optional `recorder-host` profile selects the TCG NixOS recorder VM and the
three recorder commands. The workload waits for the VM health check, then its
own read-only probe requires a fresh all-active unit sample, producer and spool
identities in their reviewed cgroups, a distinct 32–64 MiB archive device, a
checkpoint whose pending admissions name only the current producer PID and
start ticks, a readable SQLite archive and writable request and ledger volumes.
Missing or stale evidence leaves setup incomplete. Its first hosted validation
stopped in initrd emergency mode: the runner's `root=` argument duplicated the
image's own root fstab entry and, without `rw`, left the real root read-only,
so the `/run` bind into it failed. The runner now relies on the image fstab
alone; a direct local QEMU TCG boot of the rebuilt context, outside any
container, reached the runner's health check in 66–96 s. Its first hosted run
(`bbb308949ab76c0f1ce04fd209f1f091-65-0`) failed container setup because the
Antithesis container filesystem refuses O_DIRECT, which QEMU `cache=none`
needs to open the qcow2 backing image. The recorder, host and storage VMM
runners now probe O_DIRECT on every disk and its backing image and fall back to
flush-respecting `cache=writeback` (never `cache=unsafe`), printing the
effective mode. The profile is selectable, but no hosted run has completed
setup; its evidence is emulated, not native.
The optional `admission-stub` profile runs the atomic-allocation and key-replay
admission commands on a harness **stub** storage substrate, which is not ZFS.
Only in that profile does the controlled Lilly release report configured stub
pool totals for its enrolled pool identity, measured cgroup CPU and memory
headroom, and a tiny non-bootable image it digest-verifies before advertising;
the enrollment operator registers that image through Marshall's catalog action
and then enables lilly-a through the reviewed CLI `enable` action, which
refuses until Lilly's stub report is fresh and execution-ready. A fully stub-backed report advertises placement readiness, so Marshall's real
admission transaction commits VM, placement, reservation and dispatch rows,
but the controlled executor never launches a guest and a delete never
completes. Setup requires the enabled normal-mode host and those committed report, pool
and image rows in SQL; hosted runs before this check never enabled the host,
so every admission probe stopped at unknown capacity
(`dd4f5f9cd52da22427ae2e5b79c095bf-65-0`). With the host enabled, the next run
still submitted nothing: the pre-submission SQL witness read host and pool from
the VM row, which the placement migration had moved to
`compute_workload_placements`, so every query failed and was reported as
unavailable (`379970e17a2d5312bff3e5c5e2c17369-65-0`). The witness now joins the
current placement, and oracle queries log each failing SQLSTATE class once.
Catalog headroom below the request shape no longer withholds a request: a
definite `insufficient_capacity` refusal is Marshall's real decision, checked
for absent rows and a bounded one-VM replay. Every stop before a settled
decision logs a fixed `Compute admission unexercised` reason; the first hosted
run reached no admission assertion because those lines were never emitted.
The results are admission-logic evidence only, never ZFS, physical-capacity,
KVM or isolation evidence; the measured-capacity command stays in a separate,
unselected template for the measured host graph.
The optional `guest-lifecycle` profile selects the guest lifecycle command with
the guest VMM overlay. Its container Lilly is a separate STUB-storage release:
it reports a fixed synthetic pool with no ZFS and compute headroom for one free
guest-vmm slot, capped by measured cgroup limits, and sets execution readiness
only after a guest-vmm health check and a verified advertised image. The
enrollment operator registers that image manifest through the catalog action
and enables lilly-a through the reviewed CLI `enable` action once its report is
fresh and execution-ready; Marshall's catalog counts no capacity from a disabled
host. Bootstrap adds a third gate: the guest-vmm image identity, read through the
read-only witness bridge, and a Marshall catalog offering that image with known
capacity for its shape. The stub admits one emulated QEMU TCG guest only; it is
not native ZFS, KVM, Firecracker, isolation or capacity evidence. Its first
hosted run (`a2edc265384761d6607df51eac50b29d-65-0`) timed out at
`capacity_unknown` because the host was never enabled; the earlier local pass
had inherited an enabled host from a retained PostgreSQL volume, so local
validations now start from empty volumes.
In every other profile the host report has unavailable pool capacity and false
execution readiness, so a successful Control connection cannot authorize a
guest placement. The
controlled executor records requests without claiming physical effects; its
default guest callbacks remain unavailable. An optional integrated TCG adapter
is authored with a measured inner ZFS host and emulated guest observation, but
has no recorded composed journey. Its recovery inventory permits only the
fixed `lilly.service` and `lilly-guest-emulator.service` cgroups plus exact
tracked VM units when systemd creates them; unknown or malformed native
inventory fences recovery, while the emulator inventory independently checks
tracked placements. The optional TCG guest context
has a [recorded local boot](repo:antithesis/verification/guest-boot.md): exact
port 1024 readiness on three q35-adapted NixOS guest boots, with one restart
on a retained qcow2 overlay and matching offline machine-id bytes. The
storage-router VM separately passed a
[local direct-run smoke](repo:antithesis/verification/storage-boot.md) with
real ZFS/Brady, origin-off cache replay and retained marker/quota across QMP
reset. The four selected control-context exports
passed at their captured derivations. A later local base Compose project also
emitted setup and passed six serial Control commands; the selected manifest
has four stale runtime-dependency hashes, so no frozen hosted baseline follows.

The static researched catalog contains 104 primary properties. The current
literal scanner finds 164 SDK callsites, 30 matching primary messages and 74
missing primaries, with no duplicate callsite or kind mismatch; none
of the 104 properties is complete as a workload plus independent oracle and
hosted result. The default `control-core` selection now stages 13 commands in
seven templates, six of them one-command terminal singletons: credential
revalidation, dispatch, legacy request, SQL reply loss, host-session successor
and host rotation. Its cross-service dispatch primary binds only a Lilly socket
and counts foreign effect tables; its legacy-document primary observes
Marshall's durable host session, not Lilly's Store or Journal; its 4001
refusal primary drives the shared client against a loopback peer for a bounded
quiet window. None has a hosted run. Local SDK writer probes and unit tests show bounded JSONL
behavior, including short-write refusal across helper restart, but they do not
prove hosted ingestion. BEAM fallback assertions provide no BEAM branch
coverage. The harness-only Marshall hint relay `Reachable` marks an observed
notifier recovery from `:isolated`; it is a search anchor, not evidence that a
lost hint was reconciled or a committed host command progressed. Python catalog scanning provides no source coverage; the C helper is
assertion transport, not SUT instrumentation. The workload image presents the
selection-scoped Python catalog as one `/opt/antithesis/catalog` link to a
single `workload` module tree, so the hosted instrumentor catalogs one root and
every workload process registers every selected assertion; a selected
assertion no command reaches then appears as a zero-example property. A run
whose "Paths found for Antithesis instrumentation" lists more than one Python
path has split the catalog per package: the Python SDK registers one root's
catalog per process, and unreached assertions in the other packages are
absent from the report rather than passing (admission-stub run
`8e582f650dd7092cda983705eb7b0e05-65-0`). Native Rust coverage remains
pending. A local control-core setup completed on diagnostic4 image bytes, but
the selected manifest's four stale dependency hashes prevent a frozen local
or remote baseline claim for that image.

Optional Compose overlays declare separate origin/SMTP fixtures, satellite
roles, a guest VMM, a measured Lilly/ZFS TCG host and a recorder host. Closed
operator requests and witness paths are source-defined; the workload has
authored browser, Control peer, admission, terminal and recovery callsites.
Their presence does not establish that selected images, migration, credentials,
health, independent oracles and one setup owner ran together. The local guest
and router TCG records each have their own artifact identity and never count as
the default control graph's hosted baseline.

| Profile | Overlays after the base | Selected commands | Setup gate beyond the base | Reachable claim |
| --- | --- | --- | --- | --- |
| `backup-restic` | `compose.backup.yaml` | five `backup` commands | production backup operator and pinned Restic present; private fixture volume; a probe Restic file repository initializes and enumerates empty | production prune, inspect, backup and restore against disposable encrypted file repositories, checked by raw Restic and restored hashes; no ZFS capture, S3 or recovery target |
| `satellite-standin` | `compose.origin.yaml`, `compose.satellites.yaml`, `compose.satellite-standin.yaml` | four `satellite` commands | origin fixture state; private-Audi root; guest stand-in receipt of a verified TLS handshake to private Audi | private Audi forwards nothing for a forged request from a source Lilly never bound; VM-dependent commands record unexercised |

The `backup-restic` repository uses Restic's local file backend because the
production operator reports one failure status for an unavailable repository
and for a validator refusal; a network backend would let a fault read as a
refusal. The `satellite-standin` **guest stand-in** is a labelled harness process
from the workload image that shares only `lilly-a`'s network namespace and
speaks the guest-side TLS protocol to `169.254.254.1`. It is not a guest: it has
no VM, boot, tap, placement or execution authority and mounts no secret. Its
assertions test only private Audi's transport-only attribution with the origin
fixture as effect witness; they say nothing about guest routing or isolation.
The overlay also corrects the private Audi start script, which omitted the
required `connector_uid` and so could not load its configuration, and waited
on the disabled ordinary `audi.sock` instead of Lilly's private-services
`private.sock`. Porsche refuses to listen without a Marshall-signed host
certificate, which Lyra fetches in production; the stand-in start script makes
the same reviewed `/api/ssh/v1/host-certificate` request with the gateway token
held in a private header file. The harness Marshall had no SSH host CA, so that
request returned the opaque unavailable reply; the synthetic secret volume now
carries a generated ed25519 SSH host CA, and both replicas receive
`MARSHALL_SSH_HOST_TRUST` shaped like the NixOS module's. It is test-only key
material, never a production CA. Ziggy
completion, Galileo named origin and the editor login-code race need a current
running VM; the controlled Lilly pool reports unavailable capacity and no Audi
editor gateway, editor release or wildcard is configured, so their primary and
`Sometimes` assertions stay unevaluated. Ziggy and Galileo issue and
authenticate credentials only for an enabled host, and Marshall's reviewed
enable action requires a fresh execution-ready report that the controlled
`lilly-a` never sends, so satellite enrollment applies a labelled harness
**STUB**: it sets only `lilly-a`'s administrative `enabled` flag through the
Host `:configure` action and verifies it with the operator `show` command. The
stub fabricates no readiness, capacity, pool credit or VM binding, so Marshall
admission still refuses the host; it is not evidence for the readiness gate on
host enablement. A failed satellite operator command reports only the CLI's
fixed atom status line. Both profiles have rendered Compose
graphs that pass the selection validators and unit tests; neither has a local
`compose up` or hosted run.
The [integrated-host record](repo:antithesis/verification/integrated-host-boot.json)
captures two unavailable-health TCG boots and one corrected third-image boot
with actual ZFS and cgroup sampling. A fourth built private-service image
repeated the measurements, completed runtime PKI preparation and produced a
workspace-source-v2 guest image witness. Both measured samples remain
disconnected and execution-unready. A private 9p witness identified the first three images;
focused crash-actuator tests passed nine checks without a QEMU crash. A
boot-bound guest-trust receipt adapter passed twelve tests and forced Dialyzer,
but the full integrated-mode suite failed at 7/559 and private service roles
have no runtime credential or terminal acceptance.
The earlier local base Compose diagnostic passed migration, Marshall A/B, enrollment,
three synthetic account/passkey creations and Lilly health. Read-only SQL
confirmed exactly three users and three account passkeys; the enrollment
operator had no listening socket. The v4 host was connected, but
`report_sequence` was 0 and `reported_at` absent, so setup did not fire in that
project. Diagnostic4 subsequently logged `INFO Antithesis setup complete` after
a fresh v4 report at sequence 44. Six serial commands produced 13 true SDK
assertion records and the final SQL observation found fresh sequence 392;
the [foundation review](repo:docs/architecture/reviews/2026-10-13-antithesis-harness-foundation.md)
records local image IDs and the stale selected-manifest hashes. The controlled
container committed cgroup-derived effective fields while preserving nil pool
capacity and false execution readiness. Raw cgroup files were not independently
compared, and hosted ingestion remains unverified.

The `database-recovery` machine check uses the real release Repo on a separate
machine from PostgreSQL. It requires three observed lock waiters before client
loss, then checks the existing holder and connection reclamation deadlines.
The old settings and a polling-only candidate both missed the 35-second bound.
A captured candidate with one-second active disconnect polling and a 15-second
TCP acknowledgement limit reclaimed all ten connections in 27.719 seconds; its
healthy 20-second query also passed. Its exact captured-source scope and inspected
executable equivalence are retained. Both complete integrated NixOS and Ubuntu
terminal journeys separately passed browser recovery, retained shell effects,
sharing and revocation; their VM-script timers were 702.42 and 683.84 seconds.
Neither result establishes physical/provider recovery or production load. See the
[execution scope](repo:docs/architecture/reviews/2026-09-25-terminal-workspace-verification.md).

The `log-store` machine check exercises classified journald export through
verified TLS and path-scoped credentials, plus Grafana's provisioned read-only
VictoriaLogs datasource. The retired Marshall `/admin/logs`, `/admin/slos` and
fleet history routes return 404. Their pre-cutover browser/client evidence remains
historical; it does not establish current Grafana acceptance. The
[observability decoupling review](repo:docs/architecture/reviews/2026-10-09-observability-decoupling.md)
records native provisioning/query execution and remaining deployment gaps.

Provisioning benchmarks read bounded catalogued host-local transition events over
strict authenticated administrative SSH. Template cost requires one staging and
one ready event for the same host, pool and native record, with ordered timestamps.
Missing, duplicate or mismatched evidence refuses a warm sample. Diagnostic phase
files explicitly report incomplete coverage and never authorize VM cleanup.

## Developer verification

GitHub Actions runs on privileged, cached Namespace runners so Nix builds keep
their sandbox. Every job installs multi-user Nix, starts `nix-daemon` so builds
run as `nixbld` build users as on the fleet, installs the devenv revision pinned
by `devenv.lock`, and publishes what it builds to the `overalls` Cachix cache.
`publish-cache.yml` runs on trunk pushes and pull requests: repository gates,
`mix precommit` for each Elixir project, and every enabled non-machine flake
check. `nixos-machine-tests.yml` runs daily or on dispatch and fans out one job
per NixOS machine test selected from `meta.ci` (Inception is excluded); its
discovery evaluates only that metadata, and each matrix job builds its test.
`nix-upgrades.yml` updates `devenv.lock` weekly and pins the flake's
`buildNixpkgs` to the same nixpkgs. A run is execution evidence only for the
commit it ran; a selected matrix entry is not a passing result, and nested-KVM
availability on the hosted runners is unverified.

`elixir/request_accounting/` is the shared typed request-accounting library.
`Overalls.RequestAccounting.Producer` performs private quality-marker and local
Unix RPC I/O for durable admission custody. `Aggregate` provides the immutable
counter/histogram model and validates snapshot construction; each application
retains eligibility, classification, concurrency, persistence and publication.
The library remains independent of best-effort diagnostics. Protocol measurement
types and codecs remain pure; ADR-0142 confines outbound control WebSocket I/O
to `Control.Client` and `WebSocket.Connection`, with application-owned credentials
and trust. Protocol stores no durable credentials or domain authority.
An unsupported control version is terminal for that client instance: pending
requests settle as unproven, further requests remain disconnected, and recovery
requires a replacement client after the incompatible version is corrected.
The original client's delayed reconnect was reproduced after60.3seconds. The
stopped-phase repair passed the five-check client file in167.3seconds before
the queued-connect and HTTP426 extension. The expanded six-check client
file subsequently passed in288.0seconds. Its generated loopback history
retains a61000ms observation and does not prove arbitrary future absence or
native fleet rollout. The refined queued-connect wire oracle subsequently
passed the six-check file in318.9seconds and caught the targeted retry mutant.
The heartbeat ownership review reproduced early replacement-socket traffic in
10.4seconds. The timer-reference repair passed its focused reconnect property
in47.8seconds before integration. Retired-reference redelivery passed the
integrated property in45.9seconds and caught a ref-matching mutant in6.2seconds.
Protocol249, Lilly503, Marshall1466 and Galileo31-check gates passed with
zero-error forced Dialyzer; the Protocol gate predates the extended test and
is reused only for unchanged production source. Incoming-main integration,
verified TLS reconnect histories and native fleet acceptance remain open.
The loopback test's100ms transit allowance is not a production latency guarantee.
Marshall, Audi, Brady, Porsche, Galileo and Enrico package the explicit
local library inputs. Run its pinned `mix precommit` and each changed consumer's
gate. The native `otel-request-recorder` fixture separately exercises the actual
BEAM producer and Rust recorder; unit/type checks do not establish application
transport acceptance or production history.

```sh
devenv shell
elixir scripts/check_adrs.exs
elixir scripts/check_hldd.exs
elixir scripts/hldd_options.exs --check
cd marshall
mix precommit
```

Run the corresponding application gates for changed consumers and the protocol
library. Shared governance changes also run Marshall's validator tests. Select
native checks from the maintained test catalog; do not run destructive harnesses
against production resources.

Run `mix precommit` in the independent `elixir/diagnostics/` project when reviewed
event catalogs, runtime instrumentation or the SDK change. Its read-only
`mix schema.check` compares production literals with the generated finite trace
vocabulary without starting services or rewriting files. Review vocabulary
changes before regeneration; a synchronized artifact alone does not establish
delivery to the native spool or Tempo.
Schema generation orders object keys explicitly. A fresh-VM regression verifies
that opposing atom-loading orders produce the same reviewed artifact, so the
gate can distinguish source drift from serialization order.

The opt-in [HTTPS egress acceptance](repo:docs/acceptance/egress-acceptance.md) uses three
receipt-bound disposable guests on Overalls and records private command, request
and updater evidence. Its pinned public destination has a positive reachability
control before Customer refusal. Seven runner safety tests cover ownership,
replay, failed responses, approval redaction and local SSH/proxy timeout cleanup;
they cannot establish native isolation. A local timeout does not cancel admitted
VM work: reconcile the original request.
Customer refusal requires connection failure or timeout against the independently
reachable pinned public address; TLS handshake or receive errors fail the probe.
The `brady-network` and
`brady-native-storage` machine checks keep shared-service outages and pressure
faults isolated, including HTTPS full/range recovery with the origin stopped.

### Committed database fixtures

Tests using independent Marshall nodes commit real fixture rows. Public VM
provisioning also creates agent roots, initial threads and audit versions. Raw
job deletion retains redacted job history, and lifecycle records intentionally
outlive their resources. Disposable fixture teardown captures its own VM, root,
thread and job IDs and deletes dependent history in foreign-key order after all
callers finish or stop. Shared image ownership is captured before creation; prior
unreferenced catalog rows and versions survive. Serial job cleanup captures exact
new IDs and preserves completed jobs of the same worker. Catalog registration,
credential and team retirement fixtures dispose their worker jobs by the same
exact returned IDs, and each distributed authority test asserts the complete
public-table inventory around its own execution. Production archival and retained history are unchanged.

Generated cleanup histories compare complete public-table row digests before and
after both successful and deliberately failed assertions, while preserving an
unrelated fixture's automatic histories and unused image catalog entries.
Failures report changed tables and row hashes without payloads. If teardown also
fails, the original
failure remains reported. Historical rows in older verification partitions and
baseline reproduction rows remain available; a clean fixture restores the prior
inventory rather than assuming the database began empty. The
[fixture review](repo:docs/architecture/reviews/2026-09-26-committed-fixture-history.md)
records exact execution and remaining scope; the
[authority fixture review](repo:docs/architecture/reviews/2026-09-26-authority-fixture-history.md)
reproduces and repairs the retained catalog/retirement job histories. This is
test database hygiene, with
no new native isolation or user-scenario acceptance claim.

### Browser helper type gates

NixOS test drivers and separately launched browser helpers have distinct type
checks. Teams, Control room, handbook, MFA login, administration, Git mirrors,
job history, Inception and the fleet's default OSS, resize, account lifecycle,
team resources, terminal, maintenance evacuation, agent CLI, private web, clone
and executor-loss journeys execute copied helper artifacts only after pinned
`ty` passes against their actual Python/Playwright runtime; the fleet client
likewise executes typed Audi and Porsche browser artifacts. The repository's ordinary Python source discovery does not
include machine helpers. Installer trust has no standalone browser script and
retains composed driver typing. Every composed fleet variant driver passes the
framework's `ty` check and ruff lint; no variant skips type checking.

The [artifact review](repo:docs/architecture/reviews/2026-09-25-browser-type-gates.md)
and the [sweep review](repo:docs/architecture/reviews/2026-09-26-browser-typing-sweep.md)
record checker execution separately from historical native runs. Those runs keep
their original source and assertions; this build gate creates no new property,
physical isolation or browser-runtime evidence. Commands for building the
artifacts without machines are in the [test catalog](repo:nix/verification/tests/README.md).

The browser launcher change passed pinned all-files ruff-format, Ruff and ty.
Import sorting explicitly classifies the copied native `browser` helper as local,
keeping checkout and packaged configurations consistent when launcher dependencies
contain vendored Python. This classification and import ordering preserve helper
behavior and provide no new native editor execution evidence.

## Command reference

The management reference below is generated at compilation from the same catalog
as the SSH parser. `--help` and the command grammar remain authoritative for the
invocation being used. Commands operate under current authorization; examples
never supply credentials as arguments.

{{COMMAND_REFERENCE}}

## Native guest protocol reference

FreeBSD and illumos (the OmniOS downstream image) use version-6 image manifests
and version-3 firmware bundles. Their closed agent rows are `freebsd-v1` and
`illumos-v1`; every capability is currently false. The host-only vsock transport
shape remains reserved. Native metadata carries positive kernel bytes, digest,
source revision, patch/configuration hashes and compiler; unavailable receipts
and placeholder kernels cannot enter image construction. A declaration of
`workspace_source_version` 2 does not grant source delivery. Lilly's added probe
path binds kernel-file identity to the current boot fields and requires the
same boot ID from readiness. The read-only `AF_VSOCK` option
`VSOCK_SO_BUILD_ID` (1) returns exactly 65 bytes: 64 lowercase hex build-input
bytes and NUL. The probe compares that loaded token to a root-owned bounded
expected-token file before answering; the separate kernel file hash is still
required. Separate FreeBSD kernel and native userland
cross-builds now pass; illumos has a modern virtio backport and custom socket
sources with object checks. `sys/vsock.h` exposes family 45 on FreeBSD and 40 on
illumos, with the same 16-byte port/CID layout and passive host-only streams.
`overalls-illumos-candidate link OBJECT_BUNDLE BUILD_ID NEW_OUTPUT` performs
target-native nine-module linkage; `install ALTERNATE_ZFS_ROOT LINKED_BUNDLE BUILD_ID`
verifies bytes and rebuilds an alternate root's boot archive. The actual scratch
link/install passed; the command refuses the running root and retains closed
admission. The `native-freebsd-transport` nested-KVM gate passed a scoped
139-second run for exact token/CID, native ABI/buffer/capacity refusals, bounded-refusal/reconnect
and credit-window exchanges. The final ordinary catalog gate passed again in
246 seconds for image `19658a4a`, with immutable receipt and exact token/firmware/
VMM hashes recorded in the native review. The
separate FreeBSD candidate performs two offline QEMU boots and installed-byte,
Git/trust and executing-token verification. `omnios-image-candidate-kit` emits
immutable inputs for native pool assembly and fresh-boot verification as
described in its [operator guide](repo:nix/domains/artifacts/guest/omnios/README.md);
native pool import/clone/link/install/boot-archive/export passed with all nine
modules and payload entries. Seed-fixed QEMU file/Git/trust/resolver/stock-service
checks and diagnostic Firecracker executing-AF40/native Rust transport checks
passed. Final corrected token `985301b4` clean-export assembly passed all nine
native links and 764 payload checks, native validation of three manifests and
the exact four stock-network removals. Read-only receipt extraction and clean
shutdown sealed disk `24318238`; normal persistent-image replay remains pending.
This is a recorded target-native assembly, not a reproducibly Nix-built image.
The completion-corrected `76b8c1ad` object build passed all four host gates,
including 161 source-extracted completion histories and four rejected mutants.
Its separate pristine native assembly passed the same nine-module/764-entry/
schema/network checks and sealed disk `a49255bd`; exact hashes are in the native
review. A paired direct-only QEMU diagnostic reaches console login on `76b8`
under the same no-vsock settings where `9853` panics mounting root. Growth enters
maintenance in this diagnostic; corrected Firecracker service/transport/reset
acceptance remains separate, and the earlier `9853` boot failures stay recorded.
The first corrected-image Firecracker service run stays alive but misses its
240-second first-boot deadline after reaching login with growth in maintenance
and network/identity withheld. Retained serial corrects the earlier wrapper's
blank-output impression; it does not establish service acceptance.
The vendor-base FreeBSD
candidate passed complete services and same-boot daemon recovery over two clean
boots each; later canonical-roots/SSH inputs passed full service oracles in the
growth/isolation runs below. The final reviewed blocking-flush image passed all
five scoped service/growth/policy/daemon-recovery/SIGKILL-recovery variants.
Those original candidate receipts retain false admission flags. A separate
reviewed promotion now activates only the sealed FreeBSD disk `5022d714` and
manifest-derived image `d141e426`; complete image-qualified capability lookup
enables readiness, trust, workspace, terminal, flush, SSH and agents, while
editor and Inception remain false. Unqualified rows, stock or altered images,
the latest rebuilt FreeBSD candidate and all OmniOS identities remain closed.
The promotion verifier binds artifact bytes, the reviewed VMM and all five
scenario receipts. Its recursive NAR input uses signed Overalls substitution;
cache publication has a separate availability/signature/content record. The
FreeBSD results do not establish OmniOS, physical power-loss or fleet acceptance.
See the [activation review](repo:docs/architecture/reviews/2026-10-17-native-image-admission.md).
See [ADR-0190](repo:docs/architecture/decisions/0190-native-kernel-provenance-and-admission.md).

Native growth runs only `overalls-native-grow-root` without arguments. It derives
the mounted root, checks pinned dual-GPT identity/capacity, applies native grow
commands and writes `/var/run/overalls/root-growth.json` before bootstrap may
publish identity. Twelve pure checks and three native FreeBSD QEMU boots passed
one unchanged root plus two expansions with retained home/GPT/foreign-disk checks;
the later exact canonical-roots/SSH image passed 334-second Firecracker growth
with three clean boots, two expansions and full service oracles. A host-direct
Firecracker diagnostic on a disposable OmniOS `76b8` clone reproduced the `s1`
expansion-operand refusal and unsliced whole-disk success. The corrected helper
retains validated `s1` authority and raw `p0` GPT preflight, using the unsliced
disk only for expansion. The typed Rust/Clippy/native build and fresh corrected
kit `d0rd` assembly passed; read-only disk `bea32fe6` has its exact receipt in
the native review. Corrected-helper OmniOS replay and interrupted
expansion remain pending; final blocking-flush FreeBSD replay
passed the same three-boot/two-expansion boundary. The
OmniOS kit's offline SMF profile disables stock cloud-init's four instances and
stock SSH; exact-profile database-copy validation passed without touching the
live repository. Assembly removes the fixed four stock vioif0 address/DHCP files
and binds continued absence into verification. Assembly and booted verification
validate all three exact manifests with native `svccfg validate` before receipts.
The corrected `Unstable` manifests pass actual native validation; the old-enum
mutant refuses. Schema validity does not establish methods or service readiness.
A new assembled image must pass fresh-boot disabled-state and immutable payload
checks. The native isolation fixture's composed driver and
Linux nft smoke pass; the exact canonical-roots/SSH FreeBSD image also passed
two clean native policy boots with sink controls, actual guard drops and source
recovery. OmniOS, direct native peer-VM, jail and host isolation remain gaps.

`native-fixture-unit` executes the host parser/refusal/cleanup/Git/FAT boundary
suite with pinned Python, Git, OpenSSH, OpenSSL, FAT and block tools. The recorded
Nix gate passed 59 tests in a four-second build. This is host verification
evidence; no native boot, isolation, growth or recovery follows from it. The
shared service machine accepts an explicit FreeBSD/illumos test image, preserving
the same service/growth/isolation/recovery/crash scenario boundaries without
constructing an admitted production manifest.

`native-reset-probes` cross-builds isolated C probes for FreeBSD and illumos.
`native-freebsd-reset` passed its nested-KVM gate in 232 seconds: a peerless
identity socket fenced and pending accept/read/write operations woke with errors
after a real pause/full-snapshot/resume sequence, with fresh sockets refused until
a new VM. Exact test image/kernel/probe/firmware/VMM receipts are in the native
review. The private Unix fixture API and disposable snapshot/memory do not grant
production authority; this does not establish DMA/race stress, OmniOS, physical,
service or recovery acceptance.

CI metadata reads enabled `config.requiredFeatures` from a lazy NixOS tester when
its wrapper lacks `requiredSystemFeatures`, preserving explicit metadata and
avoiding evaluation of the driver/derivation/image merely to select a builder.
The throw-on-forcing regression and actual metadata checks passed. Native
service/transport/reset tests remain enabled nested-KVM machine checks; the host
fixture remains nonmachine. This corrects test scheduling without changing the
actual nested-KVM requirement or adding runtime acceptance.

## Elixir contract verification

All twelve Elixir applications declare Covenant as a development/test dependency
with `runtime: false`; production releases gain no contract service or runtime
dependency. Each application's `contracts/` tree names obligations, and tagged
tests under `test/contract/` provide executable evidence. Precommit runs
`mix covenant.check --no-run`, while the ordinary ExUnit run retains its existing
formatters and adds `Covenant.Formatter` for runtime results.

Initial module-loadability obligations detect missing or renamed declared modules.
Additional behavior fixtures establish only their asserted BEAM-observable scope.
Coverage percentages and static checks do not establish passing runtime execution,
native Rust/KVM behavior, guest isolation, physical recovery or deployment.
Existing `CONTRACTS`, ADRs and scenario-specific native/machine records remain
separate obligations. See
[ADR-0186](repo:docs/architecture/decisions/0186-covenant-contract-verification.md).

## Elixir property verification

Elixir properties use the test-only Hegel frontend pin `2c9f7a4` under
[ADR-0191](repo:docs/architecture/decisions/0191-elixir-hegel-property-verification.md).
Protocol properties run once per declared case count with fixed seeds and no
example database or printed replay blobs. A local draw boundary records literal
labels and redaction markers; generated terminal bytes and payloads do not enter
the native replay printer. Bounded generators retain exact string/collection
constraints, malformed peer shapes and unsigned 64-bit GUIDs through the engine's
signed integer interface. Transport cases release their own listeners, supervised
children and fixture messages before another case or replay.

This verifies BEAM codec, refusal and process/socket behavior. It does not
establish native guest execution, TLS, physical isolation, storage recovery or
fleet acceptance. Protocol's workspace-source and View properties still use
StreamData, and the wider migration remains partial. The recorded 299-test pass
used the previous frontend pin `6a62795`; the merged frontend's complete gate
also passed 299 tests and properties, Covenant 14/14 and Dialyzer with zero
errors or skips. Native engine sources are unchanged by that frontend update. The
[testing guide](repo:docs/development/testing-with-hegel.md) and
[verification review](repo:docs/architecture/reviews/2026-10-17-elixir-hegel-property-verification.md)
describe the current API, exact execution evidence and remaining gaps.

## Keeping this handbook current

`/hldd` lists sections. Each `/hldd/SECTION` page loads one chapter; previous and
next links follow handbook order. The contents page sends no chapter bodies, and
section changes remove previous diagrams. Direct section links require the same
current login as the contents page.

Changes to implementation, configuration, protocols, architecture, operations or
verification must use the repository's `hldd-maintenance` skill. Update affected
chapters and diagrams in the same change. When no reader-visible fact changes,
record the specific reason. Never mark a review complete by refreshing hashes
without inspecting the source change.

Describe only mechanisms that exist. When ADR-0159 removes a compatibility path,
the same change deletes its handbook text and scenario evidence rather than
marking it historical; the [removal review](repo:docs/architecture/reviews/2026-10-11-legacy-compatibility-removal.md)
keeps the per-push record and export digests.

The blocking gate compares source inventories and chapter digests against reviewed
receipts. It catches edits, additions, deletions, missing chapters and invalid
references. The Nix check also compares the evaluated option reference. Passing
these checks establishes currency and structure, not factual correctness.
Generated build caches and `.nixos-test-history` are excluded consistently from
Git and packaged-source inventories. Execution claims need an explicit reviewed
record; the generated history file is not an acceptance receipt.
CI-only `.github/` automation and unattended `devenv.lock`/`flake.lock` pin changes
are excluded from review receipts; source configuration such as `devenv.nix`,
`devenv.yaml` and `flake.nix` remains covered.

Property evidence recognizes Rust Hegel's bare `#[hegel::test]` and configured
`#[hegel::test(test_cases = 8)]` attributes, including multiline formatting and
nested settings calls. This is lexical runner recognition: the Rust compiler,
property assertions and scoped execution record establish separate facts. The
checker still requires a local evidence path and the named assertion; recorded
results require their cited text. Recognition does not upgrade a test to native
coverage or a passing execution.

Evidence: [command catalog](repo:protocol/lib/overalls_protocol/ssh_command.ex),
[test catalog](repo:nix/verification/tests/README.md),
[architecture index](repo:docs/architecture/decisions/README.md),
[maintenance skill](repo:.agents/skills/hldd-maintenance/SKILL.md).

Certificate-specific verification includes
`nix build .#checks.x86_64-linux.ssh-host-certificates`, the NixOS and Ubuntu
`user-ssh-journey` fleet checks, protocol certificate properties and Marshall
issuance tests. The current decision is
[unified host CA](repo:docs/architecture/decisions/0124-unified-ssh-host-ca.md);
[operations](repo:docs/operations/porsche-operations.md) describes trust and renewal.
