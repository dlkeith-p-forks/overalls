# Native ZFS I/O observations

## Scope and evidence

This change implements the verified native I/O source required by ADR-0031 and
retains ADR-0013's freshness, bounded collection and explicit unknowns. ADR-0033
gains a real NixOS machine check. Accepted rationale and admission arithmetic are
unchanged; implementation statuses remain partial.
The user authorized implementation of the NixOS/storage plan. No production host
is activated and no performance tuning choice is accepted.

[Lilly's native sampler](../../../lilly/lib/lilly/host/zfs_io.ex) queries all
configured native pools in one interval, suppresses boot averages and brackets
it with permanent/per-import GUID checks. Exact bounded parsing retains four
rates and drops the pool-space columns. The [collector](../../../lilly/lib/lilly/host/collector.ex)
merges those observations with independently measured dataset capacity. Failed
I/O leaves unknown rates while preserving otherwise valid capacity.

Telemetry history (`marshall/lib/marshall/telemetry/observations.ex` at kittens revision `a99f74f0`, repository deleted)
now retains separate I/O and capacity scopes, import identity and rate-clock
provenance. Native read/write IOPS and throughput are logical zpool observations,
including other datasets. The CLI truncates rates to integers. The requested
interval and collection cost are separate from the unexposed exact timestamp
delta; unknown latency, queues, in-flight, busy percentage and maxima stay null.
Ext4 continues using block-device diskstats. History and IOPS never participate
in admission. The [operator guide](../../operations/storage-capacity.md) documents semantics.

## Findings and disposition

1. **Medium, fixed — missing native I/O implementation.** The earlier lifecycle
   review's missing-source finding is addressed by a documented native pool
   source, with explicit units, scope and import binding. Physical leaf-device
   and per-VM metrics remain outside this source's claim.
2. **Medium, fixed — history discarded I/O scope.** The previous allowlist kept
   device identifiers but dropped source/scope fields. Retaining both capacity
   and I/O provenance prevents whole-pool activity from being mistaken for
   Lilly dataset activity. Changed contexts are handled by the existing recorder.
3. **Medium, fixed test weakness — reads could hit the Linux page cache.** The
   first machine run produced measured observations but failed the nonzero read
   assertion. Disabling ARC data caching did not ensure the fixture's reads
   reached storage. The revised workload uses an independent direct-I/O reader
   on a real initialized file, alongside writes, and checks completed-read
   readiness. It does not fabricate counters or loosen the nonzero assertion.
4. **Medium, open requirement — full deployment/load acceptance.** Two virtual
   pools establish functional collection, not physical IOPS ceilings, density,
   concurrent guest accounting under pressure, or three-Marshall/two-Lilly fleet
   behavior. Reference storage/disko/UEFI, provider and physical failure-domain
   acceptance remain outstanding. ADR-0034 tuning remains proposed.

## Verification

- Lilly `mix precommit`: **96 passed** (24 properties, 72 tests), forced Dialyzer
  zero findings. New properties cover arbitrary utility bytes and independence
  of rates from space columns; examples cover complete multi-pool sets, uint64
  identities, zero values, noncanonical/overflowing fields and 64-pool bounds.
- Targeted Marshall telemetry checks: **3 passed** (1 property, 2 tests),
  including separate native capacity/I/O provenance, timing and unknown maxima.
- Marshall `mix precommit`: **227 passed** (25 properties, 202 tests; 4 host
  cases excluded), including the three-BEAM distributed cases and six browser
  terminal-state checks. Forced Dialyzer passed with the existing single scoped
  upstream exclusion and no unnecessary exclusions.
- Corrected NixOS I/O machine suite: **passed in 81.96 seconds** with KVM and
  actual OpenZFS 2.4.4. It exercised source-built collector reports and shared
  protocol round trips, two distinct pools, nonzero direct reads and writes
  outside Lilly's dataset, separate quota-limited capacity, malformed output,
  timeout, actual export/import invalidation and recovery after every fault.
  Permanent GUID stayed constant while the import GUID changed. No fake rates
  supplied successful observations.
- Source-built Lilly release and NixOS module configuration checks passed.
  ADR validation passed for **34 decisions**. Contract validation passed for
  **47 CONTRACTS files, 351 native notes and 433 maintained sources**; sampler
  contract discovery and manual caller/callee review completed. These checks
  establish structure and the tested behavior, not whole-platform acceptance.
  All test QEMU processes exited; temporary builder access to `/dev/kvm` was
  removed and its original root:kvm permissions restored.
- The initial interface probe passed against OpenZFS 2.4.4 on two real virtual
  pools in **28.97 seconds**. It verified the one-interval tab-separated output
  and availability of permanent/import GUIDs; it was not collector acceptance.
- The first collector machine run failed the fixture read assertion described
  above. It is not a passing I/O suite.

## Follow-up

Continue real native collector-to-Marshall admission/exchange under the required fleet topology,
concurrent guest pressure and installation acceptance. The overall plan remains
in progress.

Interface evidence: [documented logical interval I/O](https://openzfs.github.io/openzfs-docs/man/v2.4/8/zpool-iostat.8.html),
[per-import identity](https://openzfs.github.io/openzfs-docs/man/v2.4/7/zpoolprops.7.html),
[OpenZFS 2.4.4 rate calculation](https://github.com/openzfs/zfs/blob/zfs-2.4.4/cmd/zpool/zpool_main.c),
[monotonic vdev timestamp](https://github.com/openzfs/zfs/blob/zfs-2.4.4/module/zfs/vdev.c).
