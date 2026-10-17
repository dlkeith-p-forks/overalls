# Execution lifecycle review — 2026-09-15

## Scope and evidence

Reviewed v2 messages, lifecycle transactions, archival, capacity cost, crash
budgets and the native generation fence under the authorized full platform plan.
[ADR-0016](../decisions/0016-executable-generations-and-lifecycle.md) extends
ADR-0003/0004/0005/0006/0008/0010/0012/0013/0014/0015. Existing user UI work and
staged monorepo relocations remain preserved.

## Findings and resolution

- **High, fixed — RAM mismatch.** The unit includes 64 MiB beyond guest RAM;
  prior admission reserved only guest RAM. The
  [shared cost](../../../protocol/lib/overalls_protocol/vm_shape.ex), admission,
  restart and migration now agree. Boundary tests cover the additional cost.
- **High, fixed locally — delayed systemd launch.** Per-VM process locks did not
  cancel accepted asynchronous starts. The
  [in-service guard](../../../lilly/native/launch-guard/src/lib.rs) and
  [intent](../../../lilly/lib/lilly/vm/intent.ex) fence launches before a stop,
  failure or deletion can establish a releasable outcome.
- **High, fixed — crash timestamp rounding.** Generated array storage rounded
  to seconds; rapid crashes could land in the future and escape the old age test.
  Explicit microsecond storage and conservative future retention prevent a reset.
  [Tests](../../../marshall/test/marshall/compute/lifecycle_test.exs) cover rapid
  repeats, expiration and backward-clock behavior.
- **Medium, fixed — receipts after archival.** A live-VM relationship could hide
  a VM archived earlier in the same exchange. Receipt validation now uses
  historical ownership. The [API test](../../../marshall/test/marshall_web/execution_api_test.exs)
  commits deletion plus receipt, then replays both.
- **High, open implementation — automatic execution.** V2 server/client and
  local primitives exist, but the runtime remains v1 receipt-only. Complete global
  host ownership, actor journal/outbox, exact-generation execution and restart
  reconciliation before activation.
- **Open acceptance — full platform.** Public provisioning, persisted sharing,
  terminal writer/revocation, telemetry retention, HA deployment, second-host
  isolation and scale evidence remain required.

## Decisions and constraints

No user requirement was removed. ADR-0016 supersedes ADR-0014 while preserving its
image/admission decisions and replacing its unimplemented cleanup profile-lock
requirement with host-serialized archival and the partial live-address index.
V2 is explicit; v1 remains receipt-only. Authenticated
outcomes are not hardware attestation. A successful session is not host execution
readiness. Old admission code cannot join a rollout using the new RAM cost.
Address-history rollback must reconcile slot reuse, preserving historical data.

## Verification

- Applied and reviewed both migrations; admission boundary tests passed.
- Eleven lifecycle and five API cases passed, including conflict/replay,
  archival, crash budgets, Cedar ownership and atomic exchange.
- Seven cases passed across three independent Marshall BEAM nodes, including
  restart/provision races and lifecycle AshOban rollback. Injected transaction
  failures produce expected Postgrex disconnect diagnostics.
- Seven transport cases passed, including actual v2 TLS exchange, revocation
  and rejection of unsent outcome acknowledgements.
- Five native launch-fence cases passed, including one property and queued
  launch/shared-lock/corrupt-file faults.
- Real three-guest guarded KVM smoke passed confinement, independent launching
  BEAMs, DNS/HTTPS, direct isolation, stop/start persistence and cleanup.
- Expanded root smoke passed stop before materialization, an actual delayed
  systemd launch, terminal failed generations, repeated deletion and complete
  cleanup. Owned namespaces/tables are absent afterward and the initially inactive
  `lilly.slice` was returned to inactive.
- All three `mix precommit` gates passed: Marshall 90 cases (84 tests and six
  properties), Lilly 52 (39 tests and 13 properties), protocol 14 (seven tests and
  seven properties). The four opt-in Linux/ext4 runtime cases also passed: **160
  total cases**, plus the separate root KVM smoke. Compiler warnings are errors;
  Dialyzer passed with only Marshall's existing narrow upstream typespec exclusion
  and no new/unused exclusions.
- The protocol gate caught the v2 encoder passing its extended map to the closed
  v1 command typespec. The encoder now explicitly encodes the base and adds its
  image/slot fields; all consumer gates were run with that correction.
- The full allocator test initially used a temporary relation lacking the new
  archival column. Its fixture now models the column and verifies an archived
  slot becomes reusable even when the rest of the /16 is occupied.
- Lilly's independent production release rebuilt successfully. The ADR validator
  passed all 16 records and links. Original-file hash audit found no missing files
  or changes outside the previously documented implementation edits; the 46 staged
  relocations remain pure renames.

## Follow-up

Integrate executable Lilly runtime and exercise provision,
running, stop/start and deletion through Marshall, including Lilly process death.
Continue user flows, telemetry and fleet acceptance; the overall goal is incomplete.


## Subsequent implementation

The [durable-actor review](2026-09-15-durable-vm-actors.md) records ADR-0017's
resolution of the automatic-execution finding: global physical ownership,
readiness-gated admission, persistent actors/outcomes and restart reconciliation.
The full-platform acceptance gaps above remain tracked there.
