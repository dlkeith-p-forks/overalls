# Production sign-in email

Marshall queues magic links in an encrypted Ash outbox and sends them through
AshOban's `mail` queue. Development uses Swoosh's local mailbox; production
requires authenticated, verified TLS upstream; an optional Nix-managed relay
provides explicit host-local submission as described below. See
[ADR-0024](architecture/decisions/0024-durable-magic-link-email.md).
Production releases additionally require the database TLS, replica/connection
budget and listener configuration in the [deployment guide](deployment.md).

## Configuration

Provide these through the deployment's protected environment/secret store:

| Variable | Meaning |
| --- | --- |
| `MARSHALL_SMTP_HOST` | Relay hostname matching its certificate |
| `MARSHALL_SMTP_USERNAME` | Relay authentication username |
| `MARSHALL_SMTP_PASSWORD` | Relay password; keep it out of command arguments and logs |
| `MARSHALL_MAIL_FROM` | Verified sender address, such as `noreply@your-domain.example` |
| `PHX_HOST` | Public Marshall hostname used in HTTPS sign-in links |
| `MARSHALL_SMTP_TLS` | `implicit` (default) or `starttls`; plaintext is unsupported |
| `MARSHALL_SMTP_PORT` | Defaults to 465 for implicit TLS and 587 for STARTTLS |
| `MARSHALL_SMTP_CA_CERTFILE` | Optional absolute private-CA bundle path; otherwise bundled public roots |

The existing `DATABASE_URL`, `SECRET_KEY_BASE`, `TOKEN_SIGNING_SECRET` and
`MARSHALL_CLOAK_KEYS` remain required. All Marshall nodes must share the signing
and encryption keys and the public endpoint/sender configuration. Retain old
Cloak key tags while encrypted records still need them. Do not deploy development
keys, test certificates or the example domain.

Production fails startup when SMTP configuration is missing or invalid. Apply
the outbox migration before starting the new release. Configure the relay's
sender-domain verification and DNS requirements, and verify delivery to a
controlled mailbox before exposing the deployment publicly.

## Delivery behavior

The public authentication response remains generic. Accepted work is durable
before SMTP is attempted. Jobs contain an outbox ID; recipient addresses and
usable links are encrypted in the outbox. A shared one-minute recipient cooldown
suppresses duplicate requests, including requests reaching different nodes.
The address type accepts bounded ASCII dot-atom mailboxes; quoted and
internationalized mailbox syntax is currently unsupported.

Each attempt checks that the token is still stored, valid and unexpired. A
successful attempt clears the encrypted payload; consumed or expired links are
also cleared. Cleanup jobs delete expired outbox rows. Keep the `mail` queue and
its AshOban schedules running. Its concurrency is two per Marshall instance.

SMTP retries reuse the same token and Message-ID. Relay acceptance followed by a
lost response or database rollback can produce duplicate emails. The link can
still sign in only once. Relay acceptance does not guarantee inbox placement,
and delivery delays can leave a recipient with an expired link; requesting a
fresh link is the recovery path.

Connect timeout is three seconds and the total attempt deadline is ten seconds.
The job holds its outbox row during delivery. Budget database-pool and provider
capacity for the combined mail concurrency across all control-plane instances.
The cooldown limits messages to one recipient; it does not bound requests or
delivery across arbitrary addresses. Set deployment abuse and provider quota
controls before public rollout.

## Diagnostics and TLS ingress

Structured `mail_delivery_attempt` events retain a delivery ID and one of
`smtp_accepted`, `expired`, or `failed`. They describe the attempt; the persisted
outbox status establishes whether its database transaction committed. Job failures
use a fixed error without provider response bodies, links or SMTP credentials.
Authentication HTTP/LiveView diagnostics redact token-bearing request paths and
state. HTTPS redirect logging is disabled because it runs before request privacy
tagging. External proxy/access logs must also omit magic-link URL tokens.

Use direct TLS or a proxy that connects to Marshall using TLS. Arbitrary
`X-Forwarded-Proto` no longer bypasses the production HTTPS redirect. The current
configuration does not define a trusted proxy network.

Local integration tests exercise real implicit TLS and STARTTLS sockets, wrong
CA/hostname rejection, downgrade refusal, delayed peers, sanitized failures and
single-use login through the delivered message. Real provider credentials and
inbox placement remain deployment verification, not properties established by
those fixtures.

## Optional host-local relay

[ADR-0040](architecture/decisions/0040-host-local-smtp-relay.md) adds opt-in
`services.marshall.smtpRelay` for NixOS. All local Marshall instances submit to
`127.0.0.1:2525`; Grafana smtprelay forwards synchronously through authenticated,
verified TLS. The relay has no disk queue. Oban retains encrypted pending mail
until upstream acceptance. Relay/provider failure is retried through the existing
outbox, with the same expiry and duplicate-delivery caveats as direct SMTP.

The selected local hop trusts processes on the host and uses neither TLS nor
SMTP authentication. It requires explicit `MARSHALL_MAIL_TRANSPORT=local_relay`
and literal `MARSHALL_SMTP_HOST=127.0.0.1`; hostnames and other addresses are
rejected. The default transport remains `smtp`, requiring verified remote TLS
and credentials. Nix owns local transport, sender and port in both serving and
migration commands, overriding conflicting shared environment entries.

See the [NixOS secret and relay configuration](nixos.md#host-local-smtp-relay).
The patched relay bounds upstream connection setup to three seconds and each
complete forwarding attempt to eight seconds. Marshall's ten-second total
attempt limit still applies. A lost reply after provider acceptance remains an
uncertain outcome; no exactly-once or inbox-placement guarantee is added.
