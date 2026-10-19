# ADR-0229: SCIM-managed identity and teams

- ID: ADR-0229
- Date: 2026-10-19
- Status: accepted
- Implementation: partial
- Components: Marshall, MarshallWeb, NixOS
- Supersedes: none
- Superseded by: none

## Context

Marshall needs directory provisioning for users and teams while preserving
durable account retirement, team ownership invariants, and localized control
room administration.

## Decision

Use `ash_scim` for `/scim/v2` Users and Groups with one rotating bearer token
stored only as a digest. SCIM deletion and `active=false` enter a seven-day
retirement state; machines pause immediately and are physically deleted at the
deadline. Magic-link sign-in is unavailable while SCIM is enabled. OIDC uses
runtime configuration and matches immutable SCIM `externalId` to OIDC `sub`.

SCIM becomes authoritative for teams. Enabling it archives all native teams and
retires their attached records; team machines receive the same seven-day grace
period. New groups use a hidden service owner, manual team mutations are fenced,
and disabling SCIM leaves managed teams locked until administrator handoff.

## Consequences

PostgreSQL remains the authority for configuration, lifecycle and membership;
Oban retries retirement work and Ash state machines reject closed transitions.
Ordinary users receive read-only views of active managed teams while archival
projections remain administrator-only. The control room and all new human text
use Marshall's Localize/Gettext catalog workflow.

## Alternatives

Using a bespoke provisioning API would duplicate SCIM interoperability and
client behavior. Storing bearer tokens in recoverable form would simplify
rotation but violate the credential-custody boundary. Keeping native team
mutations available would allow directory state and Marshall state to diverge.

## Invariants and verification

Bearer rotation invalidates the previous token, no token enters diagnostics,
exactly-one-owner constraints remain valid, and retired identities cannot be
resurrected. Hegel properties cover lifecycle and membership races; NixOS
machine/browser tests cover endpoint authentication, control-room configuration,
magic-link fencing, team retirement and localized rendering.

## Implementation evidence

Resource, endpoint, digest-authentication, lifecycle fields, team retirement
fence, OIDC browser flow, attached-resource cleanup, archive projections, and
control-room route are implemented in
[Marshall.Scim](../../../marshall/lib/marshall/scim.ex); durable
database-backed execution and native NixOS execution remain partial because
those environments were unavailable during verification.

## Open questions

None.

## Related decisions

- [ADR-0066](0066-account-retirement.md)
- [ADR-0077](0077-teams-and-shared-resources.md)
- [ADR-0201](0201-localized-human-surfaces.md)
