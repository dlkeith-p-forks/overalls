# Native ZFS observations and lock release

## Scope and evidence

This checkpoint implements read-only Lilly storage primitives under ADR-0031,
the native command response needed for large property trees, a discovered OS
lock-release race, and explicit Firecracker Writeback/Sync configuration. It
preserves the accepted decisions; it does not enable ZFS provisioning yet.
Affected decisions: ADR-0017, ADR-0031 and ADR-0033. Existing Marshall protocol,
admission, NixOS role, secret and ACME work remains intact.

The [reader](../../../lilly/lib/lilly/host/zfs.ex) checks canonical mount roots,
actual pool/dataset GUIDs, plain block extents and supported healthy disk/mirror
topology. LZ4 on the root and managed dataset, absent managed reservations,
standard sync and disabled dedup remain required. Consecutive equal property
trees and physical decomposition checks reject observed inconsistency. Child
records carry dataset GUIDs and physical bytes, with no VM allocation map.

The [command client](../../../lilly/lib/lilly/host/command.ex),
framing client (`lilly/lib/lilly/host/locked_command.ex`) and
native helper (`lilly/native/host-lock/src/lib.rs`; both removed by ADR-0176 decision 4) allow a 4 MiB response only when
explicitly selected. ZFS list reads select it; other commands retain 64 KiB.
Request bodies stay at 64 KiB/128 arguments and deadlines remain bounded.
The native buffer is static, not a 4 MiB stack allocation. Legacy request frames
still work. New callers and the helper ship together in the source-built closure.

## Findings and disposition

1. **High, fixed — release raced the native owner.** The full Lilly gate exposed
   an intent property returning `host_already_owned` immediately after release.
   `Port.close` had not proved that the helper exited. Release now sends an empty
   shutdown frame and awaits exit; timeout reports uncertainty. The
   paused-helper regression (`lilly/test/host/locked_command_test.exs`, removed)
   demonstrates the ordering and immediate reacquisition. Caller/helper death,
   command overflow and timeout continue to preserve ownership until work exits.
   This corrects implementation under ADR-0017; no replacement decision is needed.
2. **High, open requirement — ownership and execution are not connected.**
   Pool configuration, collection and Disk still select ext4. The native reader
   recognizes structural child names but cannot prove durable VM ownership.
   Its child records must never be promoted directly into allocation credit.
   Integrate durable host/pool/child GUID claims, interrupted create/delete,
   sparse disk readiness and outcome-confirmed cleanup before enabling ZFS hosts.
3. **Medium, open requirement — rate scope and concurrent-write coherence.**
   OpenZFS 2.4.4's actual status JSON uses `pool_guid`; the assumed
   `/proc/spl/kstat/zfs/POOL/io` file was absent. The reader uses verified native
   property/status interfaces and emits no guessed diskstats rates. Add verified
   pool I/O sampling and exercise concurrent guest writes. OpenZFS documents
   [zpool iostat](https://openzfs.github.io/openzfs-docs/man/v2.4/8/zpool-iostat.8.html)
   as logical pool/vdev I/O; its counters must not be labeled physical-device I/O
   without separate evidence. Equal property reads
   are not a transaction, and no reservation protects against unrelated writers.
4. **Medium, open acceptance — durability and deployment.** Explicit
   [Writeback/Sync settings](../../../lilly/lib/lilly/vm/jail.ex) follow the pinned
   Firecracker 1.16.1 API. They do not prove guest flush durability after host loss.
   NixOS storage options, reference mirrored-root installation and the required
   three-Marshall/two-Lilly guest suites remain outstanding.

## Verification

- Lilly `mix precommit`: **91 passed** (21 properties, 70 tests), forced Dialyzer
  zero findings. The earlier failed intent property is recorded above; it was
  fixed before this successful full gate.
- [Native parser properties](../../../lilly/test/host/zfs_test.exs): independent
  logical/compression values, physical decomposition, malformed bytes, GUID
  boundaries, duplicate rows, unsupported topology and the 4096-child bound.
- Lock command regression: exact 4 MiB response, overflow, unchanged request
  limits, continued ownership, paused release and existing death/timeout tests.
- Source-built Lilly release payload check passed.
- Four-machine service-role regression passed in **77.92 seconds**, including
  actual Lilly startup, restart and inner-KVM checks with the corrected helper.
  It does not exercise ZFS provisioning or guest flush durability.
- The [NixOS suite](../../../nix/tests/machines/native-zfs/default.nix) and
  [driver](../../../nix/tests/machines/native-zfs/driver.py) exercise actual ZFS datasets and Lilly code.
  The first complete run with 301 children passed in **209.52 seconds**. The
  final 401-child run passed in **229.27 seconds**, including the assertion that
  native property output exceeds 64 KiB, observed reclamation, replaced identity
  rejection and fixture cleanup. Hardware acceleration was required throughout.
  This is real ZFS reader evidence, not a Lilly-owned disk lifecycle, Firecracker
  guest, power-loss or throughput result. The final source release check also passed.
- ADR checks passed for 34 decisions; contract checks passed for 47 CONTRACTS,
  341 native notes and 422 maintained source files. Native discovery used the
  supported file inventory plus manual declaration/callee review; a source-line
  selector is unsupported. These checks are structural only.

The initial VM probe identified interface assumptions above. Early fixture runs
also failed on an unsupported ZED option, release cookie/eval setup, and safe ETF
decoding in a fresh VM without loaded atoms. The fixture now stores explicit JSON
identity fields. These failed attempts are not acceptance evidence.
An all-zero compression fixture was also corrected: ZFS can elide zero blocks,
so repeated nonzero bytes exercise LZ4 while random bytes exercise physical growth.

## Follow-up

Complete the owned sparse lifecycle and bind it to configuration, local receipts,
collector reports and immutable session descriptors. Test ext4 regression and
real Firecracker on ZFS, restart/crash recovery, missing-disk refusal, physical
pressure and mount/process cleanup. Continue ADR-0030/0033 host and fleet work;
ADR-0034 tuning stays proposed pending measurements. This is progress toward the
whole plan, not milestone completion or production activation.
