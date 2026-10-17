# ADR-0094: Default development environments on fleets and guests

- ID: ADR-0094
- Date: 2026-09-22
- Status: superseded
- Implementation: partial
- Components: Nix fleet hosts, NixOS guest image, Ubuntu guest image
- Supersedes: ADR-0076
- Superseded by: ADR-0153

## Context

[ADR-0153](0153-official-source-browser-editor.md) carries these toolset and offline
closure requirements forward unchanged and adds the explicitly authorized browser
editor/broker closure exception. This record retains its rationale and historical
implementation evidence.

ADR-0076 made a general interactive toolset, including `jq`, available in NixOS
and Ubuntu guests, but it did not include `direnv` or `devenv`. Fleet hosts
lacked all three commands in their shared profile. A repository checkout
therefore could not enter its pinned development environment without first
changing the host or guest, and host-side JSON inspection depended on an
undeclared tool.

The user authorized installing `direnv` and `devenv` by default on every fleet
host and in both guest images on 2026-09-22, then explicitly added `jq` to that
default. `direnv` exists in the authenticated Ubuntu snapshot. `devenv` does
not, so satisfying the requirement needs a narrow exception to ADR-0068's
preference for Ubuntu-archive applications even though the Ubuntu image already
provides Nix itself.

## Decision

Every base and enrolled fleet host and the default NixOS guest image MUST install
`jq`, `direnv` and `devenv` from their supplied pinned Nixpkgs package set. This
extends, and otherwise carries forward unchanged, ADR-0076's default guest
toolset, rootful Podman boundary and image identity rules. ADR-0093's later,
Audi-fenced guest SSH decision remains authoritative and is not changed here.

The Ubuntu guest MUST install `jq` and `direnv` from the existing authenticated
Ubuntu snapshot lock. It MUST embed `devenv` and its complete runtime closure
from the repository's supplied pinned Nixpkgs input during offline image
assembly, register those paths in the guest Nix database and retain them through
a GC root. The image exposes the command at `/usr/local/bin/devenv`; no
first-boot download or unpinned channel is permitted. This is the only
Nixpkgs-application exception introduced to ADR-0068's Ubuntu-package boundary.

## Alternatives

Installing both tools after first boot was rejected because Customer guests may
have no outbound access and because fleet hosts should converge through their
declarative profile. Treating `devenv` as an Ubuntu package was rejected because
the authenticated snapshot does not provide it. Fetching an upstream installer
or a separate channel was rejected because it would bypass the repository's
pinned Nixpkgs inputs and make the images network-dependent.

Shipping an unregistered store copy was rejected because guest Nix garbage
collection could remove the tool or its runtime dependencies. Installing
`direnv` from Nixpkgs in Ubuntu was unnecessary because the locked Ubuntu package
preserves the distribution boundary for that command.

## Consequences

Fleet system closures grow by the tools' runtime closures. The guest images
already included `jq`; their additional growth comes from the development
environment tools. Existing fleet hosts receive the complete set on normal
activation; existing guests retain their writable disks and do not change until
recreated from a new image. This decision introduced one explicitly reviewed Nixpkgs
application in addition to its Ubuntu packages, but the source stays pinned and
assembly stays offline.

ADR-0096 separately authorizes the small, static Lyra `overalls` client in both
guest images. Its Ubuntu copy is a second explicit non-archive application
exception; this does not change the `devenv` decision or its rationale.

The Ubuntu manifest-derived minimum disk size and Marshall's derived default
shape continue to absorb rootfs growth. No service, listener, credential or new
runtime authority is introduced.

## Invariants and verification

- All base and enrolled host profile evaluations contain all three packages.
- NixOS guest evaluation fails if any package is absent.
- The Ubuntu request and package lock contain `jq` and `direnv`; ordinary builds
  reject a stale lock.
- Ubuntu assembly copies and registers the pinned `devenv` closure and anchors it
  with a GC root without network access.
- Real guest smoke checks require both commands in both images.
- Guest SSH, console, networking, Podman and exact-artifact contracts remain
  unchanged.

## Implementation evidence

The shared [fleet host profile](../../../nix/platform/hosts/profile.nix) and its
[evaluation](../../../nix/verification/tests/evaluation/storage-configuration.nix) install
and check all three packages for every host fixture. The
[NixOS guest configuration](../../../nix/domains/artifacts/guest/configuration.nix) and
[toolset evaluation](../../../nix/verification/tests/evaluation/guest-toolset.nix) do the
same for the default Nix image.

The [Ubuntu builder](../../../nix/domains/artifacts/guest/ubuntu/default.nix),
[required package set](../../../nix/domains/artifacts/guest/ubuntu/required-packages.json)
and [authenticated package lock](../../../nix/domains/artifacts/guest/ubuntu/packages.lock.json)
install locked `jq` and `direnv` and embed registered, GC-rooted `devenv`. The
shared [real guest probe](../../../nix/verification/tests/machines/zfs-guest/probe.exs) checks
all three commands. Evaluation and image-build verification are implemented;
the updated real guest smoke remains to be executed, so implementation is
partial.

## Open questions

None.

## Related decisions

[ADR-0011](0011-nixos-guest-and-console.md),
[ADR-0068](0068-nix-built-ubuntu-guests.md),
[ADR-0073](0073-bounded-nix-store-reclamation.md),
[ADR-0076](0076-default-guest-toolset.md),
[ADR-0093](0093-audi-mediated-guest-ssh.md),
[architecture review](../reviews/2026-09-22-default-development-environments.md).
