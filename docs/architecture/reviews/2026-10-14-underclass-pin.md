# Underclass manual reset redemption pin

## Scope and architecture impact

Advance the [immutable package](../../../nix/domains/artifacts/underclass/default.nix)
from `3e35c3bf3d24c7fa79cb93602b571b1b9c194514` to
`d0cb27474464d35bc56f7f06fc632654981d5b4e`, the latest upstream GitHub `main`
revision at review time. Refresh both source and locked Cargo vendor hashes.
The lockfile also updates rand to 0.10, tokio, toml and the Hegel development
dependency; the fleet instrumentation patch and journal source still apply.

Source review before and after the pin change found no replacement decision:
[ADR-0102](../decisions/0102-local-underclass-monitor-socket.md) retains
[ADR-0081](../decisions/0081-independent-underclass-pools.md)'s independent
host-local pools, private credentials, loopback HTTP, separate network bearer
keys and read-only local monitor boundary. No domain, host placement or service
configuration changes. ADR-0102 remains accepted and partial.

## Findings

Upstream ADR 0020 adds manual redemption of a banked Codex reset credit.
`ResetManager::manual_reset` redeems at most one credit for exactly the named
Codex account, independent of `auto_codex_resets`, sharing the automatic path's
serialization lock, earliest-expiring credit choice, persisted idempotency key
and confirm-then-readmit behaviour. Without `force` it refuses when fresh
upstream usage reports the account allowed (readmitting a cooling account) or
when a completed redemption for this outage has not restored usage. A missing
credit or a non-Codex account is never overridable.

The operation is `POST /admin/api/accounts/{id}/reset?force=` inside the same
`route_layer` admin-token middleware as the existing enable, disable and
re-login routes; the local monitor socket router is unchanged. Refusals return
JSON with a stable `error` code: 409 for `not_rate_limited`, `already_redeemed`
and `no_credit`, 400 for `not_codex`, 502 for upstream failure, 404 for an
unknown account. The admin page gains a **Use reset** button. The new
`underclass reset <label-or-id> [--force] [--url]` command resolves the account
from `/admin/api/state` and reuses `top`'s admin token resolution, so with
`--url` the token must come from `UNDERCLASS_UI_TOKEN` and a database token is
never sent to a remote host. Structured logs record manual attempts under
request id `manual` with the existing outcome vocabulary and no tokens or
upstream bodies.

Smaller changes: the default Codex catalog adds `gpt-6-sol` with a larger
context and per-model input limits; usage accounting classifies a request as
streaming from `"stream": true` in the body as well as an event-stream content
type, so JSON-typed stream responses are no longer misattributed; the monitor
socket test uses a short path. The `utop` wrapper contract is unchanged.

Inspected upstream unit tests for the catalog entry, stream classification and
the manual reset refusal, override and idempotency paths. Their presence is not
passing execution. The fleet's existing
[service machine test](../../../nix/verification/tests/machines/underclass-service/default.nix)
covers service custody and authentication but does not exercise reset
redemption or a controlled upstream credit endpoint.

## Validation and remaining gaps

Source archive and Cargo vendor hashes were computed with Nix, and the fleet
package built offline with the instrumentation patch and journal source. The
scenario chapter is regenerated. Structural documentation, ADR and contract
checks are reported in the commit summary; they do not establish runtime
correctness.

No Rust, application, property or NixOS machine tests were run, and no manual
deployment was performed. Follow-up native coverage should drive the reset
endpoint and CLI against a controlled issuer, check the 409 refusals and
`force` override, and verify the idempotency key survives a restart. Live
provider, tailnet, ledger-retention and encrypted-restore gaps remain open.
