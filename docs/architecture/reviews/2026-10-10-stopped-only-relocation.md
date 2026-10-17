# Stopped-only relocation review (2026-10-10)

## Scope and authority

The user decided "Stopped-only; delete precopy": relocation stops the VM, sends
one full ZFS stream, imports, starts on the destination and deletes the origin
copy only after destination readiness. No backwards compatibility is required.
This review covers the cut across Marshall Compute, the shared protocol, Lilly
transfer/lifecycle code, the Marshall migration and NixOS machine tests, recorded
as [ADR-0155](../decisions/0155-stopped-only-relocation.md). It supersedes the
pre-copy clauses of ADR-0037, ADR-0061 and ADR-0072 and carries their other
requirements forward.

The checks and native results below belong to the stopped-only cut carried by
incoming `d4499c4c`, before integration with durable-identity feature `f1bd0e05`.
They are not executions of the combined tree. Current merged component and
native validation must be recorded separately. The later integration review's
documented transfer-journal discovery bound remains an unresolved source/contract
gap; see the [durable integration review](2026-10-10-durable-guest-identities.md).

## Production facts checked before the cut

Read-only queries against the production Marshall database (2026-10-10):

- `compute_relocations`: 18 rows, all `strategy = precopy`, `phase = complete`,
  `original_state = running`. No relocation is in flight.
- `compute_source_permit_requests`: 18 `baseline/superseded` and 18
  `incremental/applied` rows; 18 readiness and 18 cleanup requests.
- After applying the migration's JSON transform in a read-only query, all 36
  source requests, 18 readiness and 18 cleanup descriptors validate under the new
  `RelocationSource.command/1` and `Relocation.descriptor/1` codecs.

## Architecture assessment

### Stopped path traced end to end

The retained flow was read in code before deleting pre-copy:

| Step | Code | Observation |
| --- | --- | --- |
| Admission | `RelocationCapacity.prepare!/3` | First eligible pool in UUID order; one disk footprint, compute only for a running VM; no temporary hold. |
| Key | `Relocation.record_key` | `preparing -> checking_transfer`; cancellation/deletion phases unchanged. |
| Probe | `RelocationProbes` | Offered only for originally running moves before the stop; `ready_request/3` requires a completed probe issued within 30 s with 10 s lease left. |
| Stop | `RelocationCoordinator.step/3` | Stop enqueued only with a fresh probe, fresh endpoints and held reservations/slots; probe id recorded atomically (`relocation_stop_requires_probe`). |
| Copy | `RelocationSources.prepare_request!/1`, `Lilly.Transfer.Source` | Request only after `stop_confirmed?/2` (or unchanged stopped intent); Lilly requires a `:stop` command and confirmed unit/jail/network cleanup before the single `lilly-b` snapshot and permit. |
| Receive/import | `RelocationReceives`, `RelocationImports`, `Lilly.Transfer.Receiver`, `ZFSDataset.adopt/3` | Full stream into fenced staging, resumable via a token whose from GUID must be zero; adoption prunes `lilly-b`. |
| Handoff | `RelocationCoordinator.handoff/3` | Unchanged fenced commit of placement/epoch and activation outbox; source compute released, disks retained. |
| Readiness/cleanup | `RelocationReadinessState`, `RelocationCleanup` | Unchanged; source cleanup only after readiness. |
| Cancel | `RelocationRestoration` | Unchanged apart from removing the pre-copy temporary-headroom release. |

### Findings

1. High (fixed) — historical on-host state. Production retains 32 legacy
   import journals (Dungarees 13 `received_incremental`; Overalls 5
   `received_incremental` and 14 `received_full` from cross-host clones), all v1
   envelopes with `baseline_guid` and a stream kind, and 18 retired source
   snapshot journals naming a deleted `lilly-a` slot (read-only surveys,
   2026-10-10). Every one belongs to a placement whose claim is now a
   `deleted` tombstone binding the journal's exact nonce and filesystem GUID;
   none belongs to a live placement, and no host retains a ZFS snapshot.
   Reader trace under the new schema, before the migration:

   | Reader | Reached by | Legacy effect |
   | --- | --- | --- |
   | `ReceivedDataset.staging/1` (restart readiness) | every Lilly restart | parse failure returns `:none`; the old code returned `:none` too because an ordinary claim exists. No change. |
   | `ZFSDataset.delete/2` | VM delete, relocation source cleanup | reads only the ordinary claim; never the import journal. |
   | `ZFSDataset.adopt/3`, `Importer` | a relocation/clone import | only the new import's own fresh placement directory. |
   | `ImportCleanup.cleanup*/2`, `Disk.discard`, clone discard | cancellation/deletion of an unfinished relocation or clone | only that transfer's destination placement; no legacy transfer is unfinished. |
   | Start/stop/restart/resize | ordinary lifecycle | ordinary claim and execution journals only. |
   | Clone or relocate again | new transfer | source snapshot index in the live placement's metadata (no legacy history there); destination uses a fresh placement. |
   | `SnapshotIndex`/`SourceCleanup` history | retry of a source cleanup | only tombstoned former sources; Marshall issues none for finished moves. |
   | `Lifecycle.Diagnostics` | background scan | `.lifecycle-v1` archives only, validated by the unchanged `LegacyEvent` vocabulary. |

   No reader breaks, but the persisted state would not parse if a future path
   met it, so `TransferJournalMigration` rewrites both kinds at startup with
   adoption proof and exact archives (see ADR-0155). All 32 redacted production
   import shapes (nonce/GUIDs replaced) migrate and then validate under the new
   codec offline; synthesized unit/property tests and a native relocation-fleet
   subtest cover the rewrite, idempotence, refusals and restart/relocation/delete
   of a guest whose journal was rewritten into the legacy format.
2. Low — version skew. A clone or relocation started while Marshall and Lilly
   run different revisions fails closed on the stream shape and retries after
   both update. No relocation was in flight.
3. Info — archived v1 lifecycle diagnostics keep the historical state vocabulary
   in `Lilly.Lifecycle.LegacyEvent`; it is an archive validator, not live state.
4. Info — the native resume-token helper keeps its four-argument interface; Lilly
   always passes a zero from GUID so tokens naming a parent snapshot are refused.

No finding requires reconsidering ADR-0155.

5. Medium (fixed) — probe freshness versus cron. The first native
   relocation-fleet run timed out in pre-handoff cancellation: the coordinator
   accepts a probe only within 30 s, but a probe receipt did not schedule
   coordination, so the stop waited for a one-minute cron tick to land inside
   that window. `RelocationProbes` now schedules the relocation on the first
   probe receipt; a unit test fails when that scheduling is removed.

## Checks run

- `mix precommit` on the final tree: protocol 259 tests (100 properties), Lilly
  554 (109 properties; run with the worktree's host tools on PATH, because the
  shared devenv supplied an older `lilly-boot-log` from another checkout),
  Marshall 1432 (238 properties) with distributed tags and forced Dialyzer;
  `prek run --all-files`; `elixir scripts/check_adrs.exs`;
  `elixir scripts/check_hldd.exs`, `hldd_views.exs --check`,
  `hldd_coverage.exs --check`; observability trace schema regenerated.
- Native (`nix build .#checks.x86_64-linux.<name>`): `relocation-fleet` passed
  all 20 subtests in 4018 s on the final tree, including the legacy-journal
  subtest (journal rewritten to the pre-ADR-0155 shape, Lilly restart migrates
  it once with an archive, the guest stops, starts, relocates away and its
  imported disk is reclaimed). An earlier 19-subtest run (3991 s) after the
  probe-scheduling fix also covered
  connectivity-gated stop, return to a former host, stopped-guest move,
  pre-handoff cancellation with an unavailable destination, cancellation of a
  nonempty stream, daemon-restart recovery, endpoint-update resume, readiness
  retry, source pool pressure and destination ENOSPC. `zfs-transfer`,
  `zfs-lifecycle`, `zfs-guest`, `export-endpoint` and `ssh-transfer` (after
  fixing an assertion stale since 8bacd137) passed.
- `source-export` and `native-zfs` fail identically on the base revision
  (`{:error, :invalid_stream}` on the first export; driver type check before
  boot), so they are pre-existing failures outside this change.

## Follow-up

- Repair the pre-existing `source-export` and `native-zfs` machine tests.
- Run `cloning-fleet`, `audi-relocation-fleet` and the maintenance-evacuation
  browser test natively on this cut.
