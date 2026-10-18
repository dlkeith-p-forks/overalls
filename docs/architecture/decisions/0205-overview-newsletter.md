# ADR-0205: Overview newsletter signup

- ID: ADR-0205
- Status: accepted
- Date: 2026-10-18
- Implementation: partial
- Components: marshall
- Supersedes: none
- Superseded by: none

## Context

The Overview may offer a durable newsletter invitation without making the browser a direct provider client.

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

A browser-only provider request would expose cross-origin behavior and provider details; Marshall's fixed server-side client keeps that boundary explicit.

## Invariants and verification

Dismissal is self-only and monotonic, validation and provider failures use fixed safe messages, and diagnostic output excludes addresses, tokens and provider bodies. Focused LiveView and property tests cover the bounded behavior; external delivery remains outside local acceptance.

## Implementation evidence

The [newsletter client](../../../marshall/lib/marshall/newsletter.ex), [Overview LiveView](../../../marshall/lib/marshall_web/live/overview_live.ex), [dismissal migration](../../../marshall/priv/repo/migrations/20261018190000_user_newsletter_dismissed.exs), [LiveView test](../../../marshall/test/marshall_web/overview_live_test.exs) and [property test](../../../marshall/test/marshall/newsletter_property_test.exs) implement and exercise the bounded account behavior. These sources do not establish external Ghost delivery or production rollout.

## Open questions

External Ghost delivery, provider availability and the packaged browser journey remain unverified.

## Related decisions

- [ADR-0196](0196-single-account-settings-page.md): account settings placement and authority.
