# Lifecycle operation histories and recorded native lifecycle matrix

Campaign improvement 037. Branch `verify/037-lifecycle-histories`, worktree
`kittens-verify-lifecycle-histories`, integrated base `origin/main` at
`f24661b2` (merge of improvement 068, carrying the restored `executorLoss`
fleet parameter from `40c1e73b`; the parameter's loss in the `f7cdb3c5` merge
had made the `fleet` check unevaluable between `f7cdb3c5` and that fix).

## Scope and architecture assessment

The user operation is the ordinary machine lifecycle: an account creates a
machine and issues start, stop, restart (stop then start) and delete, while the
authenticated provisioner reports physical outcomes. No production code,
protocol, persistence schema or documented behavior changes. The change adds a
generated property suite driving the real Ash actions and durable rows, records
the existing-but-never-recorded native fleet lifecycle scenario, and updates the
handbook ledger and campaign queue to reference the recorded executions.

Architecture impact: none. The existing decisions stand unchanged:

- ADR-0017 durable VM actors and host ownership; interruption between a durable
  command effort and its physical effect requires conservative holds and
  idempotent replay, never fabricated outcomes.
- ADR-0005→ADR-0037→ADR-0050 supersession chain carrying forward retained
  disk/address on confirmed stop, immediate capacity refusal and deletion
  requiring confirmed cleanup before archiving.
- ADR-0016 generation fencing and transactional outcomes (superseded text,
  carried forward), ADR-0009/0042 durable audit and observability.

The new tests exercise existing public actions (`Compute.provision`,
`Compute.lifecycle`) and the physical outcome ingestion path
(`Marshall.Compute.Outcomes.ingest_locked!` through the real
`KittensProtocol.Execution.outcome` codec) exactly as the provisioner control
exchange invokes it under a host-locked ledger transaction.
New Inception testing and validation remain excluded per user direction; the
native run uses the existing disposable nine-VM fleet fixture only. Physical
hosts, production deployment, SMTP and hardware authenticators remain outside
this work.

## Pre-implementation record

Recorded before implementation, per the verification campaign delivery contract.

### User operation

An ordinary confirmed account provisions a machine with an idempotency key and
manages it: start, stop, delete; restart is a stop followed by a start. Each
request is `Marshall.Compute.lifecycle/2` with `%{vm_id, kind, idempotency_key}`
under the user's actor. Provisioning is `Marshall.Compute.provision/2`.
Physical effects arrive separately as authenticated host outcomes ingested
through `Outcomes.ingest_locked!/2` while holding the host row lock.

### Allowed result

A new lifecycle request commits atomically in one transaction: prior
pending/acknowledged operations cancelled, VM generation incremented, desired
state transitioned (`running`/`stopped`/`deleted`), a new `Operation` row with
provenance (initiator, requester, request key) and its dispatch job, a
redacted lifecycle event row per mutated audited resource, and — for start —
reacquired compute capacity on the retained disk. An exact retry (same
actor/VM/key/kind) returns the existing operation without changing any row.
Applied outcomes (matching host, placement, epoch, current generation, fresh
sequence) advance observed state and the operation: confirmed running completes
the provision/start generation; confirmed stop releases compute only (disk and
address retained); confirmed delete releases all reservations, archives the
address and the VM; a crash outcome while desired running restarts at most
three times in ten minutes under retained capacity, then marks the VM failed
and releases compute only.

### Refusal cases

- A caller without current manage authority on the VM (never authorized, or
  revoked after a grant) is refused with no row changes.
- Same actor/VM/key with a different kind must fail (`idempotency_conflict`)
  without advancing state.
- Any lifecycle request (other than an exact replay) against a VM whose intent
  is deleted, or already archived, fails `vm_deleted`.
- Start against a host without a fresh execution-ready report fails
  `host_unavailable` without a new generation or operation.
- Outcome ingestion rejects: a replayed ID with changed payload
  (`outcome_conflict`), a reused placement sequence (`outcome_conflict`), wrong
  host/placement/epoch/operation/VM bindings and incompatible kind/state pairs
  or future generations (`invalid_outcome`), and incoherent wire shapes
  (`invalid_message` at the protocol codec before any durable write).
- Deleted desired intent is terminal: no transition back to `running` or
  `stopped`.

### Failure and recovery cases

The journal/effect boundary is the interruption point: lifecycle intent is
committed durably before any kernel/hypervisor effect is known. Between the
commit and the physical outcome, Marshall may restart; the provisioner replays
its durable outcome IDs and Marshall must deduplicate them; an unknown effect
(`state: :unknown`) retains every capacity hold. A crash outcome under retained
compute triggers a bounded recovery start with recovery provenance and reset
crash accounting on explicit user intent. Deletion retains all
reservations until a coherent deleted outcome confirms physical absence; only
then must the guest release compute, disk and address and archive the VM.
Stale observations (older generation, or sequences at/below the applied one)
remain recorded without undoing newer intent; after exhaustion or non-crash
failure the VM reports failed with disk and address retained for an explicit
restart.

### Independent property oracle

The suite maintains an explicit model computed independently of the
implementation's state derivation:

- Legal transition graph over the durable intent: `running ⇄ stopped →
  deleted` (deleted terminal), crossed with observed states
  `pending → running/stopped/failed/unknown/deleted`.
- Per-state durable invariants asserted after every step, directly from
  PostgreSQL: VM row (desired, observed, generation, outcome sequence, failure
  reason, crash budget length, archival), the complete operation set (kind,
  generation, status, initiator, requester identity, request key), the
  per-placement reservation (compute/disk startup and settled hold bits),
  network address presence, the physical-outcome ledger (IDs, generations,
  sequences), and the complete durable lifecycle event chain
  (resource type, action, previous/next state, actor kind and ID, generation)
  for the VM.
- Refusal expectations come from the documented rules above, not from the
  implementation's error paths: the oracle computes whether each generated
  command must be admitted or refused, with the refusal reason, before the
  command executes.

Complete public-table row-hash preservation for unrelated fixtures is asserted
by the `Marshall.CommittedFixtureInventory` snapshot/`assert_restored!`
protocol from improvement 029, and each generated run deletes its exact
committed fixture rows through `Marshall.CommittedFixtureCleanup`.

### Native boundary

`nix/tests/machines/fleet/scenarios/lifecycle.py` composes into the `fleet`
check (`#checks.x86_64-linux.fleet`): real nested Firecracker stop/start
retaining ZFS dataset GUIDs, reservation hold transitions, and deletion
releasing storage through the fleet operator, plus the durable audit matrix
including human intent and authenticated provisioner transitions across
Dataset/Execution resources, with process-identity survival checks on
unrelated guests. It currently has `present` but never `recorded` execution
evidence; this improvement runs and records it.

### Dependencies

PostgreSQL (durable authority), the existing `Marshall.ComputeFixtures`
host/user fixtures, `Marshall.CommittedFixtureInventory`,
`Marshall.CommittedFixtureCleanup`, the pinned devenv Elixir/OTP runtime, and
the pinned Nix fleet check with nested KVM. No new dependencies.

### Required checks

1. Focused suite execution for the new file with recorded seed and counts.
2. Full `mix precommit` in `marshall/` including distributed tests and forced
   Dialyzer.
3. `prek run --all-files`, `elixir scripts/check_adrs.exs`,
   `elixir scripts/check_hldd.exs`, `elixir scripts/hldd_views.exs --check`,
   and `nix build .#checks.x86_64-linux.hldd`.
4. One native `checks.x86_64-linux.fleet` run recorded with store path,
   duration, exit status and process-drain evidence, serialized with other
   campaign builds through `flock /tmp/kittens-native-build.lock`.
5. One bounded mutant demonstrating detection by the new properties, restored
   and recorded.

## Composed histories

`marshall/test/marshall/compute/lifecycle_history_test.exs` generates command
histories over the real public actions and the real protocol outcome codec. A
journey starts with a real `Compute.provision/2` against the standard host
fixture and maintains an independent model of the durable state. The model —
not the implementation — decides before each command whether it must be
admitted or refused, and with which reason.

Every journey runs a fixed boundary arc around its generated middle:

1. stop, confirmed stopped (compute released, disk/address/startup-disk
   retained), start (restart: compute and startup compute reacquired on the
   retained disk), confirmed running, an exact duplicate start intent,
   confirmed running again;
2. four crash outcomes under desired running: the first three commit a
   recovery-provenance restart generation each and the fourth exhausts the
   budget, releasing compute only while retaining disk and address;
3. a running observation against the exhausted generation is refused as
   `outcome_conflict` because compute is no longer retained;
4. an explicit user start resets crash accounting and confirms running;
5. the generated middle mixes start/stop/delete requests (fresh and replayed
   keys, owner/foreign/manager actors), physical outcomes (matching, unknown,
   crash, non-crash failure and kind-mismatched states) against current and
   older generations, replay/conflict/invalid wire probes, host availability
   flips and access grants/revocations;
6. the closing arc issues delete, then delivers the physical effect first as
   unknown — the journal/effect interruption point: intent committed, every
   hold retained — and then confirmed deleted, releasing all reservations,
   archiving the address and the VM;
7. terminal probes: fresh owner, manager and foreign intents after archival
   are refused with the model-computed reason (`vm_deleted` when authorized,
   `forbidden` otherwise), an exact delete replay returns its retained
   operation unchanged, and a changed kind under a retained key fails
   `idempotency_conflict`.

## Oracles

After every step the suite re-reads the complete committed projection directly
from PostgreSQL and asserts, against the independently computed model:

- the VM row: desired state, observed state, generation, outcome sequence,
  failure reason, retained crash-restart timestamps and archival;
- the complete operation set for the VM — kind, generation, status, initiator,
  requester identity and request key — with at most one pending operation, and
  every completed operation pinning its completion outcome on the same
  generation;
- the placement reservation's four hold bits (compute, disk, startup compute,
  startup disk);
- network address presence (exactly one until deletion, none after archival);
- the physical-outcome ledger: every recorded row's id, generation, sequence
  and immutable wire bytes;
- the complete durable lifecycle event chain (resource, action, previous and
  next state, actor kind/id, generation), with each resource's per-stream chain
  (intent versus observation) required to retrace its own state history;
- the exact committed user set, access grants and changes for the VM, and the
  absence of administrator audit rows.

Generation and kind mismatches, duplicate or conflicting outcome identities,
future sequences against occupied placements and incoherent wire shapes are all
computed as refusal expectations by the oracle before the command executes.
Whole-suite committed-fixture preservation runs through
`Marshall.CommittedFixtureInventory` snapshot/`assert_restored!` in setup and
teardown, and each generated history deletes its exact committed rows through
`Marshall.CommittedFixtureCleanup`.

## Mutant result

Bounded mutant, applied mid campaign and exercised by the fixed boundary arc:
`length(attempts) < 3` weakened to `< 4` in `Marshall.Compute.Outcomes.recover!/4`
(a fourth automatic restart inside ten minutes, violating the
`outcomes-bounded-crash-recovery` contract's bound). The property detected it
on its first history: after the fourth crash the VM carried generation 8 with
four retained crash-restart timestamps against the oracle's exhausted
generation 7 with three; failure-left `{8, 4}` versus expected `{7, 3}` for
`{vm.generation, length(vm.crash_restart_times)}`. The mutant was restored
in the same session and the focused suite re-passed.

## Execution record

Focused property suite (all within
`devenv shell -- env ERL_FLAGS='+S 4:4' MIX_TEST_PARTITION=verify037
PGHOST=/run/user/1000/devenv-0e19ff2/postgres TMPDIR=/tmp/kittens-verify037`,
worktree root):

- `mix test test/marshall/compute/lifecycle_history_test.exs --seed 0`:
  1 property, 24 generated histories, passed in 20.2–23.0 seconds (initial
  development found and fixed one check-ordering bug in the suite itself —
  `DateTime` structs do not sort chronologically under Erlang term ordering;
  the event-chain check now sorts by Unix microseconds).
- Seeds 1, 2, 3, 4: 24 histories each, passed in 21.4–26.0 seconds.
- Scoped result: the focused suite passed one property of 24 generated histories per seed across seeds 0 through 4, and the bounded restart-limit mutant was detected and restored.

Full Marshall gate on the final integrated tree (`b1a91ad1` + this change),
fresh partition `verify037b`:

- `mix precommit` passed: toolchain, ADR (124 decisions), HLDD receipts,
  contracts (102 CONTRACTS files, 1,862 native notes, 126 parsed source
  files), logging (147 catalogued events), `compile --warnings-as-errors`,
  unused-dep check, formatter, `test --include distributed
  --warnings-as-errors` — **1,215 passed (146 properties, 1,069 tests), two
  exclusions, seed 761151, 879.3 seconds** — terminal/dashboard/workspace
  checks and forced Dialyzer (**0 errors, 0 skips, 0 unnecessary skips**,
  53.5 s).
- Residue finding for the coordinator: after the first full-suite execution on
  the session's `verify037` partition (which began the day carrying retained
  historical fixture rows, as other campaign partitions do), subsequent
  standalone reruns of
  `mix test --include distributed --warnings-as-errors` on that same partition
  reproducibly failed 87–89 checks across unrelated suites (admission/capacity,
  transfer slots, registration cooldowns, relocation source permits) — e.g.
  `relocation_sources_test.exs:1376`'s global enqueued-job inventory matched
  an extra `NotifySourcePermit` row inserted at 00:50:11Z by an entire-suite
  run, and account-signup suites failed on retained rows. The identical test
  passes on an empty partition, and the full gate passes on fresh
  `verify037b`. Standalone-rerun-on-retained-partition is therefore currently
  order/residue fragile on main; the property suite added here restores its
  complete committed inventory by construction (the failing suites are not
  this improvement's). This is a suite-hygiene finding against recently merged
  suites, not a functional regression signal for lifecycle behavior.

### Native lifecycle matrix (`checks.x86_64-linux.fleet` / `vm-test-run-kittens-fleet`)

`nix/tests/machines/fleet/scenarios/lifecycle.py` composes only into the
default `fleet` check (ninth of eleven concatenated scenario fragments). Two
full attempts were made under `flock /tmp/kittens-native-build.lock`, each
awaited inside one synchronous shell call with a 3600-second budget; load was
below the 25 threshold at each launch (21.4 and ~7).

1. **Attempt 1** (base `ab8b5b87` + this change, derivation
   `cxabcxsv2szh3i9kk1cp7kpbn8pddjw8-vm-test-run-kittens-fleet.drv`): the flock
   acquisition waited 47 minutes behind another campaign session's identical
   build; the vm-test build itself ran 771 seconds and was then cut by this
   harness's outer timeout (`interrupted by the user`), never reaching the
   driver. No guest was started by this attempt.
2. **Attempt 2** (base `f24661b2` + this change, derivation
   `xb2mvy0fgi1nzm9z6j3jyldxpnlhr037-vm-test-run-kittens-fleet.drv`, would-be
   output `/nix/store/wqaq8fs16lzab8p8rmfpab0d42g20wqj-vm-test-run-kittens-fleet`):
   driver ran the full scenario sequence and **failed after 1,774 guest
   seconds (33.6 minutes wall) at the `terminal.py` subtest "verified terminal
   v2 sessions, sharing and reconnect across three Marshall machines"** —
   `AssertionError: Browser acceptance failed` (composed driver line 1173 →
   `browser_probe` line 587 → `service_browser` line 570 in
   `browser-coordination.py:153`). Diagnostic capture: `fleet-browser.service`
   exited `status=1` after 91 s wall / 47.8 s CPU on the client; terminal
   marker presence `{received_marker: false, owner: false, observer: false,
   owner_echo: false, observer_echo: false, body_available: true,
   workspace_available: true, pane_available: true, browser_errors: {}}` — the
   page loaded, the terminal marker never arrived. **The lifecycle scenario
   fragment never executed.** Drain: the driver killed its nine QEMU machines
   (eight `kill QemuMachine` lines plus the m1 line lost to console flush on
   failure; remaining processes die with sandbox namespace teardown at builder
   exit) and finished cleanup in 3.88 seconds; post-run host process
   inspection at 00:14 UTC found only the concurrent session's fresh QEMU set
   (etimes 189–199 s, started 00:11, after this run's driver exit at
   00:07:33) and neither driver nor QEMU residue from this run.
   The earlier attempt-1 window's identical-hash run by another session (live
   log at 18:24, same stage region) likewise produced no success store output,
   corroborating that the failure is not caused by this change (this change
   adds one test file, scenario ledger data and review prose; it cannot affect
   the terminal browser path) and not load flake (the two attempts differed in
   base, load profile and build schedule, and failed at the same assertion).
3. Per-stage results for attempt 2 before the blocker, all passed: runtime
   credentials/schema migration 20.36 s; browser/private listener separation
   0.27 s; disabled-host admission after real observations 120.46 s; shared
   guest trust prerequisites 26.11 s; failed ZFS collection holdback 10.75 s;
   missing guest image denial 8.00 s; three-Marshall idempotent VM 37.34 s;
   capacity race single-spend 326.93 s; profile egress and same/cross-host
   denial 198.88 s; Lilly release upgrade preserving running guests 345.20 s;
   encrypted credential-only update reconnect 298.43 s.

The `fleet` check's terminal-stage failure is a reproduced blocker on current
`main` (`f24661b2`) that precedes the lifecycle scenario; repairing the
terminal browser path is outside this improvement's bounded scope and remains
campaign work. The lifecycle machine evidence therefore honestly retains
`present` (never `recorded`), and the composed `fleet` check was last recorded
passing on 2026-09-16 (`docs/architecture/reviews/2026-09-16-nixos-fleet.md`).

## Contract review

The suite introduces four `@cc` verification contracts on its own declarations
(`committed-fixture-suite-preservation` reuse, `lifecycle-history-real-action-oracle`,
`lifecycle-history-model-step`, `lifecycle-history-outcome-model`,
`lifecycle-history-outcome-admission`, `lifecycle-history-complete-row-oracle`)
and exercises existing production contracts without weakening them:
`lifecycle-generation-transaction`, `lifecycle-recheck-after-lock`,
`vm-deletion-terminal-intent`, `vm-archived-idempotency-history`,
`outcomes-replay-identity`, `outcomes-current-generation-only`,
`outcomes-release-requires-physical-result`, `outcomes-bounded-crash-recovery`,
`operation-status-evidence`, `operation-first-terminal-evidence`,
`reservation-independent-held-resources`. No production contract changed.

## Remaining gaps

- **Native lifecycle matrix not recorded.** The composed `fleet` check fails
  deterministically at the terminal browser probe before the lifecycle
  scenario fragment executes (twice reproduced on `ab8b5b87`/`f24661b2` bases;
  see the execution record). `fleet/scenarios/lifecycle.py` coverage remains
  `present`; the first next action is a terminal-stage repair improvement,
  after which the lifecycle matrix can be recorded by rerunning `fleet`.
- Native interruption injection between Marshall's durable journal commit and
  the kernel/hypervisor effect (kill/reboot mid-flight) remains unexplored in
  machine tests; the property suite covers the journal/effect boundary model
  (unknown outcomes retain every hold, replay dedup, stale recordings) but not
  physical fault injection.
- Physical hosts, production deployment, hardware authenticators, SMTP, the
  complete-suite capacity race under real load, and any Inception validation
  remain excluded per campaign direction.
- The suite's `(resource, stream)` event-chain oracle trusts wall-clock
  `occurred_at` for ordering within streams; equal-timestamp ties are broken
  by UUIDv7 ids, which are generation-ordered in practice.
