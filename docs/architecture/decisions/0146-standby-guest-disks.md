# ADR-0146: Pre-cloned standby guest disks

- ID: ADR-0146
- Date: 2026-10-09
- Status: superseded
- Implementation: partial
- Components: Lilly Host, Lilly VM, Marshall capacity
- Supersedes: none
- Superseded by: ADR-0177

## Context

With ADR-0130 templates enabled, the matched campaign measured NixOS create to
SSH at a 17.9 s median and Ubuntu at 13.7 s. Neither is under the 10-second
target. Per-step materialization events (ADR-0143) on 2026-10-09 showed:

**Where the time goes:**
- The template `image_copy` took 7.6 s (Ubuntu) and 20.9 s (NixOS) at Overalls
  load about 20–30, and 3.0 s for Ubuntu at lower load.
- `truncate`, `sync`, `mv` and `chown` each took 1–4 ms.
- Launch to provisioning-ready (boot and trust) took about 5–8 s.

**Why the copy isn't faster:**
- Pool `bcloneused`/`bclonesaved` (4.4 GB / 37.6 GB) shows the copy is a real
  ZFS block clone. Its cost is per-block reference-count work proportional to
  disk size and pool load, not data movement.
- Two concurrent Ubuntu creates cloned in 3.0 s and 6.1 s, the second queued
  behind the first. Concurrent clones from one template serialize, which
  explains the concurrent "regression".

No change to the materialization steps can remove this cost while it remains
on the create path.

## Decision

Lilly keeps a bounded number of **standby disks** per pool and image: owned,
unpublished datasets whose root disk was already cloned from the sealed
template.
- **Create:** claims a standby with an O(1) native rename into the
  placement's dataset name, re-validates ownership, GUID, template identity and
  shape, and then extends it to the requested size.
- **Fallback:** without a standby, it clones on demand as today.
- **Refill:** happens in the background, outside the create path and outside
  the pool lock.

Standby datasets earn no VM capacity credit, and they count against a
configured per-pool standby budget separate from the template budget. Capacity
observations treat them like templates: measured physical storage that is not
allocatable to VMs.

## Alternatives

- **`zfs clone` of a template snapshot.** Instant, but it creates origin
  dependencies that block template retirement and independent deletion
  (ADR-0112, ADR-0143).
- **Faster block cloning.** This depends on upstream ZFS reference-table
  performance; it is still proportional to size.
- **Smaller root disks.** These reduce cloning cost but change guest capacity
  semantics.

## Consequences

- Warm creates skip cloning, leaving roughly boot and trust (about 5–8 s) plus
  control overhead. Under 10 s becomes plausible.
- Standby disks consume physical space and lifecycle complexity: a new Ash
  state machine, recovery after crashes mid-rename, and retirement when
  templates rotate.
- Concurrent creates draw distinct standbys, so per-template serialization
  leaves the create path.

## Invariants and verification

- A standby MUST never be published to two placements. The rename MUST be
  atomic and journaled, and recovery MUST resolve any interrupted claim.
- Standbys MUST be retired with their template and MUST grant no VM credit.
- Required evidence:
  - native crash-at-rename histories;
  - property tests on the standby state machine;
  - matched campaigns showing warm medians under 10 s.

## Implementation evidence

Implemented behind `services.lilly.standbyDisks.perImage`, which originally
defaulted to 0 (off). The user accepted this decision in the implementing session
on 2026-10-09 and confirmed it on 2026-10-10.

**Update (2026-10-11, [ADR-0159](0159-remove-legacy-compatibility.md)):** the
zero/off value was removed. `standbyDisks.perImage` is a positive per-pool,
per-image count (1..128, default 1) in the
[Nix module](../../../nix/modules/lilly.nix) and
[pool model](../../../lilly/lib/lilly/host/pool.ex); refill visits every pool
(`refill` (`lilly/lib/lilly/host/standby_refill.ex`, removed by ADR-0177)). Standbys of an image
that is no longer configured are retired by the sweep, which the native
`image-template` test exercises through a deconfigured-image refill.

**Update (2026-10-13, [ADR-0163](0163-bounded-standby-refill-and-capacity-damping.md)):**
`perImage` is bounded to 1..32 with at most 64 standbys per pool, and each
refill pass is planned by `StandbyPlan` (`lilly/lib/lilly/host/standby_plan.ex`, removed by ADR-0177)
within `fillsPerPass`/`retirementsPerPass` budgets, resting between effects and
yielding to announced pool-lock waiters, after a production image rebuild
retired and filled about 260 standbys each under the pool lock.

**Historical diagnostic readers before ADR-0149:**
- the protocol [lifecycle allowlist](https://github.com/antithesishq/kittens/blob/a99f74f06542798dc9ef288e77c99d480433fc57/protocol/lib/overalls_protocol/lifecycle_audit.ex);
- Marshall [ingestion](https://github.com/antithesishq/kittens/blob/a99f74f06542798dc9ef288e77c99d480433fc57/marshall/lib/marshall/compute/lifecycle_ingestion.ex);

[ADR-0149](0149-independent-observability.md) retires those diagnostic-wire
readers. Current compatibility and authority remain in state-only native
journals and closed capacity reports, including:

- Lilly's [native standby shape](../../../lilly/lib/lilly/host/zfs.ex) and
  [allocation audit](../../../lilly/lib/lilly/host/zfs_dataset.ex).

These ownership/accounting checks grant no credit for a standby and do not depend
on trace admission or a diagnostic ACK.

**Producer:**
- the `StandbyDisk` resource (`lilly/lib/lilly/lifecycle/standby_disk.ex`, removed by ADR-0177);
- `fill, claim, sweep and retirement` (`lilly/lib/lilly/host/standby_disk.ex`, removed by ADR-0177);
- the `refill process` (`lilly/lib/lilly/host/standby_refill.ex`, removed by ADR-0177);
- [materialization](../../../lilly/lib/lilly/vm/disk.ex);
- the [Nix option](../../../nix/modules/lilly.nix).

**Tests:**
- the `state-machine property` (`lilly/test/lifecycle/standby_disk_test.exs`, removed by ADR-0177);
- the [accounting property](../../../lilly/test/host/zfs_test.exs);
- the native [`image-template` standby subtest](../../../nix/tests/machines/image-template/driver.py),
  whose historical version is recorded as passing on 2026-10-09. That evidence covers:
  - fill from the sealed template, with `bcloneused` growth;
  - a claim by rename that keeps the GUID;
  - recovery after a crash at the rename and at the claim's property change
    (accounting fails closed until the sweep rolls forward);
  - abandoned-claim cleanup;
  - retirement when standbys are deconfigured.

**Correction to the claim design (from native evidence):**
- The standby file is sealed `0400`, because native identity requires a
  non-writable root file.
- The claim compares identity without the device number, because the remount
  after the rename assigns a new one.

**Incoming production report (2026-10-09 to 2026-10-10):**
The author of `e3300040` reports the following observations. Current
[Dungarees](../../../fleet/hosts/dungarees/configuration.nix) and
[Overalls](../../../fleet/hosts/overalls/services.nix) source declarations enable
templates and set 128 standbys per image, but no independent live rollout was
performed by this observability change.

- **Enabled:** both hosts run at the configured maximum of 128 per image
  (256 per pool) since `6195e392`.
- **Fill speed:** each standby fills in about 0.5 s on Dungarees and 6–19 s
  on Overalls, which runs at load 20–30.
- **Capacity:** 64 standbys used about 21 GiB of shared physical blocks for
  50 GiB of logical `used`.
- **Sampled creates:** NixOS creates to SSH took 10.8 s, 12.8 s and 15.1 s,
  all reporting source `standby`. The templates-only median was 17.9 s.

**Corrections from production:**
- **Single-listing audit (`6195e392`):** the audit originally ran three
  native commands per standby on every capacity snapshot. It now joins the
  observation's single dataset listing.
- **Native timeouts (`dd802f42`):** a claim's remounting `zfs set` exceeded
  the 3 s utility default under load. The timeout interrupted it after ZFS
  had already unmounted the standby, and accounting then withheld the
  Overalls pool. Claims and retirement now use a 120 s bound, and recovery
  remounts an owned standby left unmounted.
- **Sweep ordering (`e203bbc7`):** the sweep now recovers claims first and
  continues past failures of individual records.
- **Native coverage:** the native subtest now covers a slow claim and an
  interrupted unmount.

Incoming `e3300040` refills one standby before the interrupted-unmount fault
because the preceding claim consumed the last one, and adds its actual GUID to
the cleanup oracle. It reports a passing native run without an exact wrapper,
duration or output artifact. This review inspects the fixture; the separate
captured observability/relocation runs do not establish this modified standby
subtest's native acceptance.

**Remaining:**
- a matched create campaign with medians. It needs both hosts quiet, and
  Overalls has been loaded by other workloads.
- an exact captured native result for the incoming slow-claim/interrupted-unmount
  fixture and independent current rollout acceptance. The decision is now
  accepted/partial following the user acceptance recorded in `e7e2f2e3`;
  acceptance adds no runtime evidence to the earlier incoming report.

The separate retained-state profile upgrade remains unverified under proposed
[ADR-0151](0151-existing-state-standard-profile-migration.md); source integration
and the reported outage recovery do not establish that native upgrade.

## Open questions

- Standby count and budget per image and pool, and the refill policy under
  pool pressure: closed by [ADR-0163](0163-bounded-standby-refill-and-capacity-damping.md)
  (32 per image at most, 64 per pool, budgeted and yielding refill passes).
- Whether guest boot and trust time (about 5 s) also needs work to reach
  under 10 s reliably.

## Related decisions

- [ADR-0130](0130-verified-provisioning-fastpath.md)
- [ADR-0143](0143-faster-create-clone-delete.md)
- [ADR-0145](0145-same-pool-block-cloned-clones.md)
- [ADR-0149](0149-independent-observability.md)
