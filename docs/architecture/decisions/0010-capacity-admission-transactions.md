# ADR-0010: Capacity admission transactions and Cedar entry points

- ID: ADR-0010
- Date: 2026-09-15
- Status: superseded
- Implementation: partial
- Components: Marshall Compute, PostgreSQL, Cedar, AshOban
- Supersedes: none
- Superseded by: ADR-0050

## Context

[ADR-0050](0050-usage-based-overcommit.md) replaces the capacity admission and
mutable resource-budget requirements while carrying forward unrelated requirements.
This record preserves the original rationale and implementation evidence.

The accepted platform plan requires admission to agree across Marshall instances
and reserve capacity before reporting acceptance. Retried requests, reordered
reports and a failed job insert must not create duplicate VMs or free capacity
that is still in use. This record specifies implementation choices within the
already authorized plan; it does not replace the lifecycle or network decisions.

## Decision

Model hosts, storage pools, VMs, reservations and operations as Ash resources in
`Marshall.Compute`. PostgreSQL remains authoritative. Use `Ash.transact` to
collect notifications and publish them after a successful transaction. Within
that transaction:

1. Lock an advisory key derived from the authenticated user ID and request key.
   A hash collision only serializes unrelated requests. Reusing a key with a
   different architecture/profile/size is an error; an identical retry returns
   the original VM, even if capacity is now exhausted.
2. Visit architecture-compatible, enabled hosts in ID order. Lock each candidate
   host row before re-reading freshness and its reservations/pools. All capacity
   reports and future allocation releases must take this same lock. This order
   prevents allocation transactions from deadlocking over multiple hosts.
3. Use effective CPU/RAM limits minus configured overhead and held reservations.
   Low CPU utilization never increases the budget. Disk admission uses the
   formula below. Reject when no fresh pool has all requested capacity.
4. Create the VM intent, reservation and operation, and enqueue the operation's
   AshOban trigger in the same transaction. Any failure rolls everything back.

[ADR-0014](0014-image-and-address-admission.md) extends this sequence with an
image shared row lock and profile advisory lock before host locks. The image ID
participates in idempotency; its minimum sizes and fresh host availability are
required. Address reservation joins the same atomic transaction before enqueue.

For a pool, schedulable disk bytes are:

```
max(0, min(total, free + credited_materialization) - overhead - retained_reservations)
```

Credit only materialized physical bytes matched by VM ID to a retained reservation
in that pool, capped at the reserved logical size. Unmatched/orphan entries earn
no credit. Reject a report where the sum of physical allocations exceeds used
space. Filesystem IDs must be canonical and unique within a host. Lilly must
reject overlapping/thin storage arrangements that alias capacity and collect
free space and allocation data consistently with its disk mutations. Those host
checks remain required before the remote admission path is enabled.

Marshall issues monotonically increasing connection epochs. Connect invalidates
old capacity; disconnect advances the epoch again so in-flight reports from the
closed connection cannot restore freshness. Reports must have an increasing
sequence, the current epoch and exactly one snapshot per enrolled pool. Apply the
complete report while holding the host lock. Invalid reports leave the previous
snapshot untouched; it still expires normally.

Default freshness is five seconds, configurable in milliseconds. A host's UTC
sample must be no older than that window and at most one second ahead of database
time. Use the earlier of receipt time and sample time as the effective timestamp.
Scheduling uses database time on every node. This requires synchronized host
clocks and deliberately rejects delayed samples. Network failure detection and
one-second sampling still need the authenticated Lilly transport.

Compile and validate the Cedar schema/policy at application startup using
`ex_cedar` 0.1.2. Ash's custom authorizer maps only explicitly listed actions.
Typed users can call provision; a typed in-process compute actor can coordinate
internal records. Unknown principals/actions, policy errors and missing handles
fail closed. Never deserialize the system actor from remote input. VM
owner/viewer/operator/manager policies are present and tested, but sharing and
record-scoped user APIs still require implementation. No user list/read endpoint
is enabled by the internal read actions.

The operation is a durable outbox. Its AshOban worker broadcasts an availability
hint; the operation stays pending until a host acknowledgement is reconciled.
The minute scheduler repeats notification. Relays must also poll pending rows:
PubSub delivery is not proof of host execution. Notification retries preserve
reservations and operation identity.

Use changes-only AshPaperTrail versions for VM intent, including owner ID and
action. Marshall logs JSON with an explicit correlation-metadata allowlist.
Credential encryption and archival are implemented separately under ADR-0012;
VM archival still requires physical cleanup.

## Alternatives

A node-local mutex cannot serialize requests on other nodes. Reserving after
job insertion leaves a failure gap. CPU idle percentage ignores already-promised
cores. Subtracting all reservations from disk free space charges materialized
disks twice. Crediting an aggregate managed-disk total can credit orphaned disks.
Receipt-time-only freshness can revive a delayed observation. Handwritten role
conditions cannot substitute for the required Cedar evaluator.

## Consequences

Admission serializes per host. The initial implementation reads that host's
reservation set; measured workload targets must guide later aggregation/index
work. Limits changing below reservations reduce new capacity to zero without
releasing existing allocations. CPU/RAM release, disk/address retention, cleanup,
generation fencing and recovery must preserve this transaction discipline.

The development-only Mishka 0.0.9 dependency pins igniter_js 0.4.11, whose optional
Rustler constraint conflicts with Cedar. Override that transitive package with
published igniter_js 0.5.0, which supports Rustler 0.38; retain Mishka and its
existing generated components. Verify its JavaScript API on the pinned runtime.
[ADR-0161](0161-monospace-web-presentation.md) later removed Mishka and its
generated components together with the igniter_js override; this clause is
historical.

## Invariants and verification

- Three independent BEAM instances with separate Repo pools cannot admit more
  held cores/RAM/disk than the shared budget.
- Concurrent identical requests have one VM, reservation, operation and job.
- A failed AshOban enqueue cannot leave a partially accepted VM or audit version.
- Reordered reports, reconnects and late disconnects cannot overwrite a newer
  connection or make its old observations current.
- Disk admission is unchanged when a reserved disk becomes materialized, apart
  from actual unreserved use, and grants no credit to orphan allocations.
- Cedar enforces the complete role/action matrix and denies direct user access
  to internal Ash actions and audit versions.
- Run distributed tests in `mix precommit`; `mix test --include distributed`
  explicitly includes them in an otherwise ordinary test invocation.

## Implementation evidence

[Admission](../../../marshall/lib/marshall/compute/admission.ex) and
[ledger transactions](../../../marshall/lib/marshall/compute/ledger.ex) implement
locking and atomic creation. [Budget](../../../marshall/lib/marshall/compute/budget.ex)
contains the admission arithmetic; [report ingestion](../../../marshall/lib/marshall/compute/host_reports.ex)
handles complete, ordered snapshots.
[Operation](../../../marshall/lib/marshall/compute/operation.ex) defines the
AshOban outbox trigger. [VM resource](../../../marshall/lib/marshall/compute/virtual_machine.ex)
includes intent and paper-trail versions.

[Cedar bridge](../../../marshall/lib/marshall/authorization/ash_authorizer.ex),
[compiled policy service](../../../marshall/lib/marshall/authorization/cedar.ex)
and [policies](../../../marshall/priv/cedar/compute.cedar) implement actual Cedar
entry-point authorization. [Configuration](../../../marshall/config/config.exs)
enables JSON logging.

[Database tests](../../../marshall/test/marshall/compute/admission_test.exs),
[three-node tests](../../../marshall/test/marshall/compute/distributed_admission_test.exs),
[report tests](../../../marshall/test/marshall/compute/host_reports_test.exs),
[budget properties](../../../marshall/test/marshall/compute/budget_test.exs) and
[Cedar properties](../../../marshall/test/marshall/authorization/cedar_test.exs)
cover the listed admission invariants. The
[review](../reviews/2026-09-15-capacity-admission.md) records validation and gaps.
The database suite now generates repeated same-key admissions after VM archival
and changed-shape refusals, comparing the complete local allocation and job
inventory after every prefix. The focused suite passed 14 checks; lost replies
and concurrent cross-node replay after an uncertain commit remain open.

Subsequent decisions add executable VM actors (ADR-0017), sharing (ADR-0018),
terminal authority and browser access (ADRs 0019–0022), and retained telemetry
([ADR-0023](0023-retained-capacity-telemetry.md)). These extend the original
admission foundation; fleet acceptance remains open.

The generated multi-node races in
[distributed capacity histories](../../../marshall/test/marshall/compute/distributed_capacity_race_test.exs)
exercise that transaction order end-to-end: admission/refusal/clone/relocation/
lifecycle calls race three BEAM replicas while the oracle reads committed rows
to verify startup-held boundaries, exactly-once respending of confirmed
releases, zero-row refusals and address lifetime. Synthetic execution outcomes
and settlement reports are host-committed state-entry fixtures; native execution
accounting is asserted separately. See the
[capacity race review](../reviews/2026-09-27-capacity-races.md).
[ADR-0012](0012-provisioner-control-transport.md) implements authenticated HTTPS
reports/commands, encrypted credentials, archived revocation and durable sessions.
[ADR-0013](0013-capacity-collection-and-local-receipt.md) adds the automatic
collector/exchange loop, effective limits and durable local receipt. Physical
disk mutation coordination is now implemented in the ADR-0015 local driver.
[ADR-0014](0014-image-and-address-admission.md) adds manifest-specific limits,
verified host image availability and coordinated profile address reservations.
[ADR-0011](0011-nixos-guest-and-console.md) adds the tested guest image and local
console primitive; admission now enforces its initial 512 MiB RAM / 2 GiB disk floor.
ADR-0018 now provides signed-in machine pages and provisioning actions; enrolled
hosts still default to disabled. A committed VM intent is not a running
Firecracker VM.

[ADR-0016](0016-executable-generations-and-lifecycle.md) adds lifecycle and physical
outcome transactions, CPU/RAM release/reacquisition, cleanup-gated VM/address
archival and the shared guest-plus-VMM memory cost. Three-node tests now cover
restart/provision races and lifecycle job rollback as well as initial admission.

## Open questions

Measure representative host/VM counts and request rates before making throughput
or 100-node claims. ADR-0016 and ADR-0017 now supply the executable protocol and
guarded runtime; ADR-0027 supplies connection-budget validation and ADR-0029
records local database recovery. Production HA/failure-domain acceptance remains
outstanding. [ADR-0031](0031-sparse-zfs-storage-and-capacity.md) adds ZFS
identity/accounting validation and a separate enrolled logical cap while retaining
this record's transaction order and ledger. The native Lilly backend now passes
real accounting/failure tests and concurrent admission in the
[NixOS fleet](../../../nix/tests/machines/fleet/default.nix). Physical performance and production
failure-domain evidence remain outstanding.

## Related decisions

[ADR-0031](0031-sparse-zfs-storage-and-capacity.md),
[ADR-0033](0033-nixos-machine-verification.md),
[ADR-0003](0003-control-plane-coordination.md),
[ADR-0005](0005-vm-lifecycle-and-storage.md),
[ADR-0006](0006-capacity-accounting.md),
[ADR-0008](0008-identity-sharing-and-terminal.md),
[ADR-0009](0009-assurance-and-testing.md).
