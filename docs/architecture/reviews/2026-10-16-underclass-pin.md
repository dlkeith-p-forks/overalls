# Underclass saturation reselect pin

## Scope and architecture impact

Advance the [immutable package](../../../nix/domains/artifacts/underclass/default.nix)
from `8c1a38c11877d871def92bcdff311d1da26039ed` to
`469aff4c797e14052285d64d9acfa4b2fc0c73a3`, the latest upstream GitHub `main`
revision at review time. Refresh the source archive hash; `Cargo.lock` is
unchanged, so the Cargo vendor hash is retained. The fleet instrumentation patch
and journal source still apply, with line offsets only.

The change is internal to the proxy's request path. It preserves ADR-0102 and
ADR-0081's independent host-local pools, private credentials, loopback HTTP,
separate network bearer keys and read-only local monitor boundary. ADR-0102
remains accepted and partial.

## Findings

On 2026-10-16 the overalls host saw sustained upstream throttling across all
three Codex accounts while one Codex app-server drove about 25 concurrent
subagent sessions. Upstream 429 cooldowns lasted 1 to 56 seconds. The pool
recorded 757 `pool_saturated` events in six hours, some with a deadline already
before the event timestamp.

Cause: when selection reported saturation, `infer` awaited the automatic reset
attempt, which serializes on a shared lock behind usage fetches, and reselected
only when a credit was redeemed. A cooldown expiring during that wait was
ignored and the client received a 429 for a pool that could serve. This also
contradicted the upstream `saturation-fail-fast-429` contract ("then select
again"). The fix always reselects, adds a lock-free pre-check so requests do not
queue on the reset lock while any Codex account is healthy, and makes
`request.saturated` log the relative `retry_after_ms` plus the absolute
`until_ms`. The client-facing `Retry-After` header was already relative.

The root load is client fan-out, not an Underclass defect; the fix removes
spurious refusals but does not add subscription capacity.

## Validation and remaining gaps

Upstream `cargo test` passed (unit, Hegel property and end-to-end suites).
Nix computed the source archive hash, the instrumentation patch applied, and
`nix build --no-link .#underclass` completed with `doCheck = false`. The Nix
`hldd`, `underclass-package`, `underclass-configuration`, `underclass-service`
and `underclass-slo` checks passed on this pin; they exercise packaging,
service startup, monitor-socket access and SLO journal custody, not saturation.
The lock-wait race has no dedicated regression test because the
reset check interval is not injectable; live provider throttling behavior after
deployment remains to be observed.
