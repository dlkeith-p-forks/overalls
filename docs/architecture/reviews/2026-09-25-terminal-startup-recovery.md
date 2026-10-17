# Terminal startup recovery

## Findings and changes

ADR-0083 and ADR-0117 remain accepted without changing their decisions or
implementation status. The recovery fixes preserve caller ownership, guest
execution fencing, five-second request deadlines and durable opening identities.
No database schema, public API, guest protocol or deployment topology changes.

- High: [relay controls](../../../marshall/lib/marshall/terminal/relay.ex) used
  the caller PID as their reply address after a timeout. Host expiry used the
  same five-second deadline. Late replies reached the LiveView's unhandled
  mailbox and raised `FunctionClauseError`. Controls now retain caller identity
  but use an expiring process alias, deactivated on every completion path; queued
  matching replies are drained without consuming unrelated messages. Local and
  remote errors and termination responses use that address too. Legacy replies
  are inert in the LiveView, under its existing fresh-login hook.
- Medium: [session refresh](../../../marshall/lib/marshall_web/live/terminal_live.ex)
  treated temporary boot-time listing failures as terminal-opening errors.
  Non-running machines now show lifecycle-specific notices without guest
  discovery. Running machines retry preparation or reconnection; definitive
  opening errors remain visible. No failed listing proves that a shell exited.

## Evidence

The original implementation failed both new relay checks (one generated property
and one production-deadline unit) and three connected workspace regressions.
The latter reproduced the exact unhandled `relay_reply` FunctionClauseError,
alongside preparation and provisioning notice failures.

Focused terminal and workspace checks passed: 53 checks, including 6 properties
and 47 tests. Generated outcomes exercise duplicate and stale replies around
subsequent requests, preserving unrelated mailbox messages. Generated opening
histories preserve execution and closed/failed phases. Connected LiveView tests
exercise recovery to one session and unchanged rendering after legacy replies.
Local host expiry and TLS peer tests cover cancelled reply aliases, owner
validation and pending shutdown responses. These are application/loopback tests,
not evidence of native guest isolation or physical multi-host availability.

Marshall's full application suite passed 1,047 checks (101 properties and
946 tests; 2 excluded), including the distributed cases. Browser terminal
checks (19), dashboard checks (4), workspace TypeScript, ADR structure,
contracts and logging checks passed. The final four connected workspace checks
also passed after extending explicit-failure retention and verifying that
non-running machines send no guest queries. Forced Dialyzer passed with zero
errors and no skipped findings after completing the internal request type.
The HLDD source, generated options/coverage/views and Nix `hldd` checks passed.

The worktree was then integrated with `origin/main` at `3f679eff`, preserving
its guest-identity, authority and scenario verification changes. The complete
Marshall `mix precommit` gate passed on that integration: 1,101 checks
(113 properties and 988 tests; 2 intentionally excluded), browser and TypeScript
checks, and forced Dialyzer with zero errors, skipped findings or unnecessary
exclusions. The integrated handbook and Nix `hldd` gate also passed.

Final integration with `origin/main` at `d2a47671` preserved the terminal vendor,
selected-ticket and database recovery changes and their scoped native evidence.
The combined terminal, connected workspace, handbook and runtime-configuration
suite passed 76 checks (11 properties and 65 tests). All 28 terminal browser
checks, 4 dashboard checks, workspace TypeScript, warning-free compilation,
formatting, runtime, ADR, logging and contract checks passed. Forced Dialyzer
reported zero errors, skipped findings or unnecessary exclusions. Generated
handbook coverage/options/views and the Nix `hldd` gate passed. The final contract
review found no conflict with caller ownership, execution fencing or durable
opening identity; no new architecture decision is required.

## Historical production observation and limits

Read-only Overalls journal inspection for the reported machine found allocation
at 20:14:34.791 UTC, launch at 20:14:43.390, terminal-process crash reports at
20:14:45.357 and 20:14:52.115, running observation at 20:14:49.434, and successful
attachment at 20:14:54.850 on September 25. The production crash payloads were
redacted, so attribution to the reproduced exception remains an inference.
The service restart after first attachment is a separate event.

An owned probe machine was created through Porsche on the existing deployment
at 21:04:46.726 UTC, launched at 21:05:00.578 and reported running at
21:05:06.917. Porsche subsequently confirmed its deletion. This validates only
the deployed provisioning path, not this worktree's fix. A Chromium login
attempt reached the connected sign-in form, but the account requires MFA;
browser startup observation stopped at that boundary without changing account
security. No fresh native browser startup or deployment acceptance is claimed.
The subsequently integrated [terminal workspace verification](2026-09-25-terminal-workspace-verification.md)
records passing NixOS and Ubuntu graphics, reconnect, whole-Marshall recovery,
sharing and revocation journeys on its separately captured candidate. Those
results do not establish native startup acceptance of this fix. Existing guest-disk
compatibility, physical/provider failure and separate assistive-technology
integration remain outside the recorded evidence.
