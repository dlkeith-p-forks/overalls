# Memory-preserving suspension and demand wake

## Scope and architecture assessment

The approved task changes execution, persistence, capacity, recovery and ingress
contracts. [ADR-0199](../decisions/0199-memory-suspension-and-demand-wake.md)
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

## Recorded validation

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

Control-plane integration, admitted exact guest images, gateway wait/relay
authorization, actual capacity-driven relocation, Marshall's full precommit,
full NixOS fleet execution, HLDD checks and final architecture review remain in
progress. No production rollout or physical-host acceptance is
claimed. Known Inception failures remain out of scope.
