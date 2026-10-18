# ADR-0201: Overview newsletter signup

- ID: ADR-0201
- Status: accepted
- Date: 2026-10-18
- Implementation: partial
- Components: marshall

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
