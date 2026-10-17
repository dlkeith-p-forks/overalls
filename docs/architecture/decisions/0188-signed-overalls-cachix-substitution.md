# ADR-0188: Use the signed Overalls Cachix cache across Nix machines

- ID: ADR-0188
- Date: 2026-10-17
- Status: accepted
- Implementation: partial
- Components: NixOS fleet, NixOS guests, Ubuntu guests, kexec installer
- Supersedes: none
- Superseded by: none

## Context

Fleet hosts and guests build the same pinned Nix closures. Rebuilding every
closure locally increases provisioning time and makes recovery depend on local
build capacity. The Overalls Cachix endpoint publishes signed paths for these
closures. Nix must retain `cache.nixos.org` and must not accept unsigned paths.

## Decision

Add `https://overalls.cachix.org` and its pinned public key to every machine
configuration that runs Nix, including NixOS hosts, NixOS and Inception guests,
the kexec installer, and Ubuntu guests running `nix-daemon`. Keep the upstream
cache, enable fallback, and require Nix signature verification. No push or
authentication credentials are installed. A cache outage falls back to the
remaining substituters or a local build.

## Alternatives

Using only `cache.nixos.org` leaves Overalls closures to local builds. Disabling
signature checks would permit tampered paths and is unacceptable. Installing a
machine token would expand credential scope without being needed for reads.

## Consequences

Known signed closures download faster and provisioning can continue when Cachix
is unavailable. Cache availability and freshness remain external dependencies;
the configuration does not claim a live Cachix SLA or prove every image uses a
substituted path.

## Invariants and verification

The Overalls URL and key are present alongside `cache.nixos.org`; `require-sigs`
cannot be forced off; and all supported host and guest configurations inherit
the same values. The evaluation check and Nix build verify these declarations.

## Implementation evidence

The shared values are in [nix/platform/nix-cache.nix](../../../nix/platform/nix-cache.nix)
and applied by [nix/domains/system/nix-cache.nix](../../../nix/domains/system/nix-cache.nix),
guest, kexec and Ubuntu image modules. The evaluation check is
[nix-cache.nix](../../../nix/verification/tests/evaluation/nix-cache.nix). These
prove configuration presence and signature policy; live cache availability and
fleet rollout remain open.

## Open questions

None.

## Related decisions

See [ADR-0030](0030-nixos-deployment-and-tls.md) for the NixOS deployment
direction and [ADR-0180](0180-multi-os-guest-image-contract.md) for guest image
boundaries.
