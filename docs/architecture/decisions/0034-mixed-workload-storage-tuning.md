# ADR-0034: Mixed-workload storage tuning

- ID: ADR-0034
- Date: 2026-09-16
- Status: proposed
- Implementation: planned
- Components: Lilly storage performance, NixOS ZFS configuration, capacity headroom, benchmarks
- Supersedes: none
- Superseded by: none

## Context

The user selected mixed workloads and wants good density for many Firecracker
VMs. LZ4, sparse native datasets without filesystem reservations, and a logical
capacity cap are accepted under [ADR-0031](0031-sparse-zfs-storage-and-capacity.md).
The reference resource budgets are recorded in
[ADR-0030](0030-nixos-deployment-and-tls.md). Neither selection proves an optimal
record size, cache policy or metadata margin for mixed workloads.

The following numerical defaults were assistant proposals. The user authorized
recording them as proposed pending validation, not treating them as measured or
as an accepted universal performance prescription.

## Decision

Propose the following baseline for managed VM datasets and expose settings
through the NixOS storage module. Do not apply the VM record size indiscriminately
to the host OS or other datasets.

| Setting | Candidate |
| --- | --- |
| VM dataset `recordsize` | `16K` |
| `atime` | `off` |
| `xattr`, `dnodesize` | `sa`, `auto` |
| `primarycache` | `all`, within the accepted 8 GiB reference ARC cap |
| `logbias` | `latency` |
| Admission headroom | 20% of the configured disk budget, using integer arithmetic |
| Reference pool | Preserve the existing mirror and `ashift=12`; retain `autotrim=on` |

The accepted constraints remain LZ4, no ZFS reservations, no overcommit, no dedup/
shared-block provisioning, and guest flush durability (`Writeback` with
`sync=standard`). Keep the synchronous Firecracker I/O engine initially. Do not
disable durability, add hardware cache devices or change pool topology merely to
improve a benchmark score. Host autotrim is not guest discard support.

The proposed 20% headroom is an admission deduction, not reserved ZFS space.
With a 1 TiB budget it limits logical commitments to approximately 819 GiB before
additional physical-pressure deductions. This is the consequence to review when
selecting the value; do not silently reduce the budget in an implementation while
describing 20% as a user-selected requirement.

Benchmark fresh VM datasets with 4K, 16K, 64K and 128K record sizes at 1, 8 and 24
concurrent guests on disposable storage. Use the same one-vCPU guest shape, image,
dataset properties and bounded workloads across comparisons. Include concurrent
boot, small random reads/writes, sequential artifact-like I/O and synchronous
writes, with both compressible and incompressible data. Compare cold and warm
cache behavior and metadata-only versus full ARC caching. Recreate test files
between record-size variants; changing a property does not retune existing files.

Record boot-time and I/O latency distributions including p95/p99, throughput,
CPU, ARC/RAM usage, physical allocation, compression and pool pressure. Repeat
measurements and publish workload, hardware, versions, concurrency and variance.
Run through actual Firecracker guests on a dedicated physical KVM runner;
functional NixOS QEMU tests validate configuration and behavior, not physical
performance. Bound the benchmark to identified disposable storage and never
reformat or consume an existing production pool for measurement.

Accept a tuning decision only with recorded tradeoffs and headroom evidence,
updating this proposed ADR before promoting defaults. Until then, 16K and 20%
remain candidates and deployment must supply reviewed values explicitly. There
is no automatic benchmark-based tuning or claimed universal optimum.

## Alternatives

The 128K dataset default can favor sequential throughput and compression but can
amplify small overwrites in raw disks. Smaller records can reduce that work while
increasing metadata and reducing compression opportunities. Metadata-only caching
can avoid duplicate guest caches but lose host cache benefits. Measure these
tradeoffs rather than assuming one profile fits every guest.

## Consequences

Benchmarking requires dedicated resources and cannot be substituted by unit-test
timing. Results may justify retaining the baseline or replacing it with a measured
choice. Record-size changes affect new files; existing VM migration/rewrite is a
separate maintenance action and must not happen automatically during rebuild.

## Invariants and verification

- Every candidate retains LZ4, sparse allocation, the logical cap and flush safety.
- Functional properties match actual datasets before recording performance.
- Runs preserve guest isolation and report failures/variance, not only best scores.
- Headroom tests include metadata growth, compression changes, multiple writers
  and external pool pressure without claiming reserved-space guarantees.
- Record hardware results and review the proposed status before claiming optimal
  configuration or enabling automatic defaults.

## Implementation evidence

No benchmark harness or measurement supporting these candidate defaults exists.
[Current disk creation](../../../lilly/lib/lilly/vm/disk.ex) uses owned sparse
ZFS storage only under [ADR-0035](0035-zfs-only-provisioning.md). The
[mirrored storage module](https://github.com/antithesishq/kittens/blob/16e8dbe4a8871df015fa9853febf1a1e7e99e29b/nix/modules/mirrored-zfs.nix) supplies LZ4,
zero reservations, explicit quota/ARC limits and conservative installation
behavior. It deliberately does not promote the proposed record-size/cache/
headroom candidates. Real functional guest/fleet tests pass under ADR-0033;
their virtual-disk timings do not establish physical performance.
No throughput, density or latency improvement is established by this record.

## Open questions

Which record size/cache policy best balances mixed guest latency, density and
throughput on the target hardware? What admission headroom covers observed
metadata/copy-on-write pressure? These are measurement questions, not permission
to reconsider the settled sparse/LZ4/logical-cap requirements.

## Related decisions

[ADR-0006](0006-capacity-accounting.md),
[ADR-0030](0030-nixos-deployment-and-tls.md),
[ADR-0031](0031-sparse-zfs-storage-and-capacity.md),
[ADR-0033](0033-nixos-machine-verification.md),
[architecture review](../reviews/2026-09-16-nixos-and-sparse-zfs.md).

Interface references: [OpenZFS workload tuning](https://openzfs.github.io/openzfs-docs/Performance%20and%20Tuning/Workload%20Tuning.html),
[dataset properties](https://openzfs.github.io/openzfs-docs/man/master/7/zfsprops.7.html).
