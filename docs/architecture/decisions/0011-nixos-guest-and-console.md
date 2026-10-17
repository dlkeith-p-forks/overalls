# ADR-0011: NixOS guest image and local serial console

- ID: ADR-0011
- Date: 2026-09-15
- Status: accepted
- Implementation: partial
- Components: Lilly, NixOS guest, Firecracker, host console
- Supersedes: none
- Superseded by: none

## Context

The accepted plan specifies an x86-64 NixOS guest, persistent disks and a root
TTY whose lifetime is independent of Lilly. Real execution is now possible on
the local exe.dev VM: root can open KVM and create a VM. A second independent
host remains necessary for the cross-host acceptance tests.

## Decision

Build the initial guest with the Nixpkgs input already pinned by `devenv.lock`.
Expose it as `devenv build outputs.guest`. Include a minimal NixOS closure in a
bare ext4 root image, Linux 6.12 kernel and matching initrd. Firecracker 1.16.1
requires the uncompressed ELF kernel from the kernel's development output;
compressed `bzImage` support documented on upstream main is not in this release.

Normalize copied filesystem timestamps, ext4 tool time and directory-hash seed
so rebuilding the root image produces identical bytes. The immutable artifact
contains kernel/initrd/rootfs links and a versioned manifest with architecture,
boot arguments and minimum sizes. Each VM must receive its own writable copy.
The manifest's integrity fields, immutable catalog and verified host availability
are now specified by [ADR-0014](0014-image-and-address-admission.md). Its manifest
version 2 adds SHA-256/length descriptors without changing the guest bytes.
The initial admission floor is 512 MiB RAM and 2 GiB disk, sufficient for the
verified image; catalog registration now validates its own manifest, and
admission requires the exact image in the host's fresh inventory.

The serial console autologs in as root, consistent with the accepted terminal
model. No SSH daemon is enabled. The image has IPv6 and DHCP disabled; networking
is not enabled by the original image-only test. ADR-0015 now supplies a validated
`lilly.ipv4` boot parameter, /32 guest routing, public DNS and host NAT/filtering.

Use pinned upstream dtach for a local console that can be detached and reattached.
Its Linux protocol has fixed ten-byte control packets with an eight-byte payload;
output is an uninterpreted byte stream. Lilly's client limits each input call to
4096 bytes and uses passive socket reads. Set initial geometry to 80 columns by
24 rows without injecting redraw keystrokes. The future terminal relay must add
writer authorization, fencing, backpressure and connection ownership; a local
socket client is not that relay.

The diagnostic smoke harness launches dtach/Firecracker under a transient systemd
unit, giving the console process an independent lifetime. It boots the image,
asserts UID 0, detaches and reattaches, writes a synthetic marker, performs orderly
shutdown, starts again with the same disk and checks the marker. It discards
console data and reports fixed result messages, then stops its own unit and
removes its unique temporary directory on success or failure. It does not launch
untrusted customer workloads or establish the production jailer/network boundary.

For this x86 smoke test, use guest `reboot` with `reboot=k` to request orderly
shutdown and terminate Firecracker. Firecracker does not emulate ACPI poweroff:
`poweroff` halts the OS but leaves the VMM process alive. Future control-plane
stop can use the documented `SendCtrlAltDel` action, but guest-initiated halt/
reboot intent, cancellation and recovery still require lifecycle reconciliation.
Never release capacity merely because a console says shutdown completed.

Lilly uses the same JSON logger and correlation-metadata allowlist as Marshall.
Console bytes are not logged; the smoke test normalizes carriage returns only
inside assertions, while the actual console client preserves the raw stream.

## Alternatives

A host-rootfs-dependent image would not be reproducible. The upstream ext4
helper alone retains changing timestamps/hash seed; its first rebuild differed.
A compressed kernel fails on the pinned Firecracker release. A PTY owned by a
Lilly process would violate console survival on restart. Guest `poweroff` is not
proof that an x86 Firecracker process terminated.

## Consequences

The initial root image is approximately 1.35 GiB; the 2 GiB admission floor leaves
room for guest state. Boot is a complete NixOS startup, not a promised subsecond
readiness target. Distribution/cache management and the execution contract
remain necessary before remote provisioning is exposed.

The local client and smoke test establish console/image primitives. Production
execution still needs the jailer, per-VM identities, durable manifests, systemd
units reconciled by VM actors and authenticated operation/generation handling.
A byte-identical rootfs rebuild does not validate networking or VM isolation.

## Invariants and verification

- Rebuild the rootfs derivation with Nix `--check`; it must compare equal.
- Boot the artifact with the pinned Firecracker on real KVM and verify UID 0.
- Reattaching the console preserves the process and its guest state.
- After confirmed VMM exit, starting the same disk preserves the marker.
- Packet encoding preserves arbitrary binary input order and rejects oversized
  messages before sending any bytes.
- The harness leaves no service/process/disk behind and emits no console dumps.

## Implementation evidence

[Guest configuration](../../../nix/packages/guest/configuration.nix) and
[image derivation](../../../nix/packages/guest/default.nix) define the image.
[Devenv output](../../../devenv.nix) reuses the pinned package input.
The console client and its property tests implemented the bounded local
protocol. [Smoke harness](../../../lilly/scripts/smoke_guest.exs) exercises
real guest boot, root access, reattachment and disk persistence.
[Lilly logging](../../../lilly/config/config.exs) emits JSON metadata.

The [execution review](../reviews/2026-09-15-guest-console.md) records successful
local KVM and reproducibility results.
[ADR-0015](0015-jailed-execution-and-host-networking.md) and its
[jailed smoke](../../../lilly/scripts/smoke_jailed.exs) add static musl VMM builds,
per-VM confinement and physical networking. VM actors, remote lifecycle
reconciliation/recovery and cross-host tests remain open.

[ADR-0012](0012-provisioner-control-transport.md) and
[ADR-0013](0013-capacity-collection-and-local-receipt.md) implement authenticated
transport and receipt. [ADR-0014](0014-image-and-address-admission.md) implements
catalog registration, artifact integrity and host image availability.

## Open questions

The image catalog/verification and execution protocol now have implementation
under ADRs 0014–0017; source-built Nix closures supply the immutable artifacts
under ADR-0030. The real [guest suite](../../../nix/tests/machines/zfs-guest/default.nix) and
[fleet](../../../nix/tests/machines/fleet/default.nix) exercise jailer/systemd/manifest integration.
Define how guest-initiated
shutdown and reboot communicate intent to Lilly without using terminal output
as an authority. Provide independent physical failure domains and workload targets.

## Related decisions

[ADR-0004](0004-lilly-and-vm-actors.md),
[ADR-0005](0005-vm-lifecycle-and-storage.md),
[ADR-0007](0007-profile-networking.md),
[ADR-0008](0008-identity-sharing-and-terminal.md),
[ADR-0009](0009-assurance-and-testing.md),
[ADR-0010](0010-capacity-admission-transactions.md),
[ADR-0076](0076-default-guest-toolset.md).

## Amendment 2026-09-19: serial console retired from terminal duty

The dtach-owned serial console was removed by
[ADR-0082](0082-guest-terminal-multiplexer.md): Firecracker stdio appends to a
read-only boot log, the root ttyS0 autologin is gone from both guests, and
terminals ride the guest vsock multiplexer. The image, manifest and jailer
requirements of this decision are unchanged.

## Amendment 2026-09-22: provisioned guest SSH

[ADR-0093](0093-audi-mediated-guest-ssh.md) adds conditional, hardened root SSH
to standard guests using the Porsche session key at initial provision. It does
not restore a serial login or replace the terminal-v2 vsock path. That SSH
mechanism is superseded by [ADR-0110](0110-cedar-guest-ssh-accounts.md), which
uses current Cedar grants and per-user guest accounts.
