# ADR-0188: Native kernel provenance and fail-closed multi-OS admission

- ID: ADR-0188
- Date: 2026-10-17
- Status: accepted
- Implementation: partial
- Components: Nix guest builders, Protocol, Lilly, Lyra, Marshall, guest-images
- Supersedes: ADR-0180
- Superseded by: none

## Context

This decision replaces [ADR-0180](0180-multi-os-guest-image-contract.md). It
carries forward the foreign Linux families, native OS identities, firmware
metadata and shared Lilly boundaries, while replacing native capability
advertisement with kernel-provenance and recorded-runtime admission gates.
Stock FreeBSD 14.3 and OmniOS lack the required AF_VSOCK/virtio-vsock kernel
support, so their earlier advertised capability rows cannot establish support.

Overalls is expanding the Linux guest catalog beyond the standard NixOS and
Ubuntu images and is defining native non-Linux image contracts. The current
branch adds Arch Linux and AlmaLinux builders as foreign Linux variants. They
reuse the existing version-4 kernel image contract and carry deterministic
distribution markers so the two catalog entries have distinct identities.

The branch also extends the shared protocol for native FreeBSD and OmniOS
(represented by the `illumos` protocol family). Both use CloudHv firmware and
version-6 raw-GPT images; FreeBSD's published GPT disk contains the EFI system
partition and UFS root, while OmniOS carries its ZFS root. Pinned builders and
catalog entries now exist. FreeBSD 14.3 is fetched from a checksum-pinned
archive capture because the rolling `Latest` endpoint was retired. The
native-kernel package evaluates immutable source, patch and configuration
receipts only: its artifact is unavailable until the OS-specific cross builds
provide kernel bytes. Image builders refuse before copying a stock disk, so
neither family has a launchable image or a recorded runtime result.

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
   manifest declares `os = freebsd`, firmware boot, virtio-pci, raw GPT root
   and `guest_agents = freebsd-v1`. A version-6 OmniOS/illumos manifest
   declares `os = illumos`, firmware boot, virtio-pci, raw GPT root and
   `guest_agents = illumos-v1`. Unknown OS values, cross-OS agent sets, extra
   keys and invalid artifact bounds are refused. Every native manifest carries
   a positive kernel byte count, SHA-256 digest, full source revision, patch
   hash, configuration hash and compiler identity. A source receipt or
   placeholder digest is not admission evidence.
3. **Bundle version 3 is closed.** Native FreeBSD and illumos firmware bundles
   carry the validated image ID, OS, matching agent set, kernel provenance and
   firmware size. Artifact file lists come from the protocol. Version-1 Linux
   and version-2 Windows firmware encodings remain byte-compatible.
4. **Capabilities stay explicit and fail closed.** The protocol's capability
   table is the sole source for Lilly and Marshall. `freebsd-v1` and
   `illumos-v1` retain their OS-specific wire identities and host-only vsock
   transport shape, but their current capability rows are all false. Readiness,
   trust, terminal, workspace, flush, SSH and agent-control surfaces remain
   unavailable until a cross-built kernel, complete agent closure and native
   machine evidence are recorded. A native manifest may carry
   `workspace_source_version = 2` as schema, but that declaration does not
   grant source delivery. A missing or mismatched manifest remains refused.
5. **Lilly preserves shared boundaries.** Kernel bundles include an initrd only
   when the validated bundle declares one. Firmware bundles select the default
   CPU model for illumos and retain Hyper-V configuration only for Windows.
   Vsock is attached only when the agent set speaks the Lilly protocols. The
   jailer, seccomp observation, per-tap network guard, ZFS ownership and durable
   lifecycle remain shared boundaries.
6. **Evidence is scoped to what exists.** The Arch/Alma evaluation check proves
   builder command shape and distinct distribution markers only. Protocol tests
   and the Lilly jail test prove bounded metadata and the native firmware
   configuration only. No native FreeBSD or OmniOS boot, readiness,
   trust, terminal, workspace, relocation or Marshall fleet acceptance is
   implied by those checks.
7. **Native admission is boot-bound and fail closed.** Before credentials or
   readiness, Lilly requires an `attested` response from the jail-local probe
   matching the native OS, placement, execution epoch, boot challenge and
   manifest kernel digest, with a bounded boot ID. Missing, placeholder, stale
   or mismatched evidence refuses admission. The fixed host-only vsock path
   and bounded frames preserve the existing transport boundary. The later
   readiness response must carry the same boot ID as the kernel response.

Authorization: the multi-OS guest-image implementation plan of 2026-10-16 and
the custom native-kernel plan of 2026-10-17.
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
- The FreeBSD and illumos rows define a versioned transport contract only. The
  implementation keeps every native capability false until the kernel, daemon
  closure and machine evidence are recorded; callers must preserve the partial
  status and must not treat metadata as proof of readiness, trust or user
  access.

## Invariants and verification

- Version-4 Linux manifests and version-1 bundles remain byte-identical.
- Arch and Alma builder commands contain the reviewed version-4 kernel/root
  shape and their own deterministic distribution marker.
- Version-6 manifests and version-3 bundles reject unknown keys, OS/agent
  mismatches, malformed boot arguments, incomplete kernel provenance and
  out-of-bound artifact sizes.
- Kernel provenance binds every native image to positive kernel bytes, a
  digest, source revision, patch hash, configuration hash and compiler.
  Unavailable or placeholder kernel artifacts cannot enter image construction
  or native admission.
- Native FreeBSD and illumos firmware bundles retain the jail-local, host-only
  vsock transport shape; they never receive the Windows Hyper-V CPU template.
  If native capabilities are enabled in a later reviewed rollout, each daemon
  must bind host CID 2 to guest CID 3 and every response to the current boot
  before Lilly or Marshall grants the corresponding operation.
- The current `foreign-linux-guests`, `native-os-guest-unit`, protocol
  validation, `Lilly.VM.JailTest` and `Lilly.Host.ImageTest` checks are
  structural evidence. Native
  FreeBSD/OmniOS execution, isolation, recovery and fleet availability remain
  untested.

## Implementation evidence

The implementation is partial. Arch and Alma builders are in
[`nix/domains/artifacts/guest/arch`](../../../nix/domains/artifacts/guest/arch),
[`nix/domains/artifacts/guest/alma`](../../../nix/domains/artifacts/guest/alma) and the shared
[`foreign-linux.nix`](../../../nix/domains/artifacts/guest/foreign-linux.nix), with the
[`foreign-linux-guests`](../../../nix/verification/tests/evaluation/foreign-linux-guests.nix)
evaluation and catalog entries in [`fleet/guest-images.nix`](../../../fleet/guest-images.nix).

Native builders and catalog entries are in
[`native.nix`](../../../nix/domains/artifacts/guest/native.nix),
[`freebsd/default.nix`](../../../nix/domains/artifacts/guest/freebsd/default.nix),
[`omnios/default.nix`](../../../nix/domains/artifacts/guest/omnios/default.nix),
and [`illumos/default.nix`](../../../nix/domains/artifacts/guest/illumos/default.nix),
[`native-os-guests.nix`](../../../nix/verification/tests/evaluation/native-os-guests.nix) and
[`fleet/guest-images.nix`](../../../fleet/guest-images.nix). The FreeBSD source
endpoint is retired and is replaced by an archived, checksum-pinned capture;
the explicit illumos constructor records `https://illumos.org/` as the upstream
project and uses OmniOS r151050 as its pinned downstream image because the
illumos project publishes source and documentation, not a canonical installable
guest image. The fleet's `OmniOS r151050` row consumes the explicit
`illumosGuest` constructor while retaining OmniOS as the display name. The
evaluation remains structural and records no native runtime acceptance.

Native metadata, bundle and kernel-attestation validation are in
[`image_manifest.ex`](../../../protocol/lib/overalls_protocol/image_manifest.ex),
[`workload_bundle.ex`](../../../protocol/lib/overalls_protocol/workload_bundle.ex),
[`kernel_attestation.ex`](../../../protocol/lib/overalls_protocol/kernel_attestation.ex)
and [`guest_agents.ex`](../../../protocol/lib/overalls_protocol/guest_agents.ex).
Lilly's conditional initrd, vsock and CPU configuration is in
[`jail.ex`](../../../lilly/lib/lilly/vm/jail.ex), with the focused
  [`jail_test.exs`](../../../lilly/test/vm/jail_test.exs) and source-artifact
  selection coverage in [`image_test.exs`](../../../lilly/test/host/image_test.exs).
  The latter verifies that manifest-declared `disk.raw` files
are selected as sources while Lilly retains its internal persistent destination
name; it does not realize an image or boot a guest.

The pinned FreeBSD and OmniOS builders and
[`kernel receipts`](../../../nix/domains/artifacts/guest/native-kernels/default.nix)
evaluate in Nix, but the receipts mark kernel artifacts unavailable and image
builders stop before copying a stock disk. The protocol and Marshall projections define the native
rows and permit workspace source version 2; this proves only the versioned
contract. Lilly's bounded kernel-attestation path and Lyra's source adapters
are covered by unit/type checks, while cross-built kernels, target-native
packaging, complete service closure, runtime image assembly, nested machine
tests and fleet execution remain absent. No signed production artifact or
runtime execution record exists, and catalog entries must not be treated as
accepted fleet support.

The [native kernel attestation review](../reviews/2026-10-17-native-kernel-attestation.md)
records source-level evidence and the remaining kernel, cross-toolchain,
native `terminald`, image assembly and machine-test requirements.

## Open questions

- Which signed FreeBSD and OmniOS/illumos inputs should be accepted. OmniOS is
  the installable downstream image and `illumos` is the stable protocol label.
  A direct illumos.org image source is unavailable: the upstream project
  identifies OmniOS, OpenIndiana and Tribblix as downstream distributions.
- Whether the native guest services pass the declared vsock protocols and the
  600-second readiness budget under CloudHv boot and restart.
- Which OS-specific cross toolchains and kernel implementations will replace
  the source/contract scaffolds, and how native `terminald` will be built and
  tested.
- Which native machine tests can establish boot, isolation, storage growth and
  recovery before either family is staged.

## Related decisions

- [ADR-0011](0011-nixos-guest-and-console.md), [ADR-0068](0068-nix-built-ubuntu-guests.md): existing Linux image contracts.
- [ADR-0113](0113-guest-trust-at-boot.md), [ADR-0154](0154-guest-boot-profile.md): boot-bound guest evidence.
- [ADR-0146](0146-standby-guest-disks.md), [ADR-0159](0159-remove-legacy-compatibility.md): standby and convergence ordering.
- [ADR-0169](0169-firmware-booted-windows-guests.md), [ADR-0170](0170-lilly-firmware-guest-launch.md), [ADR-0171](0171-windows-guest-agents.md), [ADR-0173](0173-windows-images-winget-desktop-experience.md): Windows decisions.
