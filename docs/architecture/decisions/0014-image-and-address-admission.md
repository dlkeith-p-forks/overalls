# ADR-0014: Immutable images and profile address admission

- ID: ADR-0014
- Date: 2026-09-15
- Status: superseded
- Implementation: partial
- Components: Marshall Compute, Lilly Host, shared protocol, NixOS guest
- Supersedes: none
- Superseded by: ADR-0016, ADR-0098

## Context

The authorized plan requires a reproducible guest, compatible hosts, persistent
VM identity and coordinated profile addresses. Initial admission reserved sizes
without selecting an image or allocating an address. This record implements
those prerequisites within ADR-0010; it does not authorize execution of the
receipt-only control envelopes defined by ADR-0012.

## Decision

Use an immutable, operator-registered Ash Image resource. Manifest version 2
contains exactly architecture, boot arguments, minimum memory/disk, version and
kernel/initrd/rootfs descriptors. Each descriptor has its exact byte length and
SHA-256 digest. Initially accept x86-64 only, kernel/initrd up to 512 MiB each,
root images up to 32 GiB, and minimum sizes within VM limits. Rootfs bytes must
fit the declared minimum disk. Reject malformed hashes, unknown fields and NUL/
newline boot arguments. These are artifact limits, not the VM's writable disk
limit. The initial platform admission floor remains 512 MiB RAM / 2 GiB disk.

Derive `sha256:<digest>` from SHA-256 of the compact Elixir JSON encoding of this
ordered array, without a trailing newline:

```
["lilly-image-v2", architecture, boot_args, minimum_memory_bytes,
 minimum_disk_bytes, [kernel_bytes, kernel_sha256],
 [initrd_bytes, initrd_sha256], [rootfs_bytes, rootfs_sha256]]
```

Both applications use the same pure validator/identity function. Reformatting
the input JSON cannot change the identity. Byte hashes, arguments and limits
all participate. A future implementation in another language must match encoding
test vectors, including string escaping. Manifest version 1 remains a historical
smoke artifact and is rejected by the catalog; it has insufficient integrity
metadata. The control wire version is independently still 1.

Registration is idempotent by content ID. The first display name is retained;
only `enabled` is mutable. Catalog changes have AshPaperTrail history and Cedar
internal-only entry points. Users select an image ID when provisioning. An
identical retried VM request returns its original VM even if the image is later
disabled; changing the image for the same request key is an idempotency conflict.
Disabling an image stops new admissions and does not alter existing disks.

Operators stage image directories on Lilly. No caller-supplied URL or artifact
path crosses the control API. Local configuration lists at most 128 image paths.
Resolve the fixed names `manifest.json`, `kernel`, `initrd`, `rootfs.ext4`; permit
Nix store symlinks while checking source/target ancestry and read-only regular
files owned by root or the effective user. Hash all bytes with bounded chunks
before advertising an image. File identity, size, mode, owner and change/
modification times are checked again during sampling; atime is excluded. Missing,
changed or writable artifacts disappear from `inventory.images`, while otherwise
valid capacity can still be reported. A missing image field advertises no images.
The future VM driver must rehash before copying/launching; metadata is a cheap
availability check with filesystem timestamp granularity limits, not a fresh
content hash or a defense against a compromised root operator. The
operator/Nix distribution channel supplies authenticity; hashes detect changed
content but are not signatures.

Extend admission's transaction order: user/request advisory lock, image row
`FOR SHARE`, profile advisory lock, then candidate host rows in UUID order. Image
configuration updates conflict with the shared row lock. Require the enabled
image, matching architecture, manifest minima and the exact ID in a fresh host
inventory before placement. Reserve VM, compute/disk, address, operation, audit
and AshOban job in the same transaction. A failed insertion rolls all back.

The profile `/16` pools allocate integer slots 2 through 65534. Reserve `.0.0`,
`.0.1` and `.255.255` for network, gateway and broadcast respectively. Interior
`.x.0` and `.x.255` addresses are ordinary identities in a `/16`. The address is
`10.<profile octet>.<slot div 256>.<slot mod 256>`. The gateway reservation does
not yet define per-VM link routing. Find the first unused slot under a
transaction-scoped profile advisory lock; database constraints independently
enforce valid profiles/ranges, one address per VM and unique profile/slot.
Exhaustion rejects admission immediately. Retain addresses through stop and
unknown state. No release API exists until physical cleanup reconciliation is
implemented. Future cleanup must take the profile lock before host locks.

That prospective cleanup order was not implemented. The replacement
[ADR-0016](0016-executable-generations-and-lifecycle.md) preserves this record's
image and admission decisions and replaces the cleanup lock requirement with
host-serialized archival and a partial live-address unique index. It also adds
the explicit executable v2 contract. The original rationale above is retained.
The later [ADR-0098](0098-image-artifact-limits.md) replaces this record's
32 GiB root image artifact ceiling with 128 GiB and its 512 MiB kernel/initrd
ceilings with 8 GiB each. The other image and admission requirements remain in
force.

## Alternatives

A mutable image name cannot identify boot bytes after a retry. A capacity-only
placement may select a host missing the requested image. Trusting file names or
mtime alone cannot verify initial content. Downloading arbitrary user URLs in a
root provisioner expands the privileged boundary unnecessarily. Per-host address
allocators would duplicate addresses across the fleet. Releasing on timeout
could assign an old guest's identity to another VM.

## Consequences

Host image availability is an observation, so disappearance after admission must
be reconciled by the future driver without releasing live reservations. Image
verification adds startup I/O and per-sample metadata cost; measure with realistic
image counts. Admission serializes within each profile and scans a bounded
65,533-slot range. Throughput and 100-node load remain unverified.

The new VM image foreign key is non-null. This development migration succeeds
with no preexisting VM intents. It deliberately cannot invent image bindings
for an older nonempty database; those need explicit operator backfill/review.
There is no public provisioning API or deployed execution peer to upgrade yet.
Control v1 still omits image/address execution data and remains receipt-only.
An execution protocol revision, cache distribution, storage mutation coordinator,
jailer/network driver and physical outcomes remain required before user launch.

## Invariants and verification

- Manifest identity is stable through JSON serialization and changes with
  artifact/boot requirements. Reject malformed or unsupported descriptions.
- Lilly advertises only verified, still available local files; corrupt bytes,
  writable targets, unsafe ancestry and replacement are detected.
- New admissions require image availability/minima; identical retries retain
  existing identity and reservations after availability or catalog changes.
- Three independent Marshall nodes allocate distinct addresses across two host
  records. These host records are not two KVM execution hosts.
- Exercise all occupied slots, a hole and independent profiles against the
  allocator SQL. Address encoding properties cover uniqueness and reserved slots.
- An AshOban insert failure rolls back the already-created address too.
- Run all three precommit gates and opt-in real host/TLS loop tests; validate the
  rebuilt Nix artifact with the real Lilly loader.

## Implementation evidence

[Manifest validator](../../../protocol/lib/overalls_protocol/image_manifest.ex),
[address encoding](../../../protocol/lib/overalls_protocol/address_pool.ex),
[image catalog](../../../marshall/lib/marshall/compute/image.ex),
[registration](../../../marshall/lib/marshall/compute/images.ex),
[address resource](../../../marshall/lib/marshall/compute/network_address.ex),
[allocator](../../../marshall/lib/marshall/compute/address_allocation.ex) and
[admission](../../../marshall/lib/marshall/compute/admission.ex) implement identity
and transactional placement. [Local image verification](../../../lilly/lib/lilly/host/image.ex),
[configuration](../../../lilly/lib/lilly/control/config.ex) and
[collector](../../../lilly/lib/lilly/host/collector.ex) implement availability.
[Nix artifact](../../../nix/packages/guest/default.nix) now emits integrity descriptors.

[Manifest properties](../../../protocol/test/image_manifest_test.exs),
[address properties](../../../protocol/test/address_pool_test.exs),
[file checks](../../../lilly/test/host/image_test.exs),
[admission tests](../../../marshall/test/marshall/compute/image_admission_test.exs),
[exhaustion test](../../../marshall/test/marshall/compute/address_allocation_test.exs),
[three-node tests](../../../marshall/test/marshall/compute/distributed_admission_test.exs)
and [host loop tests](../../../nix/tests/machines/fleet/default.nix)
cover these prerequisites. The [review](../reviews/2026-09-15-image-address.md)
records actual validation. Execution/distribution and physical network isolation
remain incomplete.

[ADR-0015](0015-jailed-execution-and-host-networking.md) supplies local execution
primitives with image revalidation and the assigned profile address. The v1
transport remains receipt-only until generations and physical outcomes are wired.

### 2026-09-29: verification off the startup path

The decision to hash all bytes before advertising an image is unchanged, but
hashing no longer blocks Lilly startup. Previously configuration loading hashed
every image (about 3.5 GB each) before any supervisor child started, leaving
Runtime, ingress and the Brady attribution socket down for minutes after each
restart. Configuration now stages images structurally
([Image.stage/1](../../../lilly/lib/lilly/host/image.ex)); the
[image catalog](../../../lilly/lib/lilly/host/image_catalog.ex) hashes them in
the background and host reports advertise only digest-verified images; the VM
driver still re-hashes before copying or launching. Evidence:
[catalog restart model](../../../lilly/test/host/image_catalog_test.exs) and the
native `brady-fleet` restart-attribution subtest recorded in the
[resolution review](../reviews/2026-09-29-open-problem-resolution.md).

## Open questions

Complete authenticated execution messages with image/address identity, image
cache delivery/eviction and privileged driver validation. Define per-VM routing,
NAT/filter rules and network cleanup before address reuse. Measure startup hash
and sampling costs, profile allocation contention and full-fleet admission load.

## Related decisions

[ADR-0005](0005-vm-lifecycle-and-storage.md),
[ADR-0007](0007-profile-networking.md),
[ADR-0010](0010-capacity-admission-transactions.md),
[ADR-0011](0011-nixos-guest-and-console.md),
[ADR-0012](0012-provisioner-control-transport.md),
[ADR-0013](0013-capacity-collection-and-local-receipt.md).

Interface references: [PostgreSQL locks](https://www.postgresql.org/docs/current/explicit-locking.html),
[OTP streaming hashes](https://www.erlang.org/doc/apps/crypto/crypto.html).

The original ext4/v1 host-loop tests were retired by ADR-0035. Their current
ZFS/v2 capacity, image-availability, restart and revocation coverage lives in the
linked NixOS fleet suite; earlier test results above remain historical.
