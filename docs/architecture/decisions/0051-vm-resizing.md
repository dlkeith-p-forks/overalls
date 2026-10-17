# ADR-0051: Durable stopped VM resizing

- ID: ADR-0051
- Date: 2026-09-17
- Status: superseded
- Implementation: partial
- Components: Marshall Compute, Marshall Web, Lilly VM, protocol
- Supersedes: ADR-0050
- Superseded by: ADR-0053

## Context

The authorized implementation plan requests CPU/RAM changes and disk growth for
existing VMs, with a dedicated page, durable progress and retries. Existing claims
include resource sizes, so ordinary commands cannot safely rebind them. The
usage-based capacity branch supplies physical admission and startup holds.

## Decision

Add an owner/manager resize action serialized under host-before-VM locks. Record
original and target sizes, original power state, requester, generation and request
key. Exact retries retain their identity; changed payloads and stale forms fail.
Store original provisioning sizes independently of the current shape.

Reuse stop, dispatch, generation fencing and outcome ingestion. Add one physical
resize command with source/target resources and a stable resize identity. Store
immutable executable command snapshots. Require confirmed stopped execution before
changing any size. Journal exact original/target disk and VM bindings before
mutating existing storage. Resume only recognized states; never copy the image
or shrink a disk. Commit current sizes only against matching physical evidence.

Running VMs reserve full target CPU/RAM including VMM overhead before stopping;
replace previous startup holds without double charging. Pending disk bytes charge
only growth on the retained placement. Stop evidence cannot release future restart
holds. Recheck fresh capacity before restart; failure retains confirmed disk growth
and leaves the machine stopped. Fence failed restarts before releasing compute.
Unknown physical effects retain holds and block competing lifecycle, maintenance,
relocation and automatic recovery until reconciled. Retry resumes the recorded phase.
Originally stopped machines stay stopped without CPU/RAM admission.

Carry forward all other ADR-0050 decisions and rationale, including measured
physical admission, full-shape startup holds, freshness, best-effort pressure,
mutable host budgets, ownership, relocation and deployment boundaries. Resizing is
the sole new exception to retained shape immutability. Identity, image, placement,
address, data and sharing remain unchanged. Deploy schema and both consumers
together; no capability negotiation or legacy resize protocol is introduced.

## Alternatives

Live resizing does not fit the current VMM lifecycle. Image-copy initialization
would destroy guest data. Moving on insufficient capacity changes placement and
is outside scope. Memory-only progress loses authority after process failure.
Disk shrinking, cancellation and SSH resize commands remain outside scope.

## Consequences

Running machines incur downtime. Disk growth is irreversible and is preserved
through later failures. The guest grows its filesystem on boot. Resources exposed
as confirmed remain separate from pending targets. Draft URLs retain the original
expected generation; they never constitute authorization. Host pressure can reject
a restart even after physical resizing succeeds.

## Invariants and verification

Test malformed protocol shapes, stale/replayed operations, authorization/revocation,
idempotency, retained provisioning retries, draft reload and progress. Exercise
three-node resize/lifecycle/admission races, unknown effects and generation-bound
hold settlement. Native ZFS/KVM tests must prove existing data, filesystem growth,
CPU/RAM changes, interruption recovery and neighbor isolation. Run all three
application gates, assets, contracts and architecture validation.

## Implementation evidence

[Resize coordinator](../../../marshall/lib/marshall/compute/resize.ex) and
[request resource](../../../marshall/lib/marshall/compute/resize_request.ex)
implement persisted phases. [Command snapshots](../../../marshall/lib/marshall/compute/command_snapshot.ex)
pin dispatch payloads. [Resize page](../../../marshall/lib/marshall_web/live/resize_live.ex)
retains drafts and renders separate pending targets.
[Wire validation](../../../protocol/lib/overalls_protocol/resize.ex),
[driver](../../../lilly/lib/lilly/vm/driver.ex) and
[owned ZFS transitions](../../../lilly/lib/lilly/host/zfs_dataset.ex) implement
physical resizing. [Coordinator tests](../../../marshall/test/marshall/compute/resize_test.exs)
and [native fixture](../../../nix/tests/machines/zfs-guest/driver.py) provide
executable verification cases. Application, release and real ZFS/KVM checks pass; coordinated
deployment acceptance remains pending; see the [review](../reviews/2026-09-17-vm-resizing.md).

The [lifecycle coordinator](../../../marshall/lib/marshall/compute/lifecycle.ex)
explicitly rejects new start/stop/delete intent while a resize remains unfinished,
after locking and authorizing the VM. Exact existing lifecycle retries remain
read-only. This check preserves resize exclusion alongside the newer allowance
for lifecycle during safe relocation cleanup; the ordinary resize and three-node
competing-lifecycle tests cover the integration.

**Update (2026-10-13, [ADR-0166](0166-resize-hardening.md)):** the
alternatives clause leaving cancellation and an SSH resize command out of
scope is superseded: Porsche `resize` and pre-mutation cancellation exist,
refusals are logged with their reason, and a stop confirmed without its disk
is recorded for retry instead of rolling back the host exchange.

## Open questions

Production rollout and independent physical-host acceptance remain separate.

## Related decisions

[ADR-0050](0050-usage-based-overcommit.md),
[ADR-0017](0017-durable-vm-actors-and-host-ownership.md),
[ADR-0018](0018-persisted-sharing-and-user-machine-access.md),
[ADR-0037](0037-workload-placement-and-relocation.md).

[ADR-0053](0053-vm-disk-limit.md) carries forward these decisions and limits VM disks to 500 GiB.
