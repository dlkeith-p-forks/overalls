# backup-retained-manifest-closure

P0; high source confidence; primary safety assertion `Always`, message **"Retained backup manifest references restorable component snapshots"**. The assertion is **missing** in the [fresh scan](../existing-assertions.md). A *retained complete* host manifest must reference every required successful guest, PostgreSQL (when configured), and host-state component, and each referenced snapshot must still restore the workload's recorded sentinel bytes. An incomplete capture need not publish a complete manifest. Sequential component capture does not promise one global instant.

## Evidence and fault history

`nix/modules/backups/runtime.py:122-225` records component IDs, requires owned cleanup, publishes a complete manifest last, then runs retention. `nix/modules/backups/restic.py:213-295` validates manifest shape and retained references before computing forget candidates; `journal.py:157-172` gates terminal state on cleanup. ADR-0070 is an accepted claim, not a fresh passing run. Interrupt component upload, manifest upload or its reply, journal completion, and a 128-item forget batch; retain an older point while a new run fails. Shared component IDs are a conditional branch, since no intentional ID-reuse source path was found. These source observations came independently from [focus 01](../discovery/property-candidates-01/backup-retained-manifest-closure.md) and [focus 03](../discovery/property-candidates-03/backup-recovery-manifest-reference-closure.md).

## Oracle, environment, and instrumentation

A workload ledger stores manifest ID and deterministic sentinel hashes. A separate Restic observer enumerates retained manifests/references and restores each referenced component into an isolated directory before hashing. Reconcile an uploaded manifest whose local ACK was lost by repository enumeration; never assume timeout means absence. Real Restic storage covers graph closure; TCG/native ZFS and real PostgreSQL restore are needed for physical content. Vary `keep_last` 1/2/3, guest count 0/1/configured bound, shared versus unique IDs if feasible, orphan grace around 86400 seconds, and forget batch 127/128/129. Distinct `Reachable` markers should cover shared retained references and post-upload lost reply; an optional `AlwaysOrUnreachable` can check the pre-forget set. No SDK callsite exists.

## Open questions

- Guest disk sentinel restoration in a disposable Lilly/ZFS fixture remains to be selected. `(partial: isolated host and database sentinels are in existing real-restic/native fixtures)`
- Cross-component consistency is sequential, without a global point-in-time guarantee. ADR-0070 states nominal RPO as thirty minutes plus jitter and capture runtime; outages may leave older last-good points. Neither claim expands this graph-closure property.

### Investigation Log

#### What policy defines cross-component consistency or RPO?

- Examined: backup capture order in `runtime.py:122-225`, Restic manifest/retention logic in `restic.py:213-295`, ADR-0070, and both focus evidence files.
- Found: complete reference graph and sequential component capture.
- Not found: simultaneous global snapshot or numeric RPO promise.
- Conclusion at first pass: retain the question as partial; assert reference/content closure only. Corrected by the dated entry below.

2026-10-13 correction:

- Examined: `docs/architecture/decisions/0070-host-recovery-backups.md:29-47,120-125` and `nix/modules/backups/runtime.py:122-225`.
- Found: ADR-0070 explicitly sets a thirty-minute schedule with up to five minutes' jitter and calls RPO “thirty minutes plus jitter and capture runtime”; outages can leave older points. It explicitly says independent captures have different timestamps and require quarantine reconciliation.
- Conclusion: the earlier “no numeric RPO promise” finding was incorrect. Resolve the policy question with this qualified nominal RPO; do not assert a global instant or hard outage bound.

#### Can a real fixture reuse one Restic component snapshot ID across two retained manifests?

- Examined (2026-10-13): `nix/modules/backups/restic.py:130-176,255-301` and `nix/tests/evaluation/backup-operators.py:510-565`.
- Found: the real Restic operator fixture captures components once, then publishes multiple real `host-manifest` points referring to the same host/guest snapshot IDs. Its generated retention test checks the union of references held by the retained points after real prune. Coordinator-created component uploads carry a distinct `run:` tag, so natural reuse by two separate backup runs is not shown.
- Conclusion: resolved for the retention property. Shared-ID closure is feasible with real Restic manifests; do not describe it as ordinary coordinator reuse.

#### Which isolated guest, database, and host sentinels can be restored safely?

- Examined (2026-10-13): `nix/tests/machines/backups/driver.py:187-258`, `nix/tests/evaluation/backup-operators.py:860-910,1190-1255`, and `nix/modules/backups/runtime.py:313-345`.
- Found: the NixOS backup machine restores deleted host bytes and a PostgreSQL archive into a separate `isolated` database, including a Cloak digest/keyring verification; the real Restic operator fixture verifies deterministic component bytes in fresh private targets. The restore CLI requires an empty absolute target and uses `--verify`.
- Not found: this backup machine's isolated real guest-disk sentinel restore. An Antithesis guest content oracle still needs a disposable Lilly/ZFS guest fixture and independent byte/hash ledger.
- Conclusion: partial for guest content, resolved for host/database sentinel choice. Use a private host file and a fixture-only database row; add a disposable guest disk sentinel only in a native guest fixture.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `storage`. hosted-restic-or-tcg-zfs-limited; independent witness: owned ZFS GUID/marker, independent Restic enumeration/isolated restore hash and fenced target. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

## Authored assertion snapshot

**Authored assertion snapshot (2026-10-13 15:03 UTC):** Primary `always` message is present at `antithesis/workload/backup/scenarios.py:73`. Real Restic IDs, production prune/inspect and independent per-reference restore hashes; selected guest/ZFS capture completeness is separate. It is outside the currently staged control-core selection. This records source presence, not a passing hosted or native result.
