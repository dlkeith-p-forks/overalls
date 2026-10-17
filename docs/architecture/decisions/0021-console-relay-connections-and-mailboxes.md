# ADR-0021: Console relay connections and bounded mailboxes

- ID: ADR-0021
- Date: 2026-09-15
- Status: superseded
- Implementation: implemented
- Components: shared console protocol, Marshall Terminal, Lilly console transport
- Supersedes: none
- Superseded by: ADR-0083

## Context

The authorized platform plan requires remote read/write TTY access, sharing,
revocation and independent Marshall instances. ADR-0019 establishes user and writer
authority; ADR-0020 establishes Lilly's local console gate. Neither alone moves
bytes between users and a VM. A lost reply must not cause a command to run twice,
and a restarted relay must not let an old response replace a newer output stream.

## Decision

Use a separate, versioned console exchange over Lilly's outbound authenticated
HTTPS connection. Console v1 is bound to the current v2 host execution session.
Give each relay process a new connection nonce and a durable increasing console
epoch in Marshall. Record consumed nonces; reopening an old nonce cannot replace
its successor. Every exchange echoes host, execution session/epoch, console
connection/epoch, request ID and increasing request sequence. Validate these before
applying controls. Persist the last accepted request sequence under the Host lock
and reject equal or older sequences before applying output. A timed-out HTTP
request may still run on the server; connection epochs alone do not order such
requests within one relay lifetime. A retry uses a newer request sequence while
preserving input sequence and output offsets, which remain idempotent.

Use PostgreSQL for one bounded, AshCloak-encrypted mailbox per VM, serialized on
the VM row alongside session and writer decisions. Host requests take Host before
VM locks; user requests never acquire Host after VM. Retain at most 64 KiB of
output and one 4 KiB pending input. Return output in pages of at most 16 KiB.
Terminal bytes and hashes are excluded from audit history and diagnostic logs.
Use a 60-second inactivity deadline for retained payloads, checked on access as
well as by minute-scheduled AshOban cleanup. Expiration clears encrypted payloads
and rotates the output relay, while preserving writer/sequence metadata and any
pending discard. Cleanup cannot make an old input sequence eligible for replay.
Authorization cannot rely on cleanup.

Bind each reader lifetime to a relay ID and each gate attachment to an incarnation.
When there are no readers, close the gate and clear the mailbox. A new reader
lifetime rotates the relay ID. Readers start at the current mailbox tail; output
still in transit may arrive after they join. A new gate incarnation resets the
output window and reports a gap. Absolute byte offsets deduplicate replayed pages;
Lilly advances its cursor only after Marshall acknowledges it.

Input is keyed by writer epoch and contiguous sequence. Permit one pending input;
an exact retry is idempotent and a changed body for that sequence conflicts. Expire
queued input's delivery eligibility after two seconds, retaining an explicit discard instruction until
Lilly advances its durable watermark. A discard never sends bytes but preserves
contiguous sequencing. An epoch change clears the old queue. Report attempted,
discarded or uncertain delivery. A gate restart can restore its watermark but
cannot prove the corresponding socket write, so report uncertainty and require
an explicit writer release/reclaim before further input. Never silently retry
uncertain input under a new sequence.

Poll at 100 ms with at most 16 VM updates. Controls contain the union of those
VMs and a bounded discovery page, at most 32 distinct VMs. Discovery uses a UUID
cursor. Control validity is at most two seconds, capped by remaining authority
and measured from Lilly's local request start. Under overload the gate expires;
interactive fleet capacity requires measurement. All wire shapes are closed,
collections bounded, counters exact integers through signed 64-bit maximum, and
bytes canonical Base64. No peer strings become atoms or local filesystem paths.

Complete migrations and deploy compatible Marshall instances before advertising
console support. Existing v1/v2 execution envelopes retain their semantics. A
separate optional capability enables the new Lilly loop; absent capability means
no remote console. Lilly opens no inbound listener. Browser integration must
recheck account tokens and Cedar permissions for every read/input, preserve large
counters as decimal strings, and bound its own input queue.

Lilly's Runtime owns one console Transport process. The transport opens its own
connection, performs at most one outbound request at a time, and fairly rotates
bounded VM update pages. A VM actor authorizes only that transport PID, verifies
its current durable running generation, derives the private console directory,
and asks the executor to verify the physical VMM before attaching to its canonical
socket. Gate processes monitor both actor and transport; losing either detaches
the socket and preserves the independent VMM. Superseded generations and changed
relay IDs close old gates. A restarted transport gets a new connection and gates,
restoring input watermarks while exposing a new output incarnation. Control
validity begins before local page collection, so local delay counts against it.

Advertise terminal protocol 1 in host inventory only after the transport completes
its authenticated handshake. Opening a user terminal requires a fresh report with
that capability. Runtime fencing stops the console transport and actors together;
normal transport crashes can restart under the existing execution session with a
new console connection. Diagnostic state, messages, reasons and call exits must
never expose terminal bytes.

## Alternatives

In-memory mailboxes on one Marshall require affinity and lose state on failover.
A dedicated broker adds another authority and deployment dependency. Reusing only
the execution-session epoch cannot distinguish two relay processes within one
Lilly runtime. Retrying input after a lost response can repeat guest commands.
Dropping an expired sequence without telling the gate prevents later contiguous
input. Keeping terminal bytes in PaperTrail creates an unbounded secret history.

## Consequences

Encrypted PostgreSQL buffering has a measurable write/decryption cost. This is a
bounded initial transport, with no scale claim until workload testing. Console
output before attachment or during outages can be lost, and gap reporting is part
of the interface. An acknowledged socket attempt does not prove guest execution.
Revocation cannot undo bytes already accepted or commands already running.

## Invariants and verification

- Stale execution or console connections cannot publish output or obtain controls.
- Only fresh user/token/Cedar authority can read or enqueue bytes.
- Only an active acknowledged writer epoch can carry input; pending/idle cannot.
- Retried input is attempted at most once, including across gate restart.
- Discard advances only the current sequence without sending bytes.
- Output windows and wire collections remain bounded under arbitrary guest data.
- Incarnation changes, truncation and uncertain input are visible to users.
- Verify codecs with properties, mailboxes with transaction/concurrency tests,
  clients against actual TLS, and remote guest effects through the KVM harness.

## Implementation evidence

The [shared codec](https://github.com/antithesishq/kittens/blob/9fe1e493b2090d44bacd16089049cd12b316d58a/protocol/lib/overalls_protocol/console.ex) and
[properties](https://github.com/antithesishq/kittens/blob/9fe1e493b2090d44bacd16089049cd12b316d58a/protocol/test/console_test.exs) implement strict bounded
console envelopes. The local gate and
socket tests add explicit discard and
delivery-result tracking. Connection authority persisted consumed nonces and request ordering under the Host lock.
Encrypted mailboxes,
mailbox coordination, output windows and the
[relay](../../../marshall/lib/marshall/terminal/relay.ex) implement server buffering,
fresh authorization, pending/active handoff, input acknowledgments and cleanup.
The [provisioner API](../../../marshall/lib/marshall_web/provisioner_api.ex) and
[Lilly client](../../../lilly/lib/lilly/control/client.ex) expose the bounded HTTPS
exchanges. [Transport tests](../../../marshall/test/marshall_web/provisioner_transport_test.exs)
send binary console bytes through actual TLS with simulated physical receipts;
relay tests covered expiry,
revocation, uncertainty, encrypted storage and reader lifetimes.
[Three-node tests](../../../marshall/test/marshall/compute/distributed_admission_test.exs)
race conflicting input for one writer sequence. See the
[review](../reviews/2026-09-15-console-relay.md) for executed checks and limits.
The transport loop,
[Runtime](../../../lilly/lib/lilly/control/runtime.ex),
[VM actor](../../../lilly/lib/lilly/vm/actor.ex) and
[executor](../../../lilly/lib/lilly/vm/executor.ex) now implement runtime integration.
TLS runtime tests
exercise actual network/socket traffic with simulated VMM observations.
The terminal probe extended the
[execution KVM harness](../../../marshall/scripts/smoke_execution.exs) for the full
user-authority-to-guest path; it was removed with the v1 transport when ADR-0083
superseded this decision. See the review for executed evidence. Browser access
is now implemented under [ADR-0022](0022-browser-terminal-and-live-login-checks.md);
full deployment/load validation remains required work.
The [three-node production harness](../../../nix/verification/tests/README.md)
now exercises a fresh guest through the packaged Lilly service, real browsers,
lost terminal replies, serving-node death, shared writer handoff and revocation.
Its [review](../reviews/2026-09-16-terminal-failover.md) records the passed checks;
all services still share one physical development host.

## Open questions

The single-host browser path is verified under ADR-0022. Measure interactive latency
and database load under the deployment workload; validate a second physical host
and the intended range of Marshall instances.

## Related decisions

[ADR-0012](0012-provisioner-control-transport.md),
[ADR-0017](0017-durable-vm-actors-and-host-ownership.md),
[ADR-0019](0019-terminal-session-and-writer-authority.md),
[ADR-0020](0020-local-console-fences-and-bounded-streams.md).
