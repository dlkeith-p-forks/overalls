# ADR-0224: Susan, the push relay at notifications.overalls.dev

- ID: ADR-0224
- Date: 2026-10-18
- Status: accepted
- Implementation: planned
- Components: Susan, Marshall, Mila
- Supersedes: none
- Superseded by: none

## Context

APNs and FCM accept pushes only with the store app publisher's credentials, so
self-hosted Marshalls cannot notify the store-distributed Mila directly. The
relay must not learn what the agent is asking or whom it is asking, and it is
operated independently of every Marshall.

## Decision

1. Susan is a new Elixir/OTP service (`susan/`) with its own Ash domain and
   PostgreSQL, deployed independently at the fixed origin
   `https://notifications.overalls.dev`, packaged as a Nix-built OCI image
   (non-root, read-only root, no shell). Hosting placement is left open.
2. `POST /api/push/v1/keys` (from Mila) issues an AEAD-sealed push key binding
   the provider token, deployment and issue time, with key-id rotation and a
   90-day expiry. `POST /api/push/v1/poke` (from Marshall) accepts at most
   1 KiB: push key, deployment, ciphertext, kind, collapse and delivery ids,
   nonce and issue time, signed by the Marshall install identity.
3. Pokes are content-free to Susan: the payload is end-to-end encrypted to the
   device's X25519 key; Susan sees only ciphertext, push key and collapse id.
   Titles come from fixed kind-to-localization keys.
4. Anti-abuse: issued keys only, deployment binding, a ±5-minute nonce window
   plus delivery-id dedupe, token buckets per key, install, source IP and
   globally, a key-id deny-list and a negative cache for unregistered tokens.
5. Privacy: no IP logging (at most a daily-salted HMAC); no tokens, keys,
   ciphertext or routes in logs or the database; no third parties beyond
   APNs/FCM. An append-only, hash-chained audit trail is kept for 90 days.
6. Secrets come from `secrets/overalls-susan.enc.json` through the existing
   SOPS `overallsSecrets` bundles.

Authorization: the approved Mila plan (2026-10-18).

## Alternatives

- **Each operator registers their own push credentials.** Rejected: the store
  app has one bundle identity; operators cannot sign for it.
- **UnifiedPush.** Deferred: useful for Android without Google services, but
  not v1.
- **Plaintext pokes.** Rejected: the relay would learn agent activity.

## Consequences

Overalls operates one shared service whose outage only delays notifications;
Mila's `watch` stream still works while the app is open.

## Invariants and verification

Planned: `susan-service`, `susan-secrets` and `susan-image` machine tests;
retries never double-notify; no IP or token bytes in the database dump or
journal.

## Implementation evidence

No implementation yet.

## Open questions

- Registry, host and TLS placement for the image.
- Android delivery without Google services.

## Related decisions

[ADR-0220](0220-mila-client-over-porsche-ssh.md),
[ADR-0225](0225-marshall-notifications-domain.md).
