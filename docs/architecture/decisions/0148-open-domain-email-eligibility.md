# ADR-0148: Safe email eligibility across domains

- ID: ADR-0148
- Date: 2026-10-09
- Status: superseded
- Implementation: partial
- Components: Marshall Accounts, Marshall Web
- Supersedes: ADR-0131
- Superseded by: ADR-0158

## Context

[ADR-0158](0158-durable-guest-identities.md) separates mailbox syntax from Linux
naming and preserves the same guest identity across every same-User email change.
The local-part rules and evidence below retain their original scope. Open-domain
registration and inherited browser/authentication requirements carry forward.

The user explicitly selected acceptance of safe email addresses on any domain,
replacing the inherited organizational-domain restriction. Guest names still
derive from exact lowercase email local parts; opening domains must not transfer
another account's reserved name, UID or home.

## Decision

Requests, invitations and verified-token sign-ins share bounded ASCII mailbox and
safe Linux local-part validation. Domain membership does not restrict eligibility.
Malformed addresses, unsafe/reserved local parts, header injection and unsupported
input remain refused before issuance/enqueue and again before account creation.
Errors remain fixed and non-enumerating. The unique email identity includes the
whole address case-insensitively; users sharing a local part on different domains
are distinct accounts. The existing serialized allocator assigns a suffix when
that preferred guest name is permanently reserved. It never transfers a UID/home.
For the same User ID, the unchanged source local part retains its guest identity;
changing only the domain is not a guest-name incarnation change. Local-part
changes and new account UUIDs continue to acquire fresh never-reused identities.

Carry forward ADR-0131's browser behavior and all inherited retirement/revocation
authority: JavaScript opens the existing CSRF-protected POST automatically and
remembers the browser; a plain GET consumes nothing, and the fallback button
remains. Stored-token, MFA, remembered-login and fresh-email authority stay
distinct. Users are created only after verified link consumption. SMTP delivery
is asynchronous and generic feedback proves neither account existence nor inbox
delivery. No stored login is revoked merely by expanding domain eligibility.

## Alternatives

A replacement hardcoded domain continues company-specific policy. An allowlist
introduces unwanted configuration. Accepting every local part would violate safe
guest-account naming. Sharing a guest name across account UUIDs would expose old
homes; permanent reservations and the existing bounded suffix allocator prevent it.

## Consequences

Registration is open to any domain with a supported mailbox. Plus aliases and
other Linux-unsafe local parts remain ineligible. Identical local parts may acquire
different guest names across users; the CLI must use the server-assigned name.
The same-account domain-only case preserves its current home and UID.

## Invariants and verification

Test registration and delivered-link consumption across domains, case-insensitive
identity, single-use tokens, unsafe request/token refusal, generic HTTP feedback,
distinct same-local-part accounts and stable same-user domain-only identity.
Retain remembered-login, MFA, retirement and revocation tests. Unit/property
results do not prove native account isolation or SMTP inbox delivery.

## Implementation evidence

[Eligibility](../../../marshall/lib/marshall/accounts/eligible_email.ex),
[guest-name validation](../../../marshall/lib/marshall/accounts/guest_username.ex),
[user actions](../../../marshall/lib/marshall/accounts/user.ex) and
[serialized allocation](../../../marshall/lib/marshall/accounts/guest_accounts.ex)
implement these boundaries. [Registration tests](../../../marshall/test/marshall/accounts/registration_test.exs),
[guest allocation tests](../../../marshall/test/marshall/accounts/guest_accounts_test.exs)
and [HTTP tests](../../../marshall/test/marshall_web/magic_link_flow_test.exs)
exercise the application paths. The [review](../reviews/2026-10-09-standard-branding.md)
records actual execution and remaining native evidence.

## Open questions

Public deployment, provider delivery and native cross-domain account journeys
remain separate acceptance.

## Related decisions

[ADR-0049](0049-organizational-email-registration.md),
[ADR-0066](0066-account-retirement.md),
[ADR-0110](0110-cedar-guest-ssh-accounts.md),
[ADR-0123](0123-remembered-browser-authority.md),
[ADR-0131](0131-automatic-magic-link-sign-in.md).
