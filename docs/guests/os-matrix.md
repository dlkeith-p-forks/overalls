# Guest operating-system matrix

The shared [fleet image list](../../fleet/guest-images.nix) declares seven OS
families. Its native admission filter currently yields six catalog entries:
OmniOS remains excluded. Catalog declaration, staged artifacts, native machine
execution and live fleet acceptance are separate evidence scopes.

| Family | Selected package | Boot and agent contract | Current evidence and limit |
|--------|------------------|-------------------------|----------------------------|
| NixOS | `guest` | Linux kernel, version 4, `linux` | Existing native and fleet journeys cover the standard Linux path; see [ADR-0011](../architecture/decisions/0011-nixos-guest-and-console.md). |
| Ubuntu 26.04 LTS | `ubuntuGuest` | Linux kernel, version 4, `linux` | Existing native and fleet journeys retain their recorded scopes; see the [Ubuntu guide](ubuntu-guests.md). |
| Arch Linux | `archGuest` | Linux kernel, version 4, `linux` | Pinned Arch bootstrap root, distribution identity and agent/service closure have evaluation coverage. No Arch Firecracker boot or live lifecycle pass is recorded. |
| AlmaLinux | `almaLinuxGuest` | Linux kernel, version 4, `linux` | Pinned AlmaLinux cloud root, distribution identity and agent/service closure have evaluation coverage. No AlmaLinux Firecracker boot or live lifecycle pass is recorded. |
| FreeBSD 14.3 | `freebsdGuest` | CloudHv firmware, raw GPT/UFS, version 6, `freebsd-v1` | Only the exact reviewed promoted image is admitted. Five native scenarios passed. The current live subset passed create, exact OS identity over CLI SSH, orderly stop, restart, repeat SSH and cleanup receipts. |
| OmniOS r151050 | `illumosGuest` | CloudHv firmware, raw GPT/ZFS, version 6, `illumos-v1` | Excluded from catalog admission. The handshake-fixed image passed direct host-KVM transport/reset/Lilly-policy, complete services, three-boot/two-expansion growth and process-crash fixtures; supervised daemon recovery still fails. Earlier image receipts retain separate scope. |
| Windows Server 2025 | `windowsGuestPublished` | CloudHv firmware, raw GPT, version 5, `windows-v1` | The current catalog selects a sealed recursive-hash 64 GiB Desktop Experience image with agents and a 96 GiB template budget. Publication custody is separate from native and named-fleet evidence; the complete current-image stop/restart/delete journey remains unrecorded. See the [Windows guide](windows-guests.md). |

The [foreign Linux evaluation](../../nix/verification/tests/evaluation/foreign-linux-guests.nix)
checks the Arch/Alma inputs, manifests and offline closure. It does not execute
either distribution. Distribution display names and the website's OS labels
also do not prove what kernel or root actually ran.

The admitted FreeBSD image ID is
`sha256:d141e4266c29da00a1378157b1d39369b1d48e577bca4ce7375e8ff6d399557b`.
The [compiled registry](../../protocol/lib/overalls_protocol/native_admission.ex)
requires its complete validated identity; a family name, image ID alone, stock
disk or changed candidate cannot activate native capabilities. Unqualified
`freebsd-v1` and `illumos-v1` rows remain all false. Exact FreeBSD qualification
enables readiness, trust, terminal, workspace, flush, SSH and agent execution;
editor and Inception remain disabled. Windows also keeps editor and Inception
disabled. Inception is known broken and outside this acceptance work.

[ADR-0190](../architecture/decisions/0190-native-kernel-provenance-and-admission.md)
and the [native admission review](../architecture/reviews/2026-10-17-native-image-admission.md)
govern the exact FreeBSD promotion. The [native kernel review](../architecture/reviews/2026-10-17-native-kernel-attestation.md)
records full artifact identities and the scoped OmniOS receipts. None of those
records establishes direct native peer-VM or physical-host isolation,
interrupted growth, physical durability, relocation or seven-OS fleet acceptance.

The opt-in [Porsche acceptance runner](../acceptance/porsche-acceptance.md)
provides a separate path to collect live catalog, creation, SSH OS-identity and
lifecycle evidence using explicit image IDs. A complete seven-OS run requires
all seven images to be admitted and available first; this guide does not relax
the OmniOS gate to make that run possible.
