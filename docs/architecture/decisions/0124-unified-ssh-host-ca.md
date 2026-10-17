# ADR-0124: One SSH host CA for gateways and guests

- ID: ADR-0124
- Date: 2026-09-25
- Status: accepted
- Implementation: implemented
- Components: Marshall, Porsche, Audi, Lilly, Ziggy, protocol, Lyra, NixOS, Ubuntu
- Supersedes: ADR-0118
- Superseded by: none

## Context

The installer pins Porsche but the final SSH connection still prompts for each
guest's host key. Copying one private host key into guests would let guest root
impersonate every gateway and VM. The user selected one SSH CA, native host
certificates everywhere, long lifetimes, new guest disks, a coordinated release,
and machine/property/unit verification before merging and deployment.

## Decision

A dedicated Ed25519 SSH CA authenticates Porsche, Audi and guest host identities.
Its private key has a recovery-only SOPS copy and a Marshall runtime bundle;
physical host SSH keys remain only decryption identities. The operational CA
retirement is twenty years and host certificates last ten years, capped at that
retirement and backdated five minutes. OpenSSH has neither intermediate CA chains
nor an expiry field on a CA key. The SSH authority is separate from TLS CAs.
Inception is an independent deployment: it generates a separate persistent CA
under its existing instance-identity custody and never receives the parent's
private signer. Its inner gateways use the same renewal implementation.

Marshall owns issuance through typed Ash actions and durable certificate
states: pending, issued, failed and superseded. Service/VM authority and an
advisory subject lock remain held through bounded local signing and commit.
Matching retries reuse an issued generation; signer failures retry the same failed
generation through an explicit pending transition until its renewal window. Principals come only from server
configuration and authoritative VM endpoints. SSH certificates grant no user
login or Cedar authority.
Subjects are stable service/VM identities across credential rotations and boots.
New keys supersede prior generations; bounded AshOban batches remove public
history seven days after supersession or certificate expiry. This is retention,
not certificate revocation.

Porsche certificates identify the management hostname. Audi certificates use a
full SHA256 public-key digest encoded as lowercase unpadded base32 in
`audi-DIGEST.ssh.MANAGEMENT_HOST`. The proxy derives this exact alias from the
current HTTPS route-key lookup, so certificate trust preserves current routing.
Guest certificates identify exactly the authoritative VM hostname. Each guest
boot generates its private key in `/run`; clones never inherit private keys.
The private host-certificate POST has its own bootstrap purpose and reuses
Lilly's physically verified boot authority without broadening other routes.

A maintained opt-in OTP patch adds native Ed25519 host certificate serving;
user-key parsing and default OTP algorithms retain their separate semantics.
A shared Rust installer validates and atomically installs certificates for both
guest distributions and the gateway systemd units. Guest networking follows
platform trust; certificate and roster installation precede sshd/readiness.
Renewal begins within thirty days of expiry. An invalid result never replaces
an installed certificate. New connections require valid certificates.

The public installer and direct client setup share one Rust trust installer.
Verified HTTPS publishes deployment-bound public policy. Scoped cert-authority
entries authenticate all three connections with strict checking and no unsigned
fallback in the client. Managed CA changes and revocation require explicit
reconciliation. Existing VM disks are not migrated and mixed-version support is
not required for this development release.

## Alternatives

Shared guest/gateway private keys expose platform identity to guest owners.
Per-host prompt acceptance does not meet the installation experience. A client
certificate-to-key adapter was declined in favor of native certificates; replacing
the gateways' complete transports would unnecessarily replace existing channels
and authority machinery.

## Consequences

Marshall signing availability gates initial SSH readiness. Gateways retry initial
acquisition every five seconds without a terminal start limit; the local fleet
API relay socket is activated with dependent gateways. Existing valid
certificates permit renewal retries, but expiry fails closed. The signer is an
online central authority rather than the offline root/intermediate arrangement
used for TLS. CA rotation requires updating client trust explicitly. Retained old
guest disks keep their old behavior and are outside this migration.

## Invariants and verification

- No CA private key reaches gateways, guests, images, build inputs or logs.
- Principals and signing authority cannot be selected by untrusted callers.
- Replayed, stale and cross-VM bootstrap requests cannot obtain certificates.
- OpenSSH validates CA signatures, hostname, validity and key possession on all
  three SSH connections; raw user-key possession and Cedar grants remain required.
- Native NixOS and Ubuntu tests must run the public installer without seeded guest
  pins, then reconnect after restart, cloning and relocation.

## Implementation evidence

The [certificate codec](../../../protocol/lib/overalls_protocol/ssh_host_certificate.ex),
[issuer](../../../marshall/lib/marshall/ssh/host_certificates.ex),
[resource](../../../marshall/lib/marshall/ssh/host_certificate.ex),
[OTP patch](../../../nix/patches/otp-ssh-host-certificates.patch),
[shared installer](../../../lyra/src/bin/overalls-host-certificate.rs), and
[client trust](../../../lyra/src/trust.rs) implement the initial path.
[Property tests](../../../protocol/test/ssh_host_certificate_test.exs) verify
cryptographic binding and parsing. Both native guest installer journeys, the Audi
fleet, the focused installer and OTP transport matrix passed, along with the
application gates. The complete focused Porsche lifecycle and resize checks also
passed. Both physical updaters reported the initial release healthy after gateway
startup recovery. The actual three-argument installer opened fresh live NixOS and
Ubuntu guest shells without authenticity prompts. Native regression tests verify
automatic gateway recovery beyond the former startup limit; see the
[review](../reviews/2026-09-25-unified-ssh-host-ca.md).

The extended focused installer journey additionally records: revoked-account-key
refusal after trust installation with the trust-before-proof asymmetry pinned
(`lyra/src/ssh_config.rs` installs trust before `resolve_account` runs), full
client-state retention and owner-scoped re-registration recovery; four-way digest
agreement for the installed binary (recomputed bytes, checksum endpoint, manifest
entry and a fresh download) and four-target checksum/manifest agreement;
appended-byte artifact upgrade preservation replacing the executable only after
configuration success; served-digest-mismatch refusal before replacement with the
stderr-only distinction pinned; and PATH-shimmed unsupported-platform refusal,
Darwin artifact selection and the macOS shasum checksum fallback. The fleet user
SSH journey records one revoke→probe→re-register cycle closing guest SSH and
Porsche account proof on both NixOS and Ubuntu; see the
[installer revocation review](../reviews/2026-09-26-installer-revocation.md).

## Open questions

None for the authorized scope. Native macOS and full nested Inception acceptance
remain outside the recorded Linux deployment evidence.

## Related decisions

[ADR-0118](0118-installer-management-ssh-trust.md) is replaced.
[ADR-0046](0046-porsche-ssh-management.md) retains management authority.
[ADR-0110](0110-cedar-guest-ssh-accounts.md),
[ADR-0115](0115-ssh-roster-boot-authority.md), and
[ADR-0117](0117-personal-terminal-machine-workspace.md) retain account/boot rules
except the explicit new host-certificate bootstrap purpose.
[ADR-0113](0113-guest-trust-at-boot.md) retains platform TLS root delivery.
