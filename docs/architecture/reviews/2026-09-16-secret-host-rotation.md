# SSH host identity rotation and replacement recovery

Date: 2026-09-16

## Scope and architecture impact

This closes additional ADR-0032/0033 verification obligations within the authorized
NixOS plan. Accepted decisions and production modules are unchanged. The
[secret-custody suite](../../../nix/verification/tests/machines/secret-custody/default.nix) still uses actual
SecretSpec/SOPS, runtime-generated synthetic identities and the source-built
Marshall release. No production key or deployed host is changed.

## Changes and boundaries

The [fixture helper](../../../nix/verification/tests/machines/secret-custody/fixture.py) decrypts the existing
document using an explicitly selected synthetic operator identity, with SSH
fallback disabled. It re-encrypts that recovered payload rather than regenerating
values from the fixture's plaintext input.

- Host-key rotation stages an additional SSH-derived age recipient and verifies
  decryption with both host identities and the operator before installation.
- The fixture atomically replaces the private/public host-key files, restarts
  SSH and prepares the real Marshall bundle with the new host identity. Marshall
  must return to readiness with the expected application credential.
- A fresh encrypted document then removes the retired host recipient. An explicit
  old-identity-only decryption attempt must fail; new-host and operator recovery
  must preserve the payload. Another controlled preparation/restart proves the
  live application still receives the selected values.
- Replacement uses the second machine's independently generated public key.
  Only that public key and encrypted documents cross machine boundaries. The
  formerly unauthorized machine must prepare the replacement bundle through the
  actual module, match selected values to its locally decrypted document, remove
  temporary verification identities and keep private values out of its journal.

These tests establish ciphertext custody and application delivery. Removing an
age recipient cannot revoke application credentials already learned by an old
host. Coordinated database, signing and Cloak-key rotation has separate passing
evidence in the [fleet rotation review](2026-09-16-fleet-credential-rotation.md).
The replacement case prepares the application bundle; it does not migrate the
old machine's database, start its application on a different database or transfer
Lilly's durable host ownership.

## Validation

The complete expanded machine suite passed in **135.90 seconds**, using
`qznzhiy5msbanzza00ci46mpr54gc6rd-vm-test-run-overalls-secret-custody.drv`.
The host-recipient rotation case passed in 22.75 seconds and separately keyed
replacement recovery in 1.42 seconds. Earlier wrong-host, missing-value,
permission, interrupted-publication, application-credential rotation and NixOS
generation-switch regressions also passed in that same run. Framework type/lint
and structural ADR/contract checks pass. Previous custody results remain recorded
in the [release/role review](2026-09-16-nixos-releases-and-roles.md).

## Remaining obligations

Supply and authenticate actual deployment recipients and encrypted documents.
Verify the exact existing reference host and perform the reviewed rollout with
actual deployment credentials. Reusable-image identity uniqueness, reboot persistence and mirrored-disk
survival have separate passing evidence in the
[installation review](2026-09-16-mirrored-installation.md).
