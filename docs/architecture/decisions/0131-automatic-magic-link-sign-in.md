# ADR-0131: Automatic magic-link browser sign-in

- ID: ADR-0131
- Date: 2026-10-02
- Status: superseded
- Implementation: partial
- Components: Marshall Accounts, Marshall Web
- Supersedes: ADR-0066
- Superseded by: ADR-0148

## Context

[ADR-0148](0148-open-domain-email-eligibility.md) replaces the inherited domain
restriction while retaining the browser behavior and rationale below.

ADR-0049 required a second click after opening a magic link so email scanners
following links could not consume it. ADR-0066 carried that requirement forward.
The current browser view therefore interrupts sign-in with a confirmation form
and an optional remember-browser checkbox. The user requested immediate browser
sign-in and automatic remembering after opening the email link.

## Decision

Opening a magic link in a JavaScript-enabled browser automatically submits the
token by the existing CSRF-protected POST action, enables the existing remember
credential, and follows the current signed-in destination. A plain GET does not
consume the token or authenticate the browser. The normal callback still checks
the stored login and sends pending-MFA accounts to Security settings before
workspace access. A browser without JavaScript may use the fallback submit button.

This replaces only ADR-0049's explicit second-click requirement as inherited by
ADR-0066. Carry forward all other ADR-0066 requirements, including eligible
email identity, verified-email account creation, generic request feedback,
retirement, revocation and separation of remembered login from fresh email/MFA
authority. ADR-0123's remembered-credential authority remains unchanged.

## Alternatives

Keeping the confirmation click preserves the old scanner boundary but leaves
the requested interruption. Consuming the token on GET would also sign in
simple link scanners and lose the existing CSRF-protected POST boundary.

## Consequences

JavaScript-capable automated link visitors can trigger sign-in and consume a
single-use token; GET-only scanners cannot. Every completed browser magic-link
sign-in now issues a persistent remember credential under the existing lifetime
and revocation rules. No database or public route migration is required.

## Invariants and verification

- A plain GET leaves the token unconsumed and establishes no session.
- The browser submits automatically with remember enabled, then reaches the
  explicit return destination or Overview, subject to pending MFA.
- Expired, invalid and replayed links never establish a session or remember
  credential. Revocation and sign-out continue to cover both credentials.
- Focused HTTP and native browser journeys exercise those boundaries; native
  results are recorded separately from source changes.

## Implementation evidence

[Browser handoff](../../../marshall/lib/marshall_web/automatic_magic_sign_in_live.ex)
posts through the [existing authentication routes](../../../marshall/lib/marshall_web/router.ex).
[Magic-link flow tests](../../../marshall/test/marshall_web/magic_link_flow_test.exs)
cover the GET boundary, POST and remember cookie. The updated
[native MFA browser journey](../../../nix/verification/tests/machines/mfa-login/browser.py)
passed automatic navigation, remembered-cookie issuance and pending-MFA routing
across three colocated replicas, as recorded in the
[review](../reviews/2026-10-02-automatic-magic-link.md). Actual inbox delivery,
JavaScript-capable mail scanners, independent physical hosts and production
rollout remain unverified.

## Open questions

None for the requested browser behavior. JavaScript-capable mail scanners remain
an operational compatibility risk.

## Related decisions

[ADR-0049](0049-organizational-email-registration.md),
[ADR-0123](0123-remembered-browser-authority.md),
[browser sign-in review](../reviews/2026-10-02-automatic-magic-link.md).
