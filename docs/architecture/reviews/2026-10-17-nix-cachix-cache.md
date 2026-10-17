# Nix Cachix cache review

## Scope

This review covers the fleet-wide addition of the signed Overalls Cachix read
substituter, including NixOS hosts, NixOS/Inception guests, the kexec installer
and Ubuntu guests running `nix-daemon`.

## Findings

The shared module retains `cache.nixos.org`, adds the Overalls endpoint and key,
keeps signature verification enabled, and enables fallback. An assertion rejects
an evaluated configuration with `require-sigs = false`. No write credentials are
present. Foreign images that do not run Nix are outside this boundary.

## Evidence and limits

`nix-cache-configuration` evaluates host, guest and fixture configurations and
passes; the flake check builds successfully. This is declaration evidence only:
live Cachix reachability, substitution hit rate, and deployment convergence on
physical machines remain unverified.

## Architecture impact

The change adds an external signed artifact source at the Nix deployment boundary
and does not change Ash domains, service authority, guest isolation or network
listeners. ADR-0188 records the trust boundary and partial implementation status.
