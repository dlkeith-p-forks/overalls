# lilly-interrupted-launch-at-most-once

Priority P0; confidence high in intended invariant, unexecuted in this pass. Safety.
All Antithesis instrumentation is **missing**, per [fresh scan](../../existing-assertions.md).

`Always(physical_submissions[placement, epoch, generation] <= 1)` with literal
message **"Lilly recovery never resubmits one physical launch authority"**.
Count actual systemd submissions, rather than executor calls: retries/adoption
can legitimately invoke the executor again. One launch authority cannot produce
two independently witnessed starts, including after loss of its BEAM owner.

Evidence: `lilly/lib/lilly/vm/actor.ex:272-312` (`schedule/1`) persists Journal
attempt before its task; `lilly/lib/lilly/vm/driver.ex:336-418` (`start/5` and
submission) additionally persists `launch-attempt.bin`; `:1474-1492`
(`not_attempted/3`) rejects an equal/older authority. These two markers have
different purposes and must both be tested. `lilly/lib/lilly/vm/executor.ex:257`
adopts an already running unit. ADR-0017 explicitly allows conservative failure
if death occurs after marker publication but before submission; success for that
same generation is therefore not an unconditional liveness requirement.

History: admit real provision/start; branch after actor attempt, after launch
marker rename/fsync, before systemd acceptance, after unit acceptance, and after
actual boot but before Journal.record. Kill actor, whole Lilly release and native
worker separately; preserve real supervision and persistent disks. Redeliver the
same intent, then allow an explicitly new generation as a separate control.

Independent oracle: record systemd invocation/accepted job and actual VMM/guest
boot identity in the external observer; preserve PostgreSQL operation identity,
decoded Store and journal bytes. A PID alone is insufficient because reuse is
possible. Use PID/start-time/boot challenge and guest witness together. API timeout
does not establish no submission. Native custody must be retained.

Instrumentation: proposed `Reachable` **"Lilly launch marker survived caller loss before submission"**
at the recovered equal-marker refusal, and **"Lilly adopted a physically completed unrecorded launch"**
after adoption plus independently matched boot, rather than generic function entry.
Emit safe identity/revision/phase keys; no command arguments or guest bytes.

Values/preconditions: epoch/generation pairs (1,1),(1,2),(2,1), stale (1,MAX-1),
same-ID duplicates 1/2/8; 1/2 independent guests; marker interruption on each side
of durability publication. Keep profile/image/readiness admitted and valid.
Hosted TCG can exercise real Store/actor/journal with an explicit lower executor
adapter and genuine guest effect; only native systemd/Firecracker validates this
production submission and custody invariant. Mock executor success is insufficient.

Open questions: Can the selected hosted adapter expose an independently durable
submission witness with the same conservative marker-before-effect semantics?
No current execution or confirmed defect is claimed.
