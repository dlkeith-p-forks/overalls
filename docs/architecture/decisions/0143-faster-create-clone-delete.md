# ADR-0143: Kernel copy offload, compressed local clone streams and identity-fenced deletion

- ID: ADR-0143
- Date: 2026-10-05
- Status: accepted
- Implementation: partial
- Components: Lilly Host, Lilly VM, Lilly Clone, Lilly Transfer, NixOS deployment
- Supersedes: none
- Superseded by: none

## Context

The user asked for faster VM creation, cloning and deletion, with every prior
assumption revalidated. The [measurement review](../reviews/2026-10-05-create-clone-delete-latency.md)
used read-only production data plus authorized live Porsche runs on Overalls.

**Create** took 33.8 s to provisioning readiness. Of that, 25.4 s was
materialization (`source: verified`, `method: copy`). VM datasets and `/nix/store`
images share pool `zroot`, which has block cloning active (ZFS 2.4.4), yet
`lilly-image-copy` fell back to a userspace copy. The cause is that `FICLONE`
refuses source and destination on different mounts with `EXDEV`, and the image
store is a separate bind mount.

**Clone** took 71 s for a same-host clone. The `copy` effect alone took 46.9 s:
a full uncompressed `zfs send | zfs receive` of about 3 GB logical
(about 1.3 GB physical, lz4 at about 2.2×), throttled to the 64 MiB/s peer rate
even though no network was crossed. Lilly also reported each effect result one
1 s tick late.

**Delete** has a median of 3.6 s but a p90 of 679 s and a maximum of 1,412 s.
Slow deletes showed `Dataset.mark_deleting` then a 5–23 minute wait before
`mark_deleted`, often with no concurrent control-plane operation. The deletion
precondition used the capacity observation, which requires two byte-identical
whole-pool reads. Those reads include the pool-wide `available`, so any write
anywhere in the pool (running guests, builds, other frees) turned an attempt
into `storage_busy`. That became `cleanup_failed`, which backs off up to 30 s
per attempt, and the retries were invisible because no stage was reported.

## Decision

- **Image materialization.** After whole-file `FICLONE`, try kernel copy offload
  (`copy_file_range`) before the userspace sparse copy. The helper reports
  `reflink`, `offload` or `copy`.
  - Fallback to the next strategy happens only on an allowlisted refusal
    (`EXDEV`, `ENOTTY`, `EOPNOTSUPP`, plus `ENOSYS` for offload), and only
    before any byte is transferred.
  - Partial transfer, a short read, repeated interruption or any other error fails
    without publishing.
  - `offload` makes no claim of block sharing. The kernel may clone or copy.
- **Clone and relocation streams.**
  - Exports send compressed (`zfs send -c`), keeping the snapshot name last.
  - Same-host clone streams use a separate positive operator rate,
    `services.lilly.localTransferBytesPerSecond`. It defaults to the helper's
    1 GiB/s maximum. Peer transfers keep `transferBytesPerSecond` (64 MiB/s).
  - The receive-side lineage, nonce and ownership verification is unchanged.
  - Lilly's clone runtime starts the next exchange immediately after executing
    an effect first offered in that exchange. Purposely re-offered effects
    (capture permit renewal) keep the 1 s polling cadence.
- **Deletion.**
  - Deletion uses an *identity observation*: the same reads, identity and
    backing checks, non-usage property stability, accounting validation and
    bounded resampling as a capacity observation. It tolerates usage-only drift.
  - Its usage values MUST NOT grant capacity, admission or allocation evidence.
  - Pool-lock contention during delete is retried without the cleanup-failed
    backoff, as resize already does.
  - Every unconfirmed attempt emits a fixed `stage` atom.

Authorization: the user's request and the approved 2026-10-05 plan ("make
cloning, new VMs and deleting faster; revalidate all assumptions"), including
merge-and-push deployment.

## Alternatives

- **Block-clone the clone's disk with a file-level reflink from the capture
  snapshot.** This would be fastest, but it bypasses the `zfs receive` GUID/nonce
  lineage that adoption verifies, so a new proof of provenance would be needed.
  It is deferred until compressed local streams are measured.
- **Unthrottled local streams (rate 0).** This violates the stream contract that
  production receivers use a positive operator rate. The separate rate keeps an
  operator bound without network-scale throttling.
- **Raise the backoff cap or retry count for deletes.** This hides the cause:
  under steady pool writes the exact observation keeps failing indefinitely.
- **Enable ADR-0130 templates first for create.** That remains planned, since it
  removes per-create hashing. Offload is independent and removes the copy cost
  whether or not templates are enabled.

## Consequences

- **Faster operations:**
  - Creates avoid a userspace copy of the rootfs when the kernel can offload.
  - Same-host clone copies move about half the bytes at up to 1 GiB/s instead of 64 MiB/s.
  - Delete latency no longer depends on unrelated pool activity.
- **Local clone I/O can now compete with guests** for disk bandwidth for a few
  seconds; operators can lower `localTransferBytesPerSecond`.
- **Compressed streams carry the source's on-disk compression.** Receivers
  already set `compression=lz4`, and the fleet uses lz4 throughout.
- **Delete telemetry:** dashboards can attribute delete retries by stage.

## Invariants and verification

- **Offload fallback rules.** Offload never falls back after progress, never
  publishes a partial file, and refuses unknown errors. Verified by Hegel
  properties `offload_refusal_before_progress_is_the_only_fallback`,
  `partial_or_short_offload_never_falls_back_or_publishes` and
  `kernel_offload_preserves_bytes_and_independence`.
- **Identity observations.** They tolerate only usage-counter drift; changes to
  identity or policy properties and incoherent accounting still fail. Verified by
  the StreamData properties in `lilly/test/host/zfs_test.exs`.
- **Native ZFS proof of offload: done.** The [image-copy machine test](../../../nix/tests/machines/image-copy/driver.py)
  shows `offload` on a cross-mount, same-pool materialization, with `bcloneused`
  growing by the full 8 MiB and the destination staying independent. The
  [zfs-lifecycle test](../../../nix/tests/machines/zfs-lifecycle/driver.py)
  shows delete refusing injected quota drift, then completing in 2.01 s despite a
  real pool write between its observations. The
  [clone matrix](../../../nix/tests/machines/zfs-guest/clone-matrix.py) passes
  real same-host clones with compressed exports.
- **Live comparison required.** The same Porsche cycle must be re-run on the
  deployed revision. **Not yet run.**

## Implementation evidence

- **Image materialization:**
  - [image-copy offload](../../../lilly/native/image-copy/src/lib.rs) and its [Hegel tests](../../../lilly/native/image-copy/src/tests.rs);
  - the [disk method mapping](../../../lilly/lib/lilly/vm/disk.ex).
- **Clone streams:**
  - [compressed send argv](../../../lilly/lib/lilly/transfer/source_snapshots.ex);
  - the [local clone rate](../../../lilly/lib/lilly/clone/effects.ex) with its [config validation](../../../lilly/lib/lilly/control/config.ex) and [Nix option](../../../nix/modules/lilly.nix);
  - [prompt clone result reporting](../../../lilly/lib/lilly/clone/runtime.ex).
- **Deletion:**
  - [identity observation](../../../lilly/lib/lilly/host/zfs.ex) with its [properties](../../../lilly/test/host/zfs_test.exs);
  - [staged deletion](../../../lilly/lib/lilly/host/zfs_dataset.ex) and the [catalogued stage](../../../lilly/lib/lilly/events.ex);
  - [delete contention retry](../../../lilly/lib/lilly/vm/executor.ex).

- **Native:** the [cross-mount offload machine test](../../../nix/tests/machines/image-copy/driver.py)
  passed, with `bcloneused_delta=8388608`.

- **Native:** zfs-lifecycle passed in 3624.76s, including delete under pool
  writes; zfs-guest-clone passed in 1641.22s.

- **Deployed** as `7106dd24` (2026-10-07). One live cycle: clone 71.0 s →
  43.3 s; create unchanged at about 40 s, because the materializing phase is
  dominated by per-create SHA-256 verification even with `offload`; deletes
  showed no retries. The prompt-reporting change spun on re-offered capture
  effects; it is corrected to follow up only for newly offered effects (see the
  [review](../reviews/2026-10-05-create-clone-delete-latency.md)).

- **Cadence fix deployed** as `d7413482`: clone 37.8 s (from 71.0 s), with the
  source restored at 13.4 s; capture renews about once a second. Three
  concurrent deletes took 5.3–8.2 s with no unconfirmed attempts. The copy
  remains about 22 s, bounded by native send/receive throughput.

Remaining: remove per-create hashing through the ADR-0130 template release;
consider same-pool block-cloned clones if the copy still dominates.

## Open questions

- Whether the fleet kernel and real image files reproduce the native block
  sharing. The post-deploy `vm.image_materialized` method and `bcloneused` will show it.
- Whether same-host clones still need file-level block cloning after compressed
  local streams are measured.

## Related decisions

- [ADR-0130](0130-verified-provisioning-fastpath.md): templates and readiness.
- [ADR-0037](0037-workload-placement-and-relocation.md): transfer streams.
- [ADR-0031](0031-sparse-zfs-storage-and-capacity.md): storage observation and capacity.
- [ADR-0112](0112-zfs-namespace-delete.md): fenced deletion.
- [ADR-0144](0144-nix-builds-exclude-guest-datasets.md): Nix build namespaces exclude guest datasets.
- [ADR-0145](0145-same-pool-block-cloned-clones.md): proposed same-pool block-cloned clones.
