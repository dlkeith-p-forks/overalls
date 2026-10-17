# Browser acceptance failure diagnostics (verification 120)

## Scope

Test-infrastructure only: the fleet browser acceptance worker
(`nix/tests/machines/fleet/browser.py`) and its coordinator
(`browser-coordination.py`) gain bounded, allowlisted failure diagnostics, so a
red acceptance phase is now root-causeable from build logs alone.

Background: the campaign ledger records a reproduced main-HEAD defect — the
"verified terminal v2 sessions" machine leg fails at `service_browser` with
`AssertionError: Browser acceptance failed` (see the campaign row 119). The
worker previously withheld everything but the stage name; this change adds the
diagnostics without exposing any guest bytes, tokens, tickets or terminal content.

## What changed

- The worker (`browser.py`) now publishes into the rendezvous `state.json` on
  failure: `failure_stage` (the protocol's fixed stage label), `failure_error`
  (the exception class name only), `browser_errors` (the pageerror
  category→count table) and `navigation_tail` (the last eight route/status
  pairs). All four were already-bounded channels; nothing else is added.
- The coordinator (`browser-coordination.py`) prints those keys (when present)
  right before the acceptance assertion, and the worker's stderr now appends
  to the allowlisted public log instead of `/dev/null` (traceback class
  information for the worker script itself; guest content stays excluded).

## Evidence

Three-phase reproduction of the recorded defect (finding 119):

| Run | Tree | Log | Result |
| --- | --- | --- | --- |
| `terminal-fleet` | main `e3f2a8fc`..`33e16342`/… | build-log `1790526809167-2331334-0` | failed at `service_browser`, same signature |
| `terminal-fleet` | main + `2b82c624` reverted | build-log `1790579408949-392370-0` | failed identically → suspect exonerated |
| `terminal-fleet` | this branch (`bb396d94`) | build-log `1790583461175-1344964-0` | failed identically AND yielded bounded diagnosis (`failure_stage`, `failure_error`, `browser_errors={}`, 8-entry navigation tail ending `terminal 302 → machines 200 → other 503 ×2 → terminal 200`) |

The instrumented run was itself red — expected: the defect under investigation is
still open. Type/lint story: `ruff format` + `ruff check` pass; standalone `ty`
produces 65 diagnostics, all in the known driver-fragment baseline (injected
globals such as `client`, `m1`, `root`, `sql`, `json`, `eventually`, and the
`playwright.sync_api` import), unchanged by this edit. No other suite runs; no
runtime/production change (test-side only).

## Remaining

The defect itself (finding 119) is unrepaired; follow-up work reads the failure
stage's reconnect path.
