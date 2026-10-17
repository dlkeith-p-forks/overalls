# ADR-0049: Organizational email registration

- ID: ADR-0049
- Date: 2026-09-17
- Status: superseded
- Implementation: implemented
- Components: Marshall Accounts, authentication UI
- Supersedes: ADR-0008
- Superseded by: ADR-0064, ADR-0066

## Context

[ADR-0064](0064-customer-workspace-isolation.md) replaces Customer networking and
sharing policy while carrying forward all unrelated decisions below.

The operator requested automatic registration for organizational mailboxes
and exclusion of all other registration domains. Registration was already enabled
but the generated sign-in message incorrectly implied prior registration was
required. ADR-0008 originally selected open email registration.

## Decision

Replace open registration with magic-link access restricted to the exact
organizational domain, compared case-insensitively. Retain bounded ASCII mailbox
validation. Subdomains, lookalike domains and suffix extensions are ineligible.
Validate the request before token issuance/email enqueue and validate the signed
identity again before account creation/upsert. Previously issued tokens cannot
bypass the new rule. Existing stored login sessions are not revoked by this change.

Create a new eligible account only after successful magic-link consumption with
explicit user interaction. Repeat sign-in uses the existing case-insensitive
email identity. Request feedback describes automatic registration without disclosing account
existence or enqueue/provider results. At the operator's request, visible labels,
messages and validation errors do not name the organization/domain requirement;
the server-side domain restriction remains enforced.

Carry forward all other ADR-0008 decisions and rationale: signed-in users may
provision any profile subject to capacity without initial per-user quotas; real
Cedar evaluation protects VM and sharing actions; sharing targets exact existing
registered recipients; viewer/operator/manager grants retain their permissions;
ownership remains protected with no transfer; root guest terminals permit multiple
readers and one authoritative writer with bounded streams and revocation across
nodes. Subsequent decisions implementing those boundaries remain applicable.

The Audi extension in [ADR-0047](0047-audi-ingress-and-authoritative-dns.md)
adds web-only sharing below these VM roles. It grants only the distinct Cedar
web action, without changing viewer/operator/manager terminal or lifecycle
semantics. Persisted sharing and transactional terminal revocation follow
[ADR-0018](0018-persisted-sharing-and-user-machine-access.md).

## Alternatives

A UI-only restriction leaves direct account actions and old tokens unprotected.
Creating accounts before email verification allows unauthenticated registration
of another person's address. Subdomain/suffix matching admits addresses outside
the explicitly requested organization. Invite-only registration contradicts the
requested automatic registration for eligible addresses.

## Consequences

New magic-link requests and token sign-ins require an eligible domain. Existing
accounts and stored sessions are not deleted. Losing access to an organizational
mailbox does not itself revoke an already-issued session; session revocation is
separate from this registration policy. SMTP delivery remains asynchronous and
the generic response does not prove inbox delivery.

## Invariants and verification

Test successful first registration only after delivered-link consumption,
case-insensitive repeated sign-in, single-use tokens, rejected unrelated and
lookalike domains before email/token insertion, and rejected outside-domain
tokens minted before the restriction. Exercise the real sign-in form and its
non-enumerating feedback. Run Marshall's precommit gate and deployed UI checks.

## Implementation evidence

The evidence below is historical. [ADR-0148](0148-open-domain-email-eligibility.md)
replaces the domain restriction; current linked tests now exercise that policy.

[User actions](../../../marshall/lib/marshall/accounts/user.ex) enforce both
boundaries. [UI overrides](../../../marshall/lib/marshall_web/auth_overrides.ex)
explain eligible automatic registration.
[Account tests](../../../marshall/test/marshall/accounts/registration_test.exs)
exercise the database, encrypted outbox and delivered token.
[UI tests](../../../marshall/test/marshall_web/registration_test.exs) exercise the
actual LiveView form. The full Marshall gate passed with 397 tests/properties
and Dialyzer. The physical deployment is healthy and its sign-in form omits the
organization requirement; see the registration review for scope and evidence.

The [HTTP regression tests](../../../marshall/test/marshall_web/magic_link_flow_test.exs)
exercise the separate request callback, ordinary form submission, generic rejection,
cooldown and explicit single-use sign-in for new, existing and MFA-enabled users.
The [callback review](../reviews/2026-09-25-magic-link-request.md) records a production
request crash missed by the earlier LiveView-only coverage and its correction.
These tests use the test mail adapter and do not establish SMTP inbox delivery.

## Open questions

None for the registration policy. SMTP inbox delivery is separate acceptance.

## Related decisions

[ADR-0008](0008-identity-sharing-and-terminal.md),
[ADR-0022](0022-browser-terminal-and-live-login-checks.md),
[ADR-0040](0040-host-local-smtp-relay.md),
[registration review](../reviews/2026-09-17-email-registration.md).

[ADR-0066](0066-account-retirement.md) replaces the authority/lifecycle policy while retaining the rationale above.
