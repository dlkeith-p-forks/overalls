# ADR-0026: Host maintenance drain and retirement

- ID: ADR-0026
- Date: 2026-09-16
- Status: accepted
- Implementation: implemented
- Components: Marshall Compute, AshOban, operator commands, Lilly VM lifecycle
- Supersedes: none
- Superseded by: none

## Context

The accepted platform plan leaves host drain and replacement operations open.
Disabling admission alone does not stop existing guests or establish physical
quiescence. ADR-0005 retains disks on the original host and excludes migration.
The user's instruction to implement the plan authorizes this maintenance workflow.

## Decision

An explicit operator drain disables new provisioning and starts under the host
lock, records an idempotent Ash drain request with operator reference, and queues
AshOban work atomically. Its default behavior stops the host's guests while
retaining disks, addresses and host assignments. It never deletes guest data or
migrates VMs. Existing disable remains an admission control independent of drain.

Process at most twenty running VM intents per transaction. Reuse the existing
generation fencing, terminal invalidation and stop/outcome protocol. Enqueue
continuations with the same transaction; periodic scheduling recovers missed
work. Duplicate workers re-read under the host lock. Already stopping guests are
not restarted, and user deletion continues to completion. Suppress automatic
crash recovery while a host is draining. A stop request or elapsed time never
releases capacity; matching physical outcomes remain the authority.

Record maintenance-origin operations separately from user and recovery work.
Maintenance actions refer to their drain request and have no fabricated user
requester. Preserve durable request and transition history through AshPaperTrail.
Ordinary users cannot invoke or mutate drain/retirement resources.
The operator application includes Oban for insertion with consumers, scheduling
plugins, leadership and staging disabled. This extends ADR-0025's small operator
tree without adding background execution or listeners.

Confirm drained only after no live VM needs a running intent, every remaining
live VM has a confirmed stopped state, no compute reservation remains, and the
host has a fresh v2 execution-ready report. Unknown/stale hosts remain pending.
Keep historical confirmation separate from current report freshness. A resume
requires confirmation and a fresh ready host; it restores admission without
automatically restarting guests. Owners/managers explicitly start retained VMs.

Retirement additionally requires no non-archived VM, no retained allocation or
active address and a fresh report showing no managed pool allocations. Revoke
credentials and make retirement permanent under the host lock. Retain host,
machine identity and audit history; never recycle identity or infer cleanup from
disconnection. Replacement means enrolling a separately prepared physical host.
Local reinstallation/erasure is an explicit deployment operation after verified
cleanup, not a side effect of retiring a database record.

## Alternatives

Immediate reservation release would overcommit a host whose guests still run.
Admission-only disable cannot establish maintenance readiness. Migrating retained
disks contradicts the accepted first-release storage design. Impersonating VM
owners for operator stops would create misleading audit provenance. One unbounded
transaction for every guest would stall capacity and outcome processing.

## Consequences

A drain interrupts guest execution and terminal sessions while retaining storage
cost. Disconnected or irreconcilable hosts can remain pending indefinitely.
Maintenance is explicit and recoverable, with no forced cleanup override.
Deploy migrations and compatible Marshall code on all nodes before using the
workflow. The migration backfills historical unkeyed starts as recovery rather
than user requests; explicitly keyed starts and initial provisioning retain user
provenance. Roll forward: downgrade refuses to erase drains or fabricate requesters.
The existing v2 stop protocol needs no shared-wire revision.

Lilly defers stop/delete reconciliation when execution or network locks are
unavailable, as it already does for starts. A retry adds no physical outcome and
retains the last durable observation. First stops retain reservations until actual
confirmation; real cleanup failures still report unknown. This prevents benign
shared-lock contention from undoing confirmed stopped observations while many
VM actors reconcile on the same host.

## Invariants and verification

- Request, admission exclusion and initial job commit together or roll back.
- Concurrent admission/start/drain and repeated workers cannot bypass exclusion,
  create duplicate stop generations or release capacity prematurely.
- User stop/delete races and crash outcomes preserve intended fencing and data.
- Job failure rolls back its batch and continuation; work survives node changes.
- Unknown state never establishes quiescence, and retained disks prevent retirement.
- Three-node races and property tests cover coordination; real KVM verifies
  drain-to-stop, disk persistence and explicit restart after resume.

## Implementation evidence

[Drain resource](../../../marshall/lib/marshall/compute/host_drain.ex),
[coordinator](../../../marshall/lib/marshall/compute/drains.ex),
[lifecycle](../../../marshall/lib/marshall/compute/lifecycle.ex),
[outcomes](../../../marshall/lib/marshall/compute/outcomes.ex),
[operator commands](../../../marshall/lib/marshall/operations/cli.ex) and
[migration](../../../marshall/priv/repo/migrations/20260916032917_host_maintenance.exs)
implement maintenance intent, provenance, exclusion and confirmation.
[Drain tests](../../../marshall/test/marshall/compute/drains_test.exs) include
real AshOban batches, retained resources, stale reports, Cedar rejection and
properties. [Three-node tests](../../../marshall/test/marshall/compute/distributed_admission_test.exs)
exercise concurrent entry points, duplicate workers and transaction rollback.

[Lilly executor](../../../lilly/lib/lilly/vm/executor.ex) defers lock contention;
[actor tests](../../../lilly/test/vm/actor_test.exs) cover retained durable results.
The [KVM harness](../../../marshall/scripts/smoke_execution.exs) now exercises
host-wide maintenance, retained data, explicit restart and empty-host retirement.
Migration verification (`marshall/scripts/verify_maintenance_migration.exs` at overalls revision `9fe1e493`, repository deleted)
uses a disposable database to check the historical backfill and constraints.
See the [operator guide](../../operations/host-maintenance.md) and
[review](../reviews/2026-09-16-host-maintenance.md) for checks and limitations.
Marshall and Lilly gates, three-node tests, built-release commands, historical-data
migration checks and the complete three-guest KVM maintenance run pass.

## Open questions

Deployment-specific host shutdown/reinstallation and backup handling remain
operational work. Second-host and fleet acceptance remain required. No migration
or automated data-erasure capability is introduced.

## Related decisions

[ADR-0061](0061-maintenance-evacuation.md) adds a separate administrator-requested
evacuation workflow; this decision's stop-in-place drain remains unchanged.

[ADR-0005](0005-vm-lifecycle-and-storage.md),
[ADR-0006](0006-capacity-accounting.md),
[ADR-0016](0016-executable-generations-and-lifecycle.md),
[ADR-0017](0017-durable-vm-actors-and-host-ownership.md),
[ADR-0019](0019-terminal-session-and-writer-authority.md),
[ADR-0025](0025-protected-provisioner-enrollment.md).
