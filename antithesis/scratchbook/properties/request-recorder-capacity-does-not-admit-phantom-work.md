---
sut_path: /home/ghuntley/src/kittens-antithesis-reset
commit: c835eb1017d24a001215c319373fa4204d64269b
updated: 2026-10-13
external_references: []
scope_answer: "Repository only (Recommended)"
focus: "05 — Resource Boundaries"
---

# request-recorder-capacity-does-not-admit-phantom-work

**Claim, priority, confidence.** P1 safety, high confidence in the capacity contract. At 4096 pending tickets, the next measurement admission returns unrecorded/refused and marks coverage incomplete; it must not fabricate a durable ticket or prevent the application effect from following its own authority. Proposed unique assertion: Always("request recorder saturation cannot fabricate admitted tickets or a clean quality interval", durable_pending <= 4096 && unrecorded_ids_have_no_durable_admission && saturated_interval_not_clean). Missing per ../existing-assertions.md. The effect itself can continue when measurement fails, per ADR-0149's separation.

**Source and history.** elixir/request_accounting/lib/overalls/request_accounting/producer/server.ex:7-8 sets 5 s heartbeat and 4096 local pending cap; handle_call admit at :42-66 returns :unrecorded and mark_gap at saturation, timeout or invalid owner; complete at :70-80 retires a monitored ticket; owner DOWN at :105-125 checks actual owner death. Rust nix/modules/otel-guest/receiver/src/durable_slo.rs:12 and :248-260 independently enforce MAX_PENDING 4096 in durable state. request_recorder.rs:248-268 bounds frames at 512 bytes; Runtime::publishable at :388-405 requires recent authenticated producer heartbeat, usable state, available capacity and no overdue admission. A prior focus03 recovery candidate covers crash custody; saturation is a distinct observation-integrity boundary.

**Workload and oracle.** Keep 4096 real workers alive after recorder admissions with a test application that can produce independently witnessed effects. Attempt a 4097th admission and continue its authorized work. Compare producer ticket IDs and local quality marker to read-only durable recorder pending IDs and application fixture effects. After a worker dies or completes, the durable pending count must fall and a new measured admission may succeed; healthy quality may resume only after proper gap recovery. No aggregate suite exit or emitted metric alone proves coverage. Preserve real producer authentication and worker PID/start identity in the test topology.

**Limit menu.** 4095/4096/4097 outstanding, one completion and one proven death, heartbeat ages just below/at/above 15 s recorder threshold, caller admission deadline and recorder reply loss. A smaller compiled test limit would change the claim; default full boundary is necessary for end-to-end proof.

**SUT guidance and limits.** Mark local saturation refusal, durable admission commit and quality-gap publication with IDs only. The existing NixOS recorder fixture provides separate authenticated producer/recorder units; extending it to 4096 real workers still needs measured memory and FD headroom. Open question: Is a full 4096-worker hosted campaign feasible without unrelated OS limits dominating? `(partial: exact Rust limit has a unit test; no full BEAM or hosted resource measurement)`

**Architecture/HLDD impact.** No production or handbook change; diagnostics capacity remains separate from business authority.

### Investigation Log

#### Is a full 4096-worker hosted campaign feasible without unrelated OS limits dominating?

- Examined (2026-10-13): `elixir/request_accounting/lib/overalls/request_accounting/producer/server.ex:42-66`, `nix/modules/otel-guest/receiver/src/durable_slo.rs:239-267,766-777`, and `nix/tests/machines/otel-request-recorder/default.nix:51-113`.
- Found: the BEAM producer caps local pending tickets at 4096 and the Rust state independently caps durable pending admissions at 4096. A Rust unit test exercises the exact full boundary. The existing NixOS recorder fixture has a real systemd BEAM producer and recorder, but its driver exercises small numbers of workers; its VM has 1536 MiB and two cores.
- Not found: a measured hosted 4096-worker run, BEAM task/FD/memory envelope at that size, or a TCG resource budget. A loop of raw Rust admissions would bypass the local worker cap and independent business effects.
- Conclusion: partial. In the native fixture, keep 4096 BEAM worker owners alive under the existing service unit, record their application effects independently, measure VM memory/FD pressure, and require the 4097th to return `:unrecorded` without a new durable ID. If an unrelated OS limit stops the run, report that limit rather than interpreting it as the recorder boundary.

#### Which fixture preserves systemd producer identity while independently faulting the recorder?

- Examined (2026-10-13): `nix/tests/machines/otel-request-recorder/default.nix:51-113`, `driver.py:1-220`, and `nix/modules/otel-guest/receiver/src/request_recorder.rs:207-245`.
- Found: the NixOS fixture launches `sdk-producer.service` and separate `overalls-request-sdk.service`; the recorder validates UID, cgroup unit and live kernel process identity. The driver faults and restarts producer and recorder independently. This is a concrete native seam to extend for capacity; host Antithesis support for equivalent systemd identity is unproven.
- Conclusion: resolved for native fixture selection, partial for hosted deployment. Preserve the two real units; do not substitute an unauthenticated client for the end-to-end oracle.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `recorder`. real-hosted-measurement-with-native-systemd-companion; independent witness: producer PID/start and effect vs durable recorder/SQLite ticket or trace digest. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R8`: Keep exact production-capacity saturation in a measured campaign. Use lower-cost bounded replay or refusal histories for routine search; do not claim the full 4,096-worker or 1,025-receipt cap without reaching it. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

## Authored assertion snapshot

**Authored assertion snapshot (2026-10-13 15:03 UTC):** Primary `always` message is present at `antithesis/workload/recorder/scenarios.py:145`. Real Producer 4096/4097 admission boundary and fsynced fixture effect; exact UID/systemd cgroup and hosted/native saturation run remain absent. It is outside the currently staged control-core selection. This records source presence, not a passing hosted or native result.
