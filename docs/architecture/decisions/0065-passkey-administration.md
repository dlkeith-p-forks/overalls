# ADR-0065: Passkey MFA and time-limited administrative authority

- ID: ADR-0065
- Date: 2026-09-18
- Status: superseded
- Implementation: partial
- Components: Marshall Accounts, authorization, web, compute, terminal, ingress, SSH
- Supersedes: ADR-0058
- Superseded by: ADR-0119

## Context

[ADR-0119](0119-authenticated-control-room-reads.md) replaces the administrator-only
read restriction and carries forward the other requirements below.

Administrators previously received fleet-wide authority from role membership alone.
The user explicitly approved passkeys, a fixed five-minute elevation window for
all administrative mutations, and browser-only administrator override.

## Decision

Retain ADR-0058's persisted role, permanent bootstrap latch, no self-demotion,
last-administrator protection, bounded projections and transactional audit.
Add optional passkey MFA to email sign-in: enabling it requires it on subsequent
browser logins, including remember-me. Pending MFA sessions may only access setup,
verification and sign-out. Administrators must enroll to mutate administrative state.

Use the explicitly authorized Ash Authentication 5.0.0-rc.14 and Phoenix 3.0.0-rc.11
packages with Wax verification. Marshall owns the Ash ceremony action and UI rather
than exposing upstream credential-management routes: those routes alone do not enforce
our enrollment freshness, one-use shared challenges and domain elevation policy.
The upstream WebAuthn credential registration API performs cryptographic registration;
Wax verifies assertions. Require user verification and use the configured endpoint
origin/RP identity, never request-supplied hosts.

Store one-use 60-second challenges and verification receipts in PostgreSQL, binding
account, stored login, credential and MFA generation. Elevation lasts exactly 300
seconds by database time, without sliding renewal. A completed MFA login remains
usable after elevation ends. Token revocation, removal of the proving credential,
reset and retirement invalidate relevant authority. Check at domain admission,
after transactional locks, and during ongoing privileged guest access.

Cedar distinguishes administrator reads from elevated changes and VM override.
ADR-0064 remains authoritative for profile restrictions: Customer workspaces are
owner-only even for elevated administrators. Owners and explicitly shared users
keep the ordinary permissions allowed by their profiles. SSH does not
carry browser elevation and cannot exercise administrator override. No user becomes
the internal system actor. Previously admitted durable operations survive expiry.

First enrollment requires email authentication in the previous five minutes.
Further credential changes require a verified existing passkey. Ordinary users can
disable MFA by removing their last key after verification; this revokes sessions.
Administrators cannot remove their last key. Another elevated administrator may
reset a user's MFA, revoking credentials/sessions and requiring email sign-in and
replacement enrollment. Self-reset is forbidden. No recovery codes or emergency
operator command exists; total lockout requires manual database intervention.

## Alternatives

A role-only check and LiveView mount-only gate leave alternate entry points and
already-open sessions unprotected. Sliding expiry was rejected. The user selected
Ash release candidates over a separate stable-version integration, administrator
reset over recovery codes, and browser-only override over SSH browser approval.

## Consequences

The runtime has new dependencies and additive schema. Upgrade all serving replicas
before exposing protected traffic; an older replica would bypass the new policy.
Existing logins have no elevation. Configured origin changes require deliberate
passkey migration/re-enrollment. The manual total-lockout process is intentionally
outside supported application interfaces.

## Invariants and verification

Test real WebAuthn signatures, required UV, origin/user/session binding, one-use
challenges, cross-node replay, exact deadlines, revocation and state sequences.
Exercise each administrative domain and browser path. Prove SSH has ordinary rights
only; bind terminal and authenticated guest-web checks to their original login.

## Implementation evidence

The isolated [Antithesis fixture diagnostic](../reviews/2026-10-13-antithesis-harness-foundation.md)
used a non-serving Marshall operator process to create three synthetic accounts
and register three real passkeys through the reviewed actions. Read-only SQL
counted exactly three users and three passkeys, and the operator opened no
listener. This local setup proof does not establish a hosted property, browser
MFA journey or deployed administrator recovery.

[Coordinator](../../../marshall/lib/marshall/accounts/security.ex),
[Cedar policy](../../../marshall/priv/cedar/compute.cedar), and
[Security UI](../../../marshall/lib/marshall_web/live/security_live.ex) implement the
boundary. [Unit/property tests](../../../marshall/test/marshall/accounts/security_test.exs)
exercise real signed assertions and generated state transitions.
[LiveView tests](../../../marshall/test/marshall_web/security_live_test.exs) exercise
pending login and step-up behavior. Validation and remaining native acceptance are
tracked in the [review](../reviews/2026-09-18-passkey-administration.md).

[Generated Control room histories](../../../marshall/test/marshall_web/control_room_history_test.exs)
and a [focused native browser journey](../../../nix/verification/tests/machines/control-room/browser.py)
extend current-role, elevation and stored-login coverage. Exact execution and
remaining cross-replica/hardware limits are recorded in the
[verification review](../reviews/2026-09-25-control-room-verification.md).

[Generated credential self-service histories](../../../marshall/test/marshall/accounts/credential_history_test.exs),
[domain regressions](../../../marshall/test/marshall/accounts/security_credential_test.exs),
[LiveView regressions](../../../marshall/test/marshall_web/security_live_test.exs)
and the
[credential self-service browser journey](../../../nix/verification/tests/machines/credential-self-service/browser.py)
pin rename/remove bounds, immediate elevation loss on proving-credential
removal, last-credential and limit refusals, and the repaired label-constraint
crash. Execution is recorded in the
[credential self-service review](../reviews/2026-09-26-credential-self-service.md).

## Open questions

None for product policy. Remaining executed acceptance is tracked in the review.

## Related decisions

[ADR-0064](0064-customer-workspace-isolation.md),
[ADR-0058](0058-administrative-authority.md), [ADR-0022](0022-browser-terminal-and-live-login-checks.md).
