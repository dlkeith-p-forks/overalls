# terminal-kill-progress-under-pty-backpressure

P1; medium confidence; progress hypothesis. Planned `Sometimes(condition)` message: **"Terminal explicit kill retires session under blocked PTY input"**, where `condition` means the controlled session disappears from the daemon's live inventory, its PTY child exits, and quota becomes available after a kill request made while input/write or viewer output is blocked. The reachability precondition matters: `Reachable` **"Terminal PTY input write blocked while kill requested"** should mark the synchronized interleaving. Both SDK assertions are **missing** in the [fresh scan](../existing-assertions.md). A finite recovery interval applies after the workload restores scheduling; if no blocked write can be induced, the progress claim remains untested, not passed.

Source: `nix/domains/artifacts/terminald/src/session.rs:323-347` intends kill to revoke viewers and signal the child under the session lifetime lock. `:506-525` holds that same `SessionInner` mutex while `write_all(session.master, ...)` handles viewer input. `:650-726,744-779` pumps output and retires session/quota. This creates a source-grounded lock-contention hypothesis: a truly blocking PTY write could prevent kill from taking the mutex. It is **not** a confirmed defect; PTY readiness/nonblocking behavior and child consumption may prevent a persistent write block in the real daemon.

Workload and oracle: use actual terminald and a guest command that stops reading input, send enough input to fill the PTY, withhold viewer read credit, then send explicit kill from a second connection. A separate client polls session inventory and creation budget and checks child PID death; daemon counters alone are insufficient. Run a neighbor terminal concurrently to distinguish global lock/deadlock from one blocked session. Do not infer a leak from an uncertain kill response until the physical process and inventory are checked.

Value menu: small/large PTY input bursts, 0/1/8 viewers, fast/withheld credit, one/two sessions, kill before/during/after write, EOF versus explicit kill. Hosted Linux terminald can test native threads/PTYs; TCG guest adds full vsock and guest-account context. Open question `(partial: the PTY master is blocking and reader_loop holds SessionInner across write_all, but the existing kill test only proves output-credit pressure)`: can a non-reading guest child saturate PTY *input* while an independent probe confirms the daemon thread is inside that write? Prove the blocked point before treating a failed deadline as a SUT defect.

### Investigation Log

#### Can the PTY master block while the reader holds SessionInner?

- Examined: `nix/domains/artifacts/terminald/src/pty.rs:157-163,284` and `session.rs:506-525`.
- Found: `posix_openpt` uses `O_RDWR | O_NOCTTY | O_CLOEXEC`, with no `O_NONBLOCK`, and `reader_loop` holds `SessionInner` across `write_all(master, ...)`.
- Not found: a composed observation proving buffer saturation and an indefinitely blocked write under the deployed daemon.
- Conclusion: source supports the interleaving hypothesis; the runtime precondition remains open and is not a confirmed defect.

#### 2026-10-13 follow-up: Does a current native test witness blocked PTY input during kill?

- Examined: `nix/domains/artifacts/terminald/src/pty.rs:157-163`, `session.rs:323-347,506-525,1145-1242`, and `neighbor_property_tests.rs:26-114`.
- Found: `posix_openpt` omits `O_NONBLOCK`; `reader_loop` retains `SessionInner` during `write_all`. The existing `verify_credit_stalled_kill` proves a viewer output queue exceeded its high watermark, then kill retires the session and quota. That output-credit test does not establish an input write blocked while holding `SessionInner`.
- Not found: a current native test that stops a child reading, fills the PTY input buffer, observes the specific writer thread blocked in `write_all`, then submits kill from a separate control connection.
- Conclusion: partial source-grounded hazard only. A bounded native/TCG reproduction with independent blocked-write observation is required before calling this a defect or evaluating progress under that precondition.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-real-inner-zfs-backed-lilly-plus-tcg-guest; unbuilt, no Firecracker proof; independent witness: guest PTY birth/token/deque/process/nonce observed independently of host reply; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R1`: `Sometimes` witnesses one designated recovered history. Track its exact operation ID, observed preconditions and dependency restoration; separately check that operation’s terminal state after a measured quiet interval. Missing oracle/precondition is unexercised, not a pass or a liveness violation. `R6`: Require independent evidence that an actual PTY master write is blocked while authorized kill is pending. An absent blocked-write precondition is unexercised, not product liveness failure. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

## Supporting assertion snapshot

**Supporting assertion snapshot (2026-10-13 15:03 UTC):** Narrower assertion messages are present at `antithesis/workload/terminal/scenarios.py:460`, `antithesis/workload/terminal/scenarios.py:497`. An independent input-stall witness precedes kill and a 30-second retired-process/quota Sometimes check. The planned input/output-pressure breadth and measured TCG quiet bound remain absent; no integrated VM run exists. At least one listed support callsite is outside the current staged control-core selection. This records source presence, not a passing hosted or native result.
