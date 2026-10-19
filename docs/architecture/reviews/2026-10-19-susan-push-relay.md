# Susan push relay architecture review

Susan ([ADR-0224](../decisions/0224-susan-push-relay.md)) is a new, separately
deployed Elixir/OTP service at the fixed origin `https://notifications.overalls.dev`.
It turns content-free pokes from self-hosted Marshalls (ADR-0225) into APNs and
FCM deliveries, using the store app's publisher credentials, which no Marshall
holds. It has its own Ash domains (`Susan.Relay`, `Susan.Audit`), its own
PostgreSQL, a NixOS module (`services.susan`), the OCI image `image-susan`, and
the `Susan.Events` catalog.

Boundaries reviewed:

- **Identity and authorization.** Authority comes only from a push key that Susan
  issued and can open, combined with a valid Ed25519 install signature. There are
  no accounts. Install identities are trust-on-first-use and move through
  `unknown → trusted → rate_limited → blocked`. Unauthenticated requests write
  nothing, and a 404 has the same body as a 400.
- **Protocol.** The poke body is `OverallsProtocol.SusanPoke`: eight members in
  canonical key order, signed over `"overalls-susan-poke-v1" || 0x00 || body`.
  - The Susan and Marshall workstreams first disagreed on what the signature
    covers: Susan verified the bare body, Marshall signed the domain-separated
    message.
  - At integration, Susan adopted the protocol module. `Susan.Poke.Request`
    decodes through `SusanPoke.decode/1` and verifies over
    `SusanPoke.signed_message/1`.
  - `protocol/test/fixtures/susan_poke_request.json` now carries both sides'
    vectors. Susan's section is `relay`, with a canonical 22-character collapse
    id, re-signed.
- **Persistence.**
  - The audit log is append-only and hash-chained. The database refuses UPDATE
    and TRUNCATE, and permits DELETE only to the audited 90-day prune.
  - Delivery-id dedupe is durable.
  - The negative cache keeps only keyed digests of unregistered provider tokens.
  - Neither the database nor the logs hold IP addresses, tokens, push keys,
    ciphertext or routes.
- **Capacity.** Token buckets limit per key, install, source digest and globally.
  They live in node memory, so several instances would each hold a budget.
- **Recovery.** Provider 5xx gets one in-request retry, then 503 with
  `Retry-After`. Marshall owns the longer retries. A provider 410 sets the
  negative cache, and Marshall invalidates the device.
- **Secrets.** `overallsSecrets.bundles.susan` is read from
  `$CREDENTIALS_DIRECTORY` with mode, owner and no-symlink checks. Keyring ids
  allow rotation.
- **Placement.** Susan runs on no fleet host. Hosting, registry and TLS placement
  remain open in ADR-0224.

Decision status: ADR-0224 stays `accepted`; implementation `partial`.

## Validation

Recorded in the Susan workstream before the signature reconciliation:

- `mix precommit` in `susan/`: 65 tests and 15/15 Covenant obligations passed,
  with Dialyzer reporting 0 errors.
- Machine tests: susan-service 13/13, susan-secrets 7/7, susan-image 5/5.
- The `image-susan` package and the `susan-release` check both built.

Those runs predate the change to the verifier and the fixture, so they are not
evidence for the integrated tree. The
[Mila M6 review](2026-10-19-mila-m6.md) remains the record for subsequent
integrated results, including the new `push-relay`
Marshall→Susan→provider machine test; that review currently records no
completed Phase 2 verification pass.

## Gaps

- No real APNs or FCM acceptance: the provider origins are local fakes behind a
  private CA.
- `secrets/overalls-susan.enc.json` does not exist yet, because no host recipient
  exists.
- Rate limits, the replay window and the source salt are per node and reset on
  restart.
- Rotating the keyring resets the token-digest negative cache.
- The provider client disables TLS 1.3 middlebox compatibility mode. This is
  unverified against real APNs and FCM.
