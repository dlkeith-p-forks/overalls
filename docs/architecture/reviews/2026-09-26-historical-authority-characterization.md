# Historical-authority characterization

## Scope and architecture impact

Campaign improvement 117 characterizes and pins the **existing** protections
relevant to historical authority after a backup restore. It implements no new
design: no ADR-A (restore quarantine gate), no ADR-B (default-deny authority
re-enablement), no reconciliation workflow and no production behavior change.
Those remain proposal-only and are **blocked pending user delegation**; this
review records the findings and the new characterization pins as current-
protection evidence only.

Source-level review anchors: [ADR-0029](../decisions/0029-database-durability-and-recovery.md)
carries the historical-restore quarantine requirement (restore into an isolated
environment; never treat a readable restored database as current authority;
reconcile before activation); [ADR-0048](../decisions/0048-single-host-service-deployment.md)
carries it forward for the single-host fleet; [ADR-0070](../decisions/0070-host-recovery-backups.md)
implements isolated restore and explicitly excludes automatic reactivation.
The handbook scenario row stays `partial` with its delegation block preserved.

## Findings narrative (recorded, proposal-only boundary)

- A restore resurrects **DB-resident authority surfaces**: user sessions, SSH
  keys, passkeys and access grants reappear exactly as captured; durable host
  credentials re-arm post-backup revocations; durable AshOban triggers resume on
  the stale timeline. No code-level quarantine exists for these surfaces.
- The only existing protection mechanisms are scattered current-time fences:
  Lilly's per-placement monotonic command fencing against replayed
  {execution_epoch, generation} pairs, `:unauthorized`/stale-session fencing that
  stops runtime authority while preserving guests, uninitialized physical-unit
  gating, and guest-facing checks requiring a fresh incarnation observation.
  These characterize the *provisioner side only*; the Marshall control plane has
  no corresponding boot-time historical-authority gate.
- Unknown allocations are physically visible in measured headroom but are never
  reconciled into reservations; admission freshness lapses once hosts reconnect.
- The full quarantine design sketch (restore sentinel; fail-closed quarantine
  boot; default-deny authority classes; unknown-allocation reconcile report;
  order-gated finalization, later identified as candidate ADR-A/ADR-B) exists as
  **proposal text only**; implementing it requires new ADRs delegated by the
  user. Nothing in this change creates, flips or approximates that design.

## Characterization pins added

1. **Operator-mode isolation assertion** —
   [`nix/verification/tests/machines/backups/cloak-probe.exs`](../../../nix/verification/tests/machines/backups/cloak-probe.exs)
   sets `operator_mode` and boots the real release against the restore-drill
   databases. The probe now also records a hard guarantee: the supervision tree
   starts **exactly** `Marshall.Repo`, `Marshall.Vault`,
   `Marshall.Authorization.Cedar` and `Oban`; `MarshallWeb.Endpoint` is never
   started; Oban normalizes to no queues, no plugins, no stager and a
   non-leading isolated peer (`{Oban.Peers.Isolated, leader?: false}`), so no
   AshOban trigger or queue consumer can run against restored state. The driver
   assertion `"Marshall operator isolation verified"` must appear in the probe
   journal of the restored-database run.
2. **Lilly command-replay fence monotonicity** —
   [`lilly/test/lilly/control/historical_fence_test.exs`](../../../lilly/test/lilly/control/historical_fence_test.exs):
   seven fixed fence-characterization checks drive `Runtime.handle_info/2`
   exchanges: a regressed {execution_epoch, generation} replay is acknowledged
   only after rereading matching-or-newer durable intent (acked-without-rollback,
   receipt-follows-durable-intent); an exact duplicate is acked idempotently; an
   unknown-pool receipt fences the batch with `:command_store_failed` and no
   acknowledgement; corrupt durable storage fences instead of acknowledging. An
   `:unauthorized` result stops actor supervision, the terminal stream and
   clone/transfer workers, preserves durable placement intent, emits the fenced
   telemetry status and never reopens sampling or exchanges by itself; a
   `:stale_connection` result fences identically. Physical units unknown to
   durable intent and unsuccessful inventory scans must reject execution
   readiness. The Runtime initialization composition of that refusal with
   `:vm_reconciliation_required` remains source-inspection evidence, as scoped
   below.
3. **Guest-facing restored-authority refusals** —
   [`lilly/test/vm/actor_test.exs`](../../../lilly/test/vm/actor_test.exs) pins
   that a restored journal cannot resolve egress before a fresh running
   observation, alongside the pre-existing restored-journal ingress refusal and
   missing/superseded-owner egress refusals.

## Execution record

- Focused Lilly suite: `historical_fence_test.exs` and `actor_test.exs` passed
  **24 checks (1 property, 23 tests)** in 4.9 seconds, seed `117001`,
  `MIX_TEST_PARTITION=verify117`, `ERL_FLAGS="+S 6:6"`. This includes the seven
  fixed fence-characterization checks.

  The pinned actor test name is exactly: a restored journal cannot resolve egress before a fresh running observation.
- Native restore drill: `nix build .#checks.x86_64-linux.backup-recovery`
  **passed in 435 seconds** under the campaign MEDIUM native lock; result
  `/nix/store/lkzp46sxznaxvi9j348hapf4ff37pmv5-vm-test-run-overalls-backup-recovery`.
  That run covers the final driver source. The build log records
  "Marshall operator isolation verified" three times: every operator-mode boot in
  the drill (fixture creation, the rejected wrong keyring and the successful
  restored-database verification) passed the new isolation guarantee. This is a
  restore-drill isolation guarantee, not a historical-authority reactivation
  acceptance. An earlier identical-content run of the pre-reformat driver passed
  in 175 seconds
  (`/nix/store/j0dbx31d56k05m30n3q7j19lyvjnvdjm-vm-test-run-overalls-backup-recovery`);
  the two drivers differ only by a Ruff line join.
- No new or changed NixOS machine scenarios were introduced; the drill extends
  the pre-existing `backup-recovery` check.

## Mutants and defect verdicts

The scope prescribes no mutants for this characterization-only improvement; none
were injected. No bounded production defect was reproduced: the characterized
fences behaved as contracted, so no repair was attempted and no failing-direction
(serving-boot-accepts-revoked-authority) assertion was shipped — that target is
rejected by the coordinator and belongs to the delegated quarantine design.

## Remaining gaps

On 2026-10-10 the merged Lilly suite exposed an invalid assumption in the old
ambient-host inventory assertion: it expected refusal without creating an
unknown native unit or an unreadable scan. A readable empty slice on the cleaned
enrolled host correctly returned `:ok`. That assertion and its unused alias were
removed; production `Ownership` and Runtime fencing were unchanged. The original
24-check capture above remains historical, and its ambient-host result does not
establish controlled physical-inventory refusal.

The present [native unit-inventory scenario](../../../nix/verification/tests/machines/native-zfs/driver.py)
creates 56 real sleeping systemd units and cgroups, checks compact ID-only
inventory beyond the verbose-output frame, rejects omission of a live placement
from the expected set and rejects an unknown child cgroup. It tests the native
inventory helper, not Firecracker execution or the complete Runtime initialization
fence. Its incoming `d4499c4c` merged subtest **passed in 8.22 seconds** within
the complete `native-zfs` run that later failed unrelated auto-update resource
receipt validation: the fixture's `enrollment.json` lacks the required string
`revision`. Composed-driver lint/types and preceding native ZFS scenarios passed;
no complete suite pass or resource-tuning acceptance is inferred. The
[durable integration review](2026-10-10-durable-guest-identities.md) retains both
the initial pre-boot typing failure and this exact partial execution scope.

Later incoming `bee03919` replaces the removed ambient assertion with a
deterministic child-BEAM utility fixture: exact ID-only `systemctl` arguments
return a fixed unknown unit or a failed scan, with PATH isolated to that child.
Its incoming focused capture is unit evidence; it supplies neither native
cgroup ownership nor complete Runtime initialization-fence acceptance. Latest
combined execution is recorded separately.

- The runtime-init composition of `Ownership.verify_units/1` rejection into the
  host-wide `:vm_reconciliation_required` fence is pinned by code inspection
  (`initialize_actors/2`); runtime `init/1` requires root, systemd and an
  enrolled machine identity, so a direct in-process fence test is not available
  to unprivileged suites.
- DB-resident user authority (sessions, SSH keys, passkeys, grants) and durable
  host credentials still rely on operator conduct; only the provisioner fences
  are code-pinned. The coordinator's delegation block on the scenario row is
  preserved verbatim.
- Unknown physical allocations reflected in headroom remain unreconciled; no
  admission hold exists.
- No production deployment, multi-host HA or Inception validation is claimed.

## Delegation-required follow-ups (proposal-only, not implemented here)

- **ADR-A — restore quarantine gate**: boot-time sentinel distinguishing a
  restored database; fail-closed quarantine mode fencing serving listeners,
  background workers and durable triggers until reconciliation proves authority.
- **ADR-B — default-deny authority re-enablement**: post-quarantine reconcile
  report comparing durable authority against surviving physical state, with
  unknown allocations held unavailable and an order-gated finalization step.

## Final gates

On this tree before push:

- Lilly `mix precommit` passed: toolchain, ADR (124 decisions), contracts,
  logging, `compile --warnings-as-errors`, format, suite **421 checks passed
  (50 properties, 371 tests)** and forced Dialyzer **0 errors, 0 skips, 0
  unnecessary skips** (`MIX_TEST_PARTITION=verify117`, `ERL_FLAGS="+S 6:6"`).
- Marshall `mix precommit` (priv/HLDD-only project touch) passed: suite **1,187
  checks passed (138 properties, 1,049 tests), 2 excluded**, seed `423404`, and
  forced Dialyzer **0 errors, 0 skips, 0 unnecessary skips** against the
  session PostgreSQL 18.6 instance.
- Repo governance chain passed: `scripts/check_adrs.exs` (124 decisions),
  `scripts/check_hldd.exs` (reviewed per-group receipts), `hldd_views.exs
  --check`, `hldd_options.exs --check`, `hldd_coverage.exs --check`.
- `prek run --all-files` passed, including Ruff format/check and ty over the
  changed driver fragment; Nix `python-static` passed 676 files plus the
  reformatted driver.
- `nix build .#checks.x86_64-linux.hldd` passed (result
  `/nix/store/2x7ncl28c13y93nrkrdj0k706ygjk5d3-overalls-hldd-check`, 11 seconds).
