# Guest operating-system matrix

The shared [fleet image list](../../fleet/guest-images.nix) declares seven OS
families. Its selected-package admission filter now yields seven catalog
entries: `omniosGuest` and `illumosGuest` select the exact reviewed immutable
OmniOS promotion. Catalog declaration, deployment, staged artifacts, native machine
execution and live fleet acceptance are separate evidence scopes.

All seven selected immutable images now have separately recorded successful
create/readiness, strict personal-account CLI SSH, stop with an independent
current-owner stopped checkpoint, same-VM restart, repeated strict SSH and
completed deletion. The [matrix review](../architecture/reviews/2026-10-18-guest-os-matrix.md)
binds the 49 stage receipts at their distinct times and execution revisions.

| Family | Selected package | Boot and agent contract | Current evidence and limit |
|--------|------------------|-------------------------|----------------------------|
| NixOS | `guest` | Linux kernel, version 4, `linux` | Exact selected `92114604` passed fresh `101111` strict personal-account CLI SSH, stop with separate stopped checkpoint, restart, repeat SSH and deleted cleanup. Existing native scopes remain separate; see [ADR-0011](../architecture/decisions/0011-nixos-guest-and-console.md). |
| Ubuntu 26.04 LTS | `ubuntuGuest` | Linux kernel, version 4, `linux` | Unchanged selected `8d468c67` retains the `075200` complete strict CLI lifecycle/deleted-cleanup evidence and final immutable artifact custody; see the [Ubuntu guide](ubuntu-guests.md). |
| Arch Linux | `archGuest` | Linux kernel, version 4, `linux` | Fresh helper-fixed `99fa9876` in run `114223` passed create/readiness, strict personal SSH and read-only sudo/helper checks, stop with an independent current-owner stopped checkpoint, restart with repeated strict SSH/checks and completed deletion. Earlier `8ab89c2d` reached readiness but failed SSH at PAM account management; that failed fixture and its cleanup retain separate receipts. |
| AlmaLinux | `almaLinuxGuest` | Linux kernel, version 4, `linux` | Fresh helper-fixed `473f9589` in run `114223` passed create/readiness, strict personal SSH and read-only sudo/helper checks, stop with an independent current-owner stopped checkpoint, restart with repeated strict SSH/checks and completed deletion. Earlier `bed87c33` reached readiness but failed SSH during authentication; it shares Arch's immutable helper omission, with no separate Alma PAM root probe recorded. Historical failure and cleanup receipts remain separate. |
| FreeBSD 14.3 | `freebsdGuest` | CloudHv firmware, raw GPT/UFS, version 6, `freebsd-v1` | Exact promoted image; five native scenarios passed. Runs `072900` and `075200` passed CLI lifecycle and terminal deleted cleanup. The later cleanup required scoped idle rootless-namespace recovery; that manual recovery does not establish general automatic cleanup. |
| OmniOS r151050 | `illumosGuest` | CloudHv firmware, raw GPT/ZFS, version 6, `illumos-v1` | Exact promoted image is selected and admitted. Disk `45983bb7` passed all five direct host-KVM scenarios, ordinary transport and reset. Fresh `122228` passed the full 16 GiB strict CLI lifecycle, separate current-owner stopped checkpoint and completed deletion. Earlier `091638` retains its own lifecycle and original release-label oracle failure; it lacked that separate checkpoint. |
| Windows Server 2025 | `windowsGuestPublished` | CloudHv firmware, raw GPT, version 5, `windows-v1` | Repaired `8ca0a11f` passed installation, sealing, executable readback, signed publication and independent full-content substitution. Fresh `103842` passed create/readiness, exact strict CLI SSH, stop with separate stopped checkpoint, restart, repeat SSH and deleted cleanup. Its original warning-only failure is preserved; the runner admits only the exact stock Windows warning without changing trust/algorithms. Terminal, executor, workspace, growth and isolation remain separate. See the [Windows guide](windows-guests.md). |

The helper repair following the Arch/Alma rows' failed SSH attempts is now implemented in exact
rebuilt Arch `99fa9876` and Alma `473f9589` images. The root-only guest oneshot
recreates only pinned PAM's compiled `unix_chkpwd` helper before SSH, preserving
owned key-only policy and existing nosuid mounts. Actual-image custody,
independent rootfs/package rebuilds and the isolated VM root-account
success/expiry/unsafe-path checks passed. The exact rebuilt images subsequently
passed fresh guest SSH/sudo and lifecycle acceptance in `114223`, including
the same reviewed read-only checks after restart. Runtime helper storage remained
nosuid; the result establishes the observed root PAM/sudo paths, not direct
unprivileged helper setuid elevation.

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
interrupted growth, physical durability, relocation or acceptance of every
enabled capability. The scoped SSH/lifecycle milestone does not complete every
requirement of the custom native-kernel plan; ADR-0190 remains accepted/partial.

The opt-in [Porsche acceptance runner](../acceptance/porsche-acceptance.md)
provides a separate path to collect live catalog, creation, SSH OS-identity and
lifecycle evidence using explicit image IDs. The seven families were executed
as separate identity-bound journeys; no simultaneous same-revision seven-OS
run is claimed. New runs still require every selected image to pass the
selected-package admission and live availability gates.
