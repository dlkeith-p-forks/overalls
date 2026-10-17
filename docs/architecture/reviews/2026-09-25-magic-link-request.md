# Magic-link request regression

## Scope and architecture impact

Review Marshall's authentication controller, configured magic-link and remember-me
callbacks, UI feedback and routed tests. This restores the request/login distinction
under [ADR-0049](../decisions/0049-organizational-email-registration.md), carried forward
by [ADR-0066](../decisions/0066-account-retirement.md), without changing account
eligibility, session authority, persistence or MFA policy. The encrypted outbox and
delivery guarantees in [ADR-0040](../decisions/0040-host-local-smtp-relay.md) and the
login checks in [ADR-0065](../decisions/0065-passkey-administration.md) remain intact.
No migration, dependency change or replacement decision is required.

## Findings and correction

- **High, corrected:** the MFA change in `4be7657f` added an unconditional metadata
  lookup in `AuthController.success/4`. Ash dispatches a successful magic-link
  request with a nil user/token, so requesting a link raised `BadMapError` after
  durable email enqueue. Production evidence on September 25 showed an HTTP error
  at 07:42:36 UTC and committed SMTP acceptance at 07:42:37 UTC. Isolated execution
  of the deployed release reproduced the nil-user crash. Earlier HTTP handling
  also incorrectly described requesting a link as successful sign-in.
- **Medium, corrected:** rejected HTTP requests used credential-failure feedback
  while LiveView requests gave generic email feedback. Both request outcomes now
  use the same message and redirect, without revealing account eligibility,
  existence, or enqueue/provider results.
- **Coverage gap, corrected:** existing domain and LiveView tests bypassed the
  failing HTTP callback. New routed tests cover both existing and new identities,
  pending MFA, the rendered form action, cooldown, return destinations, explicit
  token consumption, replay and private diagnostics.

The [controller](../../../marshall/lib/marshall_web/controllers/auth_controller.ex)
handles request callbacks before reading login metadata, preserving session
authority and `return_to` without emitting sign-in events. Both it and the
LiveView override use one request-feedback constant. Successful sign-in and
its MFA checks retain their existing path. Inspection of the pinned remember-me
strategy found no HTTP callback routes; its cookie path does not dispatch a
nil-user success to this controller. Password/confirmation branches are not
configured authentication strategies for this resource.

## Verification

The new [flow tests](../../../marshall/test/marshall_web/magic_link_flow_test.exs)
reproduced the HTTP failure before the fix. Seven routed scenarios pass after
the correction, using sandboxed PostgreSQL and the Swoosh test adapter.
The focused authentication selection passed all 19 tests. Marshall's complete
`mix precommit` passed inside `devenv shell`: pinned runtime, ADR and contract
checks, logging catalog validation, compilation/formatting, 945 Elixir checks
(73 properties and 872 tests, including distributed cases; 2 excluded host/capacity
cases), 21 browser-state tests, workspace TypeScript checking, and forced Dialyzer
with zero errors or skips. The final documentation-only evidence update also
passed the ADR checker and `git diff --check`.

Contract review covers `magic-link-request-is-not-login`,
`authentication-public-failure`, `registration-message-no-enumeration`,
`accounts-stored-login-authority`, `accounts-mail-secret-boundary`, and
`user-magic-link-explicit-interaction`. The tests check persisted state and real
router/dispatcher behavior rather than mocking the callback result.

No production account was altered or new production email sent for verification.
Deployment of this correction and real inbox delivery remain separate acceptance.
