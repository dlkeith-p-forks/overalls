# ADR-0040: Host-local synchronous SMTP relay

- ID: ADR-0040
- Date: 2026-09-17
- Status: accepted
- Implementation: implemented
- Components: Marshall Accounts, NixOS, SMTP relay, SecretSpec, systemd
- Supersedes: ADR-0024
- Superseded by: none

## Context

The user approved an optional SMTP relay on each Marshall host, based on Loom's
Grafana smtprelay package, with Oban retaining the queue. They selected trusted
loopback submission and focused patches to the pinned relay. They explicitly
required using the existing secret delivery workflow. This changes ADR-0024's
requirement for authentication and verified TLS on Marshall's immediate SMTP hop.

## Decision

Carry forward all ADR-0024 decisions about encrypted outbox storage, atomic job
enqueue, recipient cooldown, row-locked delivery, token validation/expiry,
Message-ID stability, payload deletion, diagnostics and uncertain SMTP outcomes.
Direct authenticated, verified-TLS SMTP remains the default.

An opt-in `services.marshall.smtpRelay` deploys one unprivileged
`overalls-smtprelay.service` per host, shared by local Marshall instances. Only
explicit `MARSHALL_MAIL_TRANSPORT=local_relay` with literal `127.0.0.1` permits
unauthenticated plaintext submission. This trusts host-local processes; it is not
an authentication boundary between mutually untrusted host users. Neither SMTP
nor metrics binds externally or opens firewall ports. Guests cannot reach the
host's loopback listener through their routed interfaces.

The relay uses Grafana smtprelay v2.2.3 with fixed source/dependency hashes and
maintained patches. Upstream delivery requires PLAIN or LOGIN authentication and
verified TLS 1.2 or later, either implicit or mandatory STARTTLS. No plaintext
fallback, disk queue or internal retry is allowed. Upstream DNS/connection setup
is bounded to three seconds; the entire forwarding attempt is bounded to eight
seconds and service cancellation closes its upstream socket. Marshall retains
its ten-second deadline. A success response requires upstream DATA acceptance.
Disconnects and lost acknowledgements can still produce duplicates; acceptance
is not inbox delivery. The relay's independent upstream deadline also bounds an
attempt when a submitting process disappears.

Generic SMTP, SES and Resend presets choose configuration defaults, not separate
APIs. The operator supplies sender verification, provider access and quotas.
Only the selected sender is accepted. Metrics contain aggregate outcomes; provider
response text, mail content and credentials are excluded from diagnostics.
Tracing and protocol/header logging are disabled by the managed service.

Use a separate `services.overallsSecrets.bundles.smtp` selection under ADR-0032.
The existing root preparation service resolves SecretSpec's SOPS provider with
its temporary SSH-derived age identity and atomically publishes raw username and
password outputs. Systemd delivers only those credentials to the relay. Provider
credentials do not belong in Marshall's environment when relay mode is enabled.
No new resolver, persistent private identity or plaintext build input is added.
The module's local transport settings override shared environment settings in
both serving and migration launchers.

The updater reuses its descriptor-bound staging and systemd consumer discovery.
Include the relay among consumers and health units, without treating it as a
Marshall process for shared authority comparison. `overalls-smtprelay` deliberately
does not match the updater's `marshall-*` process selection. Upstream reachability
is not a web readiness requirement; pending mail remains in the shared outbox.

## Alternatives

A queued MTA would move accepted mail into host-local plaintext storage and move
retry authority away from the encrypted shared outbox. Provider HTTP APIs add
vendor-specific application integration. Authenticated local TLS would require
another certificate/credential lifecycle; the user selected trusted loopback.
Unpatched v2.2.3 lacks explicit implicit-TLS outbound support and a total outbound
deadline, and logs provider response text.

## Consequences

Operators can change providers and rotate credentials independently of Marshall's
application secrets. SMTP-only manual rotation stops the relay, prepares its
bundle, starts it and verifies delivery. Automatic updates retain their existing
broader consumer activation workflow. No database migration is required.

Maintaining the upstream patch and its tests is an explicit dependency cost.
Local host users are trusted to submit from the configured sender. Host compromise
remains outside this boundary. Provider acceptance and inbox placement require
separate deployment verification.

## Invariants and verification

- Remote TLS/authentication cannot fall back to plaintext; wrong trust, hostname
  and authentication fail before message acceptance.
- Upstream rejection, timeout or relay loss leaves pending payloads encrypted;
  retry preserves Message-ID and clears ciphertext only after acceptance.
- A delayed upstream acknowledgement cannot produce early local success.
- Secrets use actual SOPS/SecretSpec preparation, private systemd delivery and
  controlled rotation; missing values preserve the previous complete bundle.
- Marshall receives no provider credentials or host decryption identity.
- Serving and migration launchers use identical local transport settings.

## Implementation evidence

The [relay package and patches](../../../nix/packages/smtprelay/default.nix)
implement verified bounded forwarding and package tests. The
[NixOS module](../../../nix/modules/smtp-relay/default.nix) implements service and
credential boundaries, and [mail configuration](../../../marshall/lib/marshall/mailer/config.ex)
implements explicit loopback mode. The [machine suite](../../../nix/tests/machines/smtp-relay/default.nix)
uses the real packages, local upstream and existing secret module. Verification
results and limitations are recorded in the [review](../reviews/2026-09-17-smtp-relay.md).

The [post-ACK and sender-rotation review](../reviews/2026-10-05-auth-mail-post-ack-runtime.md)
records actual independent-pool SMTP acknowledgment/commit loss and reproduces
the old sender-derived Message-ID changing after configuration rotation. The
corrected implementation derives identity from the delivery UUID and fixed
overalls.invalid namespace while From uses current sender configuration. This
implements the carried-forward stability requirement without new persistent
state. The first repaired selection passed22.9seconds; current combined mail
execution passed19checks (9properties,10tests),seed0,266.0seconds. Pre-integration forced Dialyzer passed54.24seconds with zero errors/skips;
full integrated gates remain pending. Previously emitted identifiers cannot be reconstructed for an uncertain
delivery spanning the format transition; provider deduplication and inbox/native
acceptance remain separate. Decision rationale and implementation status are preserved; new evidence
retains its bounded scope.

## Open questions

The [post-DATA timeout properties](../../../marshall/test/marshall/mailer/smtp_test.exs)
extend direct verified-TLS delivery evidence with generated uncertain receipt,
socket retirement and stable retry payload histories. Their
[review](../reviews/2026-10-03-mail-smtp-timeout-histories.md) separates SQL-sandbox
and loopback transport evidence from relay deployment and inbox placement;
postmerge focused execution passed eight checks in 114.6 seconds.

Actual encrypted provider credentials, sender-domain DNS and inbox acceptance
remain deployment inputs. No production deployment is performed by this change.

The [committed worker properties](../../../marshall/test/marshall/accounts/auth_email_distributed_property_test.exs)
extend verification to independent database pools, actual lock contention and
post-DATA abrupt peer death. The [review](../reviews/2026-10-03-mail-committed-worker-histories.md)
records final focused runtime63.7s, passing forced Dialyzer74.84s and passing full precommit1,432checks,seed612345,1525.2s, with forced Dialyzer50.9s;
direct Ash calls do not establish duplicate Oban scheduling or inbox delivery.

The [waiting-token properties](../../../marshall/test/marshall/accounts/auth_email_waiting_authority_property_test.exs)
exercise current stored authority after actual outbox lock waiting. The
[review](../reviews/2026-10-03-mail-waiting-token-authority.md) records a combined
four-property passing run in 80.8 seconds. Exact token removal/backdated expiry
is bounded committed evidence; complete sign-in consumption and native/hosted
timing remain separate.

## Related decisions

[ADR-0024](0024-durable-magic-link-email.md),
[ADR-0032](0032-ssh-derived-age-identities.md),
[ADR-0033](0033-nixos-machine-verification.md),
[ADR-0036](0036-automatic-host-updates.md).
