# ADR-0068: Nix-built customizable Ubuntu guests

- ID: ADR-0068
- Date: 2026-09-18
- Status: accepted
- Implementation: partial
- Components: Nix guest images, Lilly, Marshall Compute
- Supersedes: none
- Superseded by: none

## Context

Users need Ubuntu as a selectable guest while operators retain declarative Nix
image construction. The user approved Ubuntu 26.04 LTS, official base archives,
Ubuntu packages only, repository-defined customization, and all three test layers.
NixOS remains the default. Existing management API and website selection must
work; a new public HTTP API and compatibility shims are not required.

## Decision

Extend ADR-0011's initial NixOS offering with Ubuntu 26.04.1 amd64. Keep its image,
console and independent writable-disk contracts. Nix fetches the hash-pinned
Ubuntu Base archive and a complete locked set of additional Ubuntu packages.
An explicit updater resolves package names against signed Ubuntu snapshot
metadata using the base's package database and Ubuntu archive keyring. It records
versions, URLs, lengths and SHA256 hashes; ordinary builds cannot resolve newer
packages. The requested package set and base must match the committed lock.

Install packages offline inside a Nix-managed Linux build VM. Operators declare
package names, configuration files and public trusted CA certificates in Nix.
The builder includes platform prerequisites, protects integration paths, refreshes
Ubuntu's CA store and removes generated identity, logs and nondeterministic
caches. Normalize the ext4 image and verify byte-identical rebuilds. Software is
preinstalled, not continuously enforced; users retain ordinary root access and
APT inside their individual writable disks. Do not put private keys or runtime
secrets in these public Nix inputs.

Use the pinned Linux 6.12 ELF kernel and matching minimal initrd, Ubuntu systemd,
shared validated guest networking and the existing placement-bound vsock readiness
implementation. Resize root ext4 before readiness. Preserve disabled DHCP/IPv6,
/32 routing, locked root password, serial root autologin and disabled SSH.

Carry the platform public roots and split `.internal` DNS into deployment images.
Preserve ADR-0064 Customer egress restrictions independently of distribution.

Publish the existing manifest v2 and use the shared image validator for identity.
Stage named artifacts on both Overalls and Dungarees and register them on the
control plane from one deployment image list. Existing Ash
admission remains responsible for authorization, idempotency, resource minima and
fresh verified host image availability. Existing website and Porsche/Marshall
management API select image IDs. Inception retains its NixOS image.

## Alternatives

NixOS alone does not supply the requested Ubuntu userspace. Nixpkgs applications
inside Ubuntu were explicitly declined. Unpinned live APT builds would change
artifacts without a reviewed input change. Host-root installation would couple
the build to host configuration. User-submitted builds and runtime reconciliation
require different product and authority boundaries and are outside this decision.

## Consequences

Ubuntu adds maintained package locks and a KVM build requirement. Archive snapshot
retention is finite; retain Nix cache artifacts for long-lived rebuild requirements.
Ubuntu userspace and the Nix-built kernel have separate update inputs. Publishing
a new image does not replace an existing VM's writable disk. Minimum memory starts
at 512 MiB; applications may require a higher declared minimum.

## Invariants and verification

- Locks bind the exact base, request and hash-verified package inputs.
- Unit/evaluation tests reject stale requests and protected configuration paths.
- Generated tests exercise real networking/readiness parsing, duplicate and
  reserved-address rejection, and boot identity binding.
- Existing StreamData properties verify manifest identity and image default sizing.
- NixOS machine tests boot real Firecracker guests through Lilly, including
  customization, persistence, growth, cloning and relocation readiness.
- Fleet tests select Ubuntu through existing management and website paths.
- Rebuild checks compare actual image bytes, not merely dependency identities.

## Implementation evidence

[Ubuntu builder](../../../nix/domains/artifacts/guest/ubuntu/default.nix),
[lock updater](../../../nix/domains/artifacts/guest/ubuntu/update-lock.py), and
[shared image list](../../../fleet/guest-images.nix), and
[deployment catalog](../../../fleet/roles/control-plane/image-catalog.nix) implement
assembly, pinned resolution and publication configuration.
[Unit/property checks](../../../nix/verification/tests/evaluation/ubuntu-guest.py) and
[Nix evaluation assertions](../../../nix/verification/tests/evaluation/ubuntu-guest.nix) and
[offline refusal tests](../../../nix/verification/tests/evaluation/ubuntu-build-boundaries.nix)
check invalid inputs and missing packages/dependencies.
[Native guest suite](../../../nix/verification/tests/machines/zfs-guest/default.nix) and
[fleet suite](../../../nix/verification/tests/machines/fleet/default.nix) have Ubuntu variants.
Unit/property checks, rebuild comparisons, native guest lifecycle and the Marshall
application gate have passed. Fleet relocation acceptance remains in progress; see the
[review](../reviews/2026-09-18-ubuntu-guests.md).

## Open questions

Complete fleet relocation acceptance before claiming the image ready for
publication. Production activation is separate from repository delivery.

## Related decisions

[ADR-0011](0011-nixos-guest-and-console.md),
[ADR-0014](0014-image-and-address-admission.md),
[ADR-0037](0037-workload-placement-and-relocation.md),
[ADR-0054](0054-inception-development-profile.md),
[ADR-0064](0064-customer-workspace-isolation.md),
[ADR-0076](0076-default-guest-toolset.md),
[ADR-0093](0093-audi-mediated-guest-ssh.md),
[ADR-0094](0094-default-development-environments.md).

## Amendment 2026-09-22: first-boot SSH identity

ADR-0093 adds the locked OpenSSH server package, removes template host keys and
requires validated provision-key installation plus fresh host-key generation
before the Ubuntu SSH unit can start.
