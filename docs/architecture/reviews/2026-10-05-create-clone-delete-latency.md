# Create, clone and delete latency review (2026-10-05)

## Scope

This review revalidates the provisioning-fastpath assumptions against
production behaviour and extends the goal to cloning and deletion. The sources
were:
- the Overalls Marshall database, read-only over 30 days, using `occurred_at`
  timings;
- the Lilly journal;
- ZFS properties, read-only;
- authorized live Porsche runs on Overalls on 2026-10-05:
  - one NixOS create → clone → delete cycle;
  - a three-VM concurrent delete burst.

All run-owned VMs were confirmed deleted. Host load was high during the runs
(Overalls load about 25, 19 VMs running).

## Findings

| Area | Observation | Cause | ADR |
|---|---|---|---|
| Create | 30-day provision operation p50 14.9 s, p90 25.7 s. The live create reached readiness in 33.8 s: materializing 25.4 s, trust 6.7 s, SSH 0.7 s. | `vm.image_materialized` reported `source: verified, method: copy`. Images (`/nix/store`, dataset `zroot/root`) and VM datasets (`zroot/lilly/vm-*`) share pool `zroot`, block cloning is active and the properties match, but `FICLONE` returns `EXDEV` across mounts. Templates are off, so every create also hashes every artifact. | [ADR-0143](../decisions/0143-faster-create-clone-delete.md), [ADR-0130](../decisions/0130-verified-provisioning-fastpath.md) |
| Clone | 6 historical same-host clones published at about 61 s; the live clone took 71 s (published 61.7 s, source back up at 20.6 s). The copy effect took 46.9–55 s in every case. | Full uncompressed `zfs send\|recv` of about 3 GB logical at the 64 MiB/s peer rate, applied locally. Serial 1 s ticks, with results reported one tick late. prepare→probe→connect are genuinely ordered, because each later command carries the destination key from `prepare`. | ADR-0143, [ADR-0037](../decisions/0037-workload-placement-and-relocation.md) |
| Delete | 30-day p50 3.6 s, p90 679 s, max 1,412 s. Slow cases often had no concurrent operation. The live single and three-way deletes took 3.1–4.4 s on a quiet control plane. | The deletion precondition used an exact whole-pool observation whose usage counters, including pool-wide `available`, must match across two reads, so any pool write caused `storage_busy`. That became `cleanup_failed`, with backoff up to 30 s, and no stage was emitted. The cause was confirmed by code inspection. The live runs did not reproduce the tail; the journal before 2026-10-04 has rotated out. | ADR-0143, [ADR-0031](../decisions/0031-sparse-zfs-storage-and-capacity.md) |
| Clone source restore | Historical restores ranged from 19 s to 4,734 s; the live restore took 9.8 s. | Not reproduced. Re-measure after deployment. | – |
| Create SLO | 11 Porsche failures at 600 s and 3 Lilly physical failures at 120 s in 30 days. | Not attributed in this review. | – |

## Changes

See [ADR-0143](../decisions/0143-faster-create-clone-delete.md):
- kernel copy offload;
- compressed sends with a separate same-host clone rate;
- prompt clone result reporting;
- identity-fenced deletion with stage diagnostics and a contention retry.

## Checks run

- `cargo fmt`, Clippy `-D warnings` and `cargo test` for `lilly-image-copy`:
  11 passed, including 3 new Hegel properties.
- Focused Lilly suites: 257 passed (39 properties), covering config, zfs,
  image-copy, vm, transfer and clone.
- Native `kittens-image-copy` NixOS test, test script finished in 19.28s:
  - a same-pool source behind a separate read-only bind mount (the production
    `/nix/store` shape) refused `cp --reflink=always`;
  - the helper reported `offload`, with `bcloneused_delta=8388608`, i.e. all
    8 MiB were shared;
  - the destination stayed independent after writes and source destruction;
  - plain cross-dataset materialization also reported `offload`;
  - the quota-exhaustion refusal still failed as required.
- Native `kittens-zfs-lifecycle` NixOS test at `3bf5c1cf`, test script finished
  in 3624.76s (`globalTimeout` raised to 7200 s after two load-induced timeouts at
  load about 30):
  - the neighbor delete refused a quota change injected between its two
    observations (1.41 s);
  - it then succeeded in 2.01 s although a real 4 MiB pool write landed between
    them (`ZFS_OBSERVATION_FAULT=usage zfs-lifecycle delete 8`), leaving a
    retired deleted claim;
  - deliberate refusals emitted `stage` values such as `destroy`, `mounts`,
    `directory` and `recover_mount`;
  - one run under load hit the unchanged exact-observation `busy-prepare` check
    with `incoherent_zfs_observation` (accounting resampling exhausted); the next
    runs passed it.
- Native `kittens-zfs-guest-clone` NixOS test at `b83e3924`, test script finished
  in 1641.22s: both real same-host clone subtests (clone after resize, and a
  received copy as the next source) passed with compressed exports and the
  1 GiB/s local rate. The suite is dominated by guest boots, so its duration is
  not a copy-speed measurement.
- Native `kittens-porsche-lifecycle-fleet` NixOS test at `54a3c8e2`, test script
  finished in 793.83s: Porsche browser keys and native SSH ran the real guest
  lifecycle (create, restart, clone, relocation and delete), and the clone audit
  survived source deletion.

## Post-deploy measurement (2026-10-07)

Both hosts reported `7106dd24` healthy at 08:30Z. Guest image IDs changed with
the release (NixOS `dc87cba1…`; Ubuntu `5a9479b2…`, now **identical on both
hosts**). One live NixOS cycle on Overalls at load about 33 (baseline: about 25):

| Step | Before | After | Notes |
|---|---|---|---|
| Create | 35.8 s | 40.7 s | `vm.image_materialized` now reports `offload`, but materializing still took 29.5 s. That phase includes full SHA-256 verification of the image (`source: verified`), so the earlier 25.4 s was hashing plus copy, not mostly copy. |
| Clone | 71.0 s | 43.3 s | prepare→connect 5.6 s → 2.1 s; the copy effect 46.9 s → 22.2 s. |
| Delete | 3.2 / 3.1 s | 4.2 / 11.4 s | No `zfs_delete_unconfirmed` retries. The source delete included a running guest's shutdown. |

**Regression found.** Marshall deliberately re-offers `capture` through copying
to renew the source permit. The prompt-reporting change treated each
re-execution as new work, so the Lilly clone runtime looped about five times a
second, re-running capture (pool lock, snapshot and permit) during the copy.
The fix triggers immediate follow-ups only for effects first offered in that
exchange; it has a StreamData property.

Conclusions:
- Create speed now depends on removing per-create hashing (the ADR-0130
  template producers). The cross-host Ubuntu image equality that release needed
  is now observed.
- The copy step's remaining 22 s must be re-measured after the spin fix.

After the cadence fix deployed as `d7413482` (both hosts healthy at 09:15Z;
Overalls load about 29):

| Step | Baseline | `7106dd24` | `d7413482` |
|---|---|---|---|
| Create | 35.8 s | 40.7 s | 41.0 s |
| Clone | 71.0 s | 43.3 s | **37.8 s** (published 29.5 s, source restored 13.4 s) |
| Delete (copy / source) | 3.2 / 3.1 s | 4.2 / 11.4 s | 3.2 / 4.2 s |
| Three concurrent deletes | 3.2–4.4 s | – | 5.3–8.2 s, zero `zfs_delete_unconfirmed` |

- Capture ran 22 times over the 21.5 s copy, i.e. one per second: the spin is gone.
- The copy itself stays at about 60 MB/s (about 1.3 GB in 21.5 s) with the
  1 GiB/s local rate configured, so native send/receive throughput under host
  load, not the throttle, now bounds it. Block-cloning same-pool clones is the
  remaining lever.
- Create is unchanged because per-create image verification dominates; this
  awaits the ADR-0130 template release.

## Delete tail root cause and ADR-0144 (2026-10-07)

A templates-off benchmark delete waited 2187 s. Its 42+ unconfirmed attempts
all reported stage `destroy` with namespace cleanup `unconfirmed`. A mount
namespace pinned by a `nix-daemon` build worker (another session's
`nix build …#checks…fleet`) held the exact guest dataset root. Nix sandboxes
are user namespaces, so the copy was locked: host unmounts do not propagate to
it and ordinary unmount is refused. The delete completed exactly when that build
exited.

[ADR-0144](../decisions/0144-nix-builds-exclude-guest-datasets.md) runs
`nix-daemon` in a slave namespace whose start wrapper unmounts every pool, and
routes root and auto-update builds through it.

Native `kittens-zfs-namespace-cleanup` passed, with test script finished in
1652.69s:
- with a sandboxed build running, `nix-daemon`'s namespace held no `/pool`
  mount, and the guest delete completed while the build kept running;
- all existing service-copy, descriptor-pinned, proc-less, six generated-history
  and open-file subtests passed.

Earlier iterations failed and shaped the design:
- a root local-store build bypassed the daemon;
- `ExecStartPre` ran in a separate namespace;
- `MountFlags=private` made the daemon itself retain the guest mount.

Production after deploying `4ab664a5`:
- `nix-daemon` held 0 pool mounts on both hosts, and a concurrent NixOS test
  build's sandbox held 0 guest mounts;
- with six test-build processes running on Overalls (load about 11–17), a live
  cycle measured create 26.4 s, clone 36.7 s and deletes 3.2 / 4.2 s, with zero
  unconfirmed delete attempts.

The remaining user-namespaced holders (Prometheus, VictoriaLogs, a rootless
Podman pause) mirror the current guest set and so receive host unmounts.

## Templates-off baseline (2026-10-07)

The full controlled baseline at `fcba03e3` (26 creates, all cleaned up)
measured NixOS sequential median 28.5 s and Ubuntu 14.8 s create to
authenticated SSH, with `offload` on every create; see the
[provisioning ledger](../../history/ledgers/provisioning-fastpath.md).

## Clone reassessment (2026-10-07)

At this historical checkpoint after ADR-0143, the same-host clone copy remained
about 21.5 s of 37.8 s, bound by native send/receive throughput. The template
release did not touch the clone path.
[ADR-0145](../decisions/0145-same-pool-block-cloned-clones.md) then proposed
block-cloned same-pool clone disks with a local provenance journal replacing
receive lineage at adoption. It was subsequently accepted on 2026-10-09 and
remains partially implemented; this checkpoint does not establish its rollout.

## Standby and block-copy rollout (2026-10-09 to 2026-10-10)

This section preserves the incoming author report from `e3300040`. Current
[Dungarees](../../../fleet/hosts/dungarees/configuration.nix) and
[Overalls](../../../fleet/hosts/overalls/services.nix) source declarations enable
templates, 128 standbys per image and block-copy clones. The report's live
measurements and incidents were not independently repeated during this
observability change. Its claimed native pass has no exact wrapper, duration or
output artifact and is separate from the captured observability fleet runs.

**What was enabled and measured:**
- Both hosts run ADR-0146 standbys at 128 per image, plus ADR-0145
  `blockCloneCopies`.
- Sampled NixOS creates to SSH took 10.8–15.1 s, all reporting source
  `standby`. The templates-only median was 17.9 s.
- The sampled standby-backed creates skip disk copying. The reported remainder
  is boot and trust (about 5–8 s) plus control overhead; fallback creates still
  materialize a disk when no eligible standby exists.

**Incidents:**
- **Standby claim timeout:** a claim timed out under load and left an
  unmounted standby, which withheld the Overalls pool until `dd802f42` and
  `e203bbc7`. ADR-0146 records the details.
- **Profile rename outage:** another change (`d6f0383b`) renamed the
  `antithesis` guest profile without migrating deployed state. Lilly could not
  start on either host from about 23:45 UTC on 2026-10-09. Recovery:
  - `70e2aaf6` added a Marshall migration (rows plus the CHECK constraint)
    and a Lilly startup migration;
  - `76c6ce42` extended the Lilly migration to VM execution bindings.

The [profile custody review](2026-10-10-profile-migration-custody.md) records the
later repair to preserve exact legacy journal bytes and validate host binding
before migration. [ADR-0151](../decisions/0151-existing-state-standard-profile-migration.md)
keeps the wider existing-state extension proposed/partial; the reported recovery
does not establish a retained-host native upgrade. ADR-0145 and ADR-0146 are now
accepted/partial. Incoming `e7e2f2e3` records the user's ADR-0146 acceptance on
2026-10-09 and reconfirmation on 2026-10-10, updating the proposed status recorded
in the earlier `e3300040` review without adding runtime verification. Under
[ADR-0149](../decisions/0149-independent-observability.md), the earlier
diagnostic-wire rollout readers are historical; native journals, ownership and
capacity accounting retain authority independently of observability.

## Absolute campaign with standbys and block copies (2026-10-10)

Run `/tmp/opencode/fastpath-enabled-20261010-055354` at `09aecd8f`, with both
hosts quiet (load under 10).
- **Baseline:** none. The guest images had been rebuilt, so the earlier
  baseline is no longer like-for-like.
- **Samples:** all 26 creates reported source `standby`, and all were
  confirmed deleted.

**Create to SSH, sequential medians:**

| | Median | Range | Templates-only before | Old baseline (old images) |
|---|---|---|---|---|
| NixOS | 13.4 s | 12.0–16.9 s | 17.9 s | 28.5 s |
| Ubuntu | 11.3 s | 9.7–12.8 s | 13.7 s | 14.8 s |

**Where a NixOS create's time goes (12.9 s sample):**
- about 1.8 s before the host starts provisioning;
- `materializing` 3.8 s:
  - about 2 s of pool-locked verification before the claim;
  - the claim rename (0.25 s);
  - the adoption and drive steps themselves, which take milliseconds;
- launch 0.3 s;
- guest boot plus trust 6.4 s;
- SSH 0.6 s.

**Concurrency:** four simultaneous creates took 23–33 s. Each create's
pool-locked preparation runs about 3 s, made up of 20–25 native ZFS commands
at about 100 ms each over 268 datasets. The other creates defer with
`storage_busy` and their claims serialize about 3 s apart.

**Clone:** two same-host block-copy clones took 26.5 s and 29.6 s end to end,
against the earlier 37.8 s. Both reached `copy.json` `adopted`, with
`bcloneused` growth. In the 29.6 s clone:
- the root-disk block clone took 5.0 s;
- the source was stopped for about 4 s;
- destination boot plus trust took about 7 s.

**Delete:** sample deletes took 3–8 s.

## Not yet established

- Matched current clone throughput and complete create/clone/delete campaigns on
  both quiet hosts. Historical native correctness and the incoming sampled create
  timings have distinct scope; they do not establish matched speedup or the full
  current fault matrix.
- Independent current rollout acceptance, including the retained-state native
  upgrade and an exact captured result for the incoming standby fault fixture.
- Warm-create medians under 10 seconds. The reported 10.8–15.1-second samples
  remain above that target.
