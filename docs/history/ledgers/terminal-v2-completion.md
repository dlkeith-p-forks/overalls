# Terminal v2: original-plan completion ledger

> **Historical record:** This ledger preserves revision-specific implementation or verification evidence. It is not a current operational runbook, and its claims retain the original scope and execution gaps.

The later [ADR-0117](../../architecture/decisions/0117-personal-terminal-machine-workspace.md)
replaces the historical browser user picker below with automatic personal account
provisioning shared with Audi SSH, and makes Terminal the default machine tab.
The remaining transport, consent, sharing and fidelity requirements still apply.

Requirements come from the [recovered original plan](terminal-v2-plan.md), not
from later implementation summaries. This ledger distinguishes source findings
from executed validation. A checked component suite is not evidence for a
requirement absent from that suite.

## Source audit against the recovered plan

Baseline for this audit: `f78f28f6`. The table describes that baseline; subsequent
repairs below it remain separate from verification claims.

| Requirement | Actual source / current finding | Completion condition |
| --- | --- | --- |
| Guest PTYs and both images | Rust daemon and both units exist; scoped native fleet passes | Retain credential/boot checks and run expanded guest acceptance |
| 1–50 web terminals | Native Rust test creates 50 PTYs; browser fixture creates one | Real guest plus browser creates/operates 50 independent sessions |
| Credit windows both directions | Channel waits for local WS-send acknowledgement; no browser-consumption credits. Mailbox overflow closes viewers. This is **not** the planned end-to-end flow control | Wire bounded byte/frame windows across browser, Marshall, peer relay and Lilly; test stall/resume and duplicate receipts |
| Resize, replay and sequence fidelity | Resize/replay code exists; native browser scenario does not exercise geometry or sustained binary/graphics output | Native resize, cursor replay, binary/sixel backpressure and query-response cases |
| Existing guest users and modal | Text field exists; no user inventory picker or creation modal | Guest-derived bounded user inventory and accessible modal; no provisioning implied |
| Rich sidebar | Hook rebuilds list; no relative activity/unread state or LiveView stream | Stream-backed rows, keyboard navigation, activity, names and actions |
| Search and zoom | Search addon loaded but no search controls; no font zoom | Search overlay, navigation/highlights and bounded Ctrl+wheel zoom |
| Shortcuts and live theme | Alt+digits only; theme sampled at construction | Full specified shortcut set and theme updates on mounted panes |
| Sharing per terminal | Current authorization reuses VM-wide grants; no per-session share action or grant resource | Owner-controlled per-session read-only grants and live revocation, including operator viewers |
| Clipboard | Write prompt is per pane, not per machine; reads always denied without the specified opt-in; only helper tests | Per-machine consent, explicit read opt-in, selection/copy/paste browser acceptance |
| Boot log | Bounded fetch/streaming decoder exists; no autoscroll toggle/native browser test | Explicit autoscroll control and real boot-log acceptance |
| Structured logs/audit | Lifecycle catalogues and receipts exist; no session share/revoke event kinds | Complete reviewed outcomes and atomic share/revoke receipts, no terminal content |
| Fleet health | Capability gate exists. `Fleet.Sample` and `Observability` have no terminal metrics, and no terminal panel exists | Service gauges/counters, VM reachability, collection/ingestion/history/panel and outage coverage |
| Reconnect/no replay | Dedicated fleet case covers completed command preservation; input batching discards unsent data | Mid-input/dropped-ack fault injection, credit/replay recovery and bounded manager lifecycle |
| Legacy cleanup | Closed: as of `5c843eab` neither `marshall/scripts/browser_terminal_probe.py` nor its Elixir launcher references `#terminal-claim`, release/writer handoff or v1 Watching state; the probe drives the v2 pane holder and `#terminal-status` | None remaining; a source check is not a recorded native probe run |
| Governance | ADRs partial; original plan was missing from repository | Reconcile every requirement and deviation with code and executed evidence before completion |

## Completed implementation

- Protocol v2 carries cumulative input and output consumption receipts through
  browser, both Marshall relays, Lilly and terminald. Byte and frame windows are
  bounded, duplicate receipts cannot inflate capacity, replay is declared before
  bytes flow, and live input is discarded rather than replayed after disconnect.
- terminald validates PTY setup, closes non-stdio descriptors before exec, owns
  child reaping and preserves raw bounded scrollback. NixOS and Ubuntu package
  the same static daemon and authenticate it with the current boot identity.
- The terminal registry now has durable per-session view grants and atomic
  share/revoke receipts. Cedar VM access remains a prerequisite, only the owner
  may change sharing, and every shared viewer is read-only.
- The workspace uses LiveView streams for stable sidebar rows and an ignored
  hook-owned display surface for xterm state. It provides existing-user discovery,
  browser-local names, unread/activity state, keyboard navigation and shortcuts,
  search, zoom, live theme changes, boot-log follow control, accessible sharing,
  and a single active transport attachment.
- Clipboard writes use per-page machine consent, reads require explicit opt-in,
  payloads are UTF-8 and bounded, and replay cannot trigger clipboard or device
  responses. OSC 8 links require confirmed HTTP(S) destinations.
- Lilly and Marshall expose bounded terminal service, stream, viewer, peer and
  VM reachability measurements. The collector validates numeric schemas and
  identity/generation context before ingestion; the dashboard preserves unknown
  observations rather than treating them as zero or authority.
- Active Nix terminal fixtures no longer depend on the removed dtach console path. The fleet
  browser exercises fifty persistent sessions, resize, title/search, boot log,
  OSC52 consent, graphics backpressure, reconnect, serving-node loss, view-only
  sharing and revocation. The Ubuntu storage fixture authenticates terminald for
  real guest assertions across its complete VM lifecycle matrix.

## Executed validation

- `protocol/mix precommit`: 194 tests, including 73 properties; code contracts,
  ADR checks and forced Dialyzer passed with zero errors.
- `lilly/mix precommit`: 384 tests, including 43 properties; 67-event logging
  catalogue, code contracts and forced Dialyzer passed with zero errors.
- `marshall/mix precommit`: 839 tests, including 64 properties, 13 terminal
  browser tests and four fleet visualization tests; 122-event logging catalogue,
  code contracts and forced Dialyzer passed with zero errors.
- `prek run --all-files`: all logging checks, Ruff formatting/lint and `ty` passed.
- Nix checks passed for terminald native tests/Clippy, fleet-monitor decoding and
  configuration, Python static analysis, Ubuntu unit properties and Ubuntu image
  assembly.
- `terminal-fleet` passed the real HTTPS, guest, three-Marshall, sharing,
  revocation, reconnect, host-loss and capacity scenario.
- `ubuntu-guest` passed its 1,811-second native VM matrix after the test fixture
  was migrated from the removed v1 console to authenticated terminald sessions.

The implementation has architecture impact in ADR-0083 and ADR-0084 and extends
the observational model in ADR-0060. It preserves the accepted credential,
Cedar, placement/epoch, isolation and no-terminal-content boundaries. SSH, split
panes, guest-user provisioning, kitty graphics/keyboard and quantified latency
targets remain outside the approved scope.
