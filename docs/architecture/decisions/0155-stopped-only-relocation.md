# ADR-0155: Stopped-only relocation

- ID: ADR-0155
- Date: 2026-10-10
- Status: superseded
- Implementation: partial
- Components: Marshall Compute, Lilly Transfer, Lilly VM, Lilly Lifecycle, shared protocol, Nix tests
- Supersedes: ADR-0037, ADR-0061, ADR-0072
- Superseded by: ADR-0159, ADR-0198

> Superseded by [ADR-0159](0159-remove-legacy-compatibility.md) only for the transfer-journal migration and legacy lifecycle rebase. ADR-0159 carries every other requirement of this record forward unchanged.

## Context

[ADR-0198](0198-memory-suspension-and-demand-wake.md) replaces only the
memory-migration/stopped-source and cross-host-relay prohibitions where this
record carries them, and extends owner pins with automatic-suspension prevention
and wake. Unrelated requirements and historical rationale remain in force.


[ADR-0037](0037-workload-placement-and-relocation.md) introduced two transfer
strategies. Live pre-copy sent a baseline snapshot (`lilly-a`) while the source
ran, stopped it, then sent an A-to-B incremental (`lilly-b`). The stopped
strategy stopped the source and sent one full stream of `lilly-b`. Pre-copy was
preferred whenever both endpoints had one extra disk size of temporary headroom,
and the destination needed twice the disk footprint
([ADR-0072](0072-multi-disk-workload-transfer.md)).
[ADR-0061](0061-maintenance-evacuation.md) preferred pre-copy in evacuations and
required downtime approval only for running workloads that fell back to a
stopped copy.

Observed facts on 2026-10-10:

- Production holds 18 relocation rows, all `precopy`, all `complete`, originally
  running. None is in flight, so a single cut cannot strand a move.
- Pre-copy carried most of the transfer machinery: a second snapshot slot and
  lifecycle states, baseline/incremental/full stream kinds in every descriptor,
  baseline-to-incremental journal advancement, incremental resume lineage,
  temporary headroom on both endpoints, a receipt-gated stop and a second
  request kind with its own capacity rules.
- The only benefit was shorter downtime. A running source still had to stop for
  the incremental, and relocation already includes a guest reboot.

The user decided: "Stopped-only; delete precopy". Relocation should be simple:
stop the VM, send one full ZFS stream, import, start it on the destination, and
delete the origin copy only after destination readiness. No backwards
compatibility is required while the system is in development.

## Decision

Relocation has one flow, already implemented as the former `stopped` strategy:

1. Admission reserves exactly one disk footprint (plus compute for a running
   workload) on one destination pool and one transfer slot per endpoint. No
   temporary headroom is held on either endpoint: a stopped source snapshot
   cannot diverge.
2. Key preparation (`preparing -> checking_transfer`).
3. A running source is stopped only after a fresh authenticated destination
   connectivity probe, recorded atomically with the stop operation
   (`checking_transfer -> stopping_source`). An originally stopped source skips
   the probe and stop.
4. After the recorded physical stop, the source creates its single owned
   transfer snapshot (`lilly-b`) and grants one full stream (`copying`).
5. The destination receives the stream into fenced staging, then adopts it
   (`importing -> handoff`).
6. The fenced handoff commit moves placement and execution epoch and enqueues
   activation (`checking_destination`). Cancellation is possible only before
   this commit and restores the source.
7. Source disk, snapshots and transfer artifacts are deleted only after
   destination readiness (`source_cleanup -> complete`).

Remove the pre-copy strategy entirely: the `strategy` attribute and column, the
`baseline_copy` phase, baseline/incremental request kinds and the source permit
request `kind` column, receipt-gated stops, temporary relocation headroom and
the 2x destination check. Rename `final_copy` to `copying`. The protocol stream
becomes `{source_dataset_guid, to_guid}` for relocations and clones; source
requests lose `kind` and `from_guid`; the restricted SSH grammar becomes
`lilly-export-v4 <relocation>` and `lilly-resume-v4 <relocation> <token>`
(the probe verb is unchanged). Lilly keeps one snapshot slot (`lilly-b`), its
`SnapshotSet` lifecycle becomes `creating/ready/retiring/retired` and its
`Import` lifecycle becomes `receiving/received/retiring/retired`. Native ZFS
policy no longer admits `lilly-a`. Full-stream resume is kept.

Evacuating a running workload now always needs per-item downtime approval,
because every relocation stops a running workload; stopped workloads still need
none.

History is preserved, not rewritten: the migration drops the obsolete columns,
strips only the removed `kind`/`from_guid` fields from retained descriptors and
requests so the closed codecs still read them, and adds the probe-before-stop
constraint `NOT VALID` because finished pre-copy rows stopped without a probe.

Carry forward every other requirement of ADR-0037, ADR-0061 and ADR-0072
unchanged: fenced placement/epoch authority, per-relocation SSH keys and pinned
endpoints, cancellation-before-commit with source restoration, readiness before
source cleanup, explicit destination retry, evacuation campaign authority and
cohorts, and multi-disk footprint accounting.

## Alternatives

Keeping pre-copy as an option preserves shorter downtime at the cost of the
second snapshot slot, stream kinds, lineage checks, headroom rules and their
failure modes; the user rejected it. Keeping a vestigial `kind: "full"` field or
the `strategy` column with one value would retain dead branches and validation
for no information. Rewriting historical rows to `stopped` would falsify history.
Memory migration and shared storage remain rejected for ADR-0037's reasons.

## Consequences

Every move of a running workload has downtime for the full copy, proportional to
disk size and link rate, plus the guest reboot. Capacity is simpler and admits
moves that pre-copy's 2x check rejected. Evacuations of running workloads always
pause for approval. Rolling deploy is safe because nothing is in flight; a clone
or relocation started during the Marshall/Lilly version skew fails closed and
retries. Hosts retain journals written in the removed formats: received import
journals (`received_incremental`/`received_full`, `baseline_guid`, stream kind)
and retired source snapshot journals with a deleted `lilly-a` tombstone. A
one-way, idempotent Lilly startup migration (`TransferJournalMigration`, after
the profile migration and before actors start) rewrites an import journal only
when an ordinary live or tombstoned claim binds its exact nonce and filesystem
GUID, and a snapshot journal only when retired with deleted tombstones; it
archives the original bytes, never touches anything else and never refuses
startup.
Archived v1 lifecycle diagnostics keep their historical state vocabulary in
`Lilly.Lifecycle.LegacyEvent`.

The zero-in-flight observation and transfer-version skew scope above belong to
the stopped-only cut. A combined release with
[ADR-0158](0158-durable-guest-identities.md) must also satisfy its coordinated
identity migration and compatible-image requirements; transfer refusal during
version skew does not make mixed email-derived/generated identity serving
supported.

## Invariants and verification

- The Relocation state machine has no running-copy phase; every path to
  `copying` passes `checking_transfer`; cancellation is impossible after the
  handoff commit; terminal phases have no outgoing transitions; every
  non-terminal phase can reach a terminal one (property-based graph tests).
- A running source is never stopped without a fresh probe, and no snapshot or
  stream is granted before the recorded physical stop.
- Admission reserves one disk footprint at the destination and no temporary
  bytes on either endpoint.
- Descriptors, source requests and SSH verbs carrying removed lineage fields are
  rejected, not ignored.
- Retained production history (36 source requests, 18 readiness and 18 cleanup
  descriptors) validates under the new codecs after the migration transform.
- Native relocation tests move a running and a stopped workload with real ZFS and
  Firecracker, including cancellation before commit with source restoration.

## Implementation evidence

- Marshall: [Relocation state machine](../../../marshall/lib/marshall/compute/relocation.ex),
  [capacity](../../../marshall/lib/marshall/compute/relocation_capacity.ex),
  [coordinator stop gating and handoff](../../../marshall/lib/marshall/compute/relocation_coordinator.ex),
  [source requests](../../../marshall/lib/marshall/compute/relocation_sources.ex),
  [receipts](../../../marshall/lib/marshall/compute/relocation_receives.ex) and the
  [migration](../../../marshall/priv/repo/migrations/20261010120000_stopped_only_relocation.exs).
- Protocol: [descriptor stream](../../../protocol/lib/overalls_protocol/relocation.ex),
  [source requests](../../../protocol/lib/overalls_protocol/relocation_source.ex),
  [clone descriptors](../../../protocol/lib/overalls_protocol/disk_transfer.ex) and
  [tests](../../../protocol/test/relocation_test.exs).
- Lilly: [single snapshot journal](../../../lilly/lib/lilly/transfer/snapshot_journal.ex),
  [source snapshots](../../../lilly/lib/lilly/transfer/source_snapshots.ex),
  [import journal](../../../lilly/lib/lilly/transfer/import_journal.ex),
  [SSH grammar](../../../lilly/lib/lilly/transfer/export_request.ex) and
  [lifecycle resources](../../../lilly/lib/lilly/lifecycle/snapshot_set.ex).
- Legacy on-host journals: startup migration (`lilly/lib/lilly/control/transfer_journal_migration.ex` at overalls revision `9fe1e493`, repository deleted)
  and its property/unit tests (`lilly/test/control/transfer_journal_migration_test.exs` at overalls revision `9fe1e493`, repository deleted).
  ADR-0159 Push 6 deleted this migration, the import-journal `legacy`/`rebase_legacy`
  readers, the snapshot-journal `drop_legacy_slot` rewrite, the lifecycle
  `rebase_legacy` helper and their tests and `lilly.transfer_journals_migrated`
  event; those links are permalinks to the last revision containing them.
- Tests: [relocation state machine properties](../../../marshall/test/marshall/compute/relocation_state_machine_property_test.exs).

Native: `relocation-fleet` passed all 20 subtests in 4018 seconds on the final
stopped-only cut, including pre-handoff cancellation restore and legacy-journal
startup migration; the earlier 19-subtest pass took 3991 seconds. Transfer machine
tests passed (see the
[review](../reviews/2026-10-10-stopped-only-relocation.md)). Remaining: native
clone, Audi relocation and maintenance-evacuation runs on this cut.

ADR-0159 (Push 7) purged the 18 exported pre-copy relocations of archived VMs,
together with their foreign-key closure, and validated
`relocation_stop_requires_probe` for every row
(migration (`marshall/priv/repo/migrations/20261011200000_purge_pre_copy_relocations.exs` at overalls revision `033c8eef`, repository deleted)).
The retained history described above is therefore exported, no longer stored.

## Open questions

None for the decision. Downtime for very large disks is accepted; a future
bounded pre-copy would need a new ADR.

## Related decisions

[ADR-0037](0037-workload-placement-and-relocation.md),
[ADR-0050](0050-usage-based-overcommit.md),
[ADR-0061](0061-maintenance-evacuation.md),
[ADR-0072](0072-multi-disk-workload-transfer.md),
[ADR-0145](0145-same-pool-block-cloned-clones.md),
[ADR-0149](0149-independent-observability.md) and the
[stopped-only relocation review](../reviews/2026-10-10-stopped-only-relocation.md).
