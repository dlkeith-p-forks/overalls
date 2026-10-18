# ADR-0223: Porsche terminal attach through a Marshall gateway stream

- ID: ADR-0223
- Date: 2026-10-18
- Status: accepted
- Implementation: planned
- Components: Porsche, Marshall, protocol, Mila
- Supersedes: none
- Superseded by: none

## Context

Mila needs the same persistent terminal sessions the browser uses
([ADR-0083](0083-terminal-host-stream-and-registry.md),
[ADR-0117](0117-personal-terminal-machine-workspace.md)), attached over its one
Porsche connection, with replay from a cursor and a read-only mode.

## Decision

1. Porsche adds `terminal ls|new|kill M [S]` and `terminal attach M S
   [--cursor N] [--read-only]`. Attach is not a mutation: its ticket is never
   pinned in a receipt or printed.
2. Marshall adds `GET /api/terminal-gateway/v1/stream` on the fleet endpoint,
   authenticated by the Porsche gateway bearer plus a terminal ticket, which
   upgrades into `Marshall.Terminal.Viewer` with an `{:ssh, gateway, session}`
   authority rechecked every 5 seconds.
3. Porsche's channel gains an attach mode that requires a prior `pty` request.
   It relays input (gated by the terminal window), acknowledges output only
   after the local SSH send succeeds, maps `window_change` to resize, writes
   one JSON header line on stderr and maps exits to closed codes. Terminal
   bytes are never logged.

Authorization: the approved Mila plan (2026-10-18).

## Alternatives

- **Direct SSH to the guest through Audi.** Rejected: it bypasses the shared
  browser session and its writer authority.
- **Relaying over the control websocket.** Rejected: terminal bandwidth would
  share the control link's backpressure.

## Consequences

The gateway stream becomes a new authenticated Marshall surface with its own
threat model (HLDD chapter 20).

## Invariants and verification

- Read-only attachments never send input; key revocation closes an attach
  within 5 seconds; journals contain no terminal bytes (planned fleet machine
  test `porsche-terminal`).
- Output credit is granted only after a successful local send (planned
  Covenant obligation).

## Implementation evidence

No implementation yet.

## Open questions

None.

## Related decisions

[ADR-0019](0019-terminal-session-and-writer-authority.md),
[ADR-0083](0083-terminal-host-stream-and-registry.md),
[ADR-0220](0220-mila-client-over-porsche-ssh.md),
[ADR-0222](0222-porsche-client-commands.md).
