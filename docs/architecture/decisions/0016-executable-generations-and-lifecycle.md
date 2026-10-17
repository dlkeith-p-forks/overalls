# ADR-0016: Executable generations and lifecycle outcomes

- ID: ADR-0016
- Date: 2026-09-15
- Status: superseded
- Implementation: partial
- Components: Marshall Compute, provisioner protocol, Lilly VM
- Supersedes: ADR-0014
- Superseded by: ADR-0035

## Context

[ADR-0035](0035-zfs-only-provisioning.md) replaces the ext4/provisioner-v1
compatibility portions and carries forward the other requirements. The decision
and implementation evidence below describe the historical revision.

The user authorized the complete platform, including persistent stop/start,
cleanup before release, bounded crash recovery and durable capacity. V1 receipts
and the local jailed driver establish separate foundations. Executing a receipt
without an image/address or releasing capacity on delivery would violate those
requirements. Timing out a systemd client does not cancel an accepted start job.

## Decision

Add explicit v2 HTTPS sessions and exchanges; retain v1 as receipt-only.
Preserve ADR-0014's immutable image catalog, integrity/availability validation,
admission limits and profile address allocation decisions by reference. Replace
its prospective requirement to acquire a profile lock during cleanup: archival
only removes a live allocation, so PostgreSQL's partial unique index and MVCC
preserve allocation safety without that lock. This avoids acquiring a profile
lock while an authenticated outcome transaction already owns its host lock.

Executable commands carry the admitted image digest and address slot with the
operation/VM/host/pool identity, generation and exact sizes. Both consumers validate
bounded collections and aligned sizes. The shared reservation cost is guest RAM
plus 64 MiB per VMM, separately from host-wide overhead. Backfill existing
reservations before enabling execution.

Bind v2 sessions to the enrolled hash of the physical host's machine ID and a
durable PostgreSQL epoch. Unique host identity prevents accidental duplicate
enrollment. This is an operator/credential trust boundary, not hardware
attestation. Lilly must also hold global physical-host ownership and bind its
state directory before automatic execution is enabled.

Lifecycle idempotency keys are scoped to user and VM. Use Cedar `manage` before
and after locking. Lock the image before the host for start; serialize lifecycle,
reservation and outcome mutations under the host row lock, then the VM row lock.
Cancel superseded pending/acknowledged operations, advance the generation and
enqueue the AshOban operation in the same transaction. New provisioning keeps its
existing profile-before-host lock order. Address release only removes an
allocation and needs no inverse-order profile lock.

Start requires an enabled verified image and fresh capacity on the original host.
Reacquire released CPU and guest-plus-VMM RAM atomically while retaining disk and
address. Reject exhaustion immediately. Accept stop/delete intent for a disconnected
host without changing allocations. Identical keys return their original operation,
including after archival; changed semantics conflict.

Physical outcomes carry immutable event IDs, per-VM sequences, operation ID,
generation, state, compute-empty/disk-present/cleanup-complete facts and bounded
reasons. Receipts prove only durable local intent. Validate and record outcomes in
the authenticated transaction with reports/receipts. Identical events replay;
conflicting IDs/sequences or host/operation bindings abort. Audit stale-generation
and reordered events without applying them to current state.

Only a matching current stopped result releases CPU/RAM. Only a matching deleted
result with empty compute, absent disk and completed cleanup releases everything
and archives the VM/address through AshArchival. AshPaperTrail retains VM changes.
Archived address slots can be reused while historical rows remain. A deletion's
accompanying receipt validates against historical VM ownership. Unknown outcomes
retain all allocations.

Marshall owns crash recovery. A confirmed unexpected crash retains compute and
enqueues a new start generation on the same disk at most three times in ten
minutes. Persist microsecond timestamps; retain future attempts conservatively
if the database clock moves backward. The fourth crash leaves the VM failed and
releases compute after physical fencing/empty confirmation. An initial execution
failure releases compute without automatic retry. Explicit start resets the retry
budget; stop/delete clears it and supersedes recovery. Guest reboot that exits
the VMM counts as a crash unless intent requests stop/delete. Guest poweroff text
alone does not establish empty compute.

Lilly persists a nine-byte launch intent: unsigned big-endian generation followed
by running/stopped/deleted/failed state. Updates hold an exclusive OS lock. A
non-setuid native guard runs inside the systemd service after `unshare`, immediately
before jailer. It holds a shared lock, reads private single-link intent and
executes jailer only for the exact running generation. The lock survives exec;
the [pinned jailer](https://github.com/firecracker-microvm/firecracker/blob/v1.16.1/src/jailer/src/main.rs)
closes inherited descriptors once its process belongs to the owned service tree.

Stop/delete writes newer non-running intent before stopping and proving the
unit/cgroup empty. Failure fences its own generation before proof. A delayed old
launch then either fails the guard or belongs to the unit cleanup must stop.
Failure cannot become running at the same generation; deleted intent is permanent.
Support stop/delete before materialization. Missing claims beside existing
resources remain identity errors. Local operator primitives may advance
generations automatically; executable actors must pass exact command generations.

## Alternatives

Receipt-based release can free occupied capacity. Lilly-only state loses budgets
and intent on host loss. Serial actors and killing systemd clients cannot cancel
asynchronous jobs after process death. Unlocking before exec leaves a launch race.
Reusing v1 would make existing receipt consumers silently incompatible.

## Consequences

Server, validated client and local driver are independently testable.
[ADR-0017](0017-durable-vm-actors-and-host-ownership.md) adds global host ownership,
VM actors, durable outcome delivery and restart reconciliation to the v2 runtime;
v1 remains receipt-only. [ADR-0018](0018-persisted-sharing-and-user-machine-access.md)
adds authenticated user provisioning. A v2 session alone does not establish
execution readiness.

Deploy migrations and new Marshall code across all instances before executable
provisioners; do not mix old admission code with the new RAM cost. This initial
platform has no live public provisioning rollout to preserve. Rolling back address
archival after slot reuse requires reconciliation: recreating the old unique index
must fail rather than erase history. Rounded timestamps cannot regain lost precision.

## Invariants and verification

- Physical cleanup, not delivery or elapsed time, permits release.
- A late launch cannot run after its reservation is released.
- Replays consume no extra reservation, operation or restart attempt.
- Superseded generations cannot undo state or trigger recovery.
- Three-node restart/provision races cannot overcommit; job failure rolls back
  intent and accounting.
- Real KVM verifies guarded service confinement, console lifetime and persistence;
  root faults cover never-started and delayed-start cleanup.
- Runtime restart/fencing, cross-host isolation and full user/TTY flows remain
  acceptance requirements.

## Implementation evidence

[Execution codec](../../../protocol/lib/overalls_protocol/execution.ex),
[shared sizes](../../../protocol/lib/overalls_protocol/vm_shape.ex) and
[properties](../../../protocol/test/execution_test.exs) implement v2 shapes.
[Lifecycle](../../../marshall/lib/marshall/compute/lifecycle.ex),
[outcomes](../../../marshall/lib/marshall/compute/outcomes.ex),
[event resource](../../../marshall/lib/marshall/compute/physical_outcome.ex),
[ledger migration](../../../marshall/priv/repo/migrations/20260915182941_add_execution_lifecycle.exs)
and [precision migration](../../../marshall/priv/repo/migrations/20260915184511_preserve_crash_timestamp_precision.exs)
implement durable state, capacity cost and archival.

[Lifecycle tests](../../../marshall/test/marshall/compute/lifecycle_test.exs),
[API tests](../../../marshall/test/marshall_web/execution_api_test.exs),
[three-node tests](../../../marshall/test/marshall/compute/distributed_admission_test.exs)
and [TLS tests](../../../marshall/test/marshall_web/provisioner_transport_test.exs)
exercise these boundaries. The [Lilly client](../../../lilly/lib/lilly/control/client.ex)
supports v2 explicitly; its runtime now supports executable v2 under ADR-0017.

[Native guard](../../../lilly/native/launch-guard/src/lib.rs),
[intent](../../../lilly/lib/lilly/vm/intent.ex),
[driver](../../../lilly/lib/lilly/vm/driver.ex),
[fault tests](../../../lilly/test/vm/intent_test.exs) and
[KVM smoke](../../../lilly/scripts/smoke_jailed.exs) establish local fencing.
The [review](../reviews/2026-09-15-execution-lifecycle.md) records results and gaps.

[ADR-0026](0026-host-maintenance-and-retirement.md) uses the existing stop protocol
for host maintenance and records user, recovery and maintenance origins separately.
Its host lock suppresses new starts and automatic recovery during a drain.

## Open questions

Protected enrollment and public lifecycle/sharing/TTY are implemented under
ADRs 0018–0025. Their [NixOS fleet acceptance](../../../nix/tests/machines/fleet/default.nix) now
passes across three Marshall and two Lilly machines; independent physical-host
and broader fault/load acceptance remain open.
Runtime ownership and durable actors/outcomes are implemented under ADR-0017;
its review records current evidence and remaining operational limits. Measure the
fixed VMM allowance across supported sizes and concurrent boot loads.

## Related decisions

[ADR-0003](0003-control-plane-coordination.md), [ADR-0004](0004-lilly-and-vm-actors.md),
[ADR-0005](0005-vm-lifecycle-and-storage.md), [ADR-0006](0006-capacity-accounting.md),
[ADR-0008](0008-identity-sharing-and-terminal.md),
[ADR-0010](0010-capacity-admission-transactions.md),
[ADR-0012](0012-provisioner-control-transport.md),
[ADR-0013](0013-capacity-collection-and-local-receipt.md),
[ADR-0014](0014-image-and-address-admission.md),
[ADR-0015](0015-jailed-execution-and-host-networking.md).

[ADR-0035](0035-zfs-only-provisioning.md) supersedes this decision as described above.
