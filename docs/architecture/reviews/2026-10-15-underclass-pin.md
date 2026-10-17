# Underclass stream statistics pin

## Scope and architecture impact

Advance the [immutable package](../../../nix/domains/artifacts/underclass/default.nix)
from `d0cb27474464d35bc56f7f06fc632654981d5b4e` to
`8c1a38c11877d871def92bcdff311d1da26039ed`, the latest upstream GitHub `main`
revision at review time. Refresh the source archive and Cargo vendor hashes.
The fleet instrumentation patch and journal source still apply.

The upstream change preserves ADR-0102 and ADR-0081's independent host-local
pools, private credentials, loopback HTTP, separate network bearer keys and
read-only local monitor boundary. It adds statistics storage and admin routes
behind the existing administrator token; it does not change domain ownership,
host placement, service credentials or monitor-socket access. ADR-0102 remains
accepted and partial.

## Findings

The new upstream statistics layer classifies completed proxy bodies as
completed, failed, incomplete, truncated, upstream-error or client-closed and
stores only bounded sanitized error codes. It records duration, output presence,
token counts and upstream events such as capacity, policy, quota and pool
saturation. `GET /admin/api/stats`, `POST /admin/api/events/import` and the
`underclass stats` command require the administrator token. The service keeps
raw rows and daily rollups for 730 days by default, prunes old data, and bounds
minute and hour query windows. Prompt bodies, cache keys, credentials and raw
upstream error text remain excluded.

The existing monitor socket router, proxy bearer boundary, independent pool
storage and instrumentation patch remain unchanged. The package build succeeded
with the pinned source, Cargo vendor hash and local instrumentation patch.

## Validation and remaining gaps

Nix computed the source archive and Cargo vendor hashes, and `nix build
--no-link .#underclass` completed with `doCheck = false`. No Rust, application,
property or NixOS tests were run, and no deployment was performed. Native
authorization, retention, rollup recovery, provider capacity classification and
live statistics history remain unverified.
