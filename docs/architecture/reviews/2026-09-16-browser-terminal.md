# Browser terminal review

## Scope and architecture impact

ADR-0022 implements the browser boundary over ADR-0019/0021 authority and buffering.
It adds a pinned renderer dependency, client flow control, fresh login checks for
existing machine pages and terminal process log redaction. The existing Cedar,
generation, writer and host transport contracts remain authoritative.

## Findings and resolution

- **High, corrected login drift:** connected MachinesLive previously retained its
  actor after token revocation. Login hooks now verify stored token presence and
  database-time expiry before events, refreshes and parameter changes. Terminal
  actions retain their independent checks. ADR-0008/0018/0019 apply.
- **High, browser replay boundary:** reconnect discards input, and receipts use
  exact decimal counters. Uncertain/discarded input requires explicit writer
  release/reclaim. An enqueue reply is not a guest execution acknowledgment.
  Claims/releases also echo the current session ID; old buffered control events
  cannot act on a replacement LiveView's newly opened session.
- **High, diagnostic payload risk:** Phoenix parameter filters alone do not cover
  an OTP crash report's last message or state. Terminal-process log filtering
  replaces payloads before formatter/capture handlers, retaining safe metadata.
  The LiveView socket transport is tagged too, since it carries byte frames and
  may survive navigation between terminal and ordinary machine pages.
- **Medium, flow control:** output is pulled one page at a time after rendering;
  input has one pending sequence and a 16 KiB total bound. Large paste rejection,
  gaps and uncertainty have visible notices. Fixed geometry is explicit.
- **High, corrected renderer bound:** upstream xterm appends combining characters
  to a cell's string, so a scrollback-line limit does not bound retained bytes.
  A 4 MiB input budget between parser/buffer resets now bounds even a stream with
  no line advances or an unfinished escape sequence. Resets are visible.
- **Medium, corrected console contamination:** Chromium screenshots exposed
  Firecracker's private API polling logs in the guest TTY. The launch argv now
  sets the documented `--level Off`; Lilly retains structured lifecycle events.
  A separate bounded host sink is required before enabling detailed VMM logs.
  This applies ADR-0015's console/log boundary without changing VM supervision.
- **Open platform acceptance:** fleet load, terminal failover between Marshall
  nodes and the second physical host remain unverified. The single-host browser
  path is now verified; it does not establish these broader properties.

## Verification

Marshall precommit passed 154 cases (12 properties, 142 tests), including the
three-node admission/writer/input races and the new stale browser-control test.
All four host checks passed. Six Node cases cover exact counters, acknowledgment
ordering, uncertainty, queue bounds, reconnect and renderer byte budgets.
Compiler, pinned-runtime and Dialyzer gates passed; the existing single upstream
Marshall typespec exclusion is unchanged. The asset build passed.

Lilly precommit passed 78 cases (17 properties, 61 tests), with zero Dialyzer
errors or exclusions. Its production release and development modules were rebuilt
with routine Firecracker logging disabled. Protocol is unchanged; its previous
22-case suite and Dialyzer result remain the applicable evidence.

Chromium passed real magic-link sign-in, viewer read-only access, guest commands,
shared writer handoff, grant revocation, explicit WebSocket disconnect/reconnect,
manual writer reacquisition, confirmed sign-out revocation, clipboard/title/link
handling and desktop/mobile layout. The guest command checks require successful
shell exit before their marker appears. The full path uses Marshall's actual
HTTPS endpoint, Lilly's relay and the real Firecracker TTY. Screenshots were
inspected; no JavaScript errors or page-level mobile overflow were observed.
The final execution harness also passed Lilly hard-kill recovery with the same
VMM PID, stop/start disk persistence, exactly three automatic crash restarts,
credential revocation/rotation, cleanup-gated deletion and actor retirement.
It reported fixture VMs, networking, disks and database records cleaned, with the
prior inactive slice state restored. A separate post-run audit confirmed no Lilly
VM units, network namespaces, nftables tables or `/var/lib/lilly` fixture directory,
and zero execution-smoke hosts/users in PostgreSQL. The final browser-state and
22-record ADR checks passed after the documentation updates.

Architecture validation passed for 22 records. Git metadata became unavailable
in this workspace during the turn; final review uses direct source inspection
and executed checks, and makes no claim about the final staged diff.

## Remaining work

Measure database/terminal
load and verify a second physical host and the target Marshall deployment range.
These platform obligations remain open after this UI change.
