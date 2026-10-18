# Memory-preserving suspension and demand wake

## Scope and architecture assessment

The approved task changes execution, persistence, capacity, recovery and ingress
contracts. [ADR-0198](../decisions/0198-memory-suspension-and-demand-wake.md)
partially supersedes the inherited memory-migration, stopped-only relocation and
cross-host relay prohibitions and extends owner pins. Historical rationale and
unrelated boundaries remain in force. The final diff and execution evidence must
be reviewed before this milestone is described as complete.

## Reviewed findings

- A Firecracker Paused API call retains RAM. Full snapshot plus proven process
  absence is required before compute credit can be released.
- The pinned upstream block snapshot preparation logs and suppresses drain/flush
  errors. A reviewed VMM patch now aborts before snapshot publication on that
  failure; no successful API reply can authorize incomplete I/O continuation.
  The final fleet must qualify this changed executable. Native block-error fault
  injection remains distinct from ordinary successful continuation evidence.
- Snapshot restoration requires an unconfigured fresh VMM. Native hostd now
  carries a typed restore launch bit and omits both cold configuration and MMDS
  metadata arguments while preserving firmware PCI and launch custody.
- A restored RAM file remains immutable while mapped. Two prebound checkpoint
  leaf datasets permit the next full capture without modifying that backing.
- Same-boot continuation cannot rewrite cached guest identity into current
  placement authority. Those identities require a validated continuation binding.
- Paused route/key discovery cannot authorize a guest stream. A waiting connection
  needs fresh authority after restore, including when accepted by the old gateway.
- Native vsock permanent-reset contracts need a recoverable valid-reset branch;
  malformed/configuration changes must retain their fail-closed behavior.
- A successful resume observation must include the exact commanded checkpoint;
  an ordinary running observation without continuation evidence cannot complete
  that operation or restore private-service authority.
- Lock-free Lilly execution reads verify both publisher processes directly.
  Queued monitor cleanup cannot extend the authority of a dead actor or runtime.
  Observer port closure tolerates only the already-closed-port race.
- Interrupted capture/restore terminal cleanup rereads the exact durable intent,
  validates the local checkpoint binding and revision, requires the host lease
  and a confined paused process, and then independently proves unit/cgroup
  absence. It never promotes an unfinished capture to a ready checkpoint or
  retries a consumed restore. Native systemctl mutation admits one owned VM unit;
  slices and wildcard selectors cannot acquire that authority.
- Resume commands encode nested checkpoints through their closed wire schema.
  Sending atom-keyed application data to the strict peer decoder was a concrete
  merged-source defect, not a reason to widen the decoder.
- Built and supplied command snapshots pin resume authority to the VM's current
  validated checkpoint. A caller cannot replace its checkpoint ID or hashes;
  the same authoritative reconstruction already used for Git/workspace metadata
  now also preserves memory continuation.
- Actual fleet capture exposed a sealing call that supplied two paths to
  hostd's single-path ownership grammar. The caller now issues two existing
  native requests. Interrupted sealing also verifies both output files before
  skipping repair, and repairs incomplete files only in an independently
  confirmed writable dataset. The native grammar remains closed; local
  parser/metadata tests and the resumed fleet run retain separate evidence.

## Merged documentation and contract reconciliation

The merged tree contained two ADR-0193 and two ADR-0197 declarations. Per-user
pins retain ADR-0193 and localization retains ADR-0197. Suspension is ADR-0198
and Git attribution is ADR-0199; reciprocal supersession links, indexes and source
references use those distinct IDs. Accepted rationale and historical evidence
remain intact. Suspension is accepted with partial implementation status.

The restored lifecycle, storage, workflows, guest, interactive, networking,
agent, operations, security, domain and topology chapters preserve the incoming
account/localization/guest documentation. The source-derived option, Ash and
topology inventories were regenerated from the actual declarations. Scenario
evidence distinguishes test presence from recorded execution, retains historical
retry results under their former scope and records narrow wake/relay/capture
refusals without claiming native continuation.

The account route had also selected the Git-only SettingsLive while ADR-0196's
combined AccountLive and tests remained present. The repaired route serves the
combined page, with ADR-0199's Git preferences appended as a fourth section.
Profile, passkey, SSH, strict fresh-login and removed-URL boundaries are preserved.
This is reconciliation of existing accepted decisions, not a new authority model.
The separate Reference navigation tree and its Control-room hiding guard were
also restored to the existing handbook, source contracts and LiveView assertions.

The shared HLDD evidence classifier now recognizes the actual parenthesized
property macros and exact Hegel check/run callbacks. Qualified and similarly
named calls remain refused. Its regression suite preserves the separate
assertion, execution-record and native-evidence requirements; lexical recognition
alone grants none of them.

## Current reconciliation validation

- Native `lilly-hostd`: `cargo test --locked` passed **59 tests**, with
  `cargo fmt --check` and `cargo clippy --locked --all-targets -- -D warnings`
  passing against the repaired native sources. These establish local lease,
  selector, process and stream contracts; they do not establish KVM continuity,
  physical cleanup or multi-host recovery.
- The reconciled handbook review, generated coverage/options/views checks,
  ADR structure/link check (**197 decisions**), contract structure check
  (**142 CONTRACTS files, 3,424 notes**) and conflict-marker check passed.
  `nix build .#checks.x86_64-linux.hldd` passed in **9 seconds**, including
  evaluated placement. These are source, documentation and contract-structure
  checks, not browser rendering or runtime fleet acceptance.

## Historical recorded validation

These runs preceded the merged-tree repairs described below. Their exact scope
and revision remain historical evidence; their application counts do not establish
that the current merged sources pass.

- Native `lilly-hostd`: `cargo test --manifest-path
  lilly/native/hostd/Cargo.toml` inside `devenv shell`: **57 passed**. Includes
  Hegel restore launch/round-trip, fixed checkpoint stream custody and unknown-flag refusal. This proves argv and
  native custody behavior in the local test process, not KVM memory continuity.

- Exact-source `native-freebsd-reset` NixOS/KVM machine check passed together
  with `illumos-kernel-candidate-objects` in the recorded 432-second build.
  The actual FreeBSD machine script took 208 seconds. Its receipt is
  `/nix/store/2dmnb2gz3vp32adcflczpk459ww2kbcw-vm-test-run-overalls-freebsd-native-reset/reset-receipt.json`
  (SHA-256 `a63ac733b64157d3644fc2c508411f5ffd81c974861bd4174276d1d21115a2fa`).
  Full fresh-VMM memory restore retained the RAM-only nonce and PID; the original
  listener accepted another connection while connected/unbound sockets fenced.
  This test-only candidate explicitly records `native_admission=false`; it does
  not qualify the immutable production FreeBSD image. The illumos result proves
  candidate cross-object compilation only.
- The final patched-VMM `native-freebsd-reset` machine script passed in
  **417.48 seconds**. Receipt:
  `/nix/store/clz8vdcxd8h1falfzn3pj2r0m9svla5d-vm-test-run-overalls-freebsd-native-reset/reset-receipt.json`,
  SHA-256 `9f82f3fe828fab8261d488827367e53fb16b9c9ef985b9521a8e2c574ee75326`.
  VMM SHA-256 `9815649a9bed84194ca45c5aef4c9307a596c7ffbe1f9f0e881c1ae536226d02`.
  RAM-only nonce/PID and the original listener survived a fresh-VMM restore.
  This supersedes the prior executable's continuation evidence above, while
  retaining `native_admission=false`: it qualifies only the test candidate.
- Focused Lilly terminal tests: **4 passed**, including Hegel original guest
  hello continuity across generated destination epochs. This is HMAC/BEAM
  evidence, not guest or network continuity.
- Shared SSH command tests: **14 passed**, including generated pause/resume/
  unpause codec validation.

- Shared protocol full `mix precommit`: **314 tests passed**, Covenant **14/14**,
  forced Dialyzer **0 errors**. These are local codec/BEAM contracts, not KVM
  continuation evidence.
- Audi full precommit test phase: **221/222 passed**. The sole failure is the
  unchanged Inception suspended-renewer timeout, explicitly out of scope.
  The new wake, configuration, SSH and editor tests passed; forced Dialyzer completed with **0 errors and 0 skipped**; Covenant **10/10**.
- Porsche full `mix precommit`: **100 tests passed**, Covenant **4/4**, forced
  Dialyzer **0 errors and 0 skipped**. The fresh-OTP invalid-configuration
  property runs three complete shuffled refusal menus, with its external-process
  budget declared on the property rather than an ignored generator option.
- Lilly final full `mix precommit`: **627 tests passed**, Covenant **15/15**,
  forced Dialyzer **0 errors**. The watcher race regression additionally passed
  **21 consecutive executions**. This includes checkpoint shape binding,
  paused-live restore recovery and refusal while publisher-monitor cleanup is
  delayed; these BEAM checks do not establish multi-host RAM continuity.
- Covenant static checks passed for protocol **14/14**, Audi **10/10** and
  Porsche **4/4**, independently of the executable contract results above.
- Isolated Marshall ingress history: **2 tests passed**, including **10 generated
  histories**. The model now independently accounts for route replacement after
  VM-generation changes. Live PostgreSQL inspection during replay found no
  retained competing transaction or advisory-lock blocker.
- Isolated publication capacity: **100 gateways, 10,000 routes, 10 samples**;
  each refresh completed in **187–280 ms** under the unchanged production
  deadlines. This is local PostgreSQL throughput evidence, not a fleet SLA.

## Cutover and recovery review

The schema migration refuses every unfinished relocation. Operators must finish
or cancel those moves and confirm cleanup before migration; a mixed stopped-copy
and paused-copy coordinator is not retained. Existing completed relocation
history remains disk-only. Pause admission requires a fresh checkpoint capability
from Lilly, so an old host report cannot receive an unsupported memory command.
Consumer deployment and private relay enrollment must precede producer enablement;
see the operations handbook. Git integration does not perform live deployment.

## Remaining verification

The final source and code-contract review found no additional unresolved
architecture decision or definite production defect in capture publication,
single-use restore, handoff/cancellation, retained storage accounting, durable
wake or renewed relay authority. This conclusion is a source review, not
execution evidence for those boundaries.

Control-plane integration, admitted exact guest images, gateway wait/relay
authorization, actual capacity-driven relocation, current full application gates,
and full NixOS fleet execution remain in progress. Fault-injected block-barrier
failure and complete retained-image qualification remain distinct gaps.
No production rollout or physical-host acceptance is
claimed. Known Inception failures remain out of scope.
