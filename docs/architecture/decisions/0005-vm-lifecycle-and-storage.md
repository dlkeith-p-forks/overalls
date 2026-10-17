# ADR-0005: VM lifecycle and local storage

- ID: ADR-0005
- Date: 2026-09-15
- Status: superseded
- Implementation: partial
- Components: Marshall compute domain, Lilly, storage
- Supersedes: none
- Superseded by: ADR-0037

## Context

Guests need persistent disks, explicit lifecycle actions and recovery after
unexpected termination. Capacity may change while a VM is stopped.

## Decision

Keep guest disks on their original host through stop/start. Confirmed stop
releases CPU and RAM reservations while retaining disk, address and host
assignment; a later start may fail immediately for insufficient capacity.
Provide no cross-host disk migration or automatic recovery onto another host in
the first release. Users select supported architecture, vCPU, RAM and disk size.

Reject capacity exhaustion immediately with a clear result; do not queue requests
waiting for capacity. Distinguish durable desired state from observed host state.
After a confirmed unexpected crash, restart from the existing disk at most three
times in ten minutes, then mark failed. An explicit stop or delete cancels
recovery. Deletion must confirm resource cleanup before archival/release of
retained allocations. These are accepted lifecycle requirements.

## Alternatives

Ephemeral disks would lose user state on stop. Cross-host recovery requires a
different storage system. Unlimited restart loops hide faults and consume
capacity indefinitely. A capacity wait queue conflicts with immediate rejection.

## Consequences

Host failure can leave disks unavailable. A stopped VM has storage cost and may
not restart immediately. Unknown outcomes require reconciliation and idempotency;
retries must not erase disks or release capacity still in use.

## Invariants and verification

- CPU/RAM become available only after a confirmed stop or safe cleanup.
- Local disk contents and host association survive normal stop/start.
- Failure to deliver an action is not evidence that it did not execute.
- Stop/delete prevents later automatic restart, including races with queued jobs.
- The retry window survives Lilly/Marshall restarts and never exceeds its budget.
- Test duplicate commands, crash loops, cleanup failures and stale observations.

## Implementation evidence

[VM resource](../../../marshall/lib/marshall/compute/virtual_machine.ex) persists
initial desired/observed state and generation with an owner and host/pool assignment.
[Operations](../../../marshall/lib/marshall/compute/operation.ex) and reservations
are created in the admission transaction under
[ADR-0010](0010-capacity-admission-transactions.md). These establish initial intent.
The [image smoke test](../../../lilly/scripts/smoke_guest.exs)
now verifies persistent guest disk content across a real VMM shutdown/start under
[ADR-0011](0011-nixos-guest-and-console.md). This is not control-plane lifecycle
reconciliation.

[ADR-0014](0014-image-and-address-admission.md) now adds immutable image selection
and [retained addresses](../../../marshall/lib/marshall/compute/network_address.ex)
inside admission. No address release action exists before physical cleanup.

[ADR-0015](0015-jailed-execution-and-host-networking.md) adds local
[persistent disks](../../../lilly/lib/lilly/vm/disk.ex), independent
systemd supervision, API shutdown, confirmed cleanup and deletion tombstones.
[ADR-0016](0016-executable-generations-and-lifecycle.md) adds transactional user
lifecycle, physical outcomes, bounded durable recovery and cleanup-gated archival
through [the coordinator](../../../marshall/lib/marshall/compute/lifecycle.ex)
and [outcome ledger](../../../marshall/lib/marshall/compute/outcomes.ex). Local
launch fencing is verified. [ADR-0017](0017-durable-vm-actors-and-host-ownership.md)
adds automatic runtime reconciliation and a real integration harness.

[ADR-0026](0026-host-maintenance-and-retirement.md) adds host-wide maintenance
stops through the same [lifecycle coordinator](../../../marshall/lib/marshall/compute/lifecycle.ex),
with distinct operator provenance and automatic recovery suppression.

## Open questions

[ADR-0035](0035-zfs-only-provisioning.md) requires sparse ZFS host backing only,
preserving retained placement, disk ownership and
cleanup-confirmed release. The
[lifecycle review](../reviews/2026-09-16-owned-zfs-lifecycle.md) records passing
native recovery, real guest flushes and abrupt simulated host loss. Independent
physical power-loss acceptance remains outstanding.

The [fleet review](../reviews/2026-09-16-nixos-fleet.md) records terminal and
lifecycle acceptance across two simulated provisioner hosts. ADR-0017 records
actor crash accounting, durable outcome delivery and deletion retirement;
physical failure-domain and broader workload/fault acceptance remain separate.

## Related decisions

[ADR-0037](0037-workload-placement-and-relocation.md) replaces the original-host-only
placement and v2 restrictions while carrying forward other requirements.

[ADR-0031](0031-sparse-zfs-storage-and-capacity.md),
[ADR-0003](0003-control-plane-coordination.md),
[ADR-0004](0004-lilly-and-vm-actors.md),
[ADR-0006](0006-capacity-accounting.md),
[ADR-0009](0009-assurance-and-testing.md).
