# ADR-0109: Fleet Brady CA and host signers

- ID: ADR-0109
- Date: 2026-09-23
- Status: superseded
- Implementation: partial
- Components: Brady, NixOS fleet hosts, NixOS guest, Ubuntu guest, secrets
- Supersedes: none
- Superseded by: ADR-0113

## Context

ADR-0069 accepts Brady TLS interception but leaves its signing CA and guest
trust as an external assumption. Production hosts need signer credentials,
while relocated and newly provisioned guests must verify leaves from any
current or future Lilly host without rebuilding an image for each new signer.

## Decision

One P-256 fleet root certificate is a public trust anchor on every fleet host
and in the NixOS and Ubuntu guest images. It expires after twenty years. Its
private key is encrypted for recovery operators only and never delivered to a
host, image or Nix store. Each Brady host receives a distinct root-signed,
path-length-zero P-256 intermediate valid for ten years. Its private key and
certificate are encrypted for that host and recovery operators, then delivered
by SecretSpec/SOPS and systemd credentials only to Brady.

Brady sends the signer certificate with every generated leaf. Trusting the
fleet root therefore validates all current and future host signers and makes
VM relocation independent of signer distribution. A host lacking a valid
signer fails closed. The fleet auto updater treats Brady as a health unit.

## Alternatives

A shared signing private key on every host expands compromise across the fleet.
Installing each intermediate as a guest trust anchor would require a new image
for every host addition or signer rotation. Reusing the unrelated Audi private
service CA would combine two distinct signing authorities.

## Consequences

Existing writable guest disks retain their old trust store. The user accepts
intercepted HTTPS failure until those VMs are replaced and permits deletion
where needed. Root rotation requires overlapping trust and new images.

## Invariants and verification

- The root key has only recovery recipients; a host bundle has only its own
  signer key, and no private key is a Nix build input.
- Both signer certificates verify against the one root, differ in public key,
  and can validate a Brady-issued leaf after relocation.
- Native NixOS and Ubuntu guest tests verify host-specific chains and trust;
  secret-custody tests verify recipient isolation and content-free logs.
- Activation is accepted only after both hosts' updater states are healthy and
  Brady is active with its selected secret bundle.

## Implementation evidence

The [public root](../../../secrets/brady-root.pem),
[secret inventory](../../../nix/policy/secrets/secret-documents.nix),
[host configurations](../../../fleet/hosts/overalls/services.nix),
[shared guest inputs](../../../flake.nix) and
[Brady TLS adapter](../../../brady/lib/brady/tls/certificates.ex) establish the
initial custody and chain path. The encrypted recovery and two host documents
hold the generated key material. Native cross-host guest and live deployment
verification remain outstanding.

## Open questions

None for this release.

## Related decisions

[ADR-0113](0113-guest-trust-at-boot.md) replaces image-baked guest trust with
boot-bound host delivery while preserving the Brady key hierarchy and custody.

[ADR-0069](0069-brady-egress-cache.md) owns interception and fail-closed
behavior; [ADR-0068](0068-nix-built-ubuntu-guests.md) owns Ubuntu image trust
customization; [ADR-0044](0044-recovery-only-secret-documents.md) governs
recovery-only custody.
