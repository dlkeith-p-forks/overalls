# Guest operating-system matrix

The shared [fleet image list](../../fleet/guest-images.nix) declares seven OS
families. Its selected-package admission filter now yields seven catalog
entries: `omniosGuest` and `illumosGuest` select the exact reviewed immutable
OmniOS promotion. Catalog declaration, deployment, staged artifacts, native machine
execution and live fleet acceptance are separate evidence scopes.

| Family | Selected package | Boot and agent contract | Current evidence and limit |
|--------|------------------|-------------------------|----------------------------|
| NixOS | `guest` | Linux kernel, version 4, `linux` | Existing native and fleet journeys cover the standard Linux path; see [ADR-0011](../architecture/decisions/0011-nixos-guest-and-console.md). |
| Ubuntu 26.04 LTS | `ubuntuGuest` | Linux kernel, version 4, `linux` | Existing native and fleet journeys retain their recorded scopes; see the [Ubuntu guide](ubuntu-guests.md). |
| Arch Linux | `archGuest` | Linux kernel, version 4, `linux` | Original live creation exposed lost executable source modes before init. Corrected actual inode/policy audits and independent cross-host rebuilds pass; the corrected live lifecycle remains separate. |
| AlmaLinux | `almaLinuxGuest` | Linux kernel, version 4, `linux` | Original live creation exposed the same lost executable source modes before init. Corrected actual inode/policy audits and independent cross-host rebuilds pass; the corrected live lifecycle remains separate. |
| FreeBSD 14.3 | `freebsdGuest` | CloudHv firmware, raw GPT/UFS, version 6, `freebsd-v1` | Exact promoted image; five native scenarios passed. Run `072900` passed CLI lifecycle/cleanup. Later `075200` passed through repeated SSH after restart, but cleanup remains failed/unconfirmed. |
| OmniOS r151050 | `illumosGuest` | CloudHv firmware, raw GPT/ZFS, version 6, `illumos-v1` | Exact promoted image is selected in source. Disk `45983bb7` passed all five required direct host-KVM service/growth/policy/daemon-recovery/process-crash scenarios, ordinary transport and reset. Registry/publication passed; selected-release deployment and live CLI acceptance remain separate. |
| Windows Server 2025 | `windowsGuestPublished` | CloudHv firmware, raw GPT, version 5, `windows-v1` | Sealed recursive-hash 64 GiB Desktop Experience image; 96 GiB template budget. Run `075200` created and reported ready, but CLI SSH failed with stopped sshd; later lifecycle is unrun. See the [Windows guide](windows-guests.md). |

The [foreign Linux evaluation](../../nix/verification/tests/evaluation/foreign-linux-guests.nix)
checks the Arch/Alma inputs, manifests and offline closure. It does not execute
either distribution. Distribution display names and the website's OS labels
also do not prove what kernel or root actually ran.

The qualified FreeBSD image ID is
`sha256:d141e4266c29da00a1378157b1d39369b1d48e577bca4ce7375e8ff6d399557b`.
The [compiled registry](../../protocol/lib/overalls_protocol/native_admission.ex)
also qualifies OmniOS image
`sha256:98b23b7931bc52d55b3c5b38cc20c97c1c967be96cf301940f88b01c715530d8`.
It requires the complete validated immutable identity; a family name, image ID alone, stock
disk or changed candidate cannot activate native capabilities. Unqualified
`freebsd-v1` and `illumos-v1` rows remain all false. Exact qualification
enables readiness, trust, terminal, workspace, flush, SSH and agent execution;
editor and Inception remain disabled. Windows also keeps editor and Inception
disabled. Inception is known broken and outside this acceptance work.

[ADR-0190](../architecture/decisions/0190-native-kernel-provenance-and-admission.md)
and the [native admission review](../architecture/reviews/2026-10-17-native-image-admission.md)
govern per-image native promotion. The [OS matrix review](../architecture/reviews/2026-10-18-guest-os-matrix.md)
records the exact OmniOS promotion, publication and current source gates. The [native kernel review](../architecture/reviews/2026-10-17-native-kernel-attestation.md)
records full artifact identities and the scoped OmniOS receipts. None of those
records establishes direct native peer-VM or physical-host isolation,
interrupted growth, physical durability, relocation or seven-OS fleet acceptance.

The opt-in [Porsche acceptance runner](../acceptance/porsche-acceptance.md)
provides a separate path to collect live catalog, creation, SSH OS-identity and
lifecycle evidence using explicit image IDs. A complete seven-OS run requires
all seven images to be admitted and available first; this guide does not relax
the selected-package admission gate to make that run possible.
