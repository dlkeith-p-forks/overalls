# Mirrored ZFS installation and UEFI

## Scope and evidence

This change implements the reusable installation boundary in ADR-0030 with
ADR-0031 storage policy, and adds ADR-0033 firmware tests and ADR-0032
image-identity evidence. The accepted
architecture remains unchanged. The exact
existing reference host's configuration and external disko test are not present
in the worktree; their location has been requested. Generic bootstrap inputs
are explicitly identified and are not claimed to preserve that host's inventory.
No physical host has been partitioned, installed or activated.

The [storage module](https://github.com/antithesishq/kittens/blob/16e8dbe4a8871df015fa9853febf1a1e7e99e29b/nix/modules/mirrored-zfs.nix) imports locked disko,
requires two distinct declared disks and a persistent nonzero host ID, and
separates root and Lilly datasets. It declares a mirror, LZ4, zero reservations,
dedup off, standard sync, a quota and the reference ARC cap. Two EFI filesystems
receive removable-path GRUB loaders. Missing EFI devices do not block normal
mount completion; root import is not forced. Numerical tuning in ADR-0034 stays
proposed.

The [generic QEMU target](https://github.com/antithesishq/kittens/blob/16e8dbe4a8871df015fa9853febf1a1e7e99e29b/nix/machines/bootstrap.nix) reaches pinned-key
SSH with both applications disabled. The [installer](https://github.com/antithesishq/kittens/blob/16e8dbe4a8871df015fa9853febf1a1e7e99e29b/nix/machines/installer.nix)
contains the full target closure for offline installation and requires its
explicit destructive flag. Disk formatting remains outside activation. New
private SSH identities are generated at boot, and no private credentials or
test-console service are included in exported configurations.

The [machine suite](../../../nix/tests/machines/mirrored-installation/default.nix) uses test variants of
these actual modules with console instrumentation and reduced disk/ARC/quota
budgets. It boots from ISO and installed disks through OVMF with forced KVM,
without a direct kernel or shared host Nix store. It checks independent EFI
loaders, root identity, storage policy, new/persistent SSH identity, data and
actual SSH key authentication on both the healthy mirror and each degraded
surviving-disk branch. Forks are never rejoined after independent writes.

The [exported-image suite](https://github.com/antithesishq/kittens/blob/16e8dbe4a8871df015fa9853febf1a1e7e99e29b/nix/tests/machines/bootstrap-images/default.nix) separately
boots the exact public QCOW2 artifacts through OVMF. It attaches no direct kernel
or shared store and injects no credentials or test-console service. It observes
the public SSH identity through a loopback-only QEMU port forward: independent
fresh copies must differ; reboot and both single-disk branches must preserve the
first copy's identity. Authenticated sessions and in-guest assertions belong to
the instrumented installation suite above.

## Findings and disposition

1. **High, closed acceptance — installed firmware boot.** The repository previously
   had no host installer/disk output or firmware boot suite. The modules and
   exported checks are now defined, and the complete firmware installation test
   passed. This closes generic virtual installation and both surviving-disk boot
   acceptance; it does not establish physical-host or fleet acceptance.
2. **Medium, fixed — duplicate dataset input failed during attribute construction.**
   The initial negative check hit a duplicate dynamic Nix attribute before the
   explanatory module assertion. Construction now omits the colliding child so
   the dedicated assertion rejects the invalid configuration clearly.
3. **Medium, environment failure — Nix worker aborted.** Separate daemon-backed
   image and installation builds terminated with Nix 2.35.1's internal
   `!awake.empty()` assertion. Their process handles confirmed failure; these
   are not successful builds. Retrying through the local store with one build
   job built the test ISO successfully. No Nix daemon or production service was
   restarted.
4. **Medium, fixed test defect — QEMU disk serial option.** The first VM launch
   failed before boot because the fixture passed `serial` as a QCOW2 drive
   option. A bounded QEMU probe exposed the rejected argument. The fixture now
   attaches a separate virtio block device with its serial property. Firmware
   and KVM requirements are unchanged; the failed launch is not boot evidence.
5. **High, fixed implementation defect — installer executable selection.** The
   first firmware boot succeeded and the no-flag check left both disks blank.
   Installation then failed because the wrapper invoked disko's package
   directory. It now selects the declared executable with `lib.getExe`, as the
   locked disko API requires. No formatting occurred in that failed attempt.
6. **Medium, fixed test defect — OpenSSH diagnostic assumptions.** The next
   run installed successfully, verified store contents and authenticated over
   SSH on the healthy mirror. The first surviving disk booted degraded with
   the same data/key, then the diagnostic `sshd -T` check failed. NixOS starts
   sshd with an explicit `/etc/ssh/sshd_config`; selecting that file alone did
   not fix the assertion in the following run. Inspection of the built file
   and the pinned OpenSSH 10.5p1 executable's effective configuration showed
   passwords correctly disabled: this version prints setting names with capitals,
   while the assertion required lowercase. The fixture now checks successful
   diagnostic execution before comparing case-normalized setting lines from the
   service's actual configuration. It checks password, keyboard-interactive and
   root authentication policy on the installer and healthy boot as well as each
   survivor. Store verification is also unconditional. Neither failed diagnostic
   establishes that the deployed daemon enabled password authentication.
7. **Medium, open requirement — reference-host reconciliation and fleet tests.**
   The existing physical disk/network/host-ID inputs and external mirrored-boot
   fixture still need importing/reconciliation. Three-Marshall/two-Lilly guest
   coordination, pressure, provider and physical failure-domain acceptance also
   remain outstanding. This generic install work does not narrow those goals.
8. **Low, fixed fixture type error — optional QEMU process.** The exported-image
   driver initially failed NixOS's type gate before any VM launched because its
   process handle can be absent before startup. The fixture now explicitly
   requires and retains the started handle before polling or waiting on it.
   The type gate remains enabled. Runtime acceptance is recorded separately.
9. **High, fixed and verified — exported root pool left active.**
   The first exact-artifact boot timed out before SSH. Its captured display
   showed the real initrd failing to import `zroot`. The locked disko builder
   unmounts the installed target but does not export its pool, and Nixpkgs's
   minimal builder init powers off forcibly. The installer fixture had explicitly
   exported its pool, so its passing result did not cover this distinct path.
   The module now exposes `system.build.kittensMirroredImages`, extending the
   in-VM build command with a clean root-pool export; the public flake output
   selects it. Normal `forceImportRoot = false` behavior remains required.
   The locked VM wrapper returns a plain derivation; `lib.overrideDerivation`
   appends to its guest `buildCommand`, not the host-side `postVM` hook.
   The exact exported-image test passed against freshly built artifacts,
   including first boot, unique fresh identities, reboot and both surviving disks.

## Verification

- Storage module configuration check passed **22 cases**, including actual mirror,
  EFI, LZ4, reservation, quota, ARC, SSH and service-independence definitions,
  plus duplicate disk/dataset, missing/zero host ID and system-mount rejection.
  Four exported-installer checks cover its
  module assertions, pinned-key SSH policy, absent test console and offline target
  closure.
- Contract validation passed for **48 CONTRACTS files, 356 native notes and
  441 maintained sources**. The ADR checker passed **34 decisions**. These are
  structural checks, separate from the runtime acceptance below.
- Generic ISO and QCOW2 derivations evaluate. The first daemon-backed build
  attempts failed as described above. The instrumented test ISO then built
  successfully through the local store. Its first VM launch failed on the
  corrected QEMU argument. The next run booted the ISO through firmware and
  verified no-flag refusal, then found the corrected installer wrapper defect.
  The subsequent run completed installation, healthy-mirror boot/store/SSH
  checks and the first degraded boot before finding the SSH diagnostic defect;
  another run reproduced its output-casing mismatch with the explicit config.
- The final full `mirrored-installation` check passed in **522.35 seconds**:
  real ISO/UEFI boot, no-flag refusal on blank disks, offline installation, both
  EFI loader files, healthy installed boot without ISO, unconditional store
  content verification and actual SSH authentication. Both independently forked
  single-disk boots then passed root/data/key, degraded-pool and SSH checks.
  Password and keyboard-interactive authentication remained disabled on every
  boot. No direct kernel or shared host store was attached. All test QEMU
  processes exited normally. The test variant disables the instrumentation
  module's password-file override, preserving the target's
  own account policy while retaining its test console.
- The exported `bootstrap-disks` and `installer-iso` builds passed through the
  local store with one build job. Each QCOW2 disk has **32 GiB virtual capacity**
  and occupies approximately **1.1 GiB**, with no backing file. The ISO is
  **1,517,780,992 bytes** and contains the complete offline target closure.
  Exported configurations exclude test-console instrumentation. The first exact
  exported-image boot check found the import failure above; the public output
  now selects the corrected clean-export build. Both corrected QCOW2 artifacts
  passed `qemu-img check` with zero errors. The ISO installation path is unchanged.
- The final `bootstrap-images` check passed in **279.40 seconds** against the
  exact public disk artifacts, with forced KVM and five OVMF boots: first copy,
  independent fresh copy, reboot, and each surviving mirror disk. Fresh copies
  produced different public Ed25519 identities; reboot and both survivors
  retained the original identity. All five VMs powered off through ACPI and
  exited normally. No test-console service, credentials, direct kernel or host
  store was injected. This check observes the SSH identity externally; it does
  not authenticate as the operator or replace the instrumented storage checks.
- The final installer, storage-configuration and ISO derivations remain identical
  to their passing builds. No Elixir project source changed in this installation
  work; earlier project gates are recorded in the storage and I/O reviews.

## Follow-up

Reconcile the existing host configuration once available. Continue the full
fleet and physical/provider acceptance requirements. The entire plan remains
in progress.

Implementation references: [locked disko image builder](https://github.com/nix-community/disko/blob/ff8702b4de27f72b4c78573dfb89ec74e36abdf1/lib/make-disk-image.nix),
[NixOS GRUB mirrored boot definitions](https://github.com/NixOS/nixpkgs/blob/c3eea5b2156db11c7eeeada3dc737711255b253e/nixos/modules/system/boot/loader/grub/grub.nix).
