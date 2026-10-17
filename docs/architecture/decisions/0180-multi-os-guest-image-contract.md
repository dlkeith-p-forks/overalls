# ADR-0180: Multi-OS guest image families on the Firecracker fleet

- ID: ADR-0180
- Date: 2026-10-16
- Status: proposed
- Implementation: partial
- Components: Nix guest builders, Protocol, Lilly, Marshall, guest-images
- Supersedes: none
- Superseded by: none

## Context

Overalls is expanding the Linux guest catalog beyond the standard NixOS and
Ubuntu images and is defining native non-Linux image contracts. The current
branch adds Arch Linux and AlmaLinux builders as foreign Linux variants. They
reuse the existing version-4 kernel image contract and carry deterministic
distribution markers so the two catalog entries have distinct identities.

The branch also extends the shared protocol for native FreeBSD and OmniOS
(represented by the `illumos` protocol family). Both use CloudHv firmware and
version-6 raw-GPT images; FreeBSD's published GPT disk contains the EFI system
partition and UFS root, while OmniOS carries its ZFS root. Pinned builders and
catalog entries now exist. FreeBSD
14.3 is fetched from a checksum-pinned archive capture because the rolling
`Latest` endpoint was retired. Local Nix realization now succeeds for both
native builders, but neither family has a recorded runtime result.

The existing NixOS, Ubuntu and Windows contracts must remain intact. OS names,
root formats, boot artifacts and agent capabilities must come from validated
protocol metadata. Lilly must not infer a guest family from a filename or
package contents, and Marshall must not grant a capability merely because an
image contains a tool.

## Decision

1. **Foreign Linux variants retain the Linux contract.** Arch Linux and
   AlmaLinux use the existing version-4 kernel manifest and version-1 bundle
   shape, with the same Lilly kernel boot, guest agents and capability table as
   the standard Linux row. Their builders assemble distro-specific roots from
   pinned sources, add deterministic `arch` and `almalinux` identity markers
   and remain separate catalog entries.
2. **Native OS families use explicit version-6 metadata.** A version-6 FreeBSD
  manifest declares `os = freebsd`, firmware boot, virtio-pci, raw GPT root and
  `guest_agents = freebsd-v1`. A version-6 OmniOS/illumos manifest declares
  `os = illumos`, firmware boot, virtio-pci, raw GPT root and
  `guest_agents = illumos-v1`. Unknown OS values, cross-OS agent sets, extra
   keys and invalid artifact bounds are refused.
3. **Bundle version 3 is closed.** Native FreeBSD and illumos firmware bundles
  carry the validated image ID, OS, matching agent set and firmware size.
  Artifact file lists come from
   the protocol. Version-1 Linux and version-2 Windows firmware encodings
   remain byte-compatible.
4. **Capabilities stay explicit.** The protocol's capability table is the sole
   source for Lilly and Marshall. `freebsd-v1` and `illumos-v1` currently have
   the same capability flags as `windows-v1` (readiness, trust, terminal,
   workspace, SSH and agents; no editor or Inception) and a 600-second readiness
   budget. This is a contract definition, not evidence that those guests or
   agents exist yet.
5. **Lilly preserves shared boundaries.** Kernel bundles include an initrd only
   when the validated bundle declares one. Firmware bundles select the default
   CPU model for illumos and retain Hyper-V configuration only for Windows.
   Vsock is attached only when the agent set speaks the Lilly protocols. The
   jailer, seccomp observation, per-tap network guard, ZFS ownership and durable
   lifecycle remain shared boundaries.
6. **Evidence is scoped to what exists.** The Arch/Alma evaluation check proves
   builder command shape and distinct distribution markers only. Protocol tests
   and the Lilly jail test prove bounded metadata and the no-initrd native
   kernel configuration only. No native FreeBSD or OmniOS boot, readiness,
   trust, terminal, workspace, relocation or Marshall fleet acceptance is
   implied by those checks.

Authorization: the multi-OS guest-image implementation plan of 2026-10-16.
The Windows decisions remain in [ADR-0169](0169-firmware-booted-windows-guests.md),
[ADR-0170](0170-lilly-firmware-guest-launch.md),
[ADR-0171](0171-windows-guest-agents.md) and
[ADR-0173](0173-windows-images-winget-desktop-experience.md).

## Alternatives

- **Infer the OS from a filename or package set.** Rejected because admission,
  artifact mounting and capability authorization would be ambiguous.
- **Give each new OS a separate Lilly lifecycle.** Rejected because it would
  duplicate fencing, ZFS ownership, network isolation and recovery logic.
- **Treat Arch/Alma as new protocol OS values now.** Rejected while their
  builders retain the Linux boot contract and only their root assembly and
  identity vary.
- **Claim native FreeBSD/OmniOS support from metadata alone.** Rejected because
  a manifest and unit test do not prove a boot, guest isolation or recovery.

## Consequences

- Arch and Alma can be built and cataloged through the established Linux path,
  while their identities remain distinct.
- Version-6 metadata and bundle version 3 provide a stable extension point for
  native FreeBSD and OmniOS without changing existing wire encodings.
- Native families add protocol, Lilly and Marshall branches. Preliminary image
  builders and catalog entries exist, but successful reproducible builds,
  machine tests, security scenarios and fleet rollout evidence are required
  before staging.
- The FreeBSD and illumos capability rows remain contract surface only until
  those artifacts and tests are recorded; callers must preserve their partial
  status.

## Invariants and verification

- Version-4 Linux manifests and version-1 bundles remain byte-identical.
- Arch and Alma builder commands contain the reviewed version-4 kernel/root
  shape and their own deterministic distribution marker.
- Version-6 manifests and version-3 bundles reject unknown keys, OS/agent
  mismatches, malformed boot arguments and out-of-bound artifact sizes.
- Native FreeBSD and illumos firmware bundles receive a vsock only for their
  declared protocol-speaking agent set and never receive the Windows Hyper-V
  CPU template.
- The current `foreign-linux-guests`, `native-os-guest-unit`, protocol
  validation, `Lilly.VM.JailTest` and `Lilly.Host.ImageTest` checks are
  structural evidence. Native
  FreeBSD/OmniOS execution, isolation, recovery and fleet availability remain
  untested.

## Implementation evidence

The implementation is partial. Arch and Alma builders are in
[`nix/packages/guest/arch`](../../../nix/packages/guest/arch),
[`nix/packages/guest/alma`](../../../nix/packages/guest/alma) and the shared
[`foreign-linux.nix`](../../../nix/packages/guest/foreign-linux.nix), with the
[`foreign-linux-guests`](../../../nix/tests/evaluation/foreign-linux-guests.nix)
evaluation and catalog entries in [`fleet/guest-images.nix`](../../../fleet/guest-images.nix).

Native builders and catalog entries are in
[`native.nix`](../../../nix/packages/guest/native.nix),
[`freebsd/default.nix`](../../../nix/packages/guest/freebsd/default.nix),
[`omnios/default.nix`](../../../nix/packages/guest/omnios/default.nix),
and [`illumos/default.nix`](../../../nix/packages/guest/illumos/default.nix),
[`native-os-guests.nix`](../../../nix/tests/evaluation/native-os-guests.nix) and
[`fleet/guest-images.nix`](../../../fleet/guest-images.nix). The FreeBSD source
endpoint is retired and is replaced by an archived, checksum-pinned capture;
the explicit illumos constructor records `https://illumos.org/` as the upstream
project and uses OmniOS r151050 as its pinned downstream image because the
illumos project publishes source and documentation, not a canonical installable
guest image. The fleet's `OmniOS r151050` row consumes the explicit
`illumosGuest` constructor while retaining OmniOS as the display name. The
evaluation remains structural, while local Nix realization of both pinned
native artifacts is recorded below.

Native metadata and bundle validation are in
[`image_manifest.ex`](../../../protocol/lib/overalls_protocol/image_manifest.ex),
[`workload_bundle.ex`](../../../protocol/lib/overalls_protocol/workload_bundle.ex)
and [`guest_agents.ex`](../../../protocol/lib/overalls_protocol/guest_agents.ex).
Lilly's conditional initrd, vsock and CPU configuration is in
[`jail.ex`](../../../lilly/lib/lilly/vm/jail.ex), with the focused
  [`jail_test.exs`](../../../lilly/test/vm/jail_test.exs) and source-artifact
  selection coverage in [`image_test.exs`](../../../lilly/test/host/image_test.exs).
  The latter verifies that manifest-declared `disk.raw` files
are selected as sources while Lilly retains its internal persistent destination
name; it does not realize an image or boot a guest.

The pinned FreeBSD and OmniOS builders now have successful local Nix
realization checks, including preservation of FreeBSD's complete EFI/GPT/UFS
disk. No
signed production artifact, machine test, native guest agent implementation or
runtime execution record exists yet. The catalog entries do not carry standby
metadata and must not be treated as launchable support.

## Open questions

- Which FreeBSD and OmniOS/illumos image builders and signed inputs should be
  accepted, and whether OmniOS should retain the protocol label `illumos`.
  A direct illumos.org image source is unavailable: the upstream project
  identifies OmniOS, OpenIndiana and Tribblix as downstream distributions.
- Whether native guests can support the declared vsock protocols and the
  600-second readiness budget.
- Which native machine tests can establish boot, isolation, storage growth and
  recovery before either family is staged.

## Related decisions

- [ADR-0011](0011-nixos-guest-and-console.md), [ADR-0068](0068-nix-built-ubuntu-guests.md): existing Linux image contracts.
- [ADR-0113](0113-guest-trust-at-boot.md), [ADR-0154](0154-guest-boot-profile.md): boot-bound guest evidence.
- [ADR-0146](0146-standby-guest-disks.md), [ADR-0159](0159-remove-legacy-compatibility.md): standby and convergence ordering.
- [ADR-0169](0169-firmware-booted-windows-guests.md), [ADR-0170](0170-lilly-firmware-guest-launch.md), [ADR-0171](0171-windows-guest-agents.md), [ADR-0173](0173-windows-images-winget-desktop-experience.md): Windows decisions.
