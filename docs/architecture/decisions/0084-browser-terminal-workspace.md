# ADR-0084: Browser terminal workspace

- ID: ADR-0084
- Date: 2026-09-19
- Status: superseded
- Implementation: implemented
- Components: Marshall Web, browser assets
- Supersedes: ADR-0022
- Superseded by: ADR-0117

## Context

[ADR-0117](0117-personal-terminal-machine-workspace.md) replaces the machine workspace, personal browser
account opening and roster profile portions where applicable. Other decisions
and historical rationale below remain in force.

ADR-0022 rendered a single fixed 80x24 serial console through LiveView
polling, neutralized OSC 0/1/2/8/52 and fenced one exclusive writer. The
terminal model is now many persistent guest PTYs (ADR-0082) carried by a
stream (ADR-0083), and the product asks for a full-fidelity, multi-terminal
workspace with copy-on-select.

## Decision

Serve `/machines/:id/terminals`: one LiveView page owning session bookkeeping
(issue tickets, list, create, kill, boot log) and one hook-managed pane area.
Each viewer pane is an xterm.js instance (vendored runtime plus fit, webgl,
unicode11, search and image addons) attached to its own Marshall viewer
WebSocket through a single-use ticket. Input and output are binary frames;
geometry comes from the real browser size and `onResize` reaches the PTY via
`TIOCSWINSZ`. The daemon sets `TERM=xterm-256color` with
`COLORTERM=truecolor`-style truecolor advertising, and no hop interprets
terminal bytes, so full ANSI/DCS/OSC fidelity is preserved end to end.

Sequence handling is consent-based, not sanitized: window titles (OSC 0/1/2)
update the sidebar and document title; OSC 8 hyperlinks open only http/https
URLs after explicit confirmation; OSC 52 clipboard writes are bounded to
64 KiB, require an allow-once/session/mute consent per browser and default to
denial for clipboard reads. Selection copies to the clipboard on release
(trailing newline stripped so pasting never auto-executes; toggleable,
persisted in local storage). The sidebar lists sessions with user, viewer
count, activity and kill actions, switches with Alt+1..9, and exposes the
read-only boot log fetched through bounded controls. The display toolbar can
place the active terminal or boot log in browser fullscreen and refits the
emulator when that state changes. Reconnects reattach with
the pane's scrollback cursor and display the skipped range explicitly.
`TERM` answers device queries only in the browser emulator.

## Alternatives

Keeping LiveView polling cannot express binary streaming or resize and keeps
the sanitization trade. A native SSH front end is deferred: the viewer
protocol is byte-transparent, and a future russh front end can reuse the
session engine without changing the workspace.

## Consequences

The browser holds the only terminal emulator, so emulator capabilities bound
fidelity; xterm.js plus addons covers truecolor, sixel/iTerm2 images, unicode
11, search and the consent-gated OSC set, while kitty keyboard protocol and
kitty graphics remain out of scope for the web frontend. Slow viewers are
closed and reattach rather than blocking others. The workspace degrades to
read-only for viewers without write authority, and host stream loss surfaces
as an explicit reconnect state.

## Invariants and verification

- No server component renders, sanitizes or answers terminal sequences; guest
  bytes reach only the emulator and the clipboard consent handlers.
- Tickets are minted only for authenticated users with fresh Cedar read (or
  write for rw) authority, and every pane connects through one.
- Copy-on-select strips exactly one trailing newline; OSC 52 writes are
  bounded and consent-gated; OSC 8 opens confirmed http/https links only.
- The workspace never persists terminal bytes or titles server-side.
- Node unit tests cover clipboard-selection shaping, and the browser E2E
  suite exercises typing, titles, resize, reattach and the consent flow.

## Implementation evidence

The workspace LiveView is
[terminal_live.ex](../../../marshall/lib/marshall_web/live/terminal_live.ex)
with the [viewer socket](../../../marshall/lib/marshall_web/terminal_socket.ex)
upgrade and the [workspace hook](../../../marshall/assets/js/terminals.js) on
the vendored [xterm runtime and addons](../../../marshall/assets/vendor/xterm/addons/README.md).
Selection shaping is covered by
[browser tests](../../../marshall/test/browser/terminals_test.mjs), including
OSC52 bounds/read denial, OSC8 scheme validation and byte-preserving boot-log decoding,
wired into precommit. Live-typing E2E coverage moves to the fleet browser scenario; the
predecessor's failover harness results remain recorded in its review.

The implementation follow-up keeps create request IDs and original parameters
in browser memory across lost replies and LiveView reconnects. It waits for
attachment acknowledgement before input/resize, suppresses read-only mutation,
removes retired panes, retains browser-local titles, and pages bounded boot-log
chunks into a read-only xterm emulator. Regression execution was deferred
during the implementation-first phase; resumed validation is recorded below.

The follow-up also preserves xterm binary input (including non-UTF-8 mouse
reports), falls back after WebGL context loss, limits reconnect attachment to
previously selected panes, and keeps background-pane status changes from
overwriting the active pane's status. The native scope is recorded below.

Subsequent native testing adds bounded 16 KiB input batching scheduled after
16 ms, preserving byte order while avoiding per-keystroke server mailbox bursts.
Batches belong to one socket and are discarded on disconnection. Duplicate
ticket replies no longer replace an attaching or healthy socket, and attachment
acknowledgement has a deadline. LiveView uses five-second heartbeat intervals to
detect a hard serving-machine loss. Ten browser-state tests pass, including
binary batching and disconnect discard, and the dedicated native terminal-fleet
sharing/reconnect/revocation scenario passes. This does not establish all clipboard,
graphics, many-pane and performance acceptance requirements.

## Completion update

The recovered [original UI/fidelity requirements](../../terminal-v2-plan.md)
include an explicit clipboard-read opt-in, per-machine consent, search/zoom and
per-session sharing. The [completion ledger](../../terminal-v2-completion.md)
records the implemented controls and executed evidence. The UI exposes those capabilities;
clipboard reads remain denied by default and require explicit opt-in on a
writable live pane. Replayed output cannot read/write the clipboard or emit
device replies into the live guest. Stream-owned accessible sidebar rows coexist
with a hook-owned xterm surface, so periodic LiveView patches preserve terminal,
dialog, search and clipboard state. Browser unit tests and native acceptance of
the original UI matrix pass.

The [serial-console rendering review](../reviews/2026-09-22-serial-console-rendering.md)
corrects later-discovered implementation drift: the boot-log pane had decoded
raw serial bytes into a plain text element, exposing terminal control syntax.
The boot log now uses a separate read-only xterm instance, consumes raw bytes,
denies clipboard/input capabilities and resets from cursor zero when a restarted
VM truncates its boot log. This is an implementation correction to the existing
browser-emulator decision, not a new terminal transport or guest-console design.
The same UI change adds a browser-fullscreen display control without changing
terminal authorization or transport geometry rules.

## Open questions

Kitty keyboard protocol and kitty graphics need either a new frontend or the
deferred SSH front end. Latency targets under load are unquantified.

## Related decisions

[ADR-0022](0022-browser-terminal-and-live-login-checks.md),
[ADR-0082](0082-guest-terminal-multiplexer.md),
[ADR-0083](0083-terminal-host-stream-and-registry.md).
