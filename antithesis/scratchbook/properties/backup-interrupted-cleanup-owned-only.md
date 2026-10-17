# backup-interrupted-cleanup-owned-only

P0; high confidence; safety. Instrumentation **missing** per [fresh scan](../existing-assertions.md).
`Always(snapshot destruction matches journal nonce/dataset GUID/snapshot GUID
and local ownership marker; failed inspection retains cleanup journal)`; message
**"Backup recovery destroys only positively owned snapshots and retains uncertain cleanup"**.

Evidence: `nix/domains/system/backups/host.py:108-164` (`cleanup`, `release`) validates
nonce, dataset GUID, selected mount, snapshot GUID and local property, verifies
absence after destroy before journal unlink/fsync. `:192-211` (`prepare`)
publishes cleanup intent before zfs snapshot, updates GUID afterward.
`runtime.py:78-92` (`recover`) marks interrupted run cleaning/failed rather
than inventing completion. Backup CONTRACTS and ADR-0070 require owned cleanup;
Lilly-owned guest capture remains a separate physical pool authority boundary.

History: kill before snapshot, after creation before GUID receipt, during unmount,
after destroy before journal removal. Restart cleanup with ZFS/list/findmnt failing;
replace dataset with same name/new GUID or introduce same-named foreign snapshot
with missing/wrong/inherited nonce. Distinguish confirmed absence (successful
complete listing) from failed listing or inaccessible pool.

Oracle: independently enumerate real ZFS GUIDs, local ownership properties,
mount records and journal bytes before/after. Foreign resources unchanged;
uncertain cleanup remains visible/pending. Record every actual destroy invocation
and its independently matched authorization identity. A status pending counter
alone cannot prove the journal is retained or ownership was checked.

Guidance: `Reachable` **"Backup cleanup recovered its own snapshot created before GUID receipt"**
after journal null GUID is paired with matching local nonce; **"Backup cleanup retained intent after unavailable snapshot inspection"**;
**"Backup cleanup refused a same-name foreign snapshot during recovery"**.
Replay anchors at durable journal creation, snapshot effect, receipt and final
absence proof. Preserve real host-wide flock; never mutate live fleet snapshots.

Values: 0/1/2/8 owned snapshots, snapshot_guid null/matching/mismatched, matching/
foreign dataset GUID, local/inherited/missing marker, mounted/unmounted, list
success/no row versus actual inspection error. Hosted TCG Linux/ZFS guest can
exercise real storage and Python runtime; native NixOS machine validates deployed
privileges/mount namespaces. Pure mocked ZFS replies cannot establish ownership.

Open questions: Can the bounded hosted storage VM preserve independent cleanup
observation through pool inspection faults without granting observer mutation authority?
`(partial: source and native fixture support read-only observation; hosted split-view fault unproven)`

### Investigation Log

#### Can the bounded hosted storage VM preserve independent cleanup observation through pool inspection faults without granting observer mutation authority?

- Examined (2026-10-13): `nix/domains/system/backups/host.py:108-164`, `nix/verification/tests/evaluation/backup-workflow.py:578-733`, and `nix/verification/tests/machines/backups/driver.py:91-139`.
- Found: the cleanup path uses real `zfs list/get`, `findmnt`, local nonce, dataset GUID, snapshot GUID, and a durable descriptor; inspection errors retain the descriptor. Generated proof histories cover unavailable inspection and foreign identities, while the NixOS machine test kills a real upload and observes cleanup recovery. A separate read-only observer can enumerate GUIDs and descriptor bytes without using the cleanup service's mutation API.
- Not found: a hosted storage topology or executed fault that makes the production ZFS inspection path unavailable while a separate observer still reads the same pool. The machine test does not exercise that split-view fault.
- Conclusion: partial. Probe a disposable NixOS/ZFS VM with a narrowly faulted `zfs`/`findmnt` invocation for the cleanup unit, then compare independent read-only GUID/property/descriptor observations before and after retry. Do not claim the hosted fault is available from source alone.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `storage`. hosted-restic-or-tcg-zfs-limited; independent witness: owned ZFS GUID/marker, independent Restic enumeration/isolated restore hash and fenced target. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.
