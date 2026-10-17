---
sut_path: /home/ghuntley/src/kittens-antithesis-reset
commit: c835eb1017d24a001215c319373fa4204d64269b
updated: 2026-10-13
external_references: []
scope_answer: "Repository only (Recommended)"
focus: "05 — Resource Boundaries"
---

# terminal-stalled-viewer-neighbor-progress

**Claim, priority, confidence.** P1 conditional liveness, high confidence in the intended boundary. Under a healthy finite quiet interval, a viewer that withholds socket read credit may stall its own session but must not stop a different authorized session from creating, attaching and delivering bytes. Proposed unique assertion: Sometimes("terminal neighbor completes create attach and byte delivery while another viewer is credit stalled", designated_neighbor_real_bytes_received && designated_stalled_viewer_still_blocked). Sometimes is appropriate because the meaningful combined state must occur at least once; a global successful terminal is insufficient. The assertion is missing per ../existing-assertions.md.

**Source and history.** nix/packages/terminald/src/session.rs:18-35 sets a 1 MiB viewer high-water mark. attach at :382-421 reserves one of 128 global viewers and limits eight per session. pump at :690-724 enqueues output and waits on the per-session drain condition when any queue exceeds the high-water mark. Its source contract at :635-647 says waiting for credit cannot retain the shared registry lock or block another session. Queue writes and the writer loop at :528-611 use distinct mutexes; explicit kill at :323-344 revokes writers. docs/architecture/reviews/2026-10-03-terminald-neighbor-pressure.md and 2026-10-03-terminald-credit-retirement.md record local test design, not a hosted guarantee. focus-11-assumptions.md:84 separately flags input-to-PTY mutex contention; this property exercises output credit, not that unresolved input hazard.

**Workload and oracle.** Run real PTYs and socket viewers. Stop one viewer reading after a verified enqueue above high-water; keep its socket and session alive. On a separate session, issue create, attach, resize and a nonce output command. The oracle observes actual nonce bytes on its socket and the blocked viewer's still-open descriptor, plus process identities, not a task completion counter. Explicitly kill the stalled session and verify a freed global viewer slot can admit another attachment. On natural EOF, drain the accepted queued suffix before socket close; a separate safety assertion could check exact byte sequence. Gate progress on enough global session/viewer/ring capacity, valid authority, functioning scheduler and a measured baseline timeout.

**Limit menu.** Viewer HWM 1 MiB default and reduced 32767/32768/32769-byte cases; global viewers 127/128/129 attempts and per-session 7/8/9; ring budget ample enough to isolate queue behavior. Use tiny and default PTY read chunks.

**SUT guidance and limits.** Mark pump entry into actual high-water wait and neighbor delivery. Outer container pauses can stall both sessions and do not refute conditional progress. Native PTY work establishes thread/mutex behavior; TCG guest/vsock composition is required for guest deployment. Open questions: What quiet interval is justified by a measured TCG baseline? `(partial: the local property test uses a five-second condition deadline; no hosted baseline has run)` Can the hosted fault action retain the stalled viewer socket and guest-vmm while perturbing outer services? `(partial: the local Unix-socket fixture does, but hosted composition is absent)`

**Architecture/HLDD impact.** No implementation or documented-status change; this probes the existing terminal contract.

### Investigation Log

#### What quiet interval is justified by a measured native or TCG baseline?

- Examined: `nix/packages/terminald/src/neighbor_property_tests.rs:26-114,161-218` and `session.rs:685-724`.
- Found: the local Linux PTY/socket property test samples viewer watermarks including the default 1 MiB, confirms actual queue pressure, then requires two to four neighbor output markers within five seconds each while pressure persists. It tests retirement and further neighbor progress before either client is dropped. This is a concrete local timing baseline and effect oracle, with no authenticated guest/vsock component.
- Not found: a TCG baseline or current hosted quiet interval accounting for emulated boot and vsock scheduling.
- Conclusion: partial. Carry over the causal pressure and marker checks, then measure the TCG interval before setting a hosted liveness deadline.

#### Can a stalled viewer retain its socket through the chosen hosted fault mechanism?

- Examined: `neighbor_property_tests.rs:41-114,123-159` and the proposed `guest-journey` topology in `../deployment-topology.md`.
- Found: the local fixture owns two real Unix socket pairs and keeps both clients open while the stalled queue remains above its high watermark and the neighbor delivers. A hosted action that pauses Marshall/Lilly or the whole guest-vmm may also freeze the control path or both PTYs, so the selected fault must preserve guest terminald and its viewer socket during the measured quiet interval.
- Not found: an assembled hosted fault action or TCG socket-retention observation.
- Conclusion: partial. Treat a whole-guest pause as an excluded precondition, not a failed neighbor-progress assertion.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-real-inner-zfs-backed-lilly-plus-tcg-guest; unbuilt, no Firecracker proof; independent witness: guest PTY birth/token/deque/process/nonce observed independently of host reply; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R1`: `Sometimes` witnesses one designated recovered history. Track its exact operation ID, observed preconditions and dependency restoration; separately check that operation’s terminal state after a measured quiet interval. Missing oracle/precondition is unexercised, not a pass or a liveness violation. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

## Authored assertion snapshot

**Authored assertion snapshot (2026-10-13 15:03 UTC):** Primary `sometimes` message is present at `antithesis/workload/terminal/scenarios.py:398`. Observer-confirmed blocked write and viewer queue beyond the high-water mark, with nonce bytes on a second real viewer while pressure remains; no hosted physical result exists. It is outside the currently staged control-core selection. This records source presence, not a passing hosted or native result.
