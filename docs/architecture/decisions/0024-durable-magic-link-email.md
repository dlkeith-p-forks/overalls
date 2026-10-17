# ADR-0024: Durable magic-link email

- ID: ADR-0024
- Date: 2026-09-16
- Status: superseded
- Implementation: implemented
- Components: Marshall Accounts, AshOban, AshCloak, SMTP, production configuration
- Supersedes: none
- Superseded by: ADR-0040

## Context

[ADR-0040](0040-host-local-smtp-relay.md) adds optional trusted-loopback submission
through a synchronous host relay and carries forward the outbox requirements.
The decisions and evidence below describe the original direct SMTP path.

ADR-0008 selects open magic-link registration. The generated sender used a
placeholder address, interpolated the recipient into HTML and called a local
mailer synchronously. Production had no external delivery configuration. The
user's instruction to implement the plan authorizes completing this path with
durable background work and protected credentials.

## Decision

Use Swoosh's SMTP adapter with pinned `gen_smtp` 1.3.0. SMTP supports an operator's
chosen relay without selecting a commercial provider. Production requires an
explicit relay, username, password, sender address and public Marshall hostname.
Support implicit TLS and mandatory STARTTLS, always verifying the certificate
chain and hostname. Disable MX lookup and internal transport retries. Require
TLS 1.2 or 1.3 and bound connection setup to three seconds. A separate owning
task bounds the entire delivery attempt to ten seconds, since the SMTP library's
receive timeout is longer. Task termination closes its connection.

The Accounts domain owns an `AuthEmail` Ash resource with an AshCloak-encrypted
recipient/token payload. Enqueue the record and its AshOban job in one database
transaction. Jobs contain the record identity, never the link or credentials.
Use Cedar's existing trusted system-actor bridge; ordinary users cannot read or
mutate outbox resources. Public authentication requests continue through
AshAuthentication's interaction policy.

A PostgreSQL advisory lock and database-clock creation timestamp impose a shared
one-minute per-recipient cooldown. The recipient key is an HMAC using the shared
token-signing secret; a separate token digest prevents repeat enqueue of the same
token. Address case follows the existing case-insensitive account identity.
Mailbox inputs are bounded ASCII dot-atom addresses, excluding header/command
syntax. Quoted or internationalized mailboxes are not supported by this initial
SMTP path. Responses keep the existing generic authentication behavior.

The delivery action re-reads a pending record under a row lock inside its
transaction; the AshOban worker's earlier read does not provide this boundary.
Before each attempt, verify the token signature, action, stored magic-link purpose
and expiry.
Consumed or expired links are not newly submitted. Provider errors are converted
to fixed retry errors; retryable records remain encrypted until successful
delivery or token expiry. Retries use the same token and stable Message-ID.
SMTP has no exactly-once acknowledgment: a crash or lost reply after acceptance
can cause a duplicate email. The link itself remains single-use. Acceptance by
the relay is not proof of inbox placement, and a link may expire in transit.

Delivery or expiry replaces ciphertext with SQL NULL. An AshOban cleanup trigger
physically deletes expired rows. Do not create archival or audit copies of these
ephemeral credentials. Periodic scheduling recovers missed work and retries stop
being useful at token expiry. The `mail` queue has concurrency two per instance;
provider quotas and aggregate fleet limits remain operational constraints.

Build both plain-text and HTML messages from the configured endpoint URL, never
request headers. The recipient is not interpolated into HTML. Tagged mail process
diagnostics are redacted before logger handlers; structured attempt events retain
only safe identifiers and outcomes. Authentication HTTP and LiveView processes
are tagged before request diagnostics, because the magic-link token is part of
the URL path; parameter filtering alone cannot protect that path. Disable redirect
diagnostics because the endpoint's HTTPS redirect precedes the privacy plug.
Production HTTPS handling no longer trusts arbitrary `X-Forwarded-Proto` or
exempts loopback Host headers, reconciling generated configuration with ADR-0012's
accepted direct-TLS policy.

## Alternatives

Synchronous requests lose delivery on transient failures and hold the browser
request open. Unencrypted Oban arguments expose usable login links in job storage
and failures. Provider-specific HTTP APIs can add idempotency but would select a
vendor the user has not chosen. Blind SMTP retries cannot establish exactly-once
delivery. An unbounded transport receive wait can exhaust the mail queue and
database pool.

## Consequences

Production needs working SMTP credentials, sender-domain configuration and DNS,
plus shared signing/encryption keys on all Marshall instances. Migration must
precede the new release. SMTP work holds only the outbox row and a bounded database
connection, never a host/admission lock. Two slow deliveries per instance still
consume part of its database pool. The cooldown limits messages per recipient,
not token generation or requests across arbitrary recipient addresses; deployment
abuse controls and workload limits need validation.

## Invariants and verification

- Enqueue failure leaves no outbox record without its delivery job.
- Three Marshall nodes share duplicate suppression, recipient cooldown and
  serialized delivery of a pending record.
- Stored payloads are encrypted and removed after completion or expiry.
- Expired/consumed links are not newly submitted; received links sign in once.
- Real TLS tests cover implicit TLS, STARTTLS, untrusted certificates, hostname
  mismatch, downgrade refusal, stalled peers and sanitized provider failures.
- Property tests cover mailbox boundary input and diagnostic redaction.
- Production forwarding headers cannot turn plaintext requests into trusted TLS.

## Implementation evidence

[Outbox resource](../../../marshall/lib/marshall/accounts/auth_email.ex),
[enqueue coordination](../../../marshall/lib/marshall/accounts/auth_emails.ex),
[delivery change](../../../marshall/lib/marshall/accounts/deliver_auth_email.ex),
[SMTP configuration](../../../marshall/lib/marshall/mailer/config.ex) and
[log filter](../../../marshall/lib/marshall/mailer/log_filter.ex) implement the
path. [Database tests](../../../marshall/test/marshall/accounts/auth_emails_test.exs),
[real SMTP tests](../../../marshall/test/marshall/mailer/smtp_test.exs) and
[three-node checks](../../../marshall/test/marshall/compute/distributed_admission_test.exs)
provide implementation evidence. Final Marshall precommit passed 186 cases
(17 properties, 169 tests), six browser-state checks and Dialyzer with the existing
single upstream exclusion. Schema checks, production asset/release construction,
release startup with verified SMTP configuration and rejection of missing SMTP
credentials passed. The [review](../reviews/2026-09-16-production-email.md)
records scope, the corrected three-node race and operational gaps.

## Open questions

The deployment operator must supply a relay and credentials, sender-domain DNS
and appropriate quota/abuse limits. Real provider acceptance and inbox placement
are unverified; local fixtures do not establish either. Enrollment and drain now
have implementation evidence under ADRs 0025/0026. Release deployment has local
acceptance under ADR-0027; production infrastructure and fleet acceptance remain
separate platform obligations.

## Related decisions

[ADR-0008](0008-identity-sharing-and-terminal.md),
[ADR-0009](0009-assurance-and-testing.md),
[ADR-0012](0012-provisioner-control-transport.md),
[ADR-0027](0027-production-release-deployment.md).

Interface references: [Swoosh SMTP](https://hexdocs.pm/swoosh/Swoosh.Adapters.SMTP.html),
[gen_smtp](https://hexdocs.pm/gen_smtp/readme.html),
[AshAuthentication sender behavior](https://hexdocs.pm/ash_authentication/AshAuthentication.Sender.html).
