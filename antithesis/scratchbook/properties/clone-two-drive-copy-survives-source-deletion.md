# clone-two-drive-copy-survives-source-deletion

**Candidate:** P0 safety; proposed primary `Always` message **"Cloned root and data drives retain independent acknowledged bytes after source deletion"**. Instrumentation is missing per `antithesis/scratchbook/existing-assertions.md`. `Always` is the right semantic fit because every *settled, published* copy of a captured marker must preserve it at every independent read; the property must not pass because one successful clone occurred. A separate `Reachable` message, **"Published two-drive clone survived source deletion and destination reboot"**, can guide the rare complete history, but is not the safety oracle. No code-side assertion is required to claim byte correctness; the workload reads both guests and ZFS. A SUT-side optional branch marker at the clone copy/adopt transition could help search, but it cannot certify content.

## Invariant and sequence

On an Inception source, create different incompressible marker files on the root filesystem and the filesystem hosted by `data.raw`; fsync both files and directories and independently record hashes, sizes, physical boot ID and source dataset GUID. Capture the accepted clone snapshot identity after the stable markers. Allow retries, interruption and acknowledgment loss during capture/copy/adopt. After the destination is published and boots, read *both* markers through the destination guest and compare to the pre-capture ledger. Assert the destination dataset GUID differs from source and `zfs origin` is `-`; both expected drive files exist with exact profile sizes and destination ownership. Mutate the source with new fsynced markers, then reread the destination to prove it still has the captured generation. Mutate the destination and reread the source to prove separation. Delete the source only after the destination is independently readable, wait for native source absence, reboot the destination, and reread both captured markers and its divergent write. Do not compare a post-capture source write to the captured baseline as though it were committed before the snapshot.

This is deliberately stronger than a placement success row or the one-file clone marker. GUID inequality alone does not prove either file's bytes. A successful guest marker echo is also insufficient unless the ledger independently captured pre-copy bytes and the post-copy read comes from the new physical boot/placement.

## Source trail and fault interleaving

- ADR-0072 (`docs/architecture/decisions/0072-multi-disk-workload-transfer.md:29-68`) says both drive files belong to one dataset stream and adoption must validate every expected drive. ADR-0155 (`:61-70`) retains one full stream for clones and relocations. ADR-0145 (`docs/architecture/decisions/0145-same-pool-block-cloned-clones.md:33-61,97-107`) specifies independent same-pool dataset origin and a journal-bound block copy, but omits content hashing at adopt; this external byte oracle is thus necessary.
- `marshall/lib/marshall/compute/clone_placement.ex:19-24,68-93` reserves before source interruption; `clone_coordinator.ex:171-254` gates capture after stop, restores a running source after capture, then copies/adopts/publishes. Race receipt loss around these transitions, source restoration, and post-capture source writes. The copied snapshot is the baseline, not the source's later live state.
- `lilly/lib/lilly/transfer/clone_copy.ex:30-53,72-90,252-306` verifies the private snapshot and copy journal for same-pool copies; `lilly/lib/lilly/host/zfs_dataset.ex:350-390` checks exact drive names and publishes every drive. Check cross-host full stream separately; same-pool block accounting is not cross-host proof.
- `nix/tests/machines/zfs-guest/driver.py:250-271` has an Inception two-drive clone with guest `data-write`/`data-read`, shape/owner checks and source deletion. `nix/tests/machines/zfs-transfer/driver.py:360-450` hashes two received files, but its data hash covers only the first 8 MiB. `nix/tests/machines/zfs-guest/clone-matrix.py:31-70,137-180` checks distinct GUID/origin, divergence, source deletion and `bcloneused` on a one-drive clone. These are test definitions, not a fresh combined execution of the stronger oracle.

## Values, boundary, questions

Use one-drive OSS as a control and two-drive Inception as the primary history; source originally running/stopped; same-pool block copy on/off; cross-pool and cross-host full stream; copy interrupted before/after each drive; source restart after capture; duplicate copy/adopt outcome; delete source after publication. Select random bytes independently per drive and include a marker offset past the first 8 MiB of `data.raw` so a prefix-only check cannot pass. Record source/destination dataset GUIDs and the physical guest boot witnesses. `bcloneused` is an additional same-pool mechanism witness, not a content oracle.

The complete property needs real ZFS plus the two-drive guest, and cross-host variant needs actual source/destination transfer. TCG overlay storage can test a narrower copy experiment, but it cannot inherit ZFS GUID/origin or Firecracker/KVM proof. No current run was performed.

**Open questions:** Which Inception guest path/mount exposes a stable, fsyncable marker on the `data.raw` inner filesystem, and how can the workload obtain a bounded independent digest without logging terminal bytes? `(partial: native two-drive guest commands and host shapes found; exact full per-drive digest witness not found)`

### Investigation Log

#### Which Inception guest path/mount exposes a stable, fsyncable marker and bounded digest?

- Examined: `nix/tests/machines/zfs-guest/driver.py:250-271`, `nix/tests/machines/zfs-transfer/driver.py:360-450`, `nix/tests/machines/zfs-guest/clone-matrix.py:4-13,31-70`.
- Found: A production-effect two-drive guest clone and separate native file-hash adoption exist; the latter hashes a prefix of `data.raw`, while the former checks guest data through fixture commands.
- Not established: An independently ledgered, fsynced marker at a chosen inner-filesystem path on both drives, including a late offset on `data.raw`, is not shown by those cited test passages. Inspect the guest helper/mount mapping before implementing this exact witness.
- Conclusion: partial; retain the proposed oracle and make the guest path an implementation prerequisite.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `no selected hosted template`. two-host-native-KVM-and-ZFS-required-for-full-claim; independent witness: two independently current VMMs, retained root/data GUID and bytes, committed handoff and actual DNS/SSH route. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.
