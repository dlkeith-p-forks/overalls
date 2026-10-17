# ADR-0022: Browser terminal and fresh LiveView login checks

- ID: ADR-0022
- Date: 2026-09-16
- Status: superseded
- Implementation: implemented
- Components: Marshall Web, Accounts, Terminal, browser assets
- Supersedes: none
- Superseded by: ADR-0084

## Context

The authorized platform plan requires users and their collaborators to interact
with VM terminals through Marshall. The HTTPS relay now reaches real Firecracker
guests, but browsers still need rendering, flow control and revocation checks.
LiveView mount authentication alone does not revoke an already connected login.

## Decision

Expose `/machines/:id/terminal` within the authenticated LiveView session. Open a
new Terminal session only on the connected mount. Use the existing Accounts login
token at opening; do not retain its bearer value in LiveView assigns or expose it
to the terminal hook. Every authenticated machine/terminal LiveView event, parameter
change and refresh checks the stored login identifier and database-time expiry.
Terminal actions independently recheck the session's token, VM generation and
Cedar permissions under the VM lock. Browser-supplied session IDs have no authority.

Vendor xterm.js 6.0.0's official compiled ESM and CSS into the existing app bundles,
with its MIT license, tarball integrity and upgrade instructions. No runtime CDN
or terminal addons. Render guest bytes as terminal data, never HTML. Ignore guest
clipboard, title and hyperlink sequences; do not activate terminal links. Start
read-only with explicit Take control and Release control actions. Keep the physical
console's fixed 80-column, 24-row geometry and allow horizontal scrolling on small
screens. Dynamic resize is not part of this protocol version.

Use client-pulled output with at most one read outstanding. Wait for the renderer
to consume each page before requesting another, at a 100 ms interval. Server pages
remain bounded at 16 KiB. Retain at most 1,000 browser scrollback lines and reset
the renderer after at most 4 MiB of consumed bytes, with an explicit notice.
Line counts alone cannot bound arbitrary combining characters in one cell or an
unfinished escape sequence; reset the parser and buffers together. Preserve
signed-64-bit counters as canonical decimal strings and use BigInt for input
sequencing. An output gap resets parser/display state and shows an explicit notice;
a missing fragment cannot complete an old escape sequence in the new stream.
An unanswered output request ends the client session after five seconds. Control
and input confirmations have three-second client deadlines; late control replies
cannot re-enable typing after a timeout. Server authority deadlines remain
independent and authoritative.

Bound queued plus unacknowledged browser input at 16 KiB and individual input at
4 KiB. Only one input sequence can await the host. A Marshall enqueue reply does
not establish guest delivery. Host receipts advance the sequence; discard,
uncertainty or missing confirmation stops typing and clears queued bytes. Do not
automatically resubmit an uncertain command. Require explicit release/reclaim
before continuing. Oversized paste is rejected as a whole before it is sent.
Browser disconnect discards unsent typing. Reconnection opens a new read session
and requires explicit writer acquisition; it cannot replay the old queue.
Writer control events echo the current Terminal session ID as a connection
binding, which the LiveView compares with its own session. It is not a bearer
capability. A browser transport may buffer an old claim/release across rejoin;
that event must not acquire or release a replacement session's writer.

Close the Terminal session when the user closes the page or normal LiveView
termination runs. Durable expiry still handles abrupt process loss. A client that
stops reading cannot retain authority indefinitely because it stops refreshing.
Filter terminal byte parameters in Phoenix logs and redact terminal-process log
payloads, including OTP crash messages/state, before handlers format them. Apply
the same redaction to LiveView transport processes, which can multiplex terminal
traffic after navigation even when the initial page is not a terminal.

## Alternatives

A plain text area does not interpret a shell's terminal control sequences. A
runtime CDN adds a mutable dependency to a page with root guest access. Unbounded
server push can outrun a slow renderer. JavaScript Number counters lose precision
above 2^53. Automatic retry under a new sequence can execute a guest command twice.
Mount-only authentication leaves revoked logins usable until reconnection.

## Consequences

The UI is usable without an additional public Lilly listener. Per-read authorization
and encrypted database buffering add work that requires workload measurement.
Fixed geometry trades flexible layouts for a single consistent shared terminal.
The browser retains visible output until navigation; server payload expiry cannot
erase content already delivered to an authorized reader. Redacted process diagnostics
retain severity and event metadata but omit crash details that could contain bytes.
Node from the pinned Nix package set runs the browser input-state tests in precommit.

## Invariants and verification

- Viewers cannot claim or forge input; every read/input uses current authority.
- Login and grant revocation affect connected pages on their next operation.
- Guest output cannot write HTML, activate links or access the clipboard.
- Slow rendering and input bursts keep queues bounded; gaps are visible.
- Lost replies, reconnection and writer changes cannot replay queued typing.
- Counters above 2^53 remain exact, including in browser tests.
- Run LiveView access/codec tests, input-state interleavings, actual browser checks,
  compiler/Dialyzer, and the real VM terminal path. Distinguish simulated output
  from browser-to-guest execution evidence.

## Implementation evidence

[TerminalLive](../../../marshall/lib/marshall_web/live/terminal_live.ex) and the
browser hook implemented the page and
bounded read loop, and input state
models sequencing and failure behavior. [Vendored renderer provenance](../../../marshall/assets/vendor/xterm/README.md)
records the pinned package and integrity. [Login checks](../../../marshall/lib/marshall/accounts/login.ex)
and [LiveView hooks](../../../marshall/lib/marshall_web/live_user_auth.ex) add current
token presence to connected machine pages. [Log filtering](../../../marshall/lib/marshall_web/terminal_log_filter.ex)
redacts terminal process payloads. LiveView tests,
input tests and
[logging tests](../../../marshall/test/marshall_web/terminal_log_filter_test.exs)
cover these boundaries. The [Chromium probe](../../../marshall/scripts/browser_terminal_probe.py)
and [private probe driver](../../../marshall/scripts/browser_terminal_probe.exs) run
against the real Firecracker guest through the full HTTPS endpoint. See the
[review](../reviews/2026-09-16-browser-terminal.md) for executed results and limits.

The [production failover harness](../../../nix/verification/tests/README.md)
adds three deployed Marshall services, a newly provisioned real guest and actual
Chromium browsers. It suppresses replies after accepted input, queues more typing,
kills the serving node, and proves explicit reacquisition without replay. It also
checks shared writer handoff and grant/login revocation across nodes. See the
[failover review](../reviews/2026-09-16-terminal-failover.md) and
run instructions (`scripts/test/fixtures/legacy-deployment/README.md#browser-failover-with-a-fresh-guest` at kittens revision `9fe1e493`, repository deleted).

## Open questions

Extend fault checks and workload measurements beyond the verified three-node,
single-host browser path, including Lilly restart during input. Dynamic
resize would require a separately versioned physical control contract. Second-host
and 100-instance platform acceptance remain broader obligations.

## Related decisions

[ADR-0008](0008-identity-sharing-and-terminal.md),
[ADR-0009](0009-assurance-and-testing.md),
[ADR-0018](0018-persisted-sharing-and-user-machine-access.md),
[ADR-0019](0019-terminal-session-and-writer-authority.md),
[ADR-0020](0020-local-console-fences-and-bounded-streams.md),
[ADR-0021](0021-console-relay-connections-and-mailboxes.md).
