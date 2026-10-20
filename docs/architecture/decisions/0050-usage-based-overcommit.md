# ADR-0050: Usage-based overcommit and mutable host budgets

- ID: ADR-0050
- Date: 2026-09-17
- Status: superseded
- Implementation: implemented
- Components: Marshall Compute, Lilly Host, protocol, NixOS deployment
- Supersedes: ADR-0006, ADR-0010, ADR-0037, ADR-0048
- Superseded by: ADR-0051

## Context

The operator explicitly requested CPU, memory and disk overcommit, selected
actual-usage admission without ratios, best-effort pressure behavior, and required
each new VM's complete shape to fit current headroom. The previous ledger deducted
idle guests' full promises. Overalls consequently advertised no CPU despite low
physical usage. The operator also replaced the old host ceilings and duplicate
overheads, choosing 12 GiB system RAM and 128 GiB system disk margins.

## Decision

Use fresh scoped physical CPU/RAM consumption and ZFS availability for admission.
Keep requested shapes, ownership and lifecycle reservations, but do not subtract
settled guests' virtual promises from physical headroom. Bound concurrent startup
with durable full-shape holds, including the existing 64 MiB VMM memory allowance.
Only a matching fresh physical observation may replace a startup hold with actual
usage. CPU coverage requires a complete interval after verified startup. Unknown
or stale evidence withholds admission. Provision, restart, recovery and relocation
must use this policy under the existing database host lock. Disk copies and
temporary snapshot commitments remain physically budgeted until confirmed effects.

Overalls uses 32 logical CPUs, 116036 MiB guest RAM, a 1593 GiB physical guest quota,
and a 4 GiB ARC target, with zero additional scheduler overhead deductions. The
12 GiB host RAM margin includes ARC; neither margin is subtracted a second time.
Keep existing per-VM limits, sparse ZFS identity and ownership, and disabled swap.
Retain legacy logical_budget_bytes for enrollment compatibility, not aggregate
admission. Report assigned, observed and pending resources separately.

Guest CPU contention, guest OOM and write failure remain possible when workloads
grow together. No fixed overcommit ratio, ballooning, swap, automatic eviction or
automatic disk expansion is introduced. Current physical pressure rejects new
work; it cannot guarantee future physical availability.

Allow reviewed resource-only changes through the updater. Compare all installation
and Lilly binding fields except the exact bound quota and guest CPU/RAM ceilings;
verify native pool/dataset GUIDs, journal original receipts before mutation, and
apply properties to the existing slice/dataset without stopping guests. Preserve
all original receipt evidence. CPU/RAM/quota decreases require maintenance; ARC
target reductions do not count as reclaimed memory until observed. Boot reapplies
the exact declared policy. Publish updater support and verify it before publishing
the changed policy, because the old updater rejects such changes. Never mutate
database state backward on deployment failure.

Carry forward every other requirement of ADR-0006, ADR-0010, ADR-0037 and ADR-0048,
including authentication, architecture compatibility, transaction order, outcome
fencing, relocation identity, storage durability, single-host deployment limits,
freshness and telemetry retention. Their historical rationale is preserved.

## Alternatives

Fixed overcommit ratios were explicitly rejected. Ignoring pending starts would
allow concurrent callers to spend the same sample. Multiplying advertised host
capacity would misrepresent hardware. Removing the shared-root quota would let
guests consume capacity retained for the control plane. Ignoring entire binding
objects would silently authorize topology or ownership changes.

## Consequences

Virtual commitments may exceed physical budgets. Samples cannot predict future
load; failure remains best effort. Resource tuning requires a journaled narrow
exception to installation-binding immutability, not a general bypass. A corrective
commit must preserve increased ceilings if ordinary rollback would shrink them.

## Invariants and verification

- Concurrent admissions cannot spend the same outstanding startup headroom.
- Missing, reset, stale or wrong-generation samples cannot release startup holds.
- Physical cleanup alone releases durable ownership; low utilization cannot.
- Resource updates preserve running guests, native GUIDs and original receipts.
- Interrupted receipt updates resume from only known original/target states.
- Reject unrelated binding changes, decreases and native quota/identity drift.
- Verify application gates, distributed races, native guest/storage pressure and
  real two-stage updater activation; distinguish fixtures from production evidence.

## Implementation evidence

[Resource transition support](../../../nix/domains/system/auto-update/resources.py) and
the [updater](../../../nix/domains/system/auto-update/runtime.py) implement exact binding
comparison, native identity checks, journaled receipts and in-place application.
The [host profile](../../../nix/platform/hosts/profile.nix) publishes its reviewed policy;
the [module](../../../nix/domains/system/auto-update/default.nix) reapplies it at boot.
[Usage sampling](../../../lilly/lib/lilly/host/usage.ex) constrains headroom across
cgroup ancestors and host availability. [Budget](../../../marshall/lib/marshall/compute/budget.ex)
and [startup settlement](../../../marshall/lib/marshall/compute/startup_holds.ex)
separate measured use from pending starts and retained ownership. Settlement
requires interval coverage of the current placement/epoch/generation and the
latest authenticated outcome; disk also requires a native owned allocation.
[Restart admission](../../../marshall/lib/marshall/compute/restart_capacity.ex)
protects manual starts, recovery and relocation activation. The
the retired Overalls host configuration declares new ceilings;
[operator reconciliation](../../../marshall/lib/marshall/compute/capacity_policy.ex)
updates scheduler margins using host-locked Ash actions before serving.
The [review](../reviews/2026-09-17-usage-based-overcommit.md) records executed
checks and deployment evidence separately from implementation.
[The generated capacity-race property](../../../marshall/test/marshall/compute/distributed_capacity_race_test.exs)
verifies the settled-versus-startup split under three-node admission/outcome
races: committed startup-held shapes and settled running occupancy never
exceed enrolled capacity minus overheads, settlement clears startup holds only
through real coverage evidence, and a confirmed delete's released capacity is
spent exactly once by racing admissions. Its settlement reports measure
occupied placements from committed reservation/outcome rows, mirroring honest
host measurement. See the
[capacity race review](../reviews/2026-09-27-capacity-races.md).

Resource-journal replay validates the enrollment receipt's nested storage
evidence while preserving its independently authenticated current revision; the
[resource regression test](../../../nix/verification/tests/machines/auto-update/resources_test.py)
covers retry after later re-enrollment, and updater preflight maps failures to
the helper's closed diagnostic reasons.
The [real guest fixture](../../../nix/verification/tests/machines/zfs-guest/driver.py) passed
aggregate CPU/RAM/disk promises above physical budgets and CPU-pressure recovery.
The [fleet suite](../../../nix/verification/tests/machines/fleet/default.nix) passed concurrent
startup admission, retained-disk restart, deletion, stale-capacity rejection,
updates, terminal recovery and authority revocation. Overalls completed both
deployment stages with unchanged original guest PIDs and native storage identity.
This status covers the capacity/resource-update decision; inherited platform
requirements retain their separately recorded verification boundaries.

## Open questions

Native acceptance passed. Production workload characterization and sustained
contention performance remain operational measurements; this decision does not
promise future capacity or protection from guest OOM or quota write failure.

## Related decisions

[ADR-0006](0006-capacity-accounting.md),
[ADR-0010](0010-capacity-admission-transactions.md),
[ADR-0037](0037-workload-placement-and-relocation.md),
[ADR-0048](0048-single-host-service-deployment.md).

[ADR-0051](0051-vm-resizing.md) carries forward this policy and adds durable VM resizing.

The inherited ADR-0010 idempotency requirement gains [lost reply evidence](../reviews/2026-10-05-admission-lost-reply.md): actual authorized admission commits before observed worker or whole-BEAM loss; concurrent three-node retries return the original live or archived VM without added allocation rows. This does not establish HTTP loss, pre-commit ambiguity or native VM execution.
