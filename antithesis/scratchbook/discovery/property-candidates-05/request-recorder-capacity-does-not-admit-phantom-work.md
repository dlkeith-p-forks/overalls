---
sut_path: /home/ghuntley/src/kittens-antithesis-reset
commit: c835eb1017d24a001215c319373fa4204d64269b
updated: 2026-10-13
external_references: []
scope_answer: "Repository only (Recommended)"
focus: "05 — Resource Boundaries"
---

# request-recorder-capacity-does-not-admit-phantom-work

**Claim, priority, confidence.** P1 safety, high confidence in the capacity contract. At 4096 pending tickets, the next measurement admission returns unrecorded/refused and marks coverage incomplete; it must not fabricate a durable ticket or prevent the application effect from following its own authority. Proposed unique assertion: Always("request recorder saturation cannot fabricate admitted tickets or a clean quality interval", durable_pending <= 4096 && unrecorded_ids_have_no_durable_admission && saturated_interval_not_clean). Missing per ../../existing-assertions.md. The effect itself can continue when measurement fails, per ADR-0149's separation.

**Source and history.** elixir/request_accounting/lib/overalls/request_accounting/producer/server.ex:7-8 sets 5 s heartbeat and 4096 local pending cap; handle_call admit at :42-66 returns :unrecorded and mark_gap at saturation, timeout or invalid owner; complete at :70-80 retires a monitored ticket; owner DOWN at :105-125 checks actual owner death. Rust nix/modules/otel-guest/receiver/src/durable_slo.rs:12 and :248-260 independently enforce MAX_PENDING 4096 in durable state. request_recorder.rs:248-268 bounds frames at 512 bytes; Runtime::publishable at :388-405 requires recent authenticated producer heartbeat, usable state, available capacity and no overdue admission. A prior focus03 recovery candidate covers crash custody; saturation is a distinct observation-integrity boundary.

**Workload and oracle.** Keep 4096 real workers alive after recorder admissions with a test application that can produce independently witnessed effects. Attempt a 4097th admission and continue its authorized work. Compare producer ticket IDs and local quality marker to read-only durable recorder pending IDs and application fixture effects. After a worker dies or completes, the durable pending count must fall and a new measured admission may succeed; healthy quality may resume only after proper gap recovery. No aggregate suite exit or emitted metric alone proves coverage. Preserve real producer authentication and worker PID/start identity in the test topology.

**Limit menu.** 4095/4096/4097 outstanding, one completion and one proven death, heartbeat ages just below/at/above 15 s recorder threshold, caller admission deadline and recorder reply loss. A smaller compiled test limit would change the claim; default full boundary is necessary for end-to-end proof.

**SUT guidance and limits.** Mark local saturation refusal, durable admission commit and quality-gap publication with IDs only. A hosted deployment needs enough BEAM tasks and file descriptors for 4096; a native subset can validate bounds when full hosted saturation is too costly. Open questions: Is a full 4096-worker hosted campaign feasible without unrelated OS limits dominating? Which fixture preserves systemd producer identity while independently faulting recorder?

**Architecture/HLDD impact.** No production or handbook change; diagnostics capacity remains separate from business authority.
