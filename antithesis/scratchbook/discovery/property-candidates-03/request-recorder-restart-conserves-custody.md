# request-recorder-restart-conserves-custody

P0; high confidence; safety. Instrumentation **missing** per [fresh scan](../../existing-assertions.md).
`Always(durable admission settles at most once; recorder restart/unknown producer
liveness cannot settle before deadline; lifetime identity/counters never reset)`;
message **"Request recorder recovery conserves admissions without inventing producer death"**.

Evidence: `nix/modules/otel-guest/receiver/src/request_recorder.rs:151-186`
(`liveness`) separates unavailable boot/proc/pidfd evidence from death;
`:305-319` (`reconcile`) settles only proven-dead or expired producers;
`:324-362` (`apply`) responds after Store.transition. Durable implementation
`durable_slo.rs:274-292` rejects foreign, expired and already-settled finish;
`:314-373` counts once, excludes separately and gives loss no duration;
`:518-587` (`transition`, `persist`) fsyncs stage, rename, directory and poisons
after uncertain write. A lost Admit reply can leave an admission that producer
does not know; no stable producer admission-retry key exists, so do not assert
that a second Admit is necessarily the same request.

History: Admit/Finish with reply loss after commit, kill independent recorder
while producer survives, restart against same state, obscure proc/pidfd evidence,
then independently prove producer death or pass immutable deadline. Send delayed
Finish and duplicate Finish after reconciliation; disk full after rename,
checkpoint missing/corrupt and fresh producer incarnation are separate controls.

Independent oracle: capture observer-known acknowledged IDs plus uncertain
admission attempts, decode actual checkpoint after real exclusive reopen, compare
monotonic next_id/lifetime and requests=successes+failures; duration bucket totals
equal duration_count, no fabricated downtime duration, exclusions excluded.
Witness boot ID/start ticks/pidfd independently. A missing reply is not proof
that no admission exists. Recorder restart is not producer restart.

Guidance: `Reachable` **"Request recorder reopened pending work while its original producer remained alive"**;
**"Request recorder reconciled a proven-dead producer once after reply loss"**.
`AlwaysOrUnreachable` **"Poisoned request recorder refuses fresh acknowledgments"**
on the optional storage-failure path. Mark post-commit/pre-reply and liveness
classification branches using numeric counts and closed reasons only.

Values: 1/2/4095/4096 pending admissions around MAX_PENDING, configured deadline
1 second/production value and just-before/equal/after expiry (constructor allows
1s..1day), 0/1/8 duplicate Finish, positive/zero/unmeasured duration, same PID/new
start identity. Hosted native recorder with actual systemd/cgroup identity is
needed for end-to-end authentication; container helper tests cover Store/RPC only
when production unit identity cannot be represented.

Open questions: Which hosted deployment can retain exact systemd-unit producer
authentication while faulting recorder and producer independently?
