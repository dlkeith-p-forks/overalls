# NixOS guest and console execution review

## Scope and evidence

Build and boot the initial NixOS guest, implement a bounded local dtach client,
and verify disk persistence and console reattachment on real KVM. Review
[ADR-0011](../decisions/0011-nixos-guest-and-console.md) for the contract and code
links. Affected ADRs: ADR-0004, ADR-0005, ADR-0008, ADR-0009, ADR-0010 and ADR-0011.
This is implementation within the already authorized platform plan.

## Findings and resolutions

- **Resolved, release compatibility:** Firecracker 1.16.1 rejects a compressed
  kernel. Its tagged documentation requires ELF. Use Linux 6.12.104 `vmlinux`
  with its matching initrd; do not infer release capabilities from upstream main.
- **Resolved, reproducibility:** the first ext4 rebuild differed. Normalize source
  timestamps, ext4 time and directory-hash seed. The revised rootfs passed a
  separate `nix-store --realise --check --keep-failed` rebuild byte for byte.
- **Resolved, test assertion:** the guest serial TTY and host PTY can both add
  carriage returns. Normalize them only in readiness assertions; preserve actual
  terminal bytes in the client.
- **Required lifecycle follow-up:** guest `poweroff` halts x86 Linux but does not
  terminate Firecracker. The test now uses the documented i8042 reset path for
  orderly shutdown. Production stop/recovery must reconcile process termination
  and desired state; it must never free reservations based on console text.
- **Required production follow-up:** the harness is an isolated image diagnostic
  with no guest network interface. It uses direct Firecracker under systemd,
  not the production jailer/UID/manifest/actor integration. No claim of VM
  isolation, Lilly actor recovery, Internet access or cross-host behavior follows.

## Verification

Local root access opened KVM API version 12 and successfully created an empty
KVM VM. The user account itself lacks KVM permissions, so the smoke harness ran
through `sudo` with the pinned Elixir runtime and explicit Nix executable paths.

The real smoke test passed: NixOS boot; root UID; serial write/read; console
close/reattach; a disk marker retained after orderly VMM shutdown and a fresh
start from the same writable disk. It removed its temporary image and transient
systemd unit. Console bytes were discarded, not logged or printed on failure.

Verified artifact:

- Output: `/nix/store/pswrah53wwvsb5kkh8hk6djrii2cs1p0-lilly-nixos-x86_64`
- Rootfs: 1,444,937,728 bytes
- Rootfs SHA-256: `cda59da72e33d8e8986e4d6c32054dda00e6c1ebd72aa38aa5c0a8a52c3b640f`
- Firecracker 1.16.1, Linux 6.12.104, 1 vCPU, 512 MiB RAM
- Pinned dtach revision `b027c27b2439081064d07a86883c8e0b20a183c9`
- The rootfs derivation rebuilt successfully with Nix `--check` after normalization.

Final gates passed after logging and image-size limits were updated:

- Marshall `mix precommit`: 40 tests and four properties, including three
  independent BEAM instances, atomic admission/rollback, idempotency, Cedar and
  initial guest minimum-size rejection.
- Lilly `mix precommit`: nine tests and three properties; no Dialyzer errors or
  exclusions. Startup emitted a JSON `lilly.started` event through the configured
  formatter, with no terminal payload.
- Both applications used Elixir 1.20.4 / OTP 29.0.6. Marshall retains its one
  exact upstream AshAuthenticationPhoenix typespec exclusion, with no new or
  unused filters.
- Schema/snapshot check passed after the admission size-limit changes. ADR
  validation passed for 11 records; formatter and `git diff --check` passed.
- The final smoke harness completed and its transient unit/process/directory
  were absent afterward. Original-workspace file hashes were checked again;
  unrelated existing assets and generated components remain intact.

ADRs, their index and the overview now distinguish these verified primitives
from production execution and the remaining cross-host requirements.

## Sources

[Firecracker 1.16.1 kernel documentation](https://github.com/firecracker-microvm/firecracker/blob/v1.16.1/docs/rootfs-and-kernel-setup.md),
[Firecracker actions](https://github.com/firecracker-microvm/firecracker/blob/v1.16.1/docs/api_requests/actions.md),
[Firecracker shutdown FAQ](https://github.com/firecracker-microvm/firecracker/blob/v1.16.1/FAQ.md),
[pinned dtach protocol](https://github.com/crigler/dtach/blob/b027c27b2439081064d07a86883c8e0b20a183c9/dtach.h),
[devenv outputs](https://devenv.sh/outputs/), and the pinned local NixOS modules.

## Completion audit and follow-up

Guest/console primitives have execution evidence on one host. The complete
platform goal remains active. Next: authenticated Lilly control/report protocol,
image catalog and address validation, jailer/systemd/actor reconciliation,
networking/isolation, lifecycle/recovery, sharing/terminal leases, archival and
secret management, telemetry retention, and the second-host tests.
