# Guest operating-system matrix

The shared [fleet image list](../../fleet/guest-images.nix) declares seven OS
families. Its selected-package admission filter now yields seven catalog
entries: `omniosGuest` and `illumosGuest` select the exact reviewed immutable
OmniOS promotion. Catalog declaration, deployment, staged artifacts, native machine
execution and live fleet acceptance are separate evidence scopes.

| Family | Selected package | Boot and agent contract | Current evidence and limit |
|--------|------------------|-------------------------|----------------------------|
| NixOS | `guest` | Linux kernel, version 4, `linux` | Exact selected `92114604` passed fresh `101111` strict personal-account CLI SSH, stop with separate stopped checkpoint, restart, repeat SSH and deleted cleanup. Existing native scopes remain separate; see [ADR-0011](../architecture/decisions/0011-nixos-guest-and-console.md). |
| Ubuntu 26.04 LTS | `ubuntuGuest` | Linux kernel, version 4, `linux` | Unchanged selected `8d468c67` retains the `075200` complete strict CLI lifecycle/deleted-cleanup evidence and final immutable artifact custody; see the [Ubuntu guide](ubuntu-guests.md). |
| Arch Linux | `archGuest` | Linux kernel, version 4, `linux` | Earlier mode/LSM repairs and the root-policy override passed offline checks. Fresh `105935` image `8ab89c2d` reached readiness but strict personal SSH closed during authentication. Boot-bound diagnostics found successful NSS lookup and PAM startup, account refusal and the missing pinned PAM helper. Its owned fixture was deleted; rebuilt helper image `99fa9876` passes offline and isolated checks, with fresh lifecycle pending. |
| AlmaLinux | `almaLinuxGuest` | Linux kernel, version 4, `linux` | The resolver/identity bundle passes actual artifact, sysusers and native parser checks. Fresh `112332` image `bed87c33` reached readiness but strict personal SSH closed during authentication. Shared immutable assembly lacks the same helper diagnosed in Arch; no independent Alma PAM root probe is recorded. Its owned fixture was deleted; rebuilt helper image `473f9589` passes offline and isolated checks, with fresh lifecycle pending. |
| FreeBSD 14.3 | `freebsdGuest` | CloudHv firmware, raw GPT/UFS, version 6, `freebsd-v1` | Exact promoted image; five native scenarios passed. Runs `072900` and `075200` passed CLI lifecycle and terminal deleted cleanup. The later cleanup required scoped idle rootless-namespace recovery; that manual recovery does not establish general automatic cleanup. |
| OmniOS r151050 | `illumosGuest` | CloudHv firmware, raw GPT/ZFS, version 6, `illumos-v1` | Exact promoted image is selected and admitted. Disk `45983bb7` passed all five direct host-KVM scenarios, ordinary transport and reset. Separate run `091638` passed the 16 GiB ordinary CLI lifecycle and terminal deleted cleanup after the strict release-label oracle correction. |
| Windows Server 2025 | `windowsGuestPublished` | CloudHv firmware, raw GPT, version 5, `windows-v1` | Repaired `8ca0a11f` passed installation, sealing, executable readback, signed publication and independent full-content substitution. Fresh `103842` passed create/readiness, exact strict CLI SSH, stop with separate stopped checkpoint, restart, repeat SSH and deleted cleanup. Its original warning-only failure is preserved; the runner admits only the exact stock Windows warning without changing trust/algorithms. Terminal, executor, workspace, growth and isolation remain separate. See the [Windows guide](windows-guests.md). |

The helper repair following the Arch/Alma rows' failed SSH attempts is now implemented in exact
rebuilt Arch `99fa9876` and Alma `473f9589` images. The root-only guest oneshot
recreates only pinned PAM's compiled `unix_chkpwd` helper before SSH, preserving
owned key-only policy and existing nosuid mounts. Actual-image custody,
independent rootfs/package rebuilds and the isolated VM root-account
success/expiry/unsafe-path checks passed. These are separate from fresh guest
SSH/sudo and lifecycle acceptance, which remain pending.

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
