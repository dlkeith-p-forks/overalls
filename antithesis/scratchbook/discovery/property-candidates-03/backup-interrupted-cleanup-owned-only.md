# backup-interrupted-cleanup-owned-only

P0; high confidence; safety. Instrumentation **missing** per [fresh scan](../../existing-assertions.md).
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
