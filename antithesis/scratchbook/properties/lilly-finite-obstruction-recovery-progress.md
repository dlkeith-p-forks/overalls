# lilly-finite-obstruction-recovery-progress

P1; high confidence in conditional target; liveness. Instrumentation **missing**
per [fresh scan](../existing-assertions.md). `Sometimes(probe accepted before
restart && obstruction_removed && current physical outcome is committed && a
neighbor completed independent work)`; message **"Lilly retained eligible intent progresses after finite obstruction and restart"**.
This tests a designated probe's meaningful recovery, not Sometimes(true), generic
function reachability, or an unconditional promise for every conservative refusal.

Evidence: Runtime `lilly/lib/lilly/control/runtime.ex:148` opens retained Store
under ownership; `:867-902` ensures actors for reread commands. Actor `:275-325`
retries journal contention on ticks, `:423-439` defers physical contention;
`lilly/lib/lilly/host/storage.ex:12` serializes pool work;
`OverallsProtocol.Cadence` drops ticks while sampling is in flight. ADR-0152
and source notes describe avoiding repeated whole-pool verification starvation.
`marshall/lib/marshall/compute/dispatch.ex:3-17` makes notification a repeatable
hint over durable intent. No general source-defined fairness deadline was found.

History/preconditions: choose accepted stopped/known-running intent for which
no consumed-but-unsubmitted launch marker requires explicit new authority; retain
valid host/image/address/credential and enough capacity. Pause an actual pool or
journal owner, restart the actual Lilly supervisor, lose Control hints, then
release obstruction and provide a fault-free observation interval. Admit a neighbor
to discriminate global starvation from target-specific refusal. Include delete
cleanup where real physical cleanup can eventually complete.

Oracle: observer follows exact operation/placement/revision through committed
Marshall receipt, matching journal outcome, independent guest/process/disk proof
and neighbor effect. Use actual accepted work, not a fixture's completed flag.
Repeated sampled errors do not establish failed progress until preconditions are
restored and the observer has demonstrated access to all required services.

Guidance: `Reachable` **"Lilly recovered pending work after losing its dispatch hint"**
at reread/actor activation; **"Lilly recorded physical outcome after journal contention cleared"**
at journal success following independently observed lock contention. Replay anchors
at last deferral and first unlocked tick expose starvation histories.

Values: 1/2/4 simultaneous mutations; 0/1/4/16 dropped sampler ticks; one complete
sample versus slow sample; finite lock hold 1/2 seconds. Use actual configured
cadence and delete retry delays, never a fixed guessed production SLA. Start the
quiet interval only after measured restoration. Real services hosted cover retained
intent; TCG or native guests/storage are needed for physical progress; native
ZFS campaign covers actual pool contention and production fairness.

Open questions:

- What measured baseline interval supplies the workload budget? `(partial: cadence found; topology-specific baseline unmeasured)`

Next probe: Runtime cadence and Actor retries provide no universal recovery SLA. No measured baseline on the selected hosted topology is recorded here. Probe each eligible operation after restoring services and record P95/P99 baseline and a bounded budget with the actual topology; retain quiet-period and eligibility preconditions.

### Investigation Log

#### What recovery interval can serve the workload budget?

Examined Runtime exchange/retry, Actor schedule/deferral and Storage locking.
Found finite configured retries and dropped ticks; not found a universal
end-to-end completion deadline. Conclusion: measure the actual selected topology,
record its budget, and retain explicit eligibility and quiet-period conditions.

#### What measured baseline interval supplies the workload budget?

- Examined: `lilly/lib/lilly/control/runtime.ex:400-429,824-856,925-932; lilly/lib/lilly/vm/actor.ex:178-181,345-395`.
- Found: Runtime cadence and Actor retries provide no universal recovery SLA. No measured baseline on the selected hosted topology is recorded here. Probe each eligible operation after restoring services and record P95/P99 baseline and a bounded budget with the actual topology; retain quiet-period and eligibility preconditions.
- Not established: No current hosted/native execution was run in this investigation; source and test presence alone do not establish the physical outcome.
- Conclusion: partial; Retain partial measured-budget question; no guessed deadline.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `integrated-zfs-host`. proposed-real-inner-zfs-backed-lilly; unbuilt, native physical companion where indicated; independent witness: real ZFS GUID/content plus original lock holder and sampled pool state; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R1`: `Sometimes` witnesses one designated recovered history. Track its exact operation ID, observed preconditions and dependency restoration; separately check that operation’s terminal state after a measured quiet interval. Missing oracle/precondition is unexercised, not a pass or a liveness violation. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.
