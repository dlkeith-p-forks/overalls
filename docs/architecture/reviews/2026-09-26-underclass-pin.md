# Underclass token rotation and recovery pin

## Scope and architecture impact

Advance the [immutable package](../../../nix/domains/artifacts/underclass/default.nix)
from `9244c8169bb1b73492f0c5ad5b693d59d65034da` to
`3e35c3bf3d24c7fa79cb93602b571b1b9c194514`, the latest upstream GitHub `main`
revision at review time. Refresh both source and locked Cargo vendor hashes.
The lockfile also updates lru, thiserror and the Hegel development dependency.

Source review before and after the pin change found no replacement decision:
[ADR-0102](../decisions/0102-local-underclass-monitor-socket.md) retains
[ADR-0081](../decisions/0081-independent-underclass-pools.md)'s independent
host-local pools, private credentials, loopback HTTP, separate network bearer
keys and read-only local monitor boundary. No domain, host placement or service
configuration changes. ADR-0102 remains accepted and partial.

## Findings

Upstream `tokens::rotation_due` selects Codex accounts with stored refresh tokens
whose last token write was at least 24 hours ago. The daemon checks at startup
and every 15 minutes through the existing per-account serialized refresh path.
Scheduled failures leave health and cooldowns unchanged. `Store::open` adds
`accounts.token_refreshed_at` when absent; legacy zero timestamps make tokens
due immediately. Successful refreshes persist credentials and the timestamp
together. Restoring old credentials can require provider re-onboarding.

The proxy gives both HTTP 401 and 403 one forced refresh and same-account retry
per request. Continued rejection or refresh failure triggers existing failover.
The administrator Enable action now clears `auth_error` as well as disabled
state, while preserving cooling deadlines. The network authorization and local
monitor routers are unchanged, as is the `utop` wrapper contract.

Inspected upstream migration and rotation unit tests, the generated rotation
interval property, and HTTP recovery/Enable fixtures. Their presence is not
passing execution. The fleet's existing
[service machine test](../../../nix/verification/tests/machines/underclass-service/default.nix)
covers service custody and authentication but does not exercise provider rotation
or migration of an existing account database.

## Validation and remaining gaps

Source archive and Cargo vendor hashes were computed with Nix; only dependency
fetching/vendoring is needed for the latter. Handbook option defaults and coverage
are regenerated. Structural documentation and contract checks are reported in
the commit summary; they do not establish runtime correctness.

No Rust, application, property or NixOS machine tests were run, as requested by
the user. No full package build or manual deployment was performed. Follow-up
native coverage should open a legacy database, check first-pass rotation and
issuer failures, and verify authenticated recovery without shortening cooldowns.
Live provider, tailnet, ledger-retention and encrypted-restore gaps remain open.
