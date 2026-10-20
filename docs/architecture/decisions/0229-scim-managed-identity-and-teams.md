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

Implemented, with evidence in the
[2026-10-20 completion review](../reviews/2026-10-20-scim-completion.md):

- `/scim/v2` Users and Groups through vendored `ash_scim` (three marked
  Marshall-local changes) routed for both
  [Marshall.Accounts](../../../marshall/lib/marshall/accounts.ex) and
  [Marshall.Teams](../../../marshall/lib/marshall/teams.ex); digest-only bearer
  authentication in [Marshall.Scim.Auth](../../../marshall/lib/marshall/scim/auth.ex).
- One retirement lifecycle for SCIM `DELETE` (soft destroy) and `active=false`
  in [ScimRetirement](../../../marshall/lib/marshall/accounts/scim_retirement.ex)
  and [RetirementWorker](../../../marshall/lib/marshall/scim/retirement_worker.ex):
  immediate login revocation and machine pause, cancellation and resume of only
  SCIM-paused machines inside grace, machine deletion and ghosted finalization
  after the deadline, driven through `UserDeletion` state-machine transitions.
- SCIM-managed teams with a hidden [service owner](../../../marshall/lib/marshall/teams/service_owner.ex),
  native mutation [fences](../../../marshall/lib/marshall/teams/fence.ex) that
  persist after SCIM is disabled, native-team retirement on enable and Group
  `DELETE` through [TeamRetirementWorker](../../../marshall/lib/marshall/scim/team_retirement_worker.ex),
  and a read-only all-teams view.
- Magic-link refusal and the SCIM sign-in page; OIDC authorization-code sign-in
  with PKCE and JWKS-verified ID tokens in
  [Marshall.Scim.Oidc](../../../marshall/lib/marshall/scim/oidc.ex); the
  Control Room page with separate enable, disable, rotate and OIDC operations
  under passkey step-up.

Remaining gaps keep this decision `partial`: the administrator handoff that
releases SCIM-managed teams after SCIM is disabled is not implemented (they stay
locked); the OIDC client secret is stored in plaintext; SCIM team members are
always plain members, so directory groups cannot grant team roles.

## Open questions

None.

## Related decisions

- [ADR-0066](0066-account-retirement.md)
- [ADR-0077](0077-teams-and-shared-resources.md)
- [ADR-0201](0201-localized-human-surfaces.md)
