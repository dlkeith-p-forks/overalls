# Agent revocation histories, registration owner-authority fencing and orphaned-command retirement (improvement 114)

Date: 2026-09-28. Discovery: verification-campaign improvement 114 (scope
`/tmp/opencode/campaign/discovery-040-lifecycle.md` agent lanes), branch
`verify/114-agent-revocation`.

## Scope and architecture impact

Verification plus two small production fences. No wire layout, persistence
shape or protocol change; agent executor sessions keep their admitted
semantics. Affected: `executor_session.ex` (registration owner-authority
fencing + orphaned command retirement), `cli_access.ex` (revocation-aware
authorization path), `agents/loop.ex` and `audit_event.ex` (catalogued
retirement/refusal events), `agent_cli_controller.ex` (closed refusal surface),
`lyra/agent_cli.rs` (CLI-side refusal handling). ADR-0050/0062 evidence text
only; no decisions changed.

## Defect findings (each pinned by the landed tests)

1. **Executor registration minted leases after owner deletion.** Registration
   checked lease issuance without the owner's current VM write authority.
   Fixed: registration fails closed with `:access_revoked` and emits the
   catalogued `agent.executor_registration_refused` event (`executor-session
   owner authority is revalidated at registration; revoked owner authority can
   never mint a fresh lease`).
2. **Orphaned queued commands lingered behind dead turns.** A queued tool
   command whose turn finished retained claimable state forever. Fixed:
   `reap_orphaned/0` retires such rows to their closed terminal status with an
   audit receipt (`agent-orphaned-command-retirement`).
3. **Revocation history sequencing drift.** Generated approval/revocation
   histories now run an independent durable-row oracle in
   `agent_revocation_history_test.exs` + `agent_revocation_fixture.ex`:
   one session per approved digest, refused digests keep no row, expired
   approval tickets are exactly reaped with `cli_expired` receipts and live
   tickets untouched, post-boundary `CLIAccess.authorize` calls return the
   closed `:unauthorized` refusal (`agent-revocation-real-fixture`,
   `agent-revocation-scoped-inventory`, `agent-revocation-real-write-gate`,
   `agent-revocation-complete-cleanup`).

## Evidence

Focused runs on this tree (MIX_TEST_PARTITION=verify114, ERL_FLAGS="+S 4:4"):

- `agent_revocation_history_test.exs`: 18 passed (4 properties, 14 tests) —
  including "generated approval sequences keep one session per digest with
  classified refusals" and "the CLI session reaper destroys exactly expired
  approvals with receipts".
- `agent_revocation_distributed_test.exs` (three-BEAM schedules):
  23 passed (3 properties, 20 tests) under `--include distributed`.
- `agent_cli_test.exs` (controller surface): 10 passed.

The takeover repaired two author-interrupt artifacts before any run: a pending
`^expected` pin in the reaper test (bound as `length(expired)` with the
scoping comment) and a scaffold no-op (`|> Kernel.or(true)`) that tripped
conditional-typing rejection.

## Remaining gaps

- Lyra's terminal-side agent revocation journey (prompt rendering, CLI refusal
  UX) is pinned by controller/history tests only; no native desktop path in
  this improvement.
- Sustained multi-executor stampede remains out of scope; the distributed hop
  schedules cover the claims' commit-orders, not throughput.
