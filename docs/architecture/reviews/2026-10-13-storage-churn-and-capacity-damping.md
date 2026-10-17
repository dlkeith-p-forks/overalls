# Storage churn and capacity damping review — 2026-10-13

## Scope and authority

Part of the authorized 2026-10-13 investigation of refused clones, relocations
and resizes on the production fleet (host shell, database reads, Porsche
machine creation and deletion, changes without limit). The user chose 32
standby disks per image. [ADR-0163](../decisions/0163-bounded-standby-refill-and-capacity-damping.md)
records the decision; this review records the evidence and verification. The
clone-side findings are in the
[clone cleanup liveness review](2026-10-13-clone-cleanup-liveness.md).

## Production findings

| Observation | Evidence |
| --- | --- |
| 256 standby datasets per host (128 per image, two images) for seven guests; 287 Lilly mounts on overalls | `zfs list`, `findmnt` |
| The guest-image rebuild between 11:43 and 12:58 retired 260 and filled 257 standbys; fills p50 1.2 s, p90 8.8 s, max 18 s, each under the pool lock | `lilly.standby_disk_filled`/`retired` journal timings |
| `pool.snapshot_withheld` fired 352 times in that hour (`usage_moving`, `storage_busy`) and about 150 times per hour at rest (10,570 in fourteen days) | `lilly.service` journal |
| A withheld pool keeps its previous row, which ages out of the five-second capacity window, so admissions in that window refused `insufficient_capacity`, `source_unavailable` or `host_unavailable` | `host_reports.ex`, `host_liveness.ex` at `f2970dfe6`, `clone.failed` journal |
| ZFS ARC capped at 4 GiB on 125 GiB hosts with metadata at 3.86 GiB and dnodes above the default limit; `arc_prune` consumed most of a core for nineteen days (host load 18–23) | `/proc/spl/kstat/zfs/arcstats`, `top` |

## Architecture assessment

Initial and final assessments: the change alters the standby refill policy
(planned, budgeted, yielding), the pool configuration shape (two new counts),
the capacity observation rule for usage drift (resample, then latest coherent
tree), the pool snapshot lock wait (200 ms) and Marshall's busy-entry
handling (freshness extension bounded by a grace window and host authority).
Pool ownership, accounting checks, the allocation audit, isolation and
authorization are unchanged: a busy entry still never changes measured numbers,
unavailable still revokes at once, and no standby earns VM credit. ADR-0146's
refill open question closes; ADR-0031 and ADR-0140 gain dated evidence notes.
ADR-0159 applies to the closed pool configuration shape.

## Verification

| Gate | Result |
| --- | --- |
| Lilly `standby_plan_test.exs`, `zfs_test.exs`, `session_pools_test.exs`, `standby_disk_test.exs` | pass (recorded with the commit) |
| Marshall `host_reports_test.exs` (busy within grace extends, beyond grace does not, unavailable revokes) | pass |
| `nix eval` of the overalls and dungarees Lilly options (`perImage` 32, `fillsPerPass` 4, `retirementsPerPass` 4) and the `perImage × images ≤ 64` assertion | pass |
| Lilly and Marshall `mix precommit` | recorded below when the full gates complete |
| Native `image-template` standby subtest (retirement by reason), `zfs-lifecycle` | rerun pending |

## Production acceptance

Rollout order: `31b56c321` refused at preflight (predicate in the live
updater); `a50316bba` (budgets reverted) deployed both hosts; `a6d166c3a`
(budgets) deployed dungarees and failed activation on overalls (relay socket);
`d720db346` (dependents rule) deployed dungarees and failed the same way on
overalls (activation runs in the live updater); `737723e92` (relay socket
`PartOf` Marshall) deployed both hosts with 52 units retained on overalls;
`cda064f36` (resize) then deployed with 52 and 20 units retained.

| Observation (18:01, about ten minutes after both hosts converged) | overalls | dungarees |
| --- | --- | --- |
| Standby datasets (from 256; target 64, retired four per pass, `reason: excess`, passes yielding to pool-lock waiters) | 88 | 105 |
| `pool.snapshot_withheld` in the last ten minutes (before: about 45 and 17) | 17 | 3 |
| ZFS ARC `c_max` / size / `arc_dnode_limit` | 24 GiB / 17.9 GiB / 6 GiB | 24 GiB / 7.5 GiB / 6 GiB |
| `arc_prune` counter | unchanged since 17:51 (was rising for nineteen days) | unchanged since 17:13 |
| Load average (1 min; before: 23 and 0.4) | 5.7 | 0.1 |
| `lilly.slice` ceiling applied live | 95232 MiB | 95232 MiB |
| Units kept running across the four deploys after `a50316bba` (`postgresql.service` and `wireguard-fleet0.service` since 17:02 on overalls; `lilly.service` on dungarees since 17:52 across the resize deploy) | yes | yes |

By 18:40 both hosts held exactly 64 standbys. `pool.snapshot_withheld` ran at
about 34 per hour on overalls and 22 per hour on dungarees over the following
half hour, down from 150 to 270 per hour, but above the five-per-hour target,
which stays open (ADR-0163 open question: the remaining withholding is real
pool-lock contention from guest activity, not usage drift). The `arc_prune`
counters have not moved since the ARC budget took effect. No
`lilly.clone_effect_unconfirmed` was logged in that period.

The Marshall-only push `282bd8084` (43 units retained on overalls) still
restarted Lilly on overalls at 18:45: `switch-to-configuration` restarted
`overalls-resource-policy.service`, whose command line names the per-release
manifest, and Lilly requires it; dungarees' Lilly stayed up. With the oneshot
`restartIfChanged = false` (ADR-0165 decision 5), the next push `dba649c6e`
restarted Marshall on overalls at 18:54 while `lilly.service` kept its 18:45
uptime and the oneshot its 18:45 start; on dungarees Lilly has run since
17:52 across four releases.

## ARC budget and safe memory decrease (ADR-0164)

| Gate | Result |
| --- | --- |
| `resources_test.py` (memory-only decrease compatible; CPU and quota decreases not; safe decrease applies and writes the dnode limit; unsafe decrease refuses `resource_decrease_unsafe` and changes nothing) | pass |
| `nix eval` of both hosts: `zfs_arc_max=25769803776 zfs_arc_dnode_limit=6442450944`, `memoryMiB` 95232 | pass |
| Native `auto-update` resource fragment (raise, safe lower, refused unsafe lower) and the relay-retention assertion | pass (122 s, merged tree `31b56c321`) |
| Fleet push `31b56c321` | refused at preflight on both hosts, `lilly_binding_change`: the live (old) updater's predicate rejected the RAM decrease; budgets reverted in a corrective push, re-applied after the new updater is live (ADR-0164 rollout note) |

## Restart only changed units (ADR-0165)

| Gate | Result |
| --- | --- |
| `unit.py` `ChangedUnits` (identity by unit file and drop-ins; stale bundle and dropped consumers restart; activation stops only the changed consumer and records `update.units_retained`) | pass, 28 focused tests |
| Overalls deployment manifest builds with `bundleConsumers` | pass |
| Native `auto-update` test (relay PID survives a candidate that changes other units) | pass (122 s, `31b56c321`) |
| Fleet: corrective push `a50316bba` deployed both hosts; budget push `a6d166c3a` activated on dungarees with 28 units retained, ARC 24 GiB, dnode limit 6 GiB, slice ceiling 95232 MiB applied live, Lilly restarted (its configuration changed) while wireguard, nix-daemon and secret preparation stayed up | updater journal, `arcstats`, cgroup |
| Fleet: the same push failed activation on overalls (`activate_failed`, roles restored, previous system retained): the unchanged `marshall-fleet-relay.service` and its listening socket were retained, Marshall's stop took the relay down by propagation, and the next fleet connection socket-activated the relay, which requires Marshall and pulled it back up during the stop phase; fixed by closing the restart set over `consumerDependents` (relay and exporters restart with Marshall, so the relay socket is quiesced); because activation runs in the live updater the fix could not deploy itself (second failure 17:2x), so the relay socket became `PartOf` Marshall, which the live updater treats as a changed socket | overalls journal 17:13, 17:2x; `attempt.log` "Job for marshall-overalls.service canceled" |

## Limits and follow-up

- The refill pass does not back off under host memory pressure (ADR-0163 open
  question).
- A changed `/etc` file read at runtime by an unchanged unit does not count as
  a unit change (ADR-0165 open question); Lilly's configuration is a store
  path referenced by its unit, so a configuration change still restarts it.
- The refill pass does not back off under host memory pressure (ADR-0163 open
  question).
