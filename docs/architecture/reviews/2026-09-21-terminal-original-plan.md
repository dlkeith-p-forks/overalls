# Terminal original-plan reconciliation

- Date: 2026-09-21
- Scope: original approved terminal master plan against baseline `f78f28f6` and
  the completed implementation
- Decisions: ADR-0082, ADR-0083, ADR-0084, ADR-0060, ADR-0042

## Requirement source

The [original master plan](../../terminal-v2-plan.md) was recovered from the
original conversation database, including user choices and approval. Earlier
ADRs and passing test summaries omitted requirements. The
[completion ledger](../../terminal-v2-completion.md) tracks actual source findings
and executed acceptance rather than inheriting those claims.

## Substantive findings and repair

- **High: absent end-to-end credit.** Lilly's channel acknowledged local WebSocket
  delivery, while Marshall closed viewers on mailbox pressure. That did not bound
  xterm's consumption queue or meet the approved no-drop live path. The new
  [window model](../../../protocol/lib/overalls_protocol/terminal_window.ex) counts
  bytes and frames, validates cumulative receipts, and carries consumption through
  browser, both Marshall relays and Lilly. Replay is read incrementally and
  declared separately so emulator-generated replies and clipboard side effects
  are suppressed while replaying. Protocol envelope version 2 rejects older
  peers. Native graphics/backpressure and reconnect acceptance now passes.
- **High: guest descriptor/child ownership.** A duplicated viewer descriptor was
  not CLOEXEC, PTY setup calls were unchecked, and ignored SIGCHLD conflicted with
  stored numeric PID ownership. The [PTY implementation](../../../nix/packages/terminald/src/pty.rs)
  now checks setup, retries interrupted status reads and marks all non-stdio
  descriptors close-on-exec before dropping credentials/exec. Session retirement
  owns child reaping. Rust tests/Clippy and both native guest paths pass.
- **High: sharing scope discrepancy.** VM grants alone exposed every terminal.
  The approved per-terminal view-only decision now has an audited
  [grant](../../../marshall/lib/marshall/terminal/grant.ex),
  [coordinator](../../../marshall/lib/marshall/terminal/sharing.ex), generated
  migration/snapshots and UI. Cedar VM access is still a prerequisite; terminal
  grants cannot escalate machine access or shared input authority. Native
  per-session sharing, operator read-only behavior and live revocation pass.
- **Medium: absent fleet health.** Capability advertising was incorrectly treated
  as completion of monitoring. The passive Lilly socket, bounded
  [collector decoder](https://github.com/antithesishq/kittens/blob/a99f74f06542798dc9ef288e77c99d480433fc57/nix/modules/fleet-monitor/terminal_metrics.py),
  service/VM allowlists and panels now exist. Failures yield absent measurements;
  observations never authorize work. Decoder, configuration, history and panel
  tests pass, and the fleet scenario covers service loss and restart.
- **Medium: incomplete browser functionality.** Addon installation did not expose
  search, zoom or user discovery. Current edits add those controls, per-page
  machine clipboard consent/read opt-in, names, shortcuts, theme changes and
  boot-log autoscroll. Names remain browser-local; no terminal data is persisted.
  The sidebar is stream-owned with keyboard navigation, while hook-owned terminal
  state is isolated from LiveView patches. Browser unit and native UI acceptance pass.
- **Medium: obsolete acceptance.** The standalone probe still expected v1 writer
  handoff and sanitized titles. It is rewritten for v2; the fleet probe now
  includes 50 terminals, geometry, search, title, clipboard writes and graphics
  output. The updated native fleet probe passes on this diff. The Ubuntu guest
  and Inception fixtures were also migrated from the removed v1 console; the
  full Ubuntu VM matrix passes and both Inception fixture modules compile.

## Validation and status

All required gates passed on the final source: protocol, Lilly and Marshall
precommit suites with forced Dialyzer; repository-wide Python/static hooks;
terminald, fleet-monitor, Ubuntu image/unit Nix checks; the terminal-fleet native
scenario; and the full Ubuntu guest VM matrix. Exact counts and commands are in
the completion ledger. The final diff was reassessed against ADR-0083, ADR-0084,
ADR-0060 and ADR-0042 and preserves their authority and confidentiality boundaries.

These repairs complete the recovered authorized scope. They do not authorize
SSH/split panes/guest-user provisioning or remove existing credential, Cedar,
placement/epoch and process-isolation boundaries. ADR-0083 and ADR-0084 are
implemented; ADR-0060 remains partial for monitoring work outside this terminal scope.
