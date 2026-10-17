# Marshall agent web search architecture review

## Scope

Review the Serper provider boundary, Marshall-owned command claims, global
cache and credit receipts, profile authorization, encrypted key delivery,
content-free logging and audit against ADR-0100, ADR-0103 and ADR-0107.

## Findings

Marshall remains the sole thread and command authority. The guest claim query
excludes search commands. The search worker rechecks persisted profile and
actor access under the command lock, and a claimed search cannot be queued
again after worker loss. The design intentionally allows duplicate provider
calls for concurrent cache misses and has no separate paid-search quota.

Search content is held in authorized thread state and the shared cache; the
cache stores a query digest and provider projection without tenant identity.
Audit events and catalogued diagnostic events contain only closed metadata.
The host-specific key is delivered through SecretSpec/SOPS and systemd
credentials. The encrypted Overalls document now contains a provider key, but
live Serper success is not yet claimed. The signed-in user's authorization is
checked before cache use as well as before a provider call.

## Verification and gaps

Marshall property and database tests cover profile policy, result projection,
cache expiry, credit receipts, guest exclusion and revoked claims. The Marshall
precommit gate passed, including its full suite and Dialyzer. The NixOS agent
fleet test passed with a synthetic Serper service and verified a paid response,
all organic results, and a zero-credit cache hit on another Marshall node. The
NixOS secret-custody test passed with the raw credential and journal checks.
The shared role fixture now uses PostgreSQL 18, matching production and the
existing UUIDv7 migrations. The encrypted manifest check passed for 32
documents. Production acceptance requires deploying the key-bearing revision
and observing a successful live call.
