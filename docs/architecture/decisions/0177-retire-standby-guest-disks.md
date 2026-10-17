# ADR-0177: Retire pre-cloned standby guest disks

- ID: ADR-0177
- Date: 2026-10-16
- Status: accepted
- Implementation: implemented
- Components: Lilly Host, Lilly VM, NixOS lilly module, fleet
- Supersedes: ADR-0146
- Superseded by: none

## Context

[ADR-0146](0146-standby-guest-disks.md) kept pre-cloned standby root disks
per pool and image. A create could then rename one into place instead of
copying the image. That decision was justified by 3–20 s clones measured at
host load 20–30. The [storage churn review](../reviews/2026-10-13-storage-churn-and-capacity-damping.md)
later traced that load mostly to `arc_prune` starvation, which has since
been fixed.

[ADR-0176](0176-host-concurrency-single-writers-and-effects.md) decision 6
made keeping standbys depend on evidence. The user approved a measurement
campaign, and then, on that evidence, approved retiring standbys
(2026-10-16).

**Evidence.** Both runs were user-approved bursts of 26 concurrent Ubuntu
creates. Each bar below is overalls only; the totals cover the whole fleet.

- **With standbys** (23 creates on overalls): `materializing` took p50
  7.3 s, max 10.7 s. All 26 creates were running after 18.7 s.
- **Without standbys** (22 on overalls; readiness batching had shipped in
  between): `materializing` took p50 4.1 s, max 4.9 s. All 26 were running
  after 15.7 s.
- **On-demand copy cost.** Block-cloned image copies took p50 966 ms and
  p95 1 044 ms. They ran in parallel, outside the pool lock.

**What standbys cost.** About 1 300 fills and 1 550 retirements a week.
32–64 mounted datasets per pool, carried in every recursive listing and in
ARC metadata. Two or three pool-lock sections per fill, plus a whole planner,
refill process, journal, audit, claim protocol and recovery path.

## Decision

Retire standby disks. Every create copies its root disk on demand from the
sealed template, by block clone where the store allows it.

Two shippable steps, because production hosts still hold standby datasets.
Once the code is gone, accounting would treat leftover `standby-*` datasets
as unknown and withhold the pool. The steps are:

1. **Drain.**
   - Every fleet image becomes standby-ineligible.
   - When no image is standby-eligible, the refill planner retires every
     sealed standby, still bounded by the per-pass retirement budget (four
     per pass, one pass a minute). This lifts ADR-0163's rule that a
     replaced image's standbys leave only as configured replacements become
     sealed, but only in this all-ineligible case.
   - Creates may still claim a remaining standby while the drain runs.
2. **Delete,** once both hosts report zero standby datasets. Remove:
   - `Lilly.Host.StandbyDisk`, `StandbyPlan` and `StandbyRefill`;
   - the `StandbyDisk` lifecycle resource and the standby claim in
     `ZFSDataset.prepare_batch/3`;
   - the standby audit in pool accounting, and the `.rootfs.standby` and
     `standby: true` paths;
   - the Nix options `services.lilly.standbyDisks.*` and each image's
     `standby` flag;
   - the `standby_*` events.

   Any `standby-*` dataset that still appears afterwards is unknown storage,
   and accounting fails closed on it.

## Alternatives

- **Keep standbys for NixOS only.** Rejected. The measured on-demand create
  is no slower end to end, so the cost buys no measured benefit.
- **Delete the code at once.** Rejected. Hosts still hold standby datasets,
  which would make accounting withhold both pools until an operator cleaned
  them up.
- **Standbys as clones of a template snapshot.** Rejected, as in ADR-0176:
  accounting refuses clones, and a clone ties the template's lifetime to
  every VM made from it.

## Consequences

- Each create pays a block-clone copy of about 1 s at a 22-way burst,
  outside the pool lock and in parallel.
- No more fill or retire churn, no standby datasets in pool listings or the
  ARC, and fewer pool-lock sections.
- A large part of Lilly's storage code and its tests is removed in step 2.
- ADR-0146 is superseded. The standby parts of ADR-0163 decision 1 (refill
  planning) no longer apply once step 2 lands. Its capacity-damping
  decisions are unaffected.

## Invariants and verification

- **Drain.** With no eligible image, a plan retires every sealed standby
  within the retirement budget. The standby plan property test covers this
  with an empty eligible image list. The `image-template` machine test
  expects deconfiguring every image to retire all its standbys.
- **Production.** Both hosts reach zero `standby-*` datasets before step 2
  ships. Creates keep working throughout: they claim a standby while one
  remains and copy on demand afterwards.
- **After step 2.** No code path creates, claims or audits a standby. A
  stray `standby-*` dataset withholds the pool instead of being trusted.

## Implementation evidence

Step 1:

- `StandbyPlan.plan/3` (`lilly/lib/lilly/host/standby_plan.ex`, removed by ADR-0177)
  contains the drain rule (contract `standby-plan-bounded`), checked by the
  `property test` (`lilly/test/host/standby_plan_test.exs`, removed by ADR-0177).
- [`fleet/guest-images.nix`](../../../fleet/guest-images.nix) makes every
  image standby-ineligible.

Production drain: step 1 was deployed as `526152d22` (2026-10-16 04:47 Z).
Within about 20 minutes both hosts went from 32 standby datasets each to 0,
and their `.lilly-standbys/records` journals were pruned to 0. No VM
directory on either host held a `.rootfs.standby` file.

Step 2 deletes the subsystem: `Lilly.Host.StandbyDisk`, `StandbyPlan`,
`StandbyRefill`, the `Lilly.Lifecycle.StandbyDisk` resource, the standby
events, `Storage.contended?/1`, the standby claim in
[`ZFSDataset.prepare_batch/2`](../../../lilly/lib/lilly/host/zfs_dataset.ex),
the standby class in pool accounting, the standby shape in
[`ZFS`](../../../lilly/lib/lilly/host/zfs.ex), and the `standby` option and
`standbyDisks.*` options in
[`nix/domains/system/lilly.nix`](../../../nix/domains/system/lilly.nix) and the fleet hosts.
Evidence:
- the [ZFS property](../../../lilly/test/host/zfs_test.exs)
  `retired-standby-is-unknown-storage` shows a `standby-*` dataset withholds
  the pool wherever it is mounted;
- the configuration test refuses the retired `standby` image key;
- the `image-template` machine test no longer has a standby subtest.

## Open questions

None.

## Related decisions

- [ADR-0146](0146-standby-guest-disks.md): superseded.
- [ADR-0163](0163-bounded-standby-refill-and-capacity-damping.md): its
  standby refill planning ends with step 2.
- [ADR-0176](0176-host-concurrency-single-writers-and-effects.md):
  decision 6 and the measurements.
