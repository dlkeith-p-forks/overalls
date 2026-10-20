# SCIM completion review — 2026-10-20

## Scope

This review covers completing [ADR-0229](../decisions/0229-scim-managed-identity-and-teams.md)
after an audit of the [2026-10-19 implementation](2026-10-19-scim-implementation.md)
found that the declared flows did not work end to end. It covers the
`/scim/v2` Users and Groups endpoint, the user retirement lifecycle, the
SCIM-managed team fence and retirement, OIDC sign-in, the sign-in page, the
Control Room provisioning page, and localization.

## Findings and resolutions

- **OIDC sign-in could be forged (security).** The callback accepted `iss` and
  `sub` from the query string with no code exchange or token verification.
  Replaced with an authorization-code flow with PKCE and one-shot state/nonce;
  the ID token is verified against the provider JWKS (RS256/ES256 only, exact
  issuer, audience, bounded time, required nonce). OIDC never registers users.
- **Every SCIM HTTP request failed.** The endpoint did not halt after the SCIM
  router replied (`AlreadySentError`). Fixed in `MarshallWeb.Endpoint`.
- **Groups were unreachable.** The router served only `Marshall.Accounts`; the
  authorizer refused every SCIM team action and enabling SCIM failed whenever a
  native team existed. Teams are now routed, SCIM actions are allowlisted for
  the service owner only while SCIM is enabled, and member add/remove works.
- **User deletion never completed.** SCIM `DELETE` hard-deleted the row, machine
  deletion was always forbidden and finalization raised. DELETE is now a soft
  retirement sharing the `active=false` lifecycle; deletion and finalization run
  through `UserDeletion` transitions; reactivation inside grace cancels them and
  resumes only SCIM-paused machines.
- **Deactivated users kept access.** Logins survived the seven-day grace and
  SSH key sessions, agents, ingress and other surfaces checked only
  `deleted_at`. Deactivation now revokes logins in its transaction and every
  live-account check requires `active`.
- **Team fences were incomplete.** Ownership transfers were unfenced, SCIM teams
  were never marked SCIM-managed and locks lapsed when SCIM was disabled. SCIM
  teams are SCIM-managed, owned by the hidden service owner, and locked against
  every native mutation permanently; the Teams page explains the lock and offers
  a read-only all-teams list.
- **Team machine deletion crashed.** `Lifecycle.delete_for_team/3` used the
  system actor as audit actor, which the ledger refuses; it now audits as the
  SCIM service owner under the retiring-team binding.
- **The Control Room page could not save** (a catch-all policy refused
  administrators) and rotated the token on every save; passkey step-up dropped
  every SCIM field. Operations are now separate, with their own bounded
  `scim-configure` elevation grammar.
- **Tests did not exercise production code.** The lifecycle property tested a
  model inside the test and the contract test asserted a function against
  itself. Both now drive the real resources.

## Validation

All runs used a throwaway PostgreSQL, never the production database.

- SCIM, OIDC, Control Room, sign-in and Teams LiveView suites
  (`test/marshall/scim`, `scim_oidc_controller_test.exs`,
  `admin_scim_live_test.exs`, `scim_sign_in_live_test.exs`,
  `teams_scim_live_test.exs`, `admin_elevation_test.exs`):
  `Result: 94 passed`, including Hegel properties for ID-token tampering, SCIM
  group membership against a model, and generated user retirement histories.
- Regression of the access surfaces touched by the `active` check
  (`test/marshall/ssh`, `test/marshall/scim`, `test/marshall/agents`,
  `test/marshall/galileo`, `test/marshall/ingress`, `test/marshall/threads`,
  `live_user_auth_test.exs`): 370 of 371 passed; the failing assertion expected
  the weaker behaviour and was updated, after which the affected files passed
  16 of 16.
- `mix localization.catalogs` and `mix gettext.extract --check-up-to-date`
  pass with all 48 new messages translated into the 27 non-English locales.
- NixOS machine test `nix build .#checks.x86_64-linux.scim` passed
  (`vm-test-run-overalls-scim-endpoint`), output
  `/nix/store/r2idn08azzf2cdvliv62lvfjggbq41c3-vm-test-run-overalls-scim-endpoint`:

```text
subtest: SCIM stays closed until an administrator enables it
subtest: Control Room redirects anonymous administrators to localized sign-in
subtest: Enabling SCIM retires native teams and replaces magic-link sign-in
scim-probe-ok native-retiring
subtest: Only the current bearer token authenticates
subtest: Directory users and groups provision Marshall accounts and SCIM-managed teams
scim-probe-ok group-synced
subtest: Deactivation starts the seven-day retirement and deletion hides the account
scim-probe-ok user-retiring
```

The machine test enables SCIM through a fixture that mirrors the administrator
`:enable` transaction; the passkey-elevated Control Room path is covered by
LiveView tests only. It does not advance the clock past the seven-day deadline;
deadline-driven machine deletion and finalization are covered by the Oban tests
in the BEAM test VM, not natively.

## Remaining gaps

- Administrator handoff of SCIM-managed teams after SCIM is disabled is not
  implemented; such teams stay locked.
- The OIDC client secret is stored in plaintext in the configuration row.
- SCIM team members are always plain members; directory groups cannot grant
  team roles, so SCIM teams cannot provision team machines or integrations.
- No browser-driven Control Room or OIDC journey runs in a machine test.

## Affected decisions

ADR-0229 (implementation evidence updated; status stays partial), ADR-0066,
ADR-0077 and ADR-0201 (preserved).
