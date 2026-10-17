# ADR-0107: Marshall-owned agent web search

- ID: ADR-0107
- Date: 2026-09-23
- Status: accepted
- Implementation: partial
- Components: Marshall, NixOS secret custody, agent fleet tests
- Supersedes: none
- Superseded by: none

## Context

ADR-0100 makes Marshall the durable agent loop. Users authorized a `web_search`
tool for OSS, Inception and Standard profiles, Serper as the provider, a
24-hour shared cache, per-call credit receipts and a nonfunctional encrypted
placeholder key during development. The guest executor has no reason to hold a
search credential or perform a public search on behalf of the control plane.

## Decision

Marshall advertises and executes `web_search`. It validates a nonempty query
under the existing model tool-call bound, persists the command and claims it
once under current VM and actor authority before sending provider bytes. A
claimed request is not automatically retried. An uncertain attempt fails the
turn. Provider failures return a closed tool error.

Marshall sends a fixed Serper search request with provider default result count
and projects the answer box plus every organic result into the model tool
output. The whole projection must fit the existing context bound; excess size
produces a closed error instead of truncation. A PostgreSQL cache shares
successful projections across tenants by exact trimmed query for 24 hours.
Only an authorized agent call can reach that cache. Cache hits cost zero new
provider credits; misses record reported credits or an unknown value.

The Serper credential is a host-specific SecretSpec/SOPS value delivered as a
raw systemd credential to each Marshall instance. The installed random
placeholder permits startup and produces `search_unavailable` without a
provider request. The user explicitly authorized that temporary behavior.
Diagnostic events and audit receipts contain identifiers, closed outcomes and
credit counts, never query or result content or credential bytes.

## Alternatives

Executing inside the VM would distribute provider access and make the global
cache and accounting cross a guest boundary. Ziggy would require new control
RPCs for a tool already coordinated by Marshall. Marshall's supervised worker
uses its existing HTTP and database authority directly.

## Consequences

Every Marshall instance that may claim work needs the same real provider key
when production search is enabled. A placeholder can be deployed safely but
does not make live search available. Concurrent cache misses can each make a
provider request. Without a per-turn search quota, the existing agent loop
limit bounds how many requests one turn may request.

## Invariants and verification

- Guest executors never claim `web_search`; a current authorized turn and
  allowed profile gate every Marshall claim.
- Search claims commit before network activity, and ambiguous attempts are
  never replayed automatically.
- Every organic result in one accepted provider response reaches the model in
  provider order, or the tool returns a complete-result size error.
- A command has one content-free audit outcome and one credit receipt; cache
  hits carry zero credits and never contact Serper.
- StreamData, database tests and isolated NixOS machine tests exercise the
  boundaries, including encrypted secret delivery and a synthetic provider.

## Implementation evidence

The [Marshall search coordinator](../../../marshall/lib/marshall/agents/web_search.ex),
[profile policy](../../../marshall/lib/marshall/agents/capabilities.ex),
[encrypted credential wiring](../../../fleet/hosts/overalls/services.nix), and
[database/property tests](../../../marshall/test/marshall/agents/model_calls_test.exs),
[agent fleet VM test](../../../nix/tests/machines/fleet/scenarios/agent.py) and
[secret-custody VM test](../../../nix/tests/machines/secret-custody/driver.py)
implement and verify the initial path. The Overalls secret document now carries
an encrypted provider key; production-provider acceptance remains to be verified.

## Open questions

None for the authorized first release. Verify a live provider response after
the credential-bearing revision deploys.

## Related decisions

[ADR-0100](0100-pulled-agent-work-over-ziggy-control.md) owns the loop and
[ADR-0103](0103-profile-scoped-agent-capabilities.md) owns tool authorization.
