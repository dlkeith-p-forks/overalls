# ADR-0222: Porsche thread, web, device and watch commands for clients

- ID: ADR-0222
- Date: 2026-10-18
- Status: accepted
- Implementation: partial
- Components: protocol, Marshall, Porsche
- Supersedes: none
- Superseded by: none

## Context

Mila (ADR-0220) can only offer what Porsche's command catalog exposes. Machine
lifecycle exists; agent threads, web endpoints, push devices and live updates
do not. Mila also needs the caller's machine pins and a canonical link per
machine, which `machine_wire_view/1` previously dropped.

## Decision

1. `ls`/`show` include the caller's own `pinned` flag and a `route` from
   `Marshall.AppRoutes` (ADR-0221). Owner contact details and browser-only
   projections stay off the wire.
2. Add, all backed by existing Ash domains and pinned `ssh_requests` receipts
   for mutations:
   - `thread ls|show|turns|prompt|answer|plan approve|plan revise|mode|read`,
     with prompt and answer text on stdin (at most 64 KiB) and redacted from
     receipts by digest;
   - `web show|set` over `Marshall.Ingress` with optimistic `policy_revision`;
   - `device register|ls|rm|prefs` over the Notifications domain (ADR-0225);
   - `watch [--machine M]… [--thread T]… [--session]`, JSON lines with a
     15-second heartbeat, fed by control-plane hints.
3. Unread state is a server-side `Marshall.Threads.ReadMarker`: monotonic, so an
   upsert never moves it backwards.
4. `SSHCommand.stdin_secret?/1` generalises to `stdin_payload?/1` returning a
   kind and limit per command.

Authorization: the approved Mila plan (2026-10-18).

## Alternatives

- **Client-side unread state.** Rejected: it diverges across devices and the
  browser.
- **Polling instead of `watch`.** Rejected: it multiplies Marshall reads and
  delays agent questions.

## Consequences

Each command needs localized refusals in `Porsche.SSH.CommandMessages` and
the 25-locale catalogs.

## Invariants and verification

- The wire view never contains owner email, time zone or guest capability
  booleans; `pinned` is the caller's pin only.
- ReadMarker positions never decrease (planned property test).
- Stdin payloads beyond the per-command limit are refused before dispatch.

## Implementation evidence

- `pinned` and `route`: [`marshall/lib/marshall/ssh/commands.ex`](../../../marshall/lib/marshall/ssh/commands.ex) with
  [`marshall/test/marshall/ssh/commands_test.exs`](../../../marshall/test/marshall/ssh/commands_test.exs). **Gap:** not run; Marshall
  does not compile on this branch's base for a pre-existing reason.
- Mila consumes `pinned` (pinned-first ordering in
  [`mila/packages/mila_core/lib/src/machine.dart`](../../../mila/packages/mila_core/lib/src/machine.dart), tested in `test/machine_test.dart`).
- Thread, web, device and watch commands, ReadMarker and stdin payloads are
  planned (M3–M5).

## Open questions

None.

## Related decisions

[ADR-0046](0046-porsche-ssh-management.md),
[ADR-0220](0220-mila-client-over-porsche-ssh.md),
[ADR-0223](0223-porsche-terminal-attach.md),
[ADR-0225](0225-marshall-notifications-domain.md).
