# ADR-0083: Terminal host stream and registry

- ID: ADR-0083
- Date: 2026-09-19
- Status: accepted
- Implementation: implemented
- Components: OverallsProtocol.Terminal, Lilly terminal stream, Marshall Terminal
- Supersedes: ADR-0019, ADR-0021
- Superseded by: none

## Context

ADR-0019/0021 moved serial console bytes between browsers and hosts through
100 ms polls at every hop, encrypted PostgreSQL mailboxes under VM-row locks,
writer epochs, nonces, fence journals and gap reporting. That design cannot
carry many terminals with full escape-sequence fidelity, its latency floor is
the poll interval, and its complexity exists mostly to make polled delivery
safe. Terminal sessions are now durable inside the guest (ADR-0082), so the
control plane no longer needs to own terminal bytes at all.

## Decision

Lilly dials one persistent authenticated WebSocket to
`/api/provisioners/v4/stream` and multiplexes every terminal channel over it.
The stream is bound to the exact current v3 execution session: the upgrade
authenticates the host credential, and the first control frame must repeat the
host, session and epoch identity before anything else is accepted. Frames carry
a 15-byte header (channel, type, sequence) with bounded payloads; control
messages are closed-schema JSON (`hello`, `hello_response`, `create`,
`created`, `attach`, `attached`, `channel_close`, `listing`, `listed`, `kill`,
`resize`, `closed`, `boot_log`, `boot_log_data`), verified by the shared
codec. Marshall numbers input sequences per channel and Lilly applies only
strictly increasing sequences, so a replayed frame can never execute twice.
The stream reconnects with bounded backoff; channels and guest managers are
rebuilt on reconnect while guest sessions survive and replay.

Marshall keeps a terminal session registry in PostgreSQL: one row per guest
session binding only VM, owner, placement, epoch and guest session id, with
paper-trail history and append-only terminal audit receipts (actor, session,
kind; never payloads). Terminal bytes never touch the database. Opening a
session requires a fresh host report advertising `terminal_protocol: 2` and
Cedar read (write for rw); the capability is advertised only while the stream
is established. Browser viewers attach through single-use short-lived tickets
that bind one registry session and mode, consumed by the viewer WebSocket
before any byte flows; each viewer attachment is its own stream channel and
guest attachment, so the guest daemon's fan-out, rings and read-only mode
provide sharing. Expired tickets are retained for one hour, then removed by a
bounded durable cleanup job. Marshall closes an individual viewer channel when
that viewer's mailbox reaches its fixed high-water mark without blocking other
viewers. Lilly applies input deduplication and reports dial failures,
fencing and session exit as fixed reasons. The VM boot log is readable through
bounded `boot_log` controls.

Host boot-log reads are independent of the image's guest terminal capability
and guest readiness. They still require current Cedar VM read authority and
the current fresh, authenticated protocol-2 host stream. Lilly authorizes the
exact current runnable placement and execution before returning a bounded page
of the private host file. That diagnostic permission grants no guest dial,
terminal session, input, boot challenge or readiness authority. Pending and
failed boots may therefore expose their retained host diagnostics while guest
terminal operations remain unavailable.

## Alternatives

Continuing HTTPS polling keeps a stateless server but preserves the latency
floor and most of the fencing machinery. A dedicated broker adds another
authority and deployment dependency. Carrying terminal bytes through
PostgreSQL again would reintroduce mailbox costs and secret handling for no
benefit, since sessions and scrollback are guest-local.

## Consequences

Interactive latency becomes connection-oriented instead of poll-bound, and
Marshall holds terminal state only in memory. A serving Marshall node's death
drops viewer sockets; browsers reconnect and reattach with scrollback cursers.
Host-side authority is connection-scoped: a fenced or restarted stream ends
channels but never guest sessions. The registry and audit receipts give
ownership and who-did-what without payload or display metadata history; guest
user, terminal type and title stay in the guest/browser listing path.

## Invariants and verification

- Streams bind the authenticated current execution session before any
  channel or control is accepted; stale hellos close the connection.
- Every VM-scoped control names the exact placement and execution epoch;
  Lilly revalidates through the VM actor before dialing the guest.
- Boot-log controls independently validate host-file incarnation and the
  newest stored runnable command. A changed placement, epoch, generation,
  launch witness or assigned stream owner refuses; the response contains at
  most 16 KiB and a cursor, with no guest dial identity.
- Input dedup by strictly increasing per-channel sequence prevents double
  execution across stream reconnects.
- Viewer tickets are single-use, short-lived and mode-bound; authority is
  rechecked against Cedar at issue time.
- Terminal bytes appear in no database table, log line or audit row.
- The codec is property-tested for round trips, truncation and bounds;
  registry tests cover capability gating, limits and audit receipts.

## Implementation evidence

The [host boot-log authorization review](../reviews/2026-10-17-host-boot-log-authorization.md)
records the correction that separates read-only host diagnostics from guest
terminal admission, including pending/failed execution and log-incarnation
fencing. It preserves the existing control schema and native capability refusal;
its focused execution and remaining machine/browser gaps are tracked separately.

The [attachment-history review](../reviews/2026-09-26-terminal-attachment-verification.md)
adds generated [real WebSock lifetimes](../../../marshall/test/marshall/terminal/attachment_history_test.exs)
across ticket mode/consumption, sharing, login, capability, execution and kill
state. Relay dispatch is synthetic; existing native guest evidence retains its
original capture. This preserves creator-only writable attachments and changes
neither the accepted decision nor implementation status.

The [startup recovery review](../reviews/2026-09-25-terminal-startup-recovery.md)
records bounded reply lifetimes in the relay and both local/remote response
paths, with generated mailbox-isolation and loopback TLS regression evidence.

The [frame codec](../../../protocol/lib/overalls_protocol/terminal.ex) and
[properties](../../../protocol/test/terminal_test.exs) define the wire. Lilly
implements the dial, hello binding and channel multiplexing in the
[terminal stream](../../../lilly/lib/lilly/terminal/stream.ex) over the shared
[WebSocket connection](../../../protocol/lib/overalls_protocol/web_socket/connection.ex) and
[guest manager](../../../lilly/lib/lilly/terminal/guest.ex). Marshall's
[relay registry](../../../marshall/lib/marshall/terminal/relay.ex),
[host stream](../../../marshall/lib/marshall/terminal/host_stream.ex),
[authority](../../../marshall/lib/marshall/terminal/authority.ex),
[registry](../../../marshall/lib/marshall/terminal/session.ex),
[registry minimization migration](../../../marshall/priv/repo/migrations/20260920120000_minimize_terminal_session_registry.exs),
[audit receipts](../../../marshall/lib/marshall/terminal/event.ex) and
[tickets](../../../marshall/lib/marshall/terminal/tickets.ex) implement the
control plane. [Ticket retention](../../../marshall/lib/marshall/terminal/ticket_retention.ex)
performs bounded scheduled cleanup; focused host-stream and authority tests
cover first-frame rejection, slow-viewer isolation, explicit kill authority
and receipt ordering. The stream upgrade lives in the
[provisioner API](../../../marshall/lib/marshall_web/provisioner_api.ex).
Registry tests and the relocation gating suites cover capability denial.
Lilly's [terminal tests](../../../lilly/test/terminal/terminal_test.exs) verify
TLS peer/hostname configuration, authenticated readiness and immediate loss
reporting.

Creation does not attach a data viewer: the first data channel belongs to an
explicit browser attachment. Owner admission permits the VM's full 64-session
capacity. The [host-stream tests](../../../marshall/test/marshall/terminal/host_stream_test.exs)
exercise actual create request/reply framing rather than only synthetic relay
replies. The [vsock tests](../../../lilly/test/terminal/vsock_test.exs) require the
Firecracker CONNECT handshake before either control or attachment authentication.

The implementation follow-up adds a metadata-only
[creation intent](../../../marshall/lib/marshall/terminal/opening.ex) and
[coordinator](../../../marshall/lib/marshall/terminal/creation.ex): admission
reserves a slot before the guest effect; request identity binds actor, VM,
placement/epoch and a parameter digest. Completion transacts registry, opened
receipt and ready state. The [background reconciler](../../../marshall/lib/marshall/terminal/reconciler.ex)
queries authenticated guest request status, recovers lost replies and claims
cancellation before tombstoning abandoned creates. Control schemas add
`creation_query`, `creation_status`, `creation_cancel`, `creation_cancelled`;
all participants must support these controls for recovery to work.

Independent non-distributed releases use an expiring
[PostgreSQL directory](../../../marshall/lib/marshall/terminal/directory.ex)
and [private peer socket](../../../marshall/lib/marshall/terminal/peer_socket.ex)
to reach the owning frontend. Each peer hop uses verified TLS and a
purpose-bound fifteen-second proof tied to a stream incarnation. Directory
renewal is nonce-fenced; host stream renewal also checks the current execution
session and credential expiry. Both clients now use the shared active-once
[connection](../../../protocol/lib/overalls_protocol/web_socket/connection.ex)
(ADR-0142); the terminal codec library remains independent of I/O and
application runtimes. The
[follow-up review](../reviews/2026-09-20-terminal-integration-follow-up.md)
records remaining fencing, compatibility and acceptance work. None of these
new source changes establishes milestone completion.

Schema artifacts are now generated for the
[opening intent](../../../marshall/priv/resource_snapshots/repo/terminal_openings/20260920213552.json),
[session kill state](../../../marshall/priv/resource_snapshots/repo/terminal_sessions/20260920213553.json),
[event actor nullability](../../../marshall/priv/resource_snapshots/repo/terminal_events/20260920213551.json)
and [stream location](../../../marshall/priv/resource_snapshots/repo/terminal_stream_locations/20260920213554.json).
Generation compiled the Elixir resources but did not apply migrations or run
tests. Guest creation probes recovery support before reservation; it never falls
back to legacy creation. ADR-0159 removed the explicit unsupported-guest report:
every admissible image's terminald supports the creation probe.

Owner kills now use a durable `kill_status` state machine on the session registry.
The [termination coordinator](../../../marshall/lib/marshall/terminal/termination.ex)
commits pending intent and a request receipt before dispatch, then waits for a
placement/epoch/session-bound `killed` acknowledgement. Guest absence also
confirms an already completed kill; failed transport/listing cannot do so.
Confirmation transacts state, archival and one receipt. Retired placement
authority is recorded separately from confirmed guest termination. Pending kills
deny fresh viewer authority and are retried by background reconciliation.

The [peer budget](../../../marshall/lib/marshall/terminal/peer_budget.ex) limits
incoming and outgoing peers together to 512 per frontend, with process-owned
slots and loss monitoring. Peer connections accept one control or attachment;
idle/incomplete connections expire and resize/input remain attachment-scoped.
The fleet reconciler schedules ten VM jobs per database batch; each VM job
attempts at most one kill and one opening, with durable ID continuations.
These additions and their regression cases were deferred during the
implementation-first phase; resumed validation is recorded below.

The resumed native run now passes the dedicated terminal-fleet scenario in
337.37 seconds: real guest commands, view-only sharing, serving-machine loss,
reattachment without replaying the completed command, grant revocation and login
revocation. Half-open TCP detection uses sequenced `heartbeat`/`heartbeat_reply`
controls; Lilly withholds readiness and reconnects after five seconds without
acknowledgement. Peer relays close when their directory nonce expires or changes.
Initial hello negotiation also has a bounded deadline. The
[follow-up review](../reviews/2026-09-20-terminal-integration-follow-up.md)
distinguishes this executed scope from remaining fleet and feature acceptance.

The full fleet check subsequently passed in 1089.57 seconds, including database
outage, provisioner loss, release/credential updates, isolated-host admission and
storage cleanup. Remaining feature/load acceptance and production activation are
separate from these passing named suites.

## Completion update

The recovered [original plan](../../history/ledgers/terminal-v2-plan.md) requires end-to-end
consumption credit and per-terminal sharing. Version-two control
envelopes now carry cumulative `input_ack`/`output_ack` counters with 256 KiB and
sixteen-frame windows, and attachment replies declare replay bytes. Lilly streams
replay under that credit; xterm acknowledges only after parsing. A
[terminal grant resource](../../../marshall/lib/marshall/terminal/grant.ex)
and [sharing coordinator](../../../marshall/lib/marshall/terminal/sharing.ex)
limit visibility to the creator and explicit viewers who retain Cedar VM read.
Only the creator may grant/revoke; shared operators remain read-only. Final
protocol and consumer precommit gates, the native terminal-fleet scenario and
the Ubuntu guest VM matrix pass on the coordinated implementation; see the
[completion ledger](../../history/ledgers/terminal-v2-completion.md).

A generated local HostStream property now checks that a future output sequence
closes only its viewer channel and emits a channel-close control, while a replayed
sequence is ignored. This supplies a local oracle for the existing bounded
reconnect and scrollback design; it does not establish native Lilly interruption
or browser reattachment behavior.

The [channel-history properties](../../../lilly/test/terminal/channel_history_test.exs)
exercise real local TCP channels and production Stream callbacks for byte/frame
credit, duplicate input, exact cumulative receipts, EOF draining and old-PID
refusal after transport loss. Fresh attachments start a new sequence space;
uncertain input must not be replayed. Authentication, guest hello/PTY persistence,
TLS and composed native reconnect are separate evidence. The
[property audit](../reviews/2026-09-29-antithesis-property-audit.md) records the
executed scope and remaining gaps; the accepted decision/status are unchanged.

*Transport (2026-10-05).* The host stream and the peer hop keep this
decision's binary framing, hello and credits, but now run over the shared
active-once `OverallsProtocol.WebSocket.Connection`
([ADR-0142](0142-overallsprotocol-control-websocket.md)). Lilly's 250 ms and
Marshall's 50 ms receive polls are gone, as are both hand-rolled clients. The
peer hop pings every five seconds, and either side ends after fifteen seconds
of silence.

*Browser liveness (2026-10-07).* The browser-facing viewer socket now carries a
five-second heartbeat control frame, and the page reconnects after fifteen
seconds of silence. In `terminal-fleet`, a page attached to a crashed Marshall
otherwise kept a half-open socket through the proxy for about twenty seconds
and never showed live again within the scenario's 45-second bound.

## Open questions

The local [host takeover property](../../../marshall/test/marshall/terminal/host_takeover_history_test.exs)
adds generated real Bandit/WebSock lifetimes across SQL-backed host-session
rotation. Explicit renewal and successor registration close old channels;
pre-takeover upgrades cannot publish delayed stale hellos, and old directory
nonces cannot renew. Successor output remains usable. HTTPS and host replies
are synthetic. This does not establish scheduler deadlines, per-frame database
fencing, remote peer authentication or partition convergence. The accepted
decision and implementation status remain unchanged; execution is recorded in
the [property audit](../reviews/2026-09-29-antithesis-property-audit.md).

End-to-end latency and reconnect behavior need measurement under real
workloads and multi-host fleets; the fleet browser suite exercises the paths
but performance targets are unquantified.

## Related decisions

[ADR-0012](0012-provisioner-control-transport.md),
[ADR-0017](0017-durable-vm-actors-and-host-ownership.md),
[ADR-0082](0082-guest-terminal-multiplexer.md),
[ADR-0084](0084-browser-terminal-workspace.md).
