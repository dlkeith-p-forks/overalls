# ADR-0092: Portable workload bundles and visible current hosts

- ID: ADR-0092
- Date: 2026-09-22
- Status: accepted
- Implementation: partial
- Components: Marshall Compute, Marshall Web, Lilly VM, Lilly Transfer, protocol, Porsche, NixOS
- Supersedes: ADR-0089
- Superseded by: none

## Context

Fresh provisioning verifies an immutable image before copying its root filesystem,
but the original placement dataset contained only guest drives. Kernel and initrd
paths remained host-local image-catalog references. Restart, clone adoption and
relocation activation consequently required the same image to remain installed on
the executing destination even though ZFS had already transported the workload's
persistent state. This made an existing VM less portable than its transfer unit
and could strand it when catalogs differed between otherwise compatible hosts.

ADR-0089 exposed automatic user relocation through Porsche but deliberately hid
all topology in its public results. The current requirement instead makes the
stable host name useful placement information in Porsche and Marshall's machine
views while retaining internal host and placement identifiers as private control
authority. The user authorized both changes on 2026-09-22 and retained automatic
destination selection: users cannot name the destination host.

## Decision

Fresh VM creation MUST copy the verified image's kernel, initrd and closed boot
metadata into the same per-placement ZFS dataset as every guest drive. Metadata
contains only its version, immutable image identity, architecture, boot arguments
and exact artifact byte lengths. It contains no paths, credentials or digests.
The metadata marker is published last after the artifacts are flushed, and the
ordinary disk-ready marker is published only after the complete bundle validates.

The first creation remains the sole image-catalog and digest-verification boundary.
Restart, clone adoption, received relocation adoption and destination activation
MUST validate the placement-local bundle's closed shape and ZFS ownership lineage,
and MUST NOT consult a local image catalog or re-hash it against an image digest.
The kernel and initrd are mounted read-only into the disposable jail from the
placement dataset. A missing, substituted, malformed or wrong-workload bundle
fails closed and is never reconstructed on an existing placement.

Capacity reservations include a fixed upper bound for the portable kernel,
initrd and metadata in addition to the profile drive footprint. Clone and
relocation temporary holds inherit the same workload reservation arithmetic, so
transported boot data is never omitted from logical capacity commitments.

Marshall's authorized machine list and detail projections expose the current
host's stable name as `host`. They do not expose host UUIDs, placement UUIDs,
pool identity or source/destination internals. Owners and existing principals
with `manage` permission may use the existing web and Porsche relocation actions;
viewers may see the current host but cannot relocate. Marshall remains the only
destination selector, and neither interface accepts a host or placement input.

All other ADR-0089 decisions remain in force: durable Porsche receipts,
idempotency, current-authorization checks, bounded status, cancellation/retry
controls and physical-command wait semantics are carried forward unchanged.

## Alternatives

Synchronizing every image catalog before relocation was rejected because catalog
availability is deployment state, not authority over an already-created workload,
and it prevents the placement dataset from being self-contained. Keeping digests
inside the bundle and re-verifying at every boot was rejected because the trusted
creation copy and ZFS transfer lineage already define the immutable placement;
repeat hashing adds an unrelated catalog dependency and expensive boot I/O.

Embedding boot artifacts in host-local VM state was rejected because that state
is intentionally excluded from ZFS transfer. Exposing host UUIDs or accepting a
destination selector was rejected because stable display names satisfy user
observability without turning internal placement identity into public authority.

## Consequences

Every new placement consumes and transfers up to the reserved bundle allowance,
and snapshots include its boot artifacts. Existing pre-bundle datasets are not
silently upgraded; they fail validation. The authorized clean deployment deletes
those existing VMs before rollout, avoiding a compatibility importer whose trust
boundary would be ambiguous.

Image removal from a host no longer prevents an existing VM from starting,
cloning or relocating. Fresh creation still fails unless the selected host has
the enabled, verified image. Users gain a stable physical-host observation and
can request automatic movement from either supported interface without learning
or controlling internal placement identities.

## Invariants and verification

- Disk readiness implies the exact profile drive set and complete bundle exist in
  one owned placement dataset; bundle metadata is closed and workload-bound.
- Only fresh provisioning loads and digest-verifies the image catalog artifact.
- Existing start, clone and relocation paths work with no destination catalog
  entry and reject missing or malformed placement-local bundle files.
- Kernel and initrd mounts are read-only and sourced from the placement dataset.
- Reservation math includes bundle capacity for initial and temporary copies.
- Public machine projections expose only a current stable host name; relocation
  inputs never contain a destination.
- Protocol/property tests, application authorization/view tests, native ZFS
  adoption tests and the multi-host Porsche fleet scenario cover these boundaries.

## Implementation evidence

The closed metadata and capacity contract is implemented by
[WorkloadBundle](../../../protocol/lib/overalls_protocol/workload_bundle.ex) and
its [protocol tests](../../../protocol/test/workload_bundle_test.exs).
[Lilly bundle materialization](../../../lilly/lib/lilly/vm/workload_bundle.ex),
[disk lifecycle](../../../lilly/lib/lilly/vm/disk.ex), and
[dataset adoption](../../../lilly/lib/lilly/host/zfs_dataset.ex) make the dataset
self-contained and separate fresh provisioning from existing-workload restart.
[Marshall views](../../../marshall/lib/marshall/compute/views.ex) and the
[machine LiveView](../../../marshall/lib/marshall_web/live/machines_live.ex)
project host names and retain permission-gated automatic relocation.

Focused [Marshall SSH tests](../../../marshall/test/marshall/ssh/commands_test.exs),
[web tests](../../../marshall/test/marshall_web/machines_live_test.exs), native
[ZFS guest tests](../../../nix/tests/machines/zfs-guest/driver.py), native
[transfer tests](../../../nix/tests/machines/zfs-transfer/driver.py), and the
[Porsche fleet scenario](../../../nix/tests/machines/fleet/scenarios/porsche.py)
encode the intended acceptance.

The Porsche scenario now executes the complete public-SSH clone relocation
round trip. It creates the source and independent clone, replays each exact
relocation request ID to the same durable operation, verifies a new placement
and stable host name after each move, boots and checks the real guest data, and
proves the former host's ZFS dataset is absent. The `cloning-fleet` NixOS machine
test passed this scenario on 2026-09-22 in 889 seconds. This is native evidence
for the accepted Porsche/ZFS path; it does not close the remaining component and
negative bundle-validation obligations, so implementation remains partial.

Production acceptance on 2026-09-22 created source VM
`605ebc7f-b4c4-4432-98a6-60ec38c7682b` on Overalls, cloned it as VM
`123fa0fb-d4c3-472c-b116-2b54de2d1441`, relocated the clone to Dungarees and
then back to Overalls, and observed the clone running with each destination's
stable host name. Replaying request
`c592dfa8-de42-4fb1-9a31-3192e1fa8aa2` returned original operation
`c8a7896f-14a6-4845-85c3-ba3c96d1542a`; replaying request
`42073895-5e9d-42d5-bf7c-e01b72d41da8` returned original operation
`cccbaf8f-abd4-4723-aba0-ebf9492c98ec`. Both fixtures were then deleted and
their names were absent from the complete Porsche machine listing. This proves
the deployed two-host path and durable request idempotency; it does not prove the
separate malformed-bundle and catalog-absence cases. Full component gates and
remaining affected native test execution must still complete before the decision
can be marked implemented.

The [2026-09-25 production acceptance](../reviews/2026-09-25-production-clone-relocation.md)
could not repeat the round trip: an older clone with failed source restoration
retained Overalls' transfer slot. Fresh creation and guest access passed, but
cloning failed `source_unavailable` and relocation refused `transfer_busy`.
Bidirectional movement, independent clone data and opposite-direction concurrency
remain unverified on that deployed state; no bundle failure was established.

The [2026-09-24 readiness review](../reviews/2026-09-24-relocation-readiness-contention.md)
records a production Porsche relocation that transferred and activated correctly
but timed out while its readiness observer contended with VM reconciliation.
The bounded local lock retry preserves the original boot-proof deadline and
authority checks; it does not change transfer or capacity semantics.

The [restart recovery review](../reviews/2026-09-26-clone-restart-recovery.md)
repairs transient error propagation through existing-disk validation and adds
bounded failure stages. The native clone fixture uses `Driver.restart`; missing
or malformed portable bundles remain terminal even while owned receive staging
defers whole-pool readiness. The historical production
`disk_not_ready` event does not identify its failing predicate.

The [clone cancellation review](../reviews/2026-09-25-clone-cancellation-verification.md)
records a reproduced retained-disk error classification defect:
[Disk.ready/2](../../../lilly/lib/lilly/vm/disk.ex) now preserves retryable
`storage_busy` from dataset verification without replaying the locked callback.
The [isolated-peer regression](../../../lilly/test/vm/disk_test.exs) executes the
real disk/lock/bundle path with synthetic ZFS results; invalid identity and absent
bundle metadata remain terminal. Full Lilly and integrated Marshall gates pass;
fresh complete cancellation/control acceptance remains pending in that review;
upstream source-restart acceptance retains its separately recorded scope. This adds no authority or artifact
reconstruction and does not change this decision's partial implementation status.

## Open questions

None.

## Related decisions

- [ADR-0037](0037-workload-placement-and-relocation.md)
- [ADR-0046](0046-porsche-ssh-management.md)
- [ADR-0055](0055-queued-machine-cloning.md)
- [ADR-0072](0072-multi-disk-workload-transfer.md)
- [Architecture review](../reviews/2026-09-22-portable-workload-relocation.md)
