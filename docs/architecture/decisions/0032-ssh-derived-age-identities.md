# ADR-0032: SSH-derived age identities

- ID: ADR-0032
- Date: 2026-09-16
- Status: superseded
- Implementation: partial
- Components: NixOS secrets, SecretSpec, SOPS, host administration, Marshall, Lilly
- Supersedes: none
- Superseded by: ADR-0041

## Context

[ADR-0041](0041-declarative-fleet-users.md) replaces the single-operator access
policy and carries forward this record's runtime secret-custody requirements.
The decisions and evidence below describe the historical implementation.

The user selected SecretSpec handling SOPS directly, host SSH server keys as the
source of age identities, and ghuntley's key for administration and recovery.
The public key was supplied explicitly, so deployment must not depend on a live
GitHub key lookup. Existing private credential-file readers and manual enrollment
remain the application boundary; they do not implement secret-store custody.

## Decision

Use pinned SecretSpec with its SOPS provider, rather than sops-nix, to resolve
deployment secrets. Commit declarations and encrypted documents only; never put
plaintext secrets or private keys into Nix expressions, evaluation results,
derivations, images, process arguments or diagnostics. Select the provider
explicitly so a developer's personal fallback configuration cannot change
production secret resolution.

Use the persistent `/etc/ssh/ssh_host_ed25519_key` as the host identity source.
Preserve it across rebuilds and upgrades. New installations generate unique keys;
do not bake a private SSH or age identity into a reusable image. Convert public
and private Ed25519 keys with the same pinned `ssh-to-age` implementation. Encrypt
to the converted age recipients consistently; do not mix native SSH-recipient
encoding with converted `age1` recipients.

Pin this user-supplied public key for administrative SSH access and as the source
of ghuntley's converted recovery recipient:

```text
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFiX7qvQS3QjzL8y31KxMPn5EOyufjgz2YuRD3GNWcuR
```

Its SSH SHA256 fingerprint is
`SHA256:Z1i0g7y863TWFc0TDWoafveEFuFZ+oXS48sjBiva1xg`. Refreshing the pin is an
explicit reviewed configuration change. No GitHub fetch occurs at build or boot.
The operator's private key remains in operator custody, never on deployed hosts.

Encrypt each SOPS document to its intended host recipient(s) and the operator
recovery recipient. Separate documents by access need; a host should not receive
all fleet secrets merely because it can decrypt its own configuration. Shared
Marshall signing/Cloak/database values must agree across the selected replicas;
Lilly enrollment credentials remain host-bound.

A privileged preparation service starts after the persistent SSH identity is
available. It derives an age identity in private runtime storage, resolves the
required SecretSpec/SOPS values, validates them, and publishes the service-specific
credentials atomically. Use private `/run` storage and systemd credentials or
protected runtime files compatible with existing readers. Keep only the required
material for its required lifetime; errors must leave services without usable
new credentials rather than publishing partial configuration.

Marshall receives its application credentials, not the SSH private key, derived
age identity or unrelated service secrets. Lilly remains a trusted root agent;
this design does not claim to hide host identities from root. No interactive
prompt or plaintext fallback is allowed during unattended startup. Missing or
undecryptable required secrets prevent dependent services from starting and
produce sanitized diagnostics. Daemon restart still preserves running guests.

For a new host, obtain and authenticate its public SSH host key, derive its
recipient, update the encrypted document, and deliver it before starting the
applications. Installation can reach SSH without having application secrets.
An existing host retains its identity; replacement/bootstrap must not silently
reuse a cloned private key. Rotation adds and verifies the new recipient and
usable encrypted document before retiring old material. Preserve a tested
operator recovery path throughout rotation.

This resolves the deployment custody question in
[ADR-0025](0025-protected-provisioner-enrollment.md), without replacing its
host-disabled enrollment, file verification, credential expiry/revocation or
intentional restart requirements. It adds no public enrollment API.

## Alternatives

sops-nix would add another secret resolver contrary to the selected SecretSpec
workflow. Independent persistent age keys introduce another host identity to
bootstrap and preserve. Live GitHub key fetching makes access depend on remote
availability and unreviewed key changes. Giving Marshall a host decryption key
would expand its access beyond application credentials.

## Consequences

SSH host identity and encrypted-secret recovery are coupled: loss of the host key
requires recovery/re-encryption; its compromise affects documents encrypted to
that identity. Revoking a recipient does not erase already decrypted secrets;
rotate affected application credentials too. Runtime delivery must retain the
strict owner/mode/link-count checks used by current private-file readers.

## Invariants and verification

- Boot with runtime-generated synthetic host keys and a synthetic recovery key;
  test actual SecretSpec/SOPS resolution and recipient conversion agreement.
- Verify wrong-host/missing-secret rejection, service ordering and permissions,
  and that Marshall cannot read SSH/age private material.
- Inspect image/store contents and diagnostics for fixture plaintext leakage.
- Exercise independent recovery, host rebuild identity persistence, new-host
  uniqueness, interrupted publication and key/credential rotation.
- Never use ghuntley's private key or real deployment secrets in tests.

## Implementation evidence

[ADR-0040](0040-host-local-smtp-relay.md) adds a separate SMTP bundle consumer
and [relay machine suite](../../../nix/verification/tests/machines/smtp-relay/default.nix).
Its [review](../reviews/2026-09-17-smtp-relay.md) tracks verification; existing
secret custody and machine acceptance boundaries remain unchanged.

[ADR-0036](0036-automatic-host-updates.md) adds private candidate staging through
the same [resolver](../../../nix/domains/system/secrets/prepare.py), retaining this ADR's
identity and recipient rules. A descriptor-bound handoff makes activation publish
the exact preflighted files. The [update review](../reviews/2026-09-16-automatic-host-updates.md)
records passing staged-source consistency, incompatible-authority rejection and
encrypted Lilly credential delivery checks. This addition does not automate
shared-authority rotation.

The [NixOS module](../../../nix/domains/system/secrets/default.nix) pins the supplied operator
public key, enables key-based SSH bootstrap, and orders root-only preparation
after persistent host-key creation. [Pinned packages](../../../nix/domains/artifacts/default.nix)
supply SecretSpec 0.19.1, SOPS 3.13.3, ssh-to-age 1.3.0 and age 1.3.1. The
operator recipient package (`nix/domains/artifacts/operator-recipient/default.nix` at overalls revision `9fe1e493`, repository deleted) checks the SSH
fingerprint and converts only the public key; it performs no remote lookup.

[Preparation](../../../nix/domains/system/secrets/prepare.py) uses explicit provider/project/profile
selection, a private temporary age identity, bounded resolver output/deadlines,
required-value validation and atomic directory publication. Runtime outputs are
root-only or readable by a selected declared group. Cleanup removes derived
identities and abandoned staging directories. Consumers order preparation through
`secretUnits`. Those systemd dependencies propagate prerequisite restarts;
controlled rotation explicitly stops consumers, prepares the new bundle, then
starts consumers and checks readiness.

The [secret custody suite](../../../nix/verification/tests/machines/secret-custody/default.nix) uses actual encrypted
documents and runtime-generated host/recovery keys. The complete current suite
passed real Marshall startup, wrong-host rejection, independent operator recovery,
selected-group access and missing-secret failure while retaining the previous
bundle. It also passed application credential rotation with an explicit
stop/prepare/start sequence, journal checks, and a switch to a second NixOS
generation preserving the SSH identity and decryption. The
[boundary checks](../../../nix/verification/tests/machines/secret-custody/properties.py) passed actual systemd
environment properties, interrupted publication, unsafe paths and resolver limits.
The [implementation review](../reviews/2026-09-16-nixos-releases-and-roles.md)
records the completed verification scope and remaining work. Existing
[Marshall private-file handling](../../../marshall/lib/marshall/operations/private_files.ex),
[Lilly credential reading](../../../lilly/lib/lilly/control/credential_file.ex) and
[systemd TLS credential delivery](../../../nix/domains/system/marshall.nix) are
compatibility constraints for delivered application credentials.

The expanded [host-rotation review](../reviews/2026-09-16-secret-host-rotation.md)
records a staged new SSH-derived recipient, explicit old-recipient rejection,
continued real Marshall delivery and operator-mediated recovery onto a separately
keyed replacement machine. The complete expanded suite passed in 135.90 seconds;
application credentials already known by an old host require separate rotation.

The [fleet credential-rotation suite](../../../nix/verification/tests/machines/credential-rotation/default.nix)
passed staged Cloak keyring promotion across three Marshall machines and a
coordinated signing/cookie/database credential cutover through actual encrypted
bundles in 249.75 seconds. Actual HTTPS requests verified retained encrypted
credentials, rejection of old cookies and old tokens inside newly signed cookies,
and fresh logins on all nodes. The
[rotation review](../reviews/2026-09-16-fleet-credential-rotation.md) records the
interruption boundary, fail-closed missing-key check and retained-key requirement.

The [ACME client](../../../nix/domains/system/acme/lego.py) consumes a selected Route 53 credential
bundle through systemd credentials, validates its sole default profile, and
excludes ambient AWS credentials and instance metadata. The
[ACME machine check](../../../nix/verification/tests/machines/acme-route53/default.nix) supplies the encrypted document
through the actual secret module and deliberately injects conflicting ambient
credentials. Reflected provider errors are included in its journal privacy check.
See the [ACME review](../reviews/2026-09-16-acme-publication.md).

The generic bootstrap (`nix/machines/bootstrap.nix` at overalls revision `16e8dbe4`, repository deleted) and
offline installer (`nix/machines/installer.nix` at overalls revision `16e8dbe4`, repository deleted) reuse the pinned public
administration key without including a private host key. SSH is available before
application enrollment and secret delivery. The
[firmware installation test](../../../nix/verification/tests/machines/mirrored-installation/driver.py) checks absence
of a private key in the newly installed target, generation on first boot, and
identity retention on each surviving mirrored disk, with actual key-based SSH.
The complete check passed with password and keyboard-interactive authentication
disabled on the installer, healthy mirror and both surviving-disk boots.
Test-console instrumentation exists only in test variants. The
[installation review](../reviews/2026-09-16-mirrored-installation.md) records
executed results and remaining host acceptance. The separate
exact exported-image check (`nix/verification/tests/machines/bootstrap-images/default.nix` at overalls revision `16e8dbe4`, repository deleted) also passed
without injected credentials or test-console instrumentation: independent fresh
copies generated different SSH identities, while reboot and either surviving
disk retained the original copy's identity.

## Open questions

Actual host public recipients, encrypted deployment documents and application
secret values must be supplied through the bootstrap workflow. Apply the tested
rotation workflow to the actual deployment, retaining all decryption keys needed
by existing data and backups. A synthetic operator key demonstrates the
recovery mechanism without claiming access to ghuntley's private key.

## Related decisions

[ADR-0009](0009-assurance-and-testing.md),
[ADR-0012](0012-provisioner-control-transport.md),
[ADR-0025](0025-protected-provisioner-enrollment.md),
[ADR-0029](0029-database-durability-and-recovery.md),
[ADR-0030](0030-nixos-deployment-and-tls.md),
[ADR-0033](0033-nixos-machine-verification.md),
[architecture review](../reviews/2026-09-16-nixos-and-sparse-zfs.md).

Interface references: [SecretSpec quick start](https://secretspec.dev/quick-start/),
[SOPS provider](https://secretspec.dev/providers/sops/),
[ssh-to-age](https://github.com/Mic92/ssh-to-age).
