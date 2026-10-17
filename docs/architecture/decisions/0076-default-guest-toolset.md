# ADR-0076: Default guest toolset

- ID: ADR-0076
- Date: 2026-09-19
- Status: superseded
- Implementation: implemented
- Components: Nix guest images, Lilly, Marshall Compute
- Supersedes: none
- Superseded by: ADR-0094

## Context

The initial guest images under [ADR-0011](0011-nixos-guest-and-console.md) and
[ADR-0068](0068-nix-built-ubuntu-guests.md) ship only platform prerequisites
plus `curl`/`iproute2`. A fresh workspace cannot run containers, clone from
GitHub, or use ordinary interactive tooling before installing it itself, and
Customer-profile guests have no outbound access to change that. The user
approved a reviewed default toolset for both images: Podman with Docker
compatibility (CLI alias, `/run/docker.sock` API socket and Podman Compose),
the GitHub CLI with `git`, `curl`, `wget`, `tmux`, `vim`, Neovim, `lsof`,
`iproute2`, `jq`, Mercurial (`hg`), `atop`, `btop`, `iotop`, `ncdu`,
`sqlite3`, `less`, ripgrep, and DNS/network tools (`nslookup`, `dig`, `ping`),
plus Nix inside the Ubuntu image so Ubuntu users can run Nix without a network
installer.

## Decision

Ship the toolset as preinstalled default content in both guest images, subject
to the existing image contracts. Software is preinstalled, not continuously
enforced, matching ADR-0068: root users retain full control of their writable
disk.

- Podman is rootful-only and enabled through each distribution's supported
  mechanism. NixOS uses the pinned NixOS module with the `docker` CLI
  compatibility alias and Docker socket compatibility; Ubuntu installs the
  archive's `podman`, `podman-docker`, `podman-compose` and `aardvark-dns`
  packages, enables the system `podman.socket` and aliases
  `/run/docker.sock`. Container egress is guest egress: it leaves through the
  guest's single validated address and remains governed by the profile network
  fences of ADR-0015 and ADR-0064. No additional network listener is opened.
- Ubuntu installs Nix only from the Ubuntu archive (`nix-bin`,
  `nix-setup-systemd`) through the existing authenticated lock; the
  `nix-daemon` unit is enabled deterministically at image assembly because
  `policy-rc.d` blocks activation during the offline install.
- The Ubuntu guest's kernel module closure is extended with the namespaces,
  overlay, bridge and netfilter modules Podman and Nix require; the NixOS guest
  already carries the full module closure.
- Boot minima are unchanged: the toolset is idle at boot and the 512 MiB
  admission floor still boots. Image size grows, and the manifest's
  `minimum_disk_bytes` plus Marshall's derived default shape absorb it under
  ADR-0014 and [ADR-0051](0051-vm-resizing.md).
- The shared registry list ([`fleet/guest-images.nix`](../../../fleet/guest-images.nix))
  is unchanged: it references image derivations, so rebuilt toolset artifacts
  propagate to host staging and catalog registration without a registry edit.

## Alternatives

Minimal images with user self-installation leave Customer-profile guests
without containers or GitHub access and push avoidable setup onto every
workspace. A Docker daemon was rejected in favor of the daemonless rootful
Podman already modeled by the pinned NixOS module. Installing upstream `gh`
or Nix binaries from outside the Ubuntu archive would violate ADR-0068's
Ubuntu-packages-only boundary and its authenticated snapshot lock. Running
Nix's network installer at first boot would depend on egress the Customer
profile denies.

## Consequences

Root filesystems grow substantially (roughly 2–3 GiB installed toolset),
increasing build time, artifact size and the manifest-derived minimum disk.
Admission floors and defaults adjust automatically from the manifest. The
Docker compatibility socket is a root-owned local socket in an image whose
only access path is already the authenticated root console. Nested container
traffic inherits the guest's own address and restrictions rather than adding
a new boundary. Both images remain reproducible from pinned inputs.

## Invariants and verification

- The NixOS guest enables Podman with the Docker CLI alias and socket, and
  ships every reviewed tool; an evaluation check fails when any is missing.
- The Ubuntu lock binds the exact extended package set with SHA256 identities
  and offline installation; stale-request and refusal tests keep enforcing it.
- Real machine suites boot both images through Firecracker and verify the
  Docker alias, `/run/docker.sock`, live Podman storage (`podman info`),
  Podman Compose, the Nix daemon (Ubuntu), Nix presence (both) and the tool
  commands inside the real image.
- Rebuilding either rootfs from unchanged inputs reproduces identical bytes.
- The guest access boundary is unchanged: no SSH and no new network listener.

## Implementation evidence

[NixOS guest configuration](../../../nix/domains/artifacts/guest/configuration.nix) and
the [Ubuntu builder](../../../nix/domains/artifacts/guest/ubuntu/default.nix) with its
[required packages](../../../nix/domains/artifacts/guest/ubuntu/required-packages.json)
and [package lock](../../../nix/domains/artifacts/guest/ubuntu/packages.lock.json)
implement the toolset. The
[evaluation check](../../../nix/verification/tests/evaluation/guest-toolset.nix) asserts
the NixOS configuration, and the
[guest suite probe](../../../nix/verification/tests/machines/zfs-guest/probe.exs) boots
both images with the live toolset smoke. The
[review](../reviews/2026-09-19-guest-toolset.md) records executed verification
and remaining acceptance limits.

## Open questions

Fleet-level acceptance for the rebuilt Ubuntu artifacts remains in progress
under ADR-0068; this decision adds no separate fleet gate. Rootless Podman
(subuid mappings, `pasta`) is deliberately out of scope until requested.

## Related decisions

[ADR-0011](0011-nixos-guest-and-console.md),
[ADR-0014](0014-image-and-address-admission.md),
[ADR-0015](0015-jailed-execution-and-host-networking.md),
[ADR-0051](0051-vm-resizing.md),
[ADR-0064](0064-customer-workspace-isolation.md),
[ADR-0068](0068-nix-built-ubuntu-guests.md),
[ADR-0094](0094-default-development-environments.md).
