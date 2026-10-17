# Storage capacity and ZFS rollout

ZFS is the only provisionable host backing storage under
[ADR-0035](../architecture/decisions/0035-zfs-only-provisioning.md). All enrollment,
runtime configuration and control exchanges use provisioner v3. Guest filesystems
remain ext4 inside sparse raw files. There is no ext4 host option, legacy data
conversion or mixed-version rollout. Use fresh development state and deploy
Marshall/Lilly together; never reinterpret old pool identities.

The [native reader](../../lilly/lib/lilly/host/zfs.ex) checks actual mount/GUID
identity, supported backing extents and coherent ZFS property observations.
The [ownership layer](../../lilly/lib/lilly/host/zfs_dataset.ex) binds child GUIDs,
private host/pool/VM claims and disk readiness before granting physical credit.
Creating or deleting datasets earn no credit. Missing initialized storage,
conflicting ownership and unrecognized descendants withhold the pool report.
Equal consecutive reads do not reserve space or freeze guest writes. Native ZFS
read/write IOPS and throughput use a separate logical whole-pool interval source;
see the scope and precision below.
See the [lifecycle review](../architecture/reviews/2026-09-16-owned-zfs-lifecycle.md)
for machine evidence and remaining acceptance.

## Enrollment

The protected enrollment workflow accepts version 3 with ZFS pools only. Each
entry has exactly these fields:

```json
{
  "name": "guests",
  "storage": {
    "backend": "zfs",
    "zpool_guid": "123",
    "dataset_guid": "456",
    "dataset": "tank/lilly"
  },
  "overhead_bytes": 1073741824
}
```

These GUIDs are illustrative. Read actual GUIDs from the managed host; never use
an ext4 filesystem ID for ZFS. GUIDs are canonical unsigned 64-bit decimal
**strings**. Marshall derives `zfs:POOL_GUID:DATASET_GUID` as the filesystem
identity. No physical space is reserved by this ledger; Lilly separately
validates the required dataset properties. The example headroom is an explicit
input, not a measured optimum. The host tool keeps headroom strictly below the
reviewed physical guest capacity (the Hetzner guest quota, or the summed raw size
of the EC2 local guest disks) so an enrolled pool can always admit something.
There is no logical commitment cap. Marshall stores no pool budget (ADR-0159 Push 11
dropped the column) and refuses an enrollment pool that supplies the retired
`logical_budget_bytes`.

PostgreSQL prevents two schedulable parent datasets from the same zpool on one
host and rejects contradictory backend fields.
New pools start without fresh capacity. The migration removing these fields
refuses while any ZFS pool remains enrolled; do not downgrade a live ZFS host.

## Reports and admission

V3 reports retain the existing host timestamp, sequence, capacity and pool fields.
A ZFS pool adds a `storage` object containing its four identity fields plus:

| Field | Meaning |
| --- | --- |
| `used_bytes` | Physical dataset/descendant use, equal to `total_bytes - free_bytes`. |
| `logical_used_bytes` | ZFS logical use, independently observed; not a commitment or physical credit. |
| `quota_bytes` | Configured parent dataset quota or `null` when absent. |
| `compression_ratio` | Positive numeric multiplier, observed independently. |

`free_bytes` means effective ZFS available bytes, including ancestor/pool/quota
constraints. `total_bytes` is physical use plus that availability. Allocation entries are exclusive physical
bytes attributable to owned VM commitments. The collector rejects unsupported snapshots/clones,
reservations, unowned descendants and incoherent samples. A schema-valid report alone cannot establish physical ownership.

Marshall checks identity and accounting under the existing host-row lock. A
missing or contradictory pool rejects the whole report. Reports without ZFS
observations and retired provisioner v1/v2 exchanges are rejected.

[ADR-0050](../architecture/decisions/0050-usage-based-overcommit.md) replaces the
aggregate logical ceiling with physical admission. Available disk is
`max(0, F - H - P - T)`: current ZFS free bytes F, configured scheduler margin H,
pending disk startup holds P (full size minus only their own observed physical
allocation), and temporary copy/snapshot holds T. Once fresh current-generation
coverage and native allocation settle a startup, its virtual size is no longer
deducted. Ownership and requested size remain recorded, including while stopped.
No logical budget caps total virtual assignments: Marshall does not store one,
and Lilly, its Nix module and the host tool no longer carry one (ADR-0159). Deletion only increases observed free space when ZFS
reports reclamation; compression cannot manufacture unobserved physical credit.

CPU and RAM admission use fresh cgroup/ancestor/host headroom less full-shape
startup holds. Unknown usage withholds new admission. Every new VM, restart or
relocation activation must fit current headroom; existing low-usage guests may
collectively promise more than the physical capacity. Future contention, OOM and
write failure remain best effort. Overalls protects system RAM and disk through
physical guest ceilings, with zero duplicate scheduler margins.

Retained telemetry labels physical use, logical use, quota and compression
separately, with byte/ratio units and pool/dataset identity.
Unknown quota remains unknown. Historical observations never authorize admission.

See the [implementation review](../architecture/reviews/2026-09-16-zfs-capacity-contract.md)
for verification and outstanding real ZFS/Firecracker acceptance.

## I/O scope and precision

Native pools report read/write operations per second and bytes per second from
one batched OpenZFS interval. `io.source=openzfs_zpool_iostat`, `scope=zpool` and
`kind=logical` include activity outside Lilly's dataset. Do not interpret these
as physical disk or per-VM performance. Capacity is independently labeled with `capacity_source`
and `capacity_scope` (`zfs_dataset_properties`/`dataset` for native ZFS).

Native rates use OpenZFS's vdev timestamp delta and integer output; a displayed
zero can include sub-unit activity. `requested_interval_ms=1000` is the requested
window, `collection_elapsed_ms` measures collection cost, and `sample_interval_ms`
stays null because the CLI does not expose its exact denominator. These native
observations leave latency, queue depth, in-flight requests and busy percentage
unknown. No maximum IOPS is inferred; any configured ceiling/provenance must
refer to the same logical pool scope and remains monitoring metadata.

The collector verifies permanent and per-import GUIDs around the native interval.
Malformed, missing, timed-out or rebound results leave rates unknown; the next
valid sample can recover. Valid dataset capacity remains independently observed.
Marshall retains the scope and import identity in history. These observations do
not alter admission or authorize capacity based on historical I/O.

See [ADR-0031](../architecture/decisions/0031-sparse-zfs-storage-and-capacity.md)
and the [I/O machine review](../architecture/reviews/2026-09-16-native-zfs-io.md)
for interface references and verified scope.
