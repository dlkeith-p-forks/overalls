# Multi-OS guest image architecture review (2026-10-16)

## Scope

This review covers the Arch Linux and AlmaLinux image builders, the preliminary
FreeBSD/OmniOS builder and catalog entries, and the shared protocol/Lilly
extension for native FreeBSD and OmniOS (the `illumos` protocol family), including
the validated source-artifact selection tests added after the initial contract review. It
reconciles the work with ADR-0011/0068, ADR-0146/0159 and the Windows decisions
ADR-0169 through ADR-0173. The FreeBSD source endpoint is retired and is
replaced by a checksum-pinned archive capture; local Nix realization now
passes for both native builders, but neither family has a recorded runtime
execution.

## Architecture impact

The change is architectural. Arch and Alma add catalog families while keeping
the Linux version-4 boot contract. FreeBSD and OmniOS add version-6 manifest and
version-3 bundle shapes and conditional Lilly launch metadata. ADR-0180 records
the contract; this review separates implementation from planned native guest
support.

## Findings

### 1. Arch and Alma preserve the Linux boundary — resolved

The two builders use the version-4 manifest and the reviewed Linux kernel/initrd
boot contract, while assembling their roots from separate pinned Arch bootstrap
and AlmaLinux cloud inputs. Their `arch` and `almalinux` markers are
deterministic inputs to the image identity, and both are catalogued as
Linux catalog entries without standby metadata. The evaluation check inspects the version-4
kernel/root shape and source format. It does not boot either image or prove
distro-native service behavior.

Evidence: `nix/packages/guest/foreign-linux.nix`,
`nix/packages/guest/arch/default.nix`, `nix/packages/guest/alma/default.nix`,
`fleet/guest-images.nix` and `nix/tests/evaluation/foreign-linux-guests.nix`.

### 2. Native protocol shapes are explicit — resolved with implementation gap

Version 6 names FreeBSD or `illumos`, binds each OS to its agent set, validates
bounded artifacts and rejects extra keys and mismatches. Both native families
use CloudHv firmware and raw-GPT roots; FreeBSD's disk retains its EFI and UFS
partitions. Version 3 bundles carry the same explicit OS and firmware metadata.
Existing Linux and Windows versions remain
separate. The protocol currently uses `illumos` for the OmniOS family; that
naming remains an open product decision.

Evidence: `protocol/lib/overalls_protocol/image_manifest.ex`,
`protocol/lib/overalls_protocol/workload_bundle.ex` and protocol tests. The
native builder evaluation is structural; no successful FreeBSD/OmniOS bundle
materialization run is recorded here.

### 3. Lilly selects transport from validated metadata — resolved with gap

Firmware bundles retain vsock only for protocol-speaking agents, apply Hyper-V
only to the Windows default and leave the native FreeBSD/illumos CPU model
unmodified. The jailer,
network guard, seccomp and storage boundaries remain shared. The focused jail
unit test covers native FreeBSD firmware configuration; it does not
start a Firecracker guest.

Evidence: `lilly/lib/lilly/vm/jail.ex`,
`lilly/lib/lilly/vm/workload_bundle.ex`, `lilly/test/vm/jail_test.exs` and
`lilly/test/host/image_test.exs`. The host image tests verify that FreeBSD
selects `disk.raw` for both native families while Lilly keeps its
internal persistent destination name; they do not realize an image or launch a
guest.

### 4. Preliminary native builders are not runtime proof — open

`native.nix` exposes FreeBSD 14.3 and OmniOS r151050 builders and the fleet
catalog contains both entries without standby metadata; its `OmniOS r151050` row
consumes the explicit `illumosGuest` constructor. The generic `illumos`
constructor selects that pinned OmniOS downstream image and
records `https://illumos.org/` as its upstream project. illumos.org publishes
the operating-system source and identifies OmniOS, OpenIndiana and Tribblix as
installable distributions; it does not publish a standalone guest root image.
The FreeBSD source uses a retired `Latest` endpoint through a checksum-pinned archive capture and the
builder preserves the complete EFI/GPT/UFS disk before writing the manifest. A local
Nix build of both packages succeeds; this is artifact evidence only and does
not establish native boot or fleet readiness.

### 5. Capability rows are contract surface, not runtime proof — open

`freebsd-v1` and `illumos-v1` are declared with the Windows capability flags and
600-second budget. No native agents, successful image output, Marshall capability
projection, guest readiness or fleet acceptance exists for either family. The
rows must remain partial until those artifacts and tests land.

## Verification boundary

The Arch/Alma and native builder evaluations plus the focused protocol/Lilly
tests and source-artifact selection tests provide structural and bounded unit
evidence. They do not establish a boot, guest isolation,
network, storage growth, recovery, relocation, SSH, terminal, workspace or
independent-host result for FreeBSD, OmniOS or Arch/Alma. The existing NixOS,
Ubuntu and Windows records retain their own scopes and are not evidence for the
new native families.

## Follow-up

Build signed FreeBSD and OmniOS/illumos images, decide whether OmniOS remains
under the `illumos` wire name, implement and test their agents, then add nested
KVM machine scenarios for boot, MMDS/vsock identity, isolation, storage growth,
restart and recovery. Add Marshall-driven fleet journeys before claiming
readiness, terminal, workspace, relocation or availability.

Structural checks for this documentation change are `elixir scripts/check_adrs.exs`,
`elixir scripts/check_hldd.exs`, `elixir scripts/hldd_coverage.exs --check` and
`elixir scripts/hldd_views.exs --check`. These checks do not add native runtime
evidence.
