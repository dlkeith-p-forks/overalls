# ADR-0205: Overview newsletter signup

- ID: ADR-0205
- Status: accepted
- Date: 2026-10-18
- Implementation: partial
- Components: marshall
- Supersedes: none
- Superseded by: none

## Context

Authenticated users need a durable, account-wide way to discover newsletter
tips, AI updates and Overalls changes without repeatedly seeing a dismissed
invitation. The existing public website already defines the Ghost signup flow.

## Decision

Marshall may show an account-wide, durable Overview newsletter invitation. A
dismissal is a self-only monotonic account preference and is never stored in
browser state. Subscription requests use Marshall's server-side Req client to
Ghost's fixed members endpoints; browsers do not make cross-origin API calls.
Email validation is bounded and failures expose fixed safe messages without
logging addresses, tokens, or upstream bodies. The native Ghost newsletter URL
remains the no-JavaScript fallback.
This amends [ADR-0194](0194-marshall-http-security-headers.md)'s form-action
clause only: the fixed `https://ghuntley.com` origin joins `'self'` for that
native form. Unrestricted `https:` and cross-origin script or connection
sources remain refused.

## Consequences

The account schema gains private presentation state and a migration. Ghost
remains the subscription authority; Marshall does not persist subscription
status. BEAM tests cover validation and account behavior, while external
delivery and provider availability remain outside local acceptance.

## Alternatives

Browser-only local storage would not persist across devices. Direct browser
requests to Ghost would violate Marshall's same-origin presentation boundary
and expose provider details. Marshall's fixed server-side client keeps that
boundary explicit.

## Invariants and verification

Dismissal is self-only and monotonic; invalid email input makes no request; the
fixed Ghost sequence maps all failures to a safe result. Diagnostic output
excludes addresses, tokens and provider bodies. Hegel, database-backed account
and LiveView tests cover these bounded cases; test presence does not establish
external delivery or full runtime gate execution.

## Implementation evidence

The [User resource](../../../marshall/lib/marshall/accounts/user.ex),
[newsletter client](../../../marshall/lib/marshall/newsletter.ex),
[Overview LiveView](../../../marshall/lib/marshall_web/live/overview_live.ex),
[dismissal migration](../../../marshall/priv/repo/migrations/20261018190000_user_newsletter_dismissed.exs),
[account persistence/refusal tests](../../../marshall/test/marshall/accounts/newsletter_dismissal_test.exs),
[LiveView test](../../../marshall/test/marshall_web/overview_live_test.exs) and
[property test](../../../marshall/test/marshall/newsletter_property_test.exs)
implement and exercise the bounded account behavior. These sources do not
establish external Ghost delivery or production rollout. Full runtime gate
execution remains a separate checkpoint.

## Open questions

External Ghost delivery, provider availability and the packaged browser journey remain unverified.

## Related decisions

- [ADR-0196](0196-single-account-settings-page.md): account settings placement and authority.
- [ADR-0191](0191-elixir-hegel-property-verification.md): property verification.
- [ADR-0194](0194-marshall-http-security-headers.md): browser same-origin boundary.
- [ADR-0201](0201-localized-human-surfaces.md): localized human surfaces.
