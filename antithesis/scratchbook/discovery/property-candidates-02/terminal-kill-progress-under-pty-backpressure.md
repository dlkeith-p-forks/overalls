# terminal-kill-progress-under-pty-backpressure

P1; medium confidence; progress hypothesis. Planned `Sometimes(condition)` message: **"Terminal explicit kill retires session under blocked PTY input"**, where `condition` means the controlled session disappears from the daemon's live inventory, its PTY child exits, and quota becomes available after a kill request made while input/write or viewer output is blocked. The reachability precondition matters: `Reachable` **"Terminal PTY input write blocked while kill requested"** should mark the synchronized interleaving. Both SDK assertions are **missing** in the [fresh scan](../../existing-assertions.md). A finite recovery interval applies after the workload restores scheduling; if no blocked write can be induced, the progress claim remains untested, not passed.

Source: `nix/domains/artifacts/terminald/src/session.rs:323-347` intends kill to revoke viewers and signal the child under the session lifetime lock. `:506-525` holds that same `SessionInner` mutex while `write_all(session.master, ...)` handles viewer input. `:650-726,744-779` pumps output and retires session/quota. This creates a source-grounded lock-contention hypothesis: a truly blocking PTY write could prevent kill from taking the mutex. It is **not** a confirmed defect; PTY readiness/nonblocking behavior and child consumption may prevent a persistent write block in the real daemon.

Workload and oracle: use actual terminald and a guest command that stops reading input, send enough input to fill the PTY, withhold viewer read credit, then send explicit kill from a second connection. A separate client polls session inventory and creation budget and checks child PID death; daemon counters alone are insufficient. Run a neighbor terminal concurrently to distinguish global lock/deadlock from one blocked session. Do not infer a leak from an uncertain kill response until the physical process and inventory are checked.

Value menu: small/large PTY input bursts, 0/1/8 viewers, fast/withheld credit, one/two sessions, kill before/during/after write, EOF versus explicit kill. Hosted Linux terminald can test native threads/PTYs; TCG guest adds full vsock and guest-account context. Open question `(partial: source opens the master without O_NONBLOCK)`: can the actual PTY buffer be saturated with a non-reading child under the deployed daemon and the blocked write independently witnessed? Prove the blocked point before treating a failed deadline as a SUT defect.

### Investigation Log

#### Can the PTY master block while the reader holds SessionInner?

- Examined: `nix/domains/artifacts/terminald/src/pty.rs:157-163,284` and `session.rs:506-525`.
- Found: `posix_openpt` uses `O_RDWR | O_NOCTTY | O_CLOEXEC`, with no `O_NONBLOCK`, and `reader_loop` holds `SessionInner` across `write_all(master, ...)`.
- Not found: a composed observation proving buffer saturation and an indefinitely blocked write under the deployed daemon.
- Conclusion: source supports the interleaving hypothesis; the runtime precondition remains open and is not a confirmed defect.
