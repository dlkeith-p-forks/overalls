# ADR-0020: Local console fences and bounded streams

- ID: ADR-0020
- Date: 2026-09-15
- Status: superseded
- Implementation: implemented
- Components: Lilly console gate, dtach client, VM actors, terminal relay
- Supersedes: none
- Superseded by: ADR-0082

## Context

ADR-0019 establishes Marshall's pending/active writer authority. Lilly also needs
a serial console owner that rejects old fences and duplicate input, including after
a crash. Console output may be arbitrarily fast, readers may stop consuming, and
input/output must not appear in diagnostic logs. This implements the local
primitive required by the authorized terminal plan; runtime and wire integration
remain separate required work.

## Decision

Use a per-VM Console Gate GenServer that owns one dtach socket and an exclusive
private directory lock. Only its designated owner process may install control
responses, read output or attempt input. The runtime must derive its directory
and socket from the verified current VM actor; remote messages never supply paths.
The gate monitors its owner and detaches on owner death. Detaching leaves the
independently supervised dtach master and VMM running.

Persist only host/VM identity, VM generation, fence epoch and last input attempt
sequence in a private durable journal. Generations and epochs cannot regress; a
new generation needs a newer fence. A newer epoch resets its input sequence.
Within an epoch, input must be contiguous and each sequence may be attempted at
most once. Journal the attempt before sending any bytes. Duplicate retries return
`already_attempted`; they never resend bytes, even after gate restart. A crash
between journal publication and socket send can lose input. The transport must
report this uncertainty and must not automatically assign a new sequence to retry
it. No terminal bytes or content hashes are written to the journal.

[ADR-0021](0021-console-relay-connections-and-mailboxes.md) adds explicit discard
instructions that advance the same watermark without sending bytes. The gate
reports the last input result in memory: attempted or discarded during its
lifetime, uncertain when reopening a nonzero watermark. Duplicate operations do
not replace that result. This supports expiry and honest lost-reply reporting by
the relay without putting terminal bytes in the journal.

The owner supplies an authenticated control response, a locally assigned increasing
request sequence, and that request's local monotonic start time. The gate accepts
only its configured VM generation and the explicit idle/pending/active phases.
Pending never allows input. Authority lasts at most two seconds from request start,
including transport and journal time. Recheck elapsed time after persistence and
immediately before accepting input for socket delivery. Expired or malformed
authority disables input; delayed lower request sequences cannot replace newer
responses. Restart restores the attempt watermark but starts without authority.
The wire relay must cap this validity by Marshall's remaining session/writer
authority and renew it through fresh authenticated responses.

Bound each input message to 4 KiB. Configure dtach socket send timeout to 100 ms
and close on timeout; partial delivery is uncertain and cannot be replayed.
Accept output one socket message at a time and retain at most the latest 64 KiB.
Read pages contain at most 16 KiB with absolute byte cursors. A reader behind the
retained window receives an explicit gap and its new starting cursor. A fresh
random incarnation identifies every gate restart; output before attachment or
during restart is not recoverable. Copy retained binary slices so a short suffix
cannot retain an oversized backing allocation.

The gate's public status contains identifiers and counters only. Redact state,
last message, debug history and termination reason through GenServer's documented
[status callback](https://elixir.hexdocs.pm/GenServer.html#c:format_status/1).
Catch call-exit diagnostics before they propagate requests containing terminal
bytes into the owner's crash report. Raw VM output is never interpreted as code,
HTML or logging metadata by this primitive.

## Alternatives

Writing before persisting the sequence permits repeated commands after a crash.
Replaying unacknowledged input cannot distinguish lost replies from commands that
already executed. An unbounded output mailbox lets a noisy guest consume host
memory. Keeping a sub-binary of a large payload can retain the entire allocation.
A lease renewed from response arrival ignores time already spent in transport.
Logging only redacted process state still exposes sensitive last messages and
call-exit arguments.

## Consequences

Input is an at-most-once attempt, not an exactly-once guest command execution.
Already accepted input or running guest commands cannot be undone by revocation.
Input/output ordering is scoped to a console incarnation; a restart explicitly
reports loss and requires new authority. The gate's time checks do not promise a
hard real-time guest execution deadline under OS scheduling or guest pauses.
Synchronous durable writes cost latency and I/O; measure them under the target
interactive workload. State-file corruption or inability to publish an input
watermark fails closed. The local owner and canonical paths remain trusted parts
of the provisioner boundary.

## Invariants and verification

- A pending, expired, old-generation or old-epoch request sends no new input.
- A duplicate input sequence never writes again after reopening the journal.
- Journal failure prevents socket delivery; owner death detaches the client.
- The directory lock excludes a second console client using the same identity path.
- Output memory is bounded, byte order is preserved within the retained window,
  and truncation/restart are explicit to callers.
- Process status and call failures contain no terminal bytes.
- Validate properties with real Unix sockets and durable files; validate actual
  guest effects and VMM survival with Firecracker. Full remote handoff/revocation
  still requires the versioned relay and VM-actor integration.

## Implementation evidence

The local console gate, fence journal, bounded buffer and dtach client
implemented the local primitive; their tests exercised its boundaries. The
jailed KVM harness simulated its control frames, so it did not establish
remote authorization. See the
[review](../reviews/2026-09-15-local-console-gate.md) for executed evidence and
limits. This console implementation was removed by the guest terminal
multiplexer and persistent host stream decisions.
[ADR-0021](0021-console-relay-connections-and-mailboxes.md) now connects the gate
to the runtime: the actor derives paths and verifies its running generation,
while the transport process owns I/O and authenticated controls. The gate monitors
both processes, so an actor or transport crash detaches it without stopping the VM.
The [production browser failover harness](../../../nix/verification/tests/README.md)
proves a real guest command is not replayed after its browser acknowledgments are
lost and the serving Marshall process dies. Queued browser input is discarded,
and the VMM PID remains stable. See the
[review](../reviews/2026-09-16-terminal-failover.md) for scope and remaining cases.

## Open questions

The versioned codec, authenticated server/client and encrypted mailboxes now exist
under [ADR-0021](0021-console-relay-connections-and-mailboxes.md), including Lilly's
relay loop and VM-actor integration. Browser rendering exists under
[ADR-0022](0022-browser-terminal-and-live-login-checks.md). Broaden transport fault
coverage and verify Lilly restart during terminal input. Measure the journal's I/O
cost under load.

## Related decisions

[ADR-0008](0008-identity-sharing-and-terminal.md),
[ADR-0011](0011-nixos-guest-and-console.md),
[ADR-0017](0017-durable-vm-actors-and-host-ownership.md),
[ADR-0019](0019-terminal-session-and-writer-authority.md).
