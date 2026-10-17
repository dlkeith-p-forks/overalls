# Browser terminal audit remediation

- Date: 2026-09-20
- Scope: browser audit findings H4, M1, M4, M5, L2 and L3
- Decisions: [ADR-0083](../decisions/0083-terminal-host-stream-and-registry.md),
  [ADR-0084](../decisions/0084-browser-terminal-workspace.md)

## Findings resolved

- OSC52 now handles the standard clipboard selector, denies reads, rejects
  malformed or decoded payloads over 64 KiB, decodes UTF-8 and offers explicit
  allow-once, session and mute choices.
- OSC8 activation uses xterm's supported link handler and permits only
  explicitly confirmed absolute HTTP/HTTPS URLs.
- Boot-log base64 is decoded as UTF-8 in the browser.
- PostgreSQL terminal session rows now retain only VM, owner, placement,
  execution epoch and guest session identity. Guest user, terminal type and
  browser title are not persisted.
- ADR-0084's `COLORTERM` typo and browser-test evidence are corrected.

## Verification

- Browser Node tests pass for OSC52 selection, bounds, read denial, consent,
  OSC8 schemes, UTF-8 boot logs and selection shaping.
- Marshall contracts, warnings-as-errors compilation, terminal browser gate,
  formatting and ADR structure checks pass.
- The focused Marshall database test compiled but could not start because the
  local PostgreSQL `pg_hba.conf` rejects the configured non-TLS test connection.
  No database-backed runtime result is claimed.

## Architecture impact

The remediation implements existing ADR-0083/0084 boundaries rather than
changing them. Browser capabilities remain explicit user decisions, terminal
bytes and titles remain outside PostgreSQL, and the registry keeps only durable
authority bindings. Both decisions remain accepted and partial because the
existing real-browser/fleet and load-acceptance gaps are unchanged.
