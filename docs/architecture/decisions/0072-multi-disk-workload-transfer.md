# ADR-0072: Multi-disk workload transfer

- ID: ADR-0072
- Date: 2026-09-19
- Status: superseded
- Implementation: partial
- Components: Marshall Compute, Lilly Transfer, Lilly VM, protocol, Porsche, Nix tests
- Supersedes: none
- Superseded by: ADR-0155

## Context

[ADR-0155](0155-stopped-only-relocation.md) removes pre-copy: relocation now
reserves the full multi-disk footprint once at the destination and no temporary
headroom on either endpoint; the "destination pre-copy requires twice that"
clause no longer applies. Full-footprint accounting, multi-disk streams and the
other requirements below are carried forward unchanged.

[ADR-0054](0054-inception-development-profile.md) added the Inception profile
with a fixed additional 256 GiB `data.raw` drive, and deliberately kept
Inception relocation unavailable "until the multi-disk transfer path is
verified". [ADR-0055](0055-queued-machine-cloning.md) excluded Inception from
cloning for the same reason. Both drives of a placement live as sparse files
inside the single per-placement ZFS dataset from
[ADR-0035](0035-zfs-only-provisioning.md), so the dataset-scoped snapshot and
`zfs send | zfs receive` stream of [ADR-0037](0037-workload-placement-and-relocation.md)
already physically carries every drive.

Observed facts: the exclusions were profile gates, not structural limits —
Marshall refused Inception at relocation and clone admission, the shared
protocol rejected Inception clone intents, Lilly adoption required the received
dataset to contain exactly one `rootfs.ext4` entry, import publication only
rebound the root file, stopped-evidence checked only the root file, and the
relocation/clone capacity math charged the root size alone for pre-copy
headroom, destination mirroring and temporary copy holds.

The user authorized on 2026-09-19 to lift both exclusions for relocation,
evacuation and cloning, without backwards compatibility, with structured
logging and unit, property and NixOS verification.

## Decision

Multi-disk workloads are portable through the existing single-dataset stream.
Relocation, evacuation and cloning MUST move every profile-derived drive of the
placement dataset; no per-drive streams, datasets or protocol fields are added.

Admission capacity arithmetic MUST use the full logical drive footprint
(`DiskLayout.bytes`) for source pre-copy headroom, destination mirroring
(`2 ×` footprint) and temporary copy holds, replacing the root-only sizes.

Destination adoption MUST require the exact profile-derived drive-name set with
per-drive single-link shape validation, and publication MUST rebind ownership,
mode and flush for every drive. Stopped evidence MUST require every expected
drive present with its exact size. No path may copy, truncate or recreate
imported guest data for any drive.

Relocation and clone destination selection MUST require the fresh native
Inception placement proof from host inventory, preserving ADR-0054 scheduling
eligibility; the source of an evacuation is exempt because the workload is
leaving it.

The profile-based exclusion reasons (`:relocation_not_supported` and
`:clone_not_supported`) are removed outright with no compatibility layer.
Evacuation blocker rotation recognizes `:clone_in_progress` so any future
unsupported interleaving rotates instead of wedging the campaign.

Snapshot crash consistency for the additional drive follows the existing
raw-disk semantics: the dataset snapshot captures `data.raw` as a file, and the
inner ZFS pool it contains replays its own intent log on boot, exactly as the
ext4 root does today.

## Alternatives

Per-drive child datasets with parallel streams were rejected: the
single-dataset layout already moves all drives atomically under one snapshot
lineage and one dataset GUID, while parallel streams would multiply transfer
keys, stream slots, journals and partial-failure windows without adding
integrity.

Keeping the exclusions and only repairing evacuation was rejected: the user
explicitly requested full multi-disk portability including cloning.

Compatibility shims for the removed error reasons were rejected per the
authorization above; fresh v3-only deployments do not need them.

## Consequences

Inception moves now reserve the full footprint (320 GiB default, more after
root growth) on both endpoints, and destination pre-copy requires twice that
physical headroom, so some moves schedule stopped copies where the previous
root-only math would have under-reserved. Stopped copies of a two-disk workload
take longer; user and admin copy reflects the longer window. Porsche and SSH
error surfaces shrink by two reasons. Evacuation campaigns containing Inception
workloads can now drain instead of skipping them.

## Invariants and verification

- Adoption fails on a missing, extra or substituted drive file for any profile.
- No code path recreates, truncates or reformats imported drives.
- Stopped evidence reports the disks absent when any expected drive is missing.
- Pre-copy requires full-footprint headroom at the source and twice the
  footprint at the destination; temporary holds equal the footprint.
- Destination selection for Inception requires the fresh nesting proof.
- Properties: clone source and destination workloads derive the same
  profile drive set. Units: admission, footprint holds, evacuation scheduling
  and proof refusal. Native: two-drive send/receive/adopt with resume, local
  clone copy, and fleet relocation/clone of an Inception guest with
  destination data verification.

## Implementation evidence

The [source-export custody review](../reviews/2026-10-05-source-export-adopted-children.md) adds fresh integrated111-second native process/lock evidence for completion and failure after escaped adoption. This preserves source permit, storage ownership and slot authority; it does not establish physical multi-disk transfer or storage-reader quiescence acceptance. Consumer/native ZFS/SSH and hosted gaps remain open; decision/status unchanged.

The protocol no longer rejects Inception clone intents and now documents the
single-stream drive-set contract in
[DiskTransfer](../../../protocol/lib/overalls_protocol/disk_transfer.ex); its
[tests](../../../protocol/test/disk_transfer_test.exs) cover multi-disk intent
round-trips and per-profile footprint properties.

Lilly adoption accepts exactly the profile-derived drive set and publishes
every drive in [ZFSDataset](../../../lilly/lib/lilly/host/zfs_dataset.ex)
(`received_entries?/2`, `publish_drives/2`) with updated `@cc` contracts, and
[stopped evidence](../../../lilly/lib/lilly/vm/executor.ex) requires all
drives. These paths run privileged and are verified by the native suites
below, not by unit tests.

Marshall admission no longer excludes Inception:
[relocation capacity](../../../marshall/lib/marshall/compute/relocation_capacity.ex)
uses the full footprint for pre-copy headroom, mirroring and temporary holds
and requires the Inception host proof for destinations;
[clone placement](../../../marshall/lib/marshall/compute/clone_placement.ex)
does the same for source headroom and holds;
[evacuations](../../../marshall/lib/marshall/compute/evacuations.ex) rotate
`clone_in_progress`. Admission and refusal structured log events exist in
[cloning](../../../marshall/lib/marshall/compute/cloning.ex) and
[relocation admission](../../../marshall/lib/marshall/compute/relocation_admission.ex)
with `clone_id`/`destination_vm_id` added to the metadata allowlist. Authenticated
receive and source receipt exchanges emit catalogued recorded/refused events
in
[relocation receives](../../../marshall/lib/marshall/compute/relocation_receives.ex)
and
[sources](../../../marshall/lib/marshall/compute/relocation_sources.ex), and
the provisioner API emits unauthorized-request events.
The web console no longer hides move or clone controls for Inception.

[Porsche](../../../porsche/lib/porsche/client.ex) no longer maps the removed
reasons. Admission, footprint, evacuation, proof-refusal and queue tests pass
in [inception tests](../../../marshall/test/marshall/compute/inception_test.exs),
and all protocol, Lilly, Marshall and Porsche gates pass.

Remaining native obligations are tracked in the
[review](../reviews/2026-09-19-multi-disk-transfer.md): the extended two-drive
`zfs-transfer` suite, the Inception clone leg of `zfs-guest`, and the fleet
Inception relocation/clone scenarios.

## Open questions

None.

## Related decisions

[ADR-0037](0037-workload-placement-and-relocation.md),
[ADR-0054](0054-inception-development-profile.md),
[ADR-0055](0055-queued-machine-cloning.md),
[ADR-0061](0061-maintenance-evacuation.md),
[ADR-0035](0035-zfs-only-provisioning.md),
[ADR-0053](0053-vm-disk-limit.md).
