# Terminal v2: recovered original plan

> **Historical record:** This ledger preserves revision-specific implementation or verification evidence. It is not a current operational runbook, and its claims retain the original scope and execution gaps.

## Provenance and interpretation

Recovered from the original OpenCode conversation **Firecracker web terminal
multiplexer redesign**, session `ses_f47f266dbffe0a9o9HBDmqE1Qa`:

- Consolidated master plan: `prt_0b826e45d001Q7rocta3jq1NoS`.
- User approval immediately afterward: `prt_0b829e8a100161aIJi7pkaCGzu`,
  “Implement the entire plan.”
- Full-fidelity specification: `prt_0b81c664700155QRUypE73wcJN`.
- Detailed UI specification: `prt_0b81db05c001qgMq74CFul55Rr`.
- User decisions: persistent multiplexed host stream, persistent sessions,
  shared view-only mode **per terminal session**, read-only boot log, root and
  existing unprivileged guest users, approximately 50 sessions, consent-gated
  clipboard, web-only, single active pane and rich sidebar rows.

The master plan below is preserved as originally proposed. It is a requirements
source, **not implementation evidence**. The earlier fidelity/UI details are
requirements incorporated by its references to “as agreed above” and “locked”.
Implementation corrections must be explicit: for example, the originally proposed
service address-family filter was inherited by child shells and prevented guest
networking. The corrected guest units retain host-only vsock admission and
resource limits without removing guest-user capabilities; the original text is
not silently rewritten to conceal that discrepancy.

## Original master plan

### 1. Architecture (locked)

Guest Rust `terminald` (vsock port 1075, PTY per session, persistence, raw-byte
scrollback rings, fan-out, resize, `getpwnam` users) ← Lilly vsock proxy ← persistent
multiplexed WS stream (Lilly-dialed, credit-windowed) ← Marshall (authz + registry,
bytes in memory only) ← browser xterm.js WS (full OSC/ANSI/DCS fidelity,
consent-gated OSC 52, dynamic geometry). Serial → read-only `boot.log`. Deletes:
dtach, console gate/fence/buffer/transport, console v1 codec, mailboxes/writers/relay.
Full details as agreed above.

### 2. Guest images (both)

- **NixOS** (`nix/domains/artifacts/guest/configuration.nix`): new
  `systemd.services.lilly-terminals` — `ExecStart = terminald`, after/wants
  `lilly-readiness`, same `ConditionKernelCommandLine`
  (placement/epoch/boot_challenge/ipv4); root-running for setuid sessions; hardened
  but `NoNewPrivileges=false`, `RestrictAddressFamilies = AF_VSOCK AF_UNIX`,
  `MemoryMax=512M`, `TasksMax=512`. Binary flows in via the module system.
- **Ubuntu** (`nix/domains/artifacts/guest/ubuntu/default.nix`): static-musl binary copied
  to builder-owned `/usr/local/lib/lilly/lilly-terminald` (0755) beside the `.py`
  scripts — never via the `files` overlay (protected-paths contract at line 26);
  new `units/lilly-terminals.service` + `multi-user.target.wants` symlink (pattern:
  lines 118–125). Static musl → zero runtime deps, offline build preserved.
- **Packaging**: new `nix/domains/artifacts/infrastructure/terminald.nix` —
  `rustPlatform.buildRustPackage` + `fetchCargoVendor` offline tree (pattern from
  ex_cedar, `nix/domains/artifacts/default.nix:46–50`), `pkgsStatic` musl x86_64; `checkPhase`
  runs `cargo test` + `cargo clippy -- -D warnings` (first in-repo Rust crate with
  real tests). Inception guest inherits via its base config.
- Manifest v2 sizes/SHA recompute automatically; existing running VMs on old
  images simply lack the daemon (gated, no compat path).

### 3. Web UI (locked)

`/machines/:id/terminals` workspace — rich-row sidebar (streams), single pane,
boot-log entry, copy-on-select (default on, trailing-newline strip, toggle
persisted), shortcuts, search, status pills, sharing UI; `TerminalWorkspaceLive`
+ `assets/js/terminals/` module set.

### 4. Testing (best-of-each layer, repo conventions)

- **Rust**: in-crate unit tests (framing, ring replay, resize, fork/setuid harness)
  + integration test with PTY pairs; run in nix `checkPhase`.
- **Property (StreamData)**: `protocol/test/terminal_test.exs` — bounded
  generators, encode/decode round-trip, malformed→fixed atoms (copy
  `console_test.exs` style); Lilly credit-window/mux properties; Marshall registry
  transitions.
- **Unit**: `lilly/test/console/` (stream client, proxy, async pure logic),
  `marshall/test/marshall/terminal/` +
  `test/marshall_web/terminal_workspace_live_test.exs` (element-ID selectors) + WS
  endpoint tests; `:distributed`-tagged failover test (stream resume, no
  double-execution).
- **Browser JS**: `node --test` in `marshall/test/browser/` wired via a
  `terminals.check` alias (pattern: `mix.exs:160–176`).
- **NixOS VM tests**: rewrite the fleet `scenarios/terminal.py` + Elixir probes
  in `nix/verification/tests/machines/fleet/` — real guest + real browser: 50 sessions, resize,
  reattach scrollback replay, sixel backpressure, OSC 52 consent flow,
  copy-on-select, boot-log view, stream drop → no double-exec, revocation
  mid-session, health panel. KVM harnesses (`terminal_probe.exs`,
  `browser_terminal_probe.py`) updated to v2.

### 5. Structured logging + audit

- **Logs**: dotted events with allowlisted IDs only — Marshall:
  `terminal.session_created/attached/closed`, `terminal.stream_up/down`; Lilly:
  `terminal.channel_opened/closed`, `terminal.vsock_dial_failed` (fixed stage+atom,
  `vm_id`/`placement_id`, pattern `driver.ex:504–518`); daemon: JSON to volatile
  journald (`terminald.session_*`, `terminald.auth_rejected`). New keys
  (`terminal_session_id`) added to **both** metadata allowlists (marshall/lilly
  `config.exs` contracts). WS handler processes tagged `marshall_terminal: true`
  (extend `terminal_log_filter.ex` pattern) + equivalent primary filter in Lilly
  for proxy/stream processes — crash reports can never contain bytes. Titles
  (OSC) are guest bytes → never logged.
- **Audit**: paper_trail on the new terminal registry resource
  (create/share/close; sensitive/token attrs ignored — `terminal/session.ex`
  pattern) **plus** append-only `Terminal.Event` (actor, session, kind ∈
  attach/detach/kill/share/revoke, request_id) written in-transaction like
  `Accounts.Security.audit!/3`; no bytes, no payloads; bounded admin projection +
  optional audit-page surfacing.

### 6. Fleet monitoring health

- **Authoritative gate**: `terminal_protocol: 2` advertised from the new stream
  manager's state (replaces `console_ready` wiring,
  `runtime.ex:331–344,438–445`); Marshall gates session open on `=== 2` +
  `Ledger.fresh?` (`authority.ex:227–229` pattern).
- **Monitoring plane**: `service`-kind gauges in the fleet sample catalog
  (`fleet/sample.ex`, Ziggy/Brady precedent) — stream state, live channels, dial
  failures, proxy errors — plus a "Terminal service" panel in
  `dashboard_catalog.ex`; Marshall adds WS/stream gauges to
  `Observability.snapshot`; per-VM terminald reachability surfaces as dial-outcome
  gauges on vm-scoped contexts.

### 7. Governance

New ADRs (guest PTY multiplexer; persistent host stream; browser workspace
fidelity) supersede 0019/0020/0021/0022; amend 0008/0011/0012 (+0042/0060 text if
monitoring descriptions change); `elixir scripts/check_adrs.exs`;
architecture-review skill at design + completion into
`docs/architecture/reviews/`; CONTRACTS files updated in every touched tree;
`prek run --all-files` (Python fragments) + `mix precommit` in
marshall/lilly/protocol.

### 8. Git workflow (execution)

```sh
git worktree add /home/antithesishq/overalls-terminal-v2 -b feat/terminal-v2   # from main @ 3e67333
# phases 1–5, logical commits per phase, all gates green
git checkout main && git merge feat/terminal-v2 && git push origin main    # when done
```

Matches your existing worktree convention (`/home/antithesishq/overalls-<feature>`).
Commit/merge/push only at completion, as you've authorized.

**Execution order**: 1 daemon+nix → 2 protocol+properties → 3 Lilly+deletions →
4 Marshall+UI+deletions → 5 tests/harnesses/monitoring → 6 ADRs/reviews →
commit/merge/push.

## Incorporated fidelity and UI requirements

The earlier locked specifications additionally spell out:

- Credit windows **in both directions**, from browser through each relay to PTY.
  Relays do not interpret or answer terminal sequences.
- Raw rings: 1–8 MiB/session, 64 MiB/VM, 24-hour idle TTL, maximum 64 sessions.
- Client-supplied TERM, truecolor, UTF-8, passwd HOME/cwd and credentials.
- OSC 0/1/2 titles; confirmed absolute HTTP(S) OSC 8 links; per-machine OSC 52
  write consent (once/session/mute), 64 KiB cap; clipboard reads default-denied
  with explicit opt-in. Sixel/iTerm2 images, mouse, bracketed paste, focus and BEL.
- Actual browser geometry at attachment and subsequent resize; xterm alone
  answers DA/DSR.
- Rich sidebar: title, user, state, unread activity, relative last activity,
  viewer counts and keyboard-accessible actions. New-terminal modal with existing
  guest-user picker and name; create/close/rename/share controls.
- Scrollback search overlay: Ctrl+F or Ctrl+Shift+F, highlight-all,
  Enter/Shift+Enter cycling. Ctrl+scroll font zoom and live theme changes.
- Alt+1…9 switch, Ctrl+Shift+T new, Ctrl+Shift+W confirmed close,
  Ctrl+Shift+C/V copy/paste; pane focus and keyboard sidebar navigation.
- Copy on selection release with a trailing newline removed; explicit
  copy; settings persisted using the app's local-storage pattern.
- Connection-loss banner and restoring-progress state. Boot-log autoscroll toggle.
  Empty-state shortcuts, accessible sharing controls, transitions and loading state.
- Web-only, single active pane, rich rows were explicit user decisions. Guest-user
  provisioning, SSH frontend, split panes, kitty graphics/keyboard and DECCOLM
  were explicitly deferred or excluded; installing existing addons alone does not
  prove any in-scope behavior.
