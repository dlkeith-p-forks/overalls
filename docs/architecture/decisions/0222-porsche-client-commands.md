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
every Porsche locale catalog, in the feature domain that owns the command.

## Invariants and verification

- The wire view never contains owner email, time zone or guest capability
  booleans; `pinned` is the caller's pin only.
- ReadMarker positions never decrease (planned property test).
- Stdin payloads beyond the per-command limit are refused before dispatch.

## Implementation evidence

- `pinned` and `route`: [`marshall/lib/marshall/ssh/commands.ex`](../../../marshall/lib/marshall/ssh/commands.ex) with
  [`marshall/test/marshall/ssh/commands_test.exs`](../../../marshall/test/marshall/ssh/commands_test.exs).
- Mila consumes `pinned` (pinned-first ordering in
  [`mila/packages/mila_core/lib/src/machine.dart`](../../../mila/packages/mila_core/lib/src/machine.dart), tested in `test/machine_test.dart`).
- Command catalog, argument grammar and `stdin_payload?/1` (prompt, answers and
  revision at 64 KiB; the integration secret keeps its own kind):
  [`protocol/lib/overalls_protocol/ssh_command.ex`](../../../protocol/lib/overalls_protocol/ssh_command.ex),
  shared line fixtures in [`protocol/test/fixtures/ssh_command_lines.json`](../../../protocol/test/fixtures/ssh_command_lines.json),
  Hegel round-trip and refusal properties in
  [`protocol/test/ssh_client_commands_test.exs`](../../../protocol/test/ssh_client_commands_test.exs), and the matching Dart
  encoder in [`mila/packages/mila_core/lib/src/ssh_command.dart`](../../../mila/packages/mila_core/lib/src/ssh_command.dart).
- Thread, terminal and web dispatch over Threads, `Terminal.Authority` and
  Ingress (optimistic `policy_revision`), with pinned receipts that keep only
  payload digests and the SSH key id:
  [`marshall/lib/marshall/ssh/commands.ex`](../../../marshall/lib/marshall/ssh/commands.ex),
  [`marshall/test/marshall/ssh/client_commands_test.exs`](../../../marshall/test/marshall/ssh/client_commands_test.exs) and the published result shapes in
  [`protocol/test/fixtures/porsche_client_results.json`](../../../protocol/test/fixtures/porsche_client_results.json).
- `Marshall.Threads.ReadMarker`, keyed per reader and agent transcript, with
  the never-decreasing Hegel property in the client command test:
  [`marshall/lib/marshall/threads/read_markers.ex`](../../../marshall/lib/marshall/threads/read_markers.ex).
- `watch`: Marshall's `watch_subscribe` authority
  ([`marshall/lib/marshall/ssh/watch.ex`](../../../marshall/lib/marshall/ssh/watch.ex)), `:thread` and
  `:terminal_session` hints, and Porsche's hint routing
  ([`porsche/lib/porsche/watchers.ex`](../../../porsche/lib/porsche/watchers.ex),
  [`porsche/lib/porsche/ssh/watch.ex`](../../../porsche/lib/porsche/ssh/watch.ex)), tested in
  [`porsche/test/client_commands_test.exs`](../../../porsche/test/client_commands_test.exs),
  [`porsche/test/ssh_channel_test.exs`](../../../porsche/test/ssh_channel_test.exs) and over real SSH, Porsche and
  HTTPS control in [`marshall/test/marshall_web/ssh_transport_test.exs`](../../../marshall/test/marshall_web/ssh_transport_test.exs).
- Terminal commands (`terminal ls|new|kill`) are implemented on the same
  receipt model, outside the receipt transaction because the terminal domain
  commits its opening intent before guest dispatch.
- **Gaps:** `device register|ls|rm|prefs` belong to the Notifications work
  (ADR-0225) and are not here. Committed-hint delivery to a watch is not
  exercised end to end, because sandboxed tests never commit `pg_notify`;
  Porsche routing is tested with direct hints. Terminal commands are tested
  only for refusals without a live guest stream. The `porsche-threads` fleet
  machine test ([`scenarios/porsche-threads.py`](../../../nix/verification/tests/machines/fleet/scenarios/porsche-threads.py))
  is written but has not run. Run records are in the
  [Mila client commands review](../reviews/2026-10-18-mila-commands.md).

- **Mila client:** [`ssh_command.dart`](../../../mila/packages/mila_core/lib/src/ssh_command.dart)
  encodes every client command against the shared `ssh_command_lines.json`;
  [`thread.dart`](../../../mila/packages/mila_core/lib/src/thread.dart),
  [`web.dart`](../../../mila/packages/mila_core/lib/src/web.dart) and
  [`watch.dart`](../../../mila/packages/mila_core/lib/src/watch.dart) decode
  `porsche_client_results.json`. Payloads go only on stdin and `web set` sends
  `--revision`. These client tests have not yet run on the integrated tree.
  Terminal `ls|new|kill` are decided in ADR-0223 and implemented with these
  commands.

## Open questions

None.

## Related decisions

[ADR-0046](0046-porsche-ssh-management.md),
[ADR-0220](0220-mila-client-over-porsche-ssh.md),
[ADR-0223](0223-porsche-terminal-attach.md),
[ADR-0225](0225-marshall-notifications-domain.md).
