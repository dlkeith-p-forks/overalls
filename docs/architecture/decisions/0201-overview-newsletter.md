# ADR-0201: Overview newsletter signup

- ID: ADR-0201
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

## Consequences

The account schema gains private presentation state and a migration. Ghost
remains the subscription authority; Marshall does not persist subscription
status. BEAM tests cover validation and account behavior, while external
delivery and provider availability remain outside local acceptance.

## Alternatives

Browser-only local storage would not persist across devices. Direct browser
requests to Ghost would violate Marshall's same-origin presentation boundary.

## Invariants and verification

Dismissal is self-only and monotonic; invalid email input makes no request; the
fixed Ghost sequence maps all failures to a safe result; Hegel and LiveView
tests cover these cases.

## Implementation evidence

Implemented in `marshall/lib/marshall/accounts/user.ex`,
`marshall/lib/marshall/newsletter.ex`,
`marshall/lib/marshall_web/live/overview_live.ex`, the user migration and
snapshot, and `marshall/test/marshall/newsletter_property_test.exs`.
External delivery and full runtime gate execution remain gaps because the
current checkout has unrelated dependency/catalog compilation failures.

## Open questions

None.

## Related decisions

ADR-0191 (Hegel property verification), ADR-0194 (Marshall HTTP security
headers), and ADR-0197 (localized human surfaces).
