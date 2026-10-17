# request-recorder-restart-conserves-custody

P0; high confidence; safety. Instrumentation **missing** per [fresh scan](../existing-assertions.md).
`Always(durable admission settles at most once; recorder restart/unknown producer
liveness cannot settle before deadline; lifetime identity/counters never reset)`;
message **"Request recorder recovery conserves admissions without inventing producer death"**.

Evidence: `nix/domains/system/otel-guest/receiver/src/request_recorder.rs:151-186`
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
`(partial: native NixOS two-unit fixture exists; hosted equivalent not proven)`

### Investigation Log

#### Which hosted deployment can retain exact systemd-unit producer authentication while faulting recorder and producer independently?

- Examined (2026-10-13): `nix/verification/tests/machines/otel-request-recorder/default.nix:51-113`, `driver.py:1-220`, `commit-reply-loss.py`, `nix/domains/system/otel-guest/receiver/src/request_recorder.rs:155-186,207-245,305-362`, and `durable_slo.rs:770-800`.
- Found: the existing NixOS VM gives each Rust recorder and BEAM producer its own systemd unit and validates the real UID/cgroup/boot/start identity. It exercises recorder restart, producer death, whole-VM crash recovery, and a source-built commit-before-reply cut. Its state tests prove duplicate settlement refusal and retained checkpoint identity.
- Not found: a documented hosted container topology that gives the recorder the same systemd unit cgroup and kernel identity while allowing independent Antithesis process faults. The native VM fixture can establish this boundary, but ordinary container process kills alone cannot claim equivalent authentication.
- Conclusion: partial for hosted topology. Reuse the NixOS VM with both production units for native acceptance; for an Antithesis deployment, first probe peer UID/cgroup/start identity through the real RPC, independently kill the recorder and producer, and verify the checkpoint across their restarts. Until that probe passes, limit hosted claims to the Store/RPC subset.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `recorder`. real-hosted-measurement-with-native-systemd-companion; independent witness: producer PID/start and effect vs durable recorder/SQLite ticket or trace digest. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

## Authored assertion snapshot

**Authored assertion snapshot (2026-10-13 15:03 UTC):** Primary `always` message is present at `antithesis/workload/recorder/scenarios.py:219`. Checkpoint conservation and conditional socket-inode restart witness; independent forced-restart orchestration and shared /proc producer identity remain incomplete. It is outside the currently staged control-core selection. This records source presence, not a passing hosted or native result.
