# ADR-0147: Standard profile naming for fresh installations

- ID: ADR-0147
- Date: 2026-10-09
- Status: accepted
- Implementation: partial
- Components: protocol, Marshall, Lilly, NixOS deployment
- Supersedes: ADR-0103
- Superseded by: none

## Context

The user authorized removal of company references and selected Standard as the
replacement product profile name, with unchanged networking and agent permissions.
They explicitly selected fresh installations only and preservation of the testing
integration, SDK and environment variables. This is a source change in a separate
worktree; Git history and deployed state are not rewritten.

## Decision

Use `standard` in the closed profile types, wire fields, CLI arguments and fresh
database schemas. Its display name is Standard and its pool remains 10.20.0.0/16.
The default remains OSS. Customer, OSS and Inception retain their current behavior.
There is no legacy-name alias, old-state importer or mixed-release compatibility.
The spelling-only migration/snapshot baseline changes are for empty databases.

Carry forward ADR-0103's complete tool authority: OSS and Inception allow
`exec_command`, `read_file`, `spawn_child_agent`, `web_search` and `web_fetch`;
Standard allows the same list except `spawn_child_agent`. Customer has no agent.
Unknown profiles/tools deny. Fresh Cedar write authority remains required. Model
advertisements, complete response validation, provider claim and guest claim/start
checks all enforce the persisted profile. Forbidden responses create no work;
pending forbidden work is cancelled durably before the RPC error. Started effects
cannot be undone or replayed. Audit/diagnostics remain content-free.

Preserve the testing integration's paths, namespaces, SDK schemas and environment
variables. Its product fixtures use Standard so the existing harness still works.
Use `antithesishq/overalls` and its `main` branch for canonical source/deployment URLs.
The user explicitly restored the original repository and branch when requesting
publication. Repository references are an intentional exception to the branding
cleanup. Publishing source does not establish existing-state deployment acceptance.

[ADR-0240](0240-account-machine-creation-presets.md) amends only browser default selection: machine and thread creation now use their independent account presets, starting with Standard (Work); repository launch starts with OSS. The original OSS default above records this decision’s historical baseline. Profile enums and permissions are unchanged.

## Alternatives

Removing the profile would remove requested capabilities. Aliasing the old name or
migrating deployed journals adds compatibility that the user explicitly excluded.
Changing only labels leaves the old product name in APIs and persisted schemas.

## Consequences

Existing databases and Lilly journals require independent migration planning before
deployment. Use a fresh test database. The address, disk and authority algorithms
are unchanged; coordinated source-built components share the new closed enum.
Historical documentation uses the current profile label while retaining recorded
revision hashes, original rationale and execution limits.

## Invariants and verification

Verify shared command/relocation round trips, CLI profile selection, slot/address
identity, fresh PostgreSQL constraints and the full profile/tool allowlist.
Retain Customer isolation and Standard child-agent refusal in native scenarios.
Run all three application gates, contract/ADR/HLDD checks and relevant Nix checks.

## Implementation evidence

[Address types](../../../protocol/lib/overalls_protocol/address_pool.ex),
[execution schema](../../../protocol/lib/overalls_protocol/execution.ex),
[agent capabilities](../../../marshall/lib/marshall/agents/capabilities.ex),
[network identity](../../../lilly/lib/lilly/network/guest.ex) and
[fresh address migration](../../../marshall/priv/repo/migrations/20260915164125_add_image_and_address_admission.exs)
implement the naming and preserved pool. [Profile properties](../../../protocol/test/profile_policy_test.exs)
and [agent tests](../../../marshall/test/marshall/agents/capabilities_test.exs)
exercise the retained policy. The [review](../reviews/2026-10-09-standard-branding.md)
records actual verification and remaining native/deployment gaps.

## Open questions

Existing-state deployment is excluded; deployment acceptance remains separate.

## Related decisions

[ADR-0007](0007-profile-networking.md), [ADR-0069](0069-brady-egress-cache.md),
[ADR-0103](0103-profile-scoped-agent-capabilities.md),
[ADR-0148](0148-open-domain-email-eligibility.md).

Proposed [ADR-0151](0151-existing-state-standard-profile-migration.md) considers
the later incoming existing-state migration. It does not supersede this accepted
fresh-only policy; its [custody review](../reviews/2026-10-10-profile-migration-custody.md)
records the implementation conflict and unresolved deployment extension.
