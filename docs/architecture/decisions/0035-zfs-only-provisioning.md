# ADR-0035: ZFS-only provisioning and provisioner v2

- ID: ADR-0035
- Date: 2026-09-16
- Status: superseded
- Implementation: implemented
- Components: Lilly Host, Lilly VM, Lilly Control, Marshall Compute, shared protocol, NixOS storage
- Supersedes: ADR-0012, ADR-0016, ADR-0025, ADR-0031
- Superseded by: ADR-0037

## Context

The native sparse ZFS implementation retained an ext4 host backend, legacy
pool descriptors and receipt-only provisioner v1 exchanges. The user explicitly
requested removing that backend while preserving ext4 inside guests, confirmed
that development requires no backward compatibility or data conversion, and
selected removal of the obsolete provisioner v1 API. This decision records the
authorized breaking change, separately from its verification status.

## Decision

ZFS is the only provisionable host backing storage. Carry forward ADR-0031's
native parent/per-VM child datasets, sparse regular raw disks, LZ4 compression,
no reservation/refreservation, ownership/GUID checks, flush durability,
conservative physical allocation credit and separate logical admission budget.
The guest filesystem, reproducible image and `rootfs.ext4` filename stay ext4.
Unrelated host root filesystems need not change.

Every enrolled pool, NixOS/runtime pool configuration and accepted pool report
must carry coherent ZFS identity. An explicit positive logical budget exceeding
headroom is required; missing identity/budget cannot select another backend or
fall back to physical total capacity. PostgreSQL constraints and Ash resource
validation enforce this boundary. Keep `backend: zfs` in the current descriptor;
it is no longer a backend selection interface.

Use provisioner v2 only. Remove v1 enrollment/runtime configuration, client,
server, command codecs and durable receipt-store branches. Retired API requests
return unsupported-version errors. Require enrolled physical machine identity,
immutable image/address intent and ownership before execution. Command receipt
remains distinct from confirmed physical completion in v2. Console relay v1,
credential envelope v1, local ownership formats and the host identity derivation
are independent formats and remain unchanged.

Carry forward all other requirements from ADR-0012 (TLS, bounded validation,
credential custody and authenticated transactions), ADR-0016 (generations,
image/address admission, outcomes and retained resources), ADR-0025 (protected
operator enrollment/export) and ADR-0031 (storage/accounting, supervision,
isolation and recovery). Their v1/ext4 compatibility and upgrade commitments are
replaced here; their historical rationale and results remain intact.

Coordinate Marshall and Lilly deployment as a development breaking change.
There is no legacy conversion, automatic disk deletion, alternate backend or
mixed-version rollout promise. Apply generated schema migrations to fresh
isolated verification databases. Existing development state requires explicit
recreation outside this change; incompatible rows must not be reinterpreted.
Historical migrations remain the record of prior schema states.

## Alternatives

Keeping ext4 behind an option or only in tests would preserve the unwanted
second storage implementation. Converting existing ext4 disks/enrollments adds a
migration product for data the user says does not need preservation. Retaining
the receipt-only v1 API cannot carry the mandatory ZFS pool contract and was
explicitly rejected. Renaming guest ext4 images would confuse two different
storage layers without changing their behavior.

## Consequences

One host storage implementation simplifies capacity and recovery reasoning.
Local execution harnesses now require an explicitly supplied disposable ZFS test
parent on supported block devices; they create only UUID-owned child fixtures
and destroy them nonrecursively after verified guest cleanup. Rootless unit and
property tests use coherent synthetic ZFS data. Actual storage/guest claims
require NixOS machine tests.

## Invariants and verification

- Reject ext4 pools, absent identities/budgets, mismatched GUIDs and provisioner
  v1 requests at the relevant configuration, protocol, resource and DB boundaries.
- Preserve capacity freshness, host-row serialization, retained commitments,
  duplicate-backing rejection, unknown I/O and outcome-confirmed release.
- Preserve sparse allocation and actual ext4 guest boot, retained writes, restart,
  abrupt host-loss recovery, interrupted lifecycle and ownership-safe deletion.
- Replace legacy success fixtures with ZFS/v2. Preserve real TLS/authentication,
  missing-image, collector-failure, restart and credential-revocation coverage.
- Run all three precommit gates, fresh-schema verification, ADR/contracts checks
  and all fifteen exported Nix checks. Static evaluation is not machine evidence.

## Implementation evidence

- [Pool binding](../../../lilly/lib/lilly/host/pool.ex),
  [disk lifecycle](../../../lilly/lib/lilly/vm/disk.ex) and
  [collector](../../../lilly/lib/lilly/host/collector.ex) select native ZFS only.
- [Pool resource](../../../marshall/lib/marshall/compute/storage_pool.ex),
  [enrollment](../../../marshall/lib/marshall/compute/enrollment_request.ex) and
  [report codec](../../../protocol/lib/overalls_protocol.ex) require ZFS identity.
- [Provisioner API](../../../marshall/lib/marshall_web/provisioner_api.ex) and
  [Lilly client](../../../lilly/lib/lilly/control/client.ex) use v2 only.
- [NixOS options](../../../nix/domains/system/lilly.nix) require pool identity/budget;
  [fleet scenarios](../../../nix/verification/tests/machines/fleet/default.nix) cover real
  collection failures, missing images and revoked authority.
- [Fixture helper](../../../lilly/scripts/zfs_fixture.exs) bounds disposable
  native dataset creation and deletion for opt-in root harnesses.

All three application precommit gates and all fifteen final Nix check derivations
passed. The [implementation review](../reviews/2026-09-16-zfs-only-provisioning.md)
records exact evidence, corrected failures, cached unchanged checks and limits.
This status covers backend/API removal, not physical-host or production rollout
acceptance.

## Open questions

None for backend/API removal. Existing physical-host and production rollout
acceptance obligations remain separate.

## Related decisions

[ADR-0037](0037-workload-placement-and-relocation.md) replaces the original-host-only
placement and v2 restrictions while carrying forward other requirements.

- [ADR-0012](0012-provisioner-control-transport.md)
- [ADR-0016](0016-executable-generations-and-lifecycle.md)
- [ADR-0025](0025-protected-provisioner-enrollment.md)
- [ADR-0031](0031-sparse-zfs-storage-and-capacity.md)
- [ADR-0011](0011-nixos-guest-and-console.md) retains ext4 guest images.
- [ADR-0033](0033-nixos-machine-verification.md) retains machine-test obligations.
- [ADR-0034](0034-mixed-workload-storage-tuning.md) remains proposed; this change
  does not promote unmeasured tuning defaults.
