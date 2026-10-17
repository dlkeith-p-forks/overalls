# Host concurrency review (2026-10-16)

## Scope

The user asked how to stop "the host lock" from blocking host work and wanted
the best possible design. This review covers how Lilly's lock primitive,
lock scopes, pool preparation, actors and observation fit together.

Sources:
- the Lilly source;
- the ADRs listed under "Related decisions" in
  [ADR-0176](../decisions/0176-host-concurrency-single-writers-and-effects.md);
- the Lilly journals of both fleet hosts for the last 7 days, read over SSH
  with `journalctl`. The analysis scripts printed only event names,
  durations and counts.

## Findings

| Area | Observation | Cause | Decision |
|---|---|---|---|
| Lock model | No host-wide lock. There are about 20 per-directory `flock` inodes. A root-disk copy holds only the placement lock and a shared template lease. | `lilly-host-lock` is at once the lock, the crash custody and the only executor of mutations. So each lock's scope grows to everything run under it, and the owner is implicit (`Lock.current`). | ADR-0176 decision 4. ADR-0173 decision 10 corrected. |
| Copies | Root `image_copy` on dungarees: n=21, p50 15 ms, p95 126 ms, max 1.6 s. Creates use block-cloned standbys (`method=offload, source=standby`). | The 30-minute 64 GiB copy happens only when the store cannot clone (the nested test's 9p share). | None needed for production. |
| Create latency | dungarees, pending→ready: p50 50 s, p95 149 s. `materializing`: p50 46.8 s, p95 144 s. overalls `materializing`: p50 1.3 s. | Bursts of 23–26 creates arriving within ~1 s drain one launch every 1.9–2.3 s, so the last waits 77–149 s. Each create runs ~90–210 utilities under the pool lock: two exact whole-pool observations, each retried up to 3× because usage moves, plus identity probes. The credits they compute are discarded. | Decision 1. |
| Waiting | 99 `vm.execution_deferred reason=storage_busy` in two burst hours. | A waiter polls a non-blocking `flock` every 10–30 ms, starting a new helper each try. It gives up after 1 s and retries on the actor tick, with no FIFO. | Decisions 1 and 4. |
| Pool lock share | ~1,300 standby fills and ~1,550 retirements a week (447 because the image was replaced). Each takes the pool lock 2–3 times. The capacity reporter takes it every 1–2 s. | Upkeep and observation share the mutation lock. | Decisions 1 and 6. |
| Templates | Builds: copy p50 2.4 s, max 35 s. In-BEAM verify p50 3.3 s, max 67.5 s. 27 builds in the week. | While a build runs, creates of the same image get `storage_busy`. Images are also re-hashed in the BEAM at every boot. | Decision 3. |
| Observation | 62 `systemctl` calls timed out at 3 s. | Every running VM is re-adopted through `Driver.launch/5` every second. Each pass takes the placement, intent and host-wide network locks and runs `systemctl show`. | Decision 2. |
| Preemption | A stop or delete waits for a whole create. | The actor runs one opaque task, which holds the placement lock throughout. | Decision 2. |
| Privilege | Lilly runs as root without hardening. | The helper gives crash custody but no privilege separation. | Security end state. |

## Changes

- [ADR-0176](../decisions/0176-host-concurrency-single-writers-and-effects.md)
  (accepted, planned) records six decisions:
  1. pool single writer with group commit;
  2. reconciler actors, with observation off the mutation path;
  3. single-flight templates with native digests;
  4. the `lilly-hostd` effects engine;
  5. durable host jobs;
  6. standbys kept only if the evidence supports them.
- ADR-0173 decision 10 and the HLDD storage chapter now describe the copy's
  locks correctly.
- `Lilly.Host.Storage.locked/4` emits `lilly.pool_section` for slow or busy
  sections, with kind, wait and hold time. It is the baseline for decision 1.

## Checks run

Each stage records its gates and machine tests in ADR-0176. A user-approved
production burst on 2026-10-16 (26 concurrent creates, 23 of them on overalls)
measured `materializing` at p50 7.3 s and max 10.7 s, with no
`storage_busy`. In the baseline, the last create of a 23–26 create burst
waited 77–149 s. Preparation ran in batches of 1, 15 and 7 creates, about
3.8 s of pool hold in total. The restart digest cache cut image verification
on dungarees from 60 s to 0.08 s.

## Remaining gaps

None of the six decisions is implemented yet. The ZFS channel-program
limits, the D-Bus transport and the feasibility of dropping privileges are
open questions in ADR-0176.
