# lilly-interrupted-launch-at-most-once

Priority P0; confidence high in intended invariant, unexecuted in this pass. Safety.
All Antithesis instrumentation is **missing**, per [fresh scan](../existing-assertions.md).

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

Open questions:

- Can the hosted adapter retain independently durable submission witnesses with production marker semantics? `(partial: native barrier exists; hosted durable adapter witness unproven)`

Next probe: The production launch path persists launch-attempt.bin before privileged start, and the native submission-recovery scenario has a real barrier on either side of submission plus marker hash and VMM snapshot checks. A hosted executor adapter with an independently durable submission ledger is not present in inspected source. Probe adapter marker-before-effect ordering under process death; do not equate adapter success with systemd acceptance.

### Investigation Log

#### Can the hosted adapter retain independently durable submission witnesses with production marker semantics?

- Examined: `lilly/lib/lilly/vm/driver.ex:336-421,1474-1492; nix/verification/tests/machines/fleet/scenarios/submission-recovery.py:21-105,190-191`.
- Found: The production launch path persists launch-attempt.bin before privileged start, and the native submission-recovery scenario has a real barrier on either side of submission plus marker hash and VMM snapshot checks. A hosted executor adapter with an independently durable submission ledger is not present in inspected source. Probe adapter marker-before-effect ordering under process death; do not equate adapter success with systemd acceptance.
- Not established: No current hosted/native execution was run in this investigation; source and test presence alone do not establish the physical outcome.
- Conclusion: partial; Name native barrier as existing test presence; keep hosted adapter question partial.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `integrated-zfs-host`. proposed-real-inner-zfs-backed-lilly; unbuilt, native physical companion where indicated; independent witness: caller key/committed rows correlated with exact physical boot, disk or capacity sample; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R5`: Add a unique SUT-side `Reachable` or `Sometimes` at the observed intermediate commit/effect before uncertain reply. Requested faults alone are not reached checkpoints; retain the independent final `Always` oracle. `R14`: Accepted placement requires a real current measured inner-ZFS-backed Lilly pool and execution readiness, or native KVM. The current Control-only hosted pool reports unavailable and cannot establish admission, guest or satellite effects; never seed fake admission. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.
