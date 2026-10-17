# Capacity admission race verification

## Scope and architecture impact

Campaign improvement 110 verifies ADR-0006/0010/0050 capacity accounting under
generated multi-node admission races, with native fleet coverage from the
extended capacity scenario. No production code, protocol, schema, authority or
persistence change is in scope; the two required mutants were injected,
observed at the intended checks and reverted. The optional native
mid-admission BEAM-kill follow-up (Phase 3) is not included; reservation
re-spend windows under executor loss remain improvement 030's scope.

## Distributed generated property

[The new property](../../../marshall/test/marshall/compute/distributed_capacity_race_test.exs)
composes per-sample three-peer fixture worlds (two synthetic Lilly hosts, one
owner) from the existing harness pieces (`distributed_admission_test.exs` peer
setup, `Marshall.ComputeFixtures` geometry, `CommittedFixtureInventory`
discipline). Each sample runs deterministic race windows first:

- execution failure on a settled VM releases compute while disk and address
  stay held; three restart keys share that freed slot,
- four crashes across the ten-minute budget stop automatic recovery and
  release compute, retaining disk,
- confirmed delete frees the full reservation; fresh distinct keys re-spend it
  exactly the measured number of times,
- stopped-workload relocation destination reservation races a provision for
  the destination host's last disk slot (exactly one winner; destination holds
  disk without compute),
- a clone's destination placement races a provision over a tuned two-slot pool
  (exactly one winner; a winning clone holds its source temporary bytes),
- an image disappears between admission and physical effect: the failed
  outcome releases compute, retains the startup disk hold with zero
  materialized credit, and confirmed delete archives and releases the address.

Generated operation mixes (provision/clone/relocate/start/stop/delete plus
injected crash/failed/unknown outcomes at generated concurrency points, plus
idempotency conflicts against committed winners) then run after the windows
against surfaces left by them. Every batch's expectations come from raw
committed SQL only (never `Budget`): enrolled inventory bounds (startup-held
plus settled-running shapes fit effective capacity minus overheads), pool disk
bounds (outstanding startup charges minus materialized credit plus temporary
and resize holds fit reported free minus overhead), VM/placement/reservation/
address/job cardinality, zero-row refusals checked at the commit boundary,
non-archived disk retention, temporary-release-at-terminal, and address
lifetime per profile without pre-archival reuse.

Per-sample teardown deletes exactly the sample's committed fixture rows and
the module checks the complete committed row inventory before and after,
including historical rows.

## Native scenario

[The capacity scenario](../../../nix/tests/machines/fleet/scenarios/capacity.py)
gains a bounded generated race stage alongside the fixed three-way/two-slot
race: each round confirms a resident VM's stop and physical delete, polls the
pool until the freed slot is visible, races a measured number of provisions
across the three Marshalls, and asserts exact winners, insufficient_capacity
refusals, replay identity, zero-row refusals and the startup bound from raw
committed rows. Fixture placement counting remains unchanged.

## Mutants

| Mutant | Intended detection | Result |
| --- | --- | --- |
| Drop `startup_compute_held` filter in `Budget.compute_holds` | window_failed_release (restart of failed VM refused as insufficient_capacity) | fired and reverted |
| Skip `Outcomes.fail!` release gate | window_failed_release ("failed terminal outcome must release compute") | fired and reverted |
| Skip `Outcomes.recover!` exhaustion release gate | window_crash_exhaustion ("exhausted crash recovery retained compute or restarted") | fired and reverted |

## Defect verdicts

No production defects reproduced. Every failure during development was a
test-harness artifact (reserved VMM/bundle geometry, relocation destination
placements outside per-host cleanup, untyped raw rows, refusable mid-window
keys, per-sample peer lifetime and fixture map placement): each was repaired
with regression-preserving test changes. The suspected
`outcomes.ex`/`budget.ex` races are not reproduced by any executed schedule.

## Execution record

Focused runs (partition `verify110`, `ERL_FLAGS="+S 6:6"`) of the new test
module passed at seeds `828441`, `371491`, `637918`, `19008`, `482211`,
`913377`, `413377`, `55555` and `777777` (eight generated batches per sample,
eight samples per run); each ending snapshot matched the complete pre-test
committed row inventory. Per-item execution evidence with schedules and
inventories is available in preserved failure logs where runs failed during
development; the final recorded suite runs contain no failure logs.

Narrow gates: contract checks report 102 CONTRACTS files, 1822 native notes,
125 parsed source files and 2137 covered maintained sources (all structural);
`mix logging.check` passes (147 catalogued marshall events); forced Dialyzer
reports zero errors, skips and unnecessary skips. The complete `mix precommit`
run (all gates plus the distributed-inclusive suite) is recorded below with the
native evidence; results and revisions are listed per execution. First and
later precommit evaluations of only the HLDD review receipt gate remain listed
in the report gap ledger; the final full run follows this text.

## Native fleet evidence

The fixed `capacity races spend pending startup headroom only once` race passed
in every completed driver (271.80s, 328.20s, 291.93s). The new `generated races
re-spend confirmed releases exactly once` stage passed its two rounds plus
same-host replacements in 388.24 seconds on the first full pass and again in
320.66 seconds on the latest run, executing the confirmed stop/delete release,
the race barrier over three Marshalls, refusal zero-row proofs, replay identity
and the per-round startup bound with committed row reads only.

The fleet driver does not currently complete on this host: every attempt ends
in the `verified terminal v2 sessions` browser stage ("Browser acceptance
failed") or the network prepare step, identical failure classes on the checked
baseline content (both predate this improvement; the box shows DBConnection
queue timeouts under nested-KVM load). The reproduced main-HEAD fleet browser
acceptance defect is separately recorded by the mainline documentation commit
`57dd0484`. These downstream flakes are documented environmental failures, not
capacity content: neither attempt's capacity stages failed. One development failure of the new stage was a test-harness artifact
(replay used the wrong profile for an `oss` winner) repaired inside the stage.
A null-capacity snapshot between reports is read as zero fitting slots, matching
the admission boundary exactly.

Result derivation for the latest attempt is recorded in the final report; the
agent-host native flake backlog is retained as an environmental gap rather than
a content outcome.

## Remaining gaps

Mid-admission BEAM kill (control-plane recovery machines), fleet throughput
and sustained contention/load remain outside scope. Distributed test peers use
synthetic committed telemetry (reports/outcomes as fixture writes), so physical
measurement drift/lag in Lilly collection is separately covered by the native
stage and suite.
