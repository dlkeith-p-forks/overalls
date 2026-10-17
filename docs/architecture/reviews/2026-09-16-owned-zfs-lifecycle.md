# Owned sparse ZFS lifecycle

## Scope and evidence

This checkpoint connects ADR-0031's native storage identity and observations to
Lilly configuration, immutable sessions, host ownership, sparse disks and
capacity reporting. It preserves ext4 materialization and admission contracts.
Affected decisions: ADR-0017, ADR-0031 and ADR-0033; ADR-0030's Lilly module gains
native storage options. No accepted rationale or numeric tuning choice changes.
ADR-0034 remains proposed. No production host is activated.

The [dataset owner](../../../lilly/lib/lilly/host/zfs_dataset.ex) stores private
parent/VM claims outside each child. It durably records a random creation nonce
before invoking fixed-argv ZFS create, binds the observed child GUID, and retains
that identity through disk readiness and deletion. Atomic, synced sparse image
publication uses the existing [Disk](../../../lilly/lib/lilly/vm/disk.ex) path.
The ext4 branch retains full allocation. Deletion persists a fence, rejects
unknown contents/mounts and wrong GUIDs, uses nonrecursive nonforced destruction,
observes absence and retires the claim outside the removed child.

[Pool](../../../lilly/lib/lilly/host/pool.ex) distinguishes native identity and
backing extents, rejects sibling capacity duplication and mixed ext4/ZFS overlap,
and verifies ready ownership before crediting exclusive physical bytes.
[Collector](../../../lilly/lib/lilly/host/collector.ex) reports capacity through
the existing v2 shape. ZFS virtual mount devices do not provide diskstats rates.
[NixOS options](../../../nix/domains/system/lilly.nix) require explicit GUIDs and logical
budget and supply the kernel-matched host ZFS package. Service activation assumes
an existing mounted parent; it does not import, format or repartition storage.

## Findings and disposition

1. **High, fixed — mismatched metadata could satisfy the success shape.** An
   internal `with` returned an unexpected `{:ok, decoded}` value on mismatch,
   while callers checked only the tuple shape. Explicit mismatch normalization
   now rejects it. The lifecycle fixture corrupts the inner disk claim and
   requires preparation, snapshot and deletion to refuse it. This protects
   attribution and destructive cleanup under ADR-0031.
2. **High, implemented with acceptance in progress — lifecycle ownership.**
   The previous observation review's missing integration is now connected.
   Creating/deleting children receive no credit. Bound GUID replacement,
   orphan descendants and missing ready disks withhold observations. A retained
   tombstone prevents reusing a deleted VM identity. Real machine tests cover
   utility interruption; they must not be described as physical power-loss proof.
3. **Medium, open requirement — native I/O rates and write coherence.** Capacity
   is measured, but native IOPS rates are explicit unknowns. Integrate a verified
   pool/device source with accurate scope and monotonic sampling. Equal property
   reads cannot reserve space or freeze concurrent guest writes; load/pressure
   acceptance remains outstanding. No fabricated rates or physical reservations
   are introduced to close this gap.
4. **Medium, fixed test weakness — crash recovery reused the same value.**
   Review caught that the guest fixture rewrote its already persisted marker
   before host loss. Old data could therefore satisfy the post-crash assertion.
   The pre-crash write now uses a distinct generation value and the recovered
   guest must read that exact new value. The earlier run proves boot, confinement,
   stop/start and cleanup but is not evidence of retaining that new crash write.
5. **Medium, open requirement — deployment and fleet acceptance.** Reference
   storage/disko/UEFI installation, three distinct Marshall plus two Lilly
   machines, real provider checks, physical failure domains and density/performance
   evidence remain outstanding. The new low-level and single-host guest checks
   do not substitute for those suites.

## Verification

- Lilly `mix precommit`: **92 passed** (22 properties, 70 tests), forced Dialyzer
  zero findings, including the final metadata comparison correction. Pool
  properties cover duplicate zpool identity and mixed ext4/ZFS backing overlap.
- Marshall `mix precommit`: **227 passed** (25 properties, 202 tests; 4 host
  cases excluded), including three-BEAM distributed tests and six browser-state
  checks. Forced Dialyzer passed with the existing single scoped upstream
  exclusion and no unnecessary exclusions. The [enrollment test](../../../marshall/test/marshall/compute/enrollment_test.exs)
  now uses the actual Lilly client over verified TLS to decode a ZFS descriptor
  with the maximum unsigned GUID, submit a synthetic observation and reject
  changed dataset identity without advancing the stored report sequence.
  This checks protocol compatibility; the sample is not collected from a VM.
- NixOS module configuration check passed with native identity/budget cases,
  missing-budget and wrong-GUID rejection, duplicate zpool rejection and ext4
  compatibility. The source-built Lilly release compiled successfully.
- Four-machine service-role regression **passed in 76.58 seconds**, including
  actual source-built Marshall/Lilly startup, role independence, inner KVM checks,
  verified proxy TLS, backend recovery and secret-free proxy logs.
- The first lifecycle VM run passed sparse publication, retained data, mount/
  content fencing and interrupted creation. It then failed because the Nix
  release launcher prepended coreutils, bypassing the fixture's copy wrapper.
  The fixture now installs and verifies its interception inside the evaluator;
  the wrapper still performs the real copy before pausing. This failed run is
  not complete lifecycle acceptance.
- Final corrected lifecycle machine run: **passed in 561.41 seconds** with KVM.
  It covers sparse real-image publication/reuse, interrupted create/copy/destroy,
  unknown contents, alias mounts, missing initialized disks, mismatched inner
  claims, replaced child GUIDs, wrong nonces, orphan descendants, observed
  reclamation and retained deletion tombstones.
- The first nested guest attempt rejected network setup because the standalone
  fixture omitted required host forwarding. It now imports the actual Lilly
  module for host prerequisites, with only the control daemon disabled.
- A complete guest run passed in **478.98 seconds** but had the repeated-value
  weakness above. Its host-loss write assertion is superseded by the distinct-value
  rerun; its other lifecycle results remain useful.
- Distinct-value nested ZFS guest machine run: **passed in 470.96 seconds**
  with hardware acceleration and actual nested KVM. Its driver starts real Firecracker
  through Lilly's privileged API and checks physical identity, persistent console
  writes, stop/start, simulated host loss and deletion. The framework's `crash()`
  sends QEMU monitor `quit` without guest shutdown. Virtual disks use Writeback;
  this is a simulated host failure with the outer host still alive, not physical
  cache/power-loss proof. The distinct acknowledged value survived recovery,
  and deletion removed the dataset only after physical process/mount cleanup.
- ADR checks passed for **34 decisions**; contract checks passed for **47
  CONTRACTS files, 348 native notes and 428 maintained source files**. Native
  ownership contract discovery and manual declaration/callee review completed.
  These are structural checks, not runtime acceptance. All test QEMU processes
  exited, and temporary builder access to `/dev/kvm` was removed.

## Fleet follow-up regressions

The [fleet review](2026-09-16-nixos-fleet.md) found that the waiting launcher of a
later VM retained a private mount reference to an older VM's dataset. The
[launcher](../../../lilly/lib/lilly/vm/unit.ex) now leaves its waiting parent in
the host mount namespace and creates the temporary mount namespace only in the
child before the generation guard and jailer. The nested guest suite now starts
a second guest before deleting the first, compares the survivor's actual process
identities and verifies continued disk reads/writes. This complete expanded
machine suite passed in **696.22 seconds**, including the existing distinct-value
simulated host-loss check. The complete fleet also passed independent deletion
on both Lilly hosts while preserving all survivors.

Dataset deletion also gains a guarded recovery path for interruption after
unmount but before destruction. Only an already-deleting claim with the same
GUID and ownership can remount a safe child at an empty canonical mountpoint,
then repeat normal destruction checks. New native cases reject unexpected host
files, changed ownership/policy and a replaced GUID with copied tags. The first
new lifecycle run failed earlier because the direct fixture expected immediate
success from a retryable `storage_busy` preparation. Normal fixture preparation
now retries only that result within 60 seconds; deliberate rejection probes stay
single attempts. The complete native lifecycle rerun passed in **797.35 seconds**,
including both new unmounted-child scenarios. Lilly precommit and structural
gates also pass. The focused two-guest cleanup regression passed separately as above.

## Follow-up

Integrate verified native I/O sampling, real host/collector-to-Marshall admission/report
exchanges on ZFS and concurrent write/pressure checks. Continue ADR-0030/0033 installation and fleet
work and ADR-0034 measurement. The whole deployment plan remains in progress.
