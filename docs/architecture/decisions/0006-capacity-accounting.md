# ADR-0006: Capacity accounting and telemetry

- ID: ADR-0006
- Date: 2026-09-15
- Status: superseded
- Implementation: partial
- Components: Marshall hosts and scheduling, Lilly telemetry
- Supersedes: none
- Superseded by: ADR-0050

## Context

[ADR-0050](0050-usage-based-overcommit.md) replaces the capacity admission and
mutable resource-budget requirements while carrying forward unrelated requirements.
This record preserves the original rationale and implementation evidence.

The control plane must show available host capacity continuously and schedule
safely across multiple provisioners. CPU, memory and disk capacity/utilization,
IOPS and architecture are required. Low measured usage does not mean resources
reserved for existing VMs can be assigned again.

## Decision

Separate three concepts: relatively stable host inventory, timestamped live
measurements, and durable allocation reservations. Schedule atomically from a
shared ledger with no CPU/RAM overcommit, configurable host overhead and no
per-user quotas in the first release. Enforce disk space reservations against
the relevant storage pool. Accept caller-selected supported architecture, vCPU,
RAM and disk size only if image/host limits and fresh allocatable capacity allow
it. Reserve before accepting; capacity exhaustion rejects immediately.

Track the following with units, source, timestamp and unavailable/unknown values
rather than fabricated zeroes:

| Resource | Inventory/capacity | Live measurements and ledger |
| --- | --- | --- |
| CPU | Architecture, model, physical/logical cores, effective host constraints | Usage percent, reserved cores and schedulable cores |
| Memory | Physical/effective maximum and host overhead | Used/free/available bytes, percent used and reservations |
| Disk per pool | Total usable bytes and backing devices | Used/free bytes, percent used, reservations and allocatable bytes |
| Disk I/O | Device identity; configured or calibrated ceiling when known | Read/write IOPS, throughput, average latency, queue depth and busy percent |

Avoid counting the same backing device as independent capacity in multiple pools.
IOPS is monitor-only initially: do not promise or reserve per-VM IOPS budgets.
A maximum IOPS figure is only reported if configured or calibrated, with its
provenance; current IOPS does not establish a theoretical maximum.

Retain the latest one-second report, ten-second summaries for 24 hours, and
five-minute summaries for 30 days. All Marshall nodes use the same latest ledger;
stale/unreachable hosts are ineligible for new allocations. Expose freshness
because observations cannot be literally instantaneous across a network. These
requirements capture the user's selected capacity and retention policy.

## Alternatives

Scheduling from CPU idle percentage would overcommit guests that are quiet now.
Blindly subtracting reservations from disk free space can double-count already
materialized allocations. Reserving IOPS without calibrated isolation would
promise guarantees the first release does not provide. Per-user quotas and
fixed VM sizes were not selected.

## Consequences

Inventory, reservation lifecycle and measured usage need distinct fields and
reconciliation. Disk accounting must distinguish allocated physical space from
reserved future growth to avoid either double subtraction or oversubscription.
Telemetry volume needs aggregation and retention jobs; missing data must be
visible instead of presented as current free capacity.

## Invariants and verification

- Accepted concurrent allocations never exceed effective allocatable capacity.
- Reservations count once throughout provision/start/stop/delete/recovery retries.
- A stale report cannot make an unreachable host schedulable or release its VMs.
- Units and architecture compatibility are explicit and validated at boundaries.
- Disk pools never double-count a shared device or materialized reservations.
- Test random reservation/action sequences, concurrent database transactions,
  delayed/reordered telemetry, aggregation boundaries and retention expiry.

## Implementation evidence

[Lilly's inventory collector](../../../lilly/lib/lilly/host/inventory.ex) reads
Linux CPU topology and memory capacities, with explicit byte units and unknown
physical topology. [Inventory tests](../../../lilly/test/host/inventory_test.exs)
cover hyperthreading, malformed data and generated topologies/memory observations.
Verification is recorded in the [foundation review](../reviews/2026-09-15-toolchain.md).

[Admission](../../../marshall/lib/marshall/compute/admission.ex) now reserves
CPU/RAM/disk transactionally. [Budget arithmetic](../../../marshall/lib/marshall/compute/budget.ex)
and [host reports](../../../marshall/lib/marshall/compute/host_reports.ex) separate
reservations, inventory and observed utilization. The
[three-node tests](../../../marshall/test/marshall/compute/distributed_admission_test.exs)
verify concurrent admissions; [ADR-0010](0010-capacity-admission-transactions.md)
defines disk credit, freshness, report epochs and transaction order.

[Collector](../../../lilly/lib/lilly/host/collector.ex) now supplies cgroup-aware
CPU/memory limits, native ZFS identity/capacity and scoped pool I/O observations.
[ADR-0035](0035-zfs-only-provisioning.md) replaces the historical ext4/v1 paths;
the ZFS fleet scenarios cover freshness expiry on collection failure. Known zero limits stay fresh
and deny new admission. [ADR-0023](0023-retained-capacity-telemetry.md) adds
transactional summaries and AshOban retention. Sampling at broader fleet load remains open. ADR-0015 supplies pool mutation coordination.

## Open questions

[ADR-0016](0016-executable-generations-and-lifecycle.md) now makes initial and
restart reservations include the VMM's 64 MiB allowance. Its lifecycle/outcome
ledger tests compute release/reacquisition and retained disk/address accounting.
[ADR-0017](0017-durable-vm-actors-and-host-ownership.md) now integrates executable
actors and requires fresh v2 execution readiness for admission. Fleet load
validation remains incomplete.

ADR-0023 defines UTC aggregation boundaries, unknown counts, sample means and
physical retention. [ADR-0026](0026-host-maintenance-and-retirement.md) defines
maintenance exclusion and outcome-gated quiescence. Define unhealthy-device thresholds.
Measure the workload before replacing per-host reservation reads with
aggregated counters. Five-second freshness is now the configurable default in
ADR-0010; it is not proof that a disconnected VM stopped.

[ADR-0031](0031-sparse-zfs-storage-and-capacity.md) adds the selected ZFS backend:
disk reservations remain logical ledger commitments, with sparse physical
allocation and no ZFS reservation/refreservation. Its shared identity/observation
contract, Marshall budget enforcement and native Lilly sampling now pass
[real ZFS checks](../../../nix/verification/tests/machines/native-zfs/default.nix) and
[two-provisioner fleet admission](../../../nix/verification/tests/machines/fleet/default.nix). Physical-device
performance and representative concurrent-write/headroom measurements remain
outstanding. [ADR-0034](0034-mixed-workload-storage-tuning.md) records
unvalidated numerical headroom/tuning candidates, not additional accepted capacity.

The [generated capacity-race property](../../../marshall/test/marshall/compute/distributed_capacity_race_test.exs)
runs provision/clone/relocate/start/stop/delete mixes with injected
crash/failed/unknown outcomes at generated concurrency points on three
independent Marshall BEAMs. Its oracle reads only committed rows: no enrolled
capacity overrun with outstanding startup holds and settled running occupancy;
exactly-one-winner admission races; zero-row refusals; freed reservations
re-spendable exactly once; disk holdings retained on every non-confirmed-delete
terminal path; profile addresses stay unique until archival. It exposed the
reservation's pinned VMM footprint as the first-order sizing unit in test
geometry. Validation is tracked in the
[capacity race review](../reviews/2026-09-27-capacity-races.md).

## Related decisions

[ADR-0031](0031-sparse-zfs-storage-and-capacity.md),
[ADR-0034](0034-mixed-workload-storage-tuning.md),
[ADR-0003](0003-control-plane-coordination.md),
[ADR-0005](0005-vm-lifecycle-and-storage.md),
[ADR-0009](0009-assurance-and-testing.md),
[ADR-0023](0023-retained-capacity-telemetry.md).
