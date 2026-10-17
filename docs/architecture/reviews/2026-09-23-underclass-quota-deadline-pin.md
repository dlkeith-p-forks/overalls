# Underclass quota deadline pin

## Scope and architecture impact

Advance the immutable Underclass source from `8c4cd02` to `9244c81`. The sole
upstream commit changes Codex quota classification and usage-poll recovery.
ADR-0102's independent host pools, state custody, loopback listener, local
monitor socket and network authorization remain unchanged. The change affects
when a Codex account leaves cooling and returns to rotation; it stays within
each host's pool and persisted SQLite health state.

## Findings

Codex now chooses the later valid future deadline from a structured
`usage_limit_reached` error and `Retry-After`, or the configured fallback when
neither is usable. A verified blocked usage poll can cool a healthy account or
extend an existing cooldown but does not shorten it. An explicit `allowed: true`
readmits cooling accounts. Failed or missing usage leaves state unchanged.
Overload remains transient; Copilot retains generic status classification.
The upstream tests cover deadline choice, persistence and readmission with
mock responses. Live provider quota timing remains unverified.

## Verification

The pinned package build, Underclass configuration and service VM checks,
upstream locked Rust tests, ADR checker and code-contract check are recorded
with their results in the change summary. These local checks verify packaging
and modeled recovery behavior, not live provider deadlines or quota accuracy.
Overalls and Dungarees activated fleet revision `c63313e7` and reported it
healthy. Both ran Underclass package `9244c81` with an active daemon. Their
local monitor sockets returned snapshots and unauthenticated network monitor
requests returned 401. No live provider quota event was induced.

## Remaining gaps

ADR-0102 remains partial for live provider/tailnet acceptance, ledger retention
and encrypted restore. Verify an actual Codex quota reset deadline before
claiming the new timing matches provider behavior.
