# Windows Firecracker spike review

## Scope and impact

[ADR-0169](../decisions/0169-firmware-booted-windows-guests.md) adds a
firmware-booted Windows Server 2025 guest image and the platform changes it
needs: a patched static Firecracker 1.16.1, an edk2 CloudHv UEFI firmware
built as the PVH payload, an offline KVM image build from Microsoft's
hash-pinned evaluation ISO, and a standalone serial-console launcher. It
preserves ADR-0011 and ADR-0068 for the Linux images (version-4 manifests,
ELF kernel plus initrd plus ext4), ADR-0014/0016/0098 image admission (the
version-5 manifest is not admitted anywhere yet) and ADR-0113/0154 boot trust
and profile (no Windows readiness or trust path exists). No wire protocol,
database field or Lilly code changes. The only runtime change visible to the
fleet is the VMM package: same version string, static linking and syscall
surface; Linux guests see no new ACPI table entry and no new CPUID leaf unless
a custom CPU template asks for `hyperv`.

## Findings and resolutions

- **Firmware cannot find ACPI without a PVH RSDP pointer.** Firecracker's
  `configure_pvh` left `hvm_start_info.rsdp_paddr` zero; edk2's
  `InstallCloudHvTables` has no fallback. Resolved by
  `firecracker-pvh-rsdp-paddr.patch`, which sets `layout::RSDP_ADDR` and asserts
  it in the existing PVH unit test.
- **Firmware busy-waits on an ACPI PM timer Firecracker never had.**
  `AcpiTimerLib` reads port `0x608` for every delay. Resolved by
  `firecracker-acpi-pm-timer.patch`: a read-only 24-bit counter derived from the
  monotonic clock, registered beside the serial and i8042 ports, with unit
  tests for advancement and partial-access refusal. Not advertised in the FADT.
- **PCI aperture overlap.** The firmware's 896 MiB 32-bit aperture covered
  Firecracker's MMCONFIG window. Resolved by
  `edk2-cloudhv-firecracker-mmio-hole.patch` (aperture ends at `0xDEC00000`).
- **Firecracker 1.16.1 does not relocate reprogrammed BARs.** The first
  firmware smoke boot reached BdsDxe but every virtio-pci access went to the
  firmware-chosen BAR address (`0xC0000000`), which Firecracker logged as
  `MissingAddressRange`: virtio-pci devices record BAR writes in config space
  but keep their original MMIO registration. A firmware-side workaround was
  tried first (`PcdPciDisableBusEnumeration` with the `PciHostBridgeLibScan`
  library, edk2's Xen and microvm mode) and failed twice: the scan library only
  counts devices whose command register already decodes memory, and after
  `firecracker-pci-decode-enabled.patch` it sized Firecracker's 64-bit BAR as
  a 32-bit 1 MiB BAR at address 0; the platform host bridge library then made
  `PciBusDxe` assert (`PciDeviceSupport.c(784): RootBridge != NULL`) because
  light mode has no root bridge handle. Resolved in the VMM instead by
  `firecracker-pci-bar-relocation.patch`: `Bars::write` records non-sizing
  address writes, `VirtioPciDevice` reports a pending relocation, and `PciBus`
  re-registers the device's capability region on the MMIO bus (logged as
  `pci: moved BAR of device N`). Normal firmware enumeration is restored; the
  decode patch is kept because it is harmless and lets a scanning firmware see
  the devices. Firecracker's `_DSM` already tells Windows to preserve the boot
  configuration.
- **A sizing read dropped the BAR type bits.** With enumeration on, the DEBUG
  firmware trace showed each virtio device as `BAR[0] Mem32 0x80000` plus
  `BAR[1] Io32 0x4`, and the relocation log showed addresses such as
  `0xc004c0080000`: Firecracker answered the `0xFFFFFFFF` probe with the bare
  size mask (`0xFFF80000`), while edk2's `PciParseBar` classifies a BAR from
  the probed value, so the low half read as 32-bit memory and the high half as
  an I/O BAR, and the firmware programmed both halves independently. Linux
  never noticed because it takes the flags from the pre-probe read. The
  relocation patch now returns the size mask with the read-only type and
  prefetch bits for the low half of a 64-bit BAR (unit-tested as
  `0xFFF80004` / `0xFFFFFFFF`).
- **Queue doorbells stayed at the old BAR address.** With the BARs correctly
  typed, the firmware moved both devices into the 64-bit aperture
  (`0x140000000`, `0x140080000`), `VirtioBlkInit` reported the 32 GiB disk and
  the boot hung on the first read: Firecracker serves queue notifications
  through KVM ioeventfds registered at attach time for the original BAR
  address, so the firmware's doorbell write landed in `write_bar` as
  "unexpected write to notification BAR" and no request was processed. The
  relocation patch now unregisters and re-registers the ioeventfds for every
  queue when the BAR address changes, unit-tested against a real KVM VM.
- **seccomp killed the vCPU thread on the first relocation.** The PCI config
  write is handled on the vCPU thread, whose filter did not allow the
  `KVM_IOEVENTFD` ioctl (`Shutting down VM after intercepting a bad syscall
  (16)`). The patch adds that one ioctl to the vCPU filter of both
  architectures, matching the VMM thread's existing hotplug rule and Cloud
  Hypervisor's vCPU filter. This is the only syscall-surface change in the
  patch set and is recorded in ADR-0169.
- **Windows Boot Manager triggered an unhandled `KVM_EXIT_HYPERV`.** With the
  doorbells moving, the DEBUG firmware read the GPT, found the EFI system
  partition and started `bootmgfw.efi`; Firecracker then stopped with
  `Unexpected exit reason on vcpu run: Hyperv`, because its vCPU loop treats
  every exit it does not know as fatal. The Hyper-V CPUID patch now completes
  that exit: a hypercall KVM does not implement is answered with
  `HV_STATUS_INVALID_HYPERCALL_CODE` (so the guest falls back to its
  non-enlightened path), SynIC and synthetic-debugger exits are logged and
  ignored, and the exit type and hypercall code are logged for the record.
- **No Firecracker virtio device could be reset.** With the Boot Manager
  running, the serial console showed `<os-product>Windows Server</os-product>`
  and a second vCPU came up, but Firecracker logged `Attempt to reset device
  when not implemented in underlying device` and then `rejecting device status
  transition 0x0 -> 0x1: previous reset did not complete successfully and
  device is still active`. The firmware's VirtioBlkDxe had activated the disk
  and reset it at `ExitBootServices`; Firecracker 1.16.1's block and net
  devices do not implement `VirtioDevice::reset`, so the transport kept the
  backend active and refused Windows' `viostor` re-initialization. Resolved by
  `firecracker-virtio-reset.patch`: both devices drain or drop in-flight
  state, return to `Inactive` and accept a second activation (the runtime
  epoll registrations from the first activation remain valid), and the
  transport no longer discards its MSI-X interrupt object on reset, which
  would otherwise have made the second activation panic. The first build of
  the patch still logged the error because the `Block` enum that wraps
  `VirtioBlock` and the vhost-user variant delegates every trait method
  except `reset`; the wrapper now delegates it too and the block unit test
  exercises the wrapper. The second build reached the EFI system partition
  (the firmware's FAT driver opened `BCD`, `bootstat.dat`, `WinSiPolicy.p7b`
  and `BOOTX64.EFI`) and then died on seccomp syscall 72 (`fcntl`): the reset
  cloned the queue eventfds to honour the trait's return type, and
  `EventFd::try_clone` is an `fcntl` the vCPU filter does not allow. The
  transport never uses those clones, so reset now returns an empty list
  instead of widening the filter. The third build then hung silently with
  the Boot Manager's EFI file opens as the last serial output and no further
  block traffic: the transport's reset path takes the device mutex to call
  `reset()` and, on success, locked the same mutex again to reset the queues,
  a self-deadlock on the vCPU thread that upstream could never reach because
  no device returned `Some`. The queues are now reset through the guard
  already held, and a transport-level unit test drives a real block device
  through initialize, reset and re-initialize twice. Unit-tested for the sync
  and async block engines in the sandbox; the net variant needs
  `/dev/net/tun` and is run outside the sandbox (recorded under Verification).
- **Windows reached the SAC prompt and crashed with `NTFS_FILE_SYSTEM`.** With
  reset working, the kernel booted, EMS printed `Computer is booting, SAC
  started and initialized.` and the `SAC>` prompt, and the bugcheck channel
  reported STOP `0x24` with `STATUS_DISK_CORRUPT_ERROR`, followed by a warm
  reset that ended the VM. The firmware and the Boot Manager had read the same
  disk correctly, so the fault lay in what the Windows storage driver does
  differently: `viostor` issues scatter-gather requests with one descriptor per
  physical page, while Firecracker 1.16.1's `Request::parse` accepts exactly
  header, one data descriptor and status (Linux only ever sends one data
  descriptor because the device does not offer `VIRTIO_BLK_F_SEG_MAX`). The
  parser took the second data buffer for the status descriptor, transferred
  the first page only and reported success, so NTFS read truncated sectors.
  Resolved by `firecracker-virtio-blk-sg.patch`: requests carry a list of data
  segments, the synchronous engine transfers them in order, the io_uring
  engine submits one vectored operation (`IORING_OP_READV`/`WRITEV`, newly
  allowed in its restrictions and probe) with the `iovec` array owned by the
  in-flight user data, and dirty-page tracking covers every segment. Single
  segment requests keep the previous operations. Unit tests cover parsing a
  three-segment read with its rejection cases and a two-in, three-out transfer
  on both engines, and the upstream parser, engine and property tests rerun
  against the new request shape.
- **Windows probes for other hypervisors.** The boot log shows reads of I/O
  port `0x5658` (the VMware backdoor) and the extended Hyper-V hypercall
  `0x8001` (`HvExtCallQueryCapabilities`); both are answered as absent and
  are harmless.
- **edk2 asserts without a CMOS clock.** The DEBUG firmware died in
  `PcRtc` because ports `0x70/0x71` read as `0xFF`. Resolved by
  `firecracker-cmos-rtc.patch`, a read-only CMOS clock that follows host UTC
  (BCD or binary per status register B, century at `0x32`), which Windows will
  also read for its initial wall clock.
- **Hyper-V enlightenments.** Firecracker exposes no Hyper-V leaves and custom
  CPU templates refuse missing leaves. Resolved by
  `firecracker-hyperv-cpuid.patch`: a `hyperv` template field installs leaves
  `0x40000000..=0x4000000a` (reference time counter, reference TSC page,
  hypercall, VP index, APIC access and frequency MSRs; relaxed timing and
  MSR-based APIC recommendations) and relocates the KVM signature leaves to
  `0x40000100`. Synthetic timers are deliberately not advertised.
- **ISO provenance.** The user asked for the ISO to come from Microsoft rather
  than being supplied by hand. The Evaluation Center link resolves to a stable
  `software-static.download.prss.microsoft.com` object; it is pinned by URL,
  build and SHA-256 in `iso.json` and fetched like the Ubuntu base tarball.
- **QEMU AHCI topology.** The first installation attempt failed because two
  `ide-cd` devices shared one SATA port on q35; each CD now has its own port.
- **Keypresses drove Setup off the unattended path.** The driver answered the
  media's "Press any key" prompt by sending Enter every second for 90 seconds.
  Two installations sat for 30 and 4 minutes with 4.5 KiB written to the disk;
  the observability pipeline's first screenshot showed Windows Server Setup on
  "unexpected error 0x80070001 - 0x40030" behind a "Support Link" dialog, the
  footprint of keyboard activity in the Setup UI. Both runs were cancelled.
  The driver now presses Enter only for twelve seconds after the firmware's
  serial line `BdsDxe: starting Boot... DVD-ROM`, with a fallback window at
  45 seconds if that line never appears, and records the window it chose.
- **Server 2025's new Setup fails Windows PE initialization under QEMU.** With
  keypresses gated, the same error dialog appeared 30 seconds into the next
  run. Typing into the stuck VM through the QEMU monitor (Shift+F10, then
  `type` on `X:\$WINDOWS.~BT\Sources\Panther\setuperr.log`, captured by
  screendump) showed `MOUPG CDlpActionWinpeInitialization::ExecuteRoutine(224):
  Result = 0x80070001 [gle=0x57]` before any answer-file processing; the
  "ConX" Setup entry point (`SetupPrep.exe`) is known to be unreliable with
  autounattend on 24H2/25H2 media, and community practice is to start the
  legacy `setup.exe /legacy` from a `winpeshl.ini` inside `boot.wim`. Resolved
  structurally: the build now extracts Microsoft's boot files and `boot.wim`
  with 7-Zip (the media's ISO 9660 side holds only a README; the tree is UDF),
  injects `winpeshl.ini` and `kittens-setup.cmd` into `boot.wim` index 2 with
  wimlib, and produces its own UEFI boot ISO from `efisys_noprompt.bin` with
  the answer file and drivers; Microsoft's ISO stays unmodified as the
  `/installfrom` source. No keypress is needed any more.
- **Windows PE has no COM1.** The legacy Setup then refused the answer file with
  "could not apply the Windows PE bootstrap setting": the windowsPE
  `RunSynchronous` checkpoint wrote to `COM1`, which does not exist in Windows
  PE, and its non-zero exit aborted the pass. Windows PE checkpoints now go to
  the RAM disk and always exit 0; the forensics copy collects them.
- **`%configsetroot%` did not resolve, so no storage driver loaded.** With the
  legacy Setup running, the next run failed at "could not apply the
  <DiskConfiguration> setting". The automatic forensics recovered the Windows PE
  Panther logs onto a scratch partition (drivers-first variant) and the build
  read them back with mtools: `PnPIBS: Error 0x3 occurred while enumerating the
  files and subdirectories` for the DriverPaths entries, then `Failed to query
  disk [0] status 0x80042405`. The virtio drivers now live inside `boot.wim` at
  `X:\kittens\drivers`, referenced by both the windowsPE and offlineServicing
  `DriverPaths`, and the boot.wim SYSTEM hive carries `SanPolicy = 1`.
- **Answer-file limits learned the hard way.** `RunSynchronousCommand` orders
  must be consecutive from 1 (a gap fails the pass with `0x8007000d`), and a
  `Path` value is limited to 259 characters (`CSI 80220005`, "Value is
  invalid", at `[Order="2"]/Path` in the specialize pass). The specialize copy
  now calls `specialize.cmd` from the boot media with a short command.
- **Automatic forensics.** When no reboot, checkpoint or disk write happens
  for seven minutes, the driver opens the Windows PE prompt through the
  monitor, creates a FAT32 scratch partition with diskpart, copies the Setup
  logs there, powers off, and the build reads them back with mtools. Failed
  installations keep their evidence because the disk derivation records the
  result instead of failing; the image derivation refuses a non-zero result.
- **Observability pipeline.** Every installation now records a QMP lifecycle
  timeline mirrored into the Nix build log, change-triggered PNG screenshots,
  guest serial checkpoints from every unattend pass, disk-usage samples, and
  the Windows Setup, specialize and driver-binding logs that `SetupComplete.cmd`
  publishes on the EFI system partition and the build reads back with mtools.
  The launcher keeps Firecracker's log and metrics beside the disk copy.

## Verification

Executed on 2026-10-13 in the worktree, all from `nix build` on the local
KVM-capable host:

- `legacyPackages.x86_64-linux.vmm`: patched static Firecracker built with the
  upstream `firecracker` and `jailer` unit tests passing; `firecracker --version`
  prints `Firecracker v1.16.1`.
- `checks.x86_64-linux.firecracker-vmm`: passed (version, `--enable-pci`,
  static x86-64 pair, patch files present).
- `checks.x86_64-linux.windows-guest-unit`: passed (ruff gate on `install.py`,
  builder rules, manifest shape, launcher flags).
- `windowsFirmware`: `CLOUDHV.fd` is an ELF64 with the Xen `PHYS32_ENTRY`
  note, entry `0x4fffd0`, single `LOAD` segment at `0x100000`.
- `checks.x86_64-linux.firecracker-patch-tests`: passed on the vmm crate
  (PVH start info, PM timer, legacy device registration, Hyper-V leaves, CMOS
  clock, BAR sizing and relocation).
- Firmware-only smoke boot under the patched Firecracker (`--enable-pci`, 2
  vCPU, 2 GiB, empty 2 GiB virtio-blk, `cpu-config.hyperv = true`): the
  firmware ran PEI and DXE (PM timer and RSDP delivery working) and reached
  `BdsDxe: No bootable option or device was found` within seconds. This boot
  exposed the BAR relocation, CMOS and BAR-type findings above.
- `packages.x86_64-linux.windows-guest`: the unattended Windows Server 2025
  Standard Core installation completed inside the Nix KVM sandbox in about
  255 seconds of guest time (QEMU, 4 vCPU, 4 GiB): two `RESET` stage
  boundaries, all nine serial checkpoints from Windows PE through
  `KITTENS-SETUP-COMPLETE`, 17 screenshots, and the Setup, specialize and
  driver-binding logs recovered from the EFI system partition. The sparse
  `disk.raw` occupies 4.2 GB of its 32 GiB.
- Firecracker boot of that image (eight-patch VMM, `--enable-pci`, 2 vCPU,
  4 GiB, `cpu-config.hyperv = true`, DEBUG firmware): the firmware enumerated
  both virtio-pci devices as 64-bit BARs, relocated them into its aperture,
  found the GPT and the EFI system partition, started `bootmgfw.efi`, and
  Windows reached `Computer is booting, SAC started and initialized.` and
  `EVENT: The CMD command is now available.` within about a minute of guest
  time. On the console, `id` reported computer `KITTENS`, build 26100, product
  Windows Server; `i` listed one network interface with an APIPA address (DHCP
  is disabled by `SetupComplete.cmd`). Firecracker's log held only the
  expected probes (extended hypercall `0x8001`, VMware port `0x5658`) and the
  firmware's zero-length config read.
- The same image booted with the release firmware (`packages.windows-guest`
  as built, final launcher) to `EVENT: The CMD command is now available.` and
  `SAC>`. That log also shows Windows reassigning both BARs twice after the
  firmware's placement (ending at `0x7ffff00000` and `0x7ffff80000`), each
  move followed by the VMM with its doorbells, which is why the relocation
  patch is needed beyond firmware enumeration.
- Host-side run of the tap-dependent net reset unit test (static vmm test
  binary built from the same source, run as root with `/dev/net/tun`):
  `test_reset_returns_interrupt_and_deactivates ... ok`.

Not recorded: the `windows-guest` NixOS machine test (nested KVM, long
running) has not been executed; a SAC command-channel login was not completed.
ADR-0169 therefore stays `partial` and the scenario ledger entry stays
`partial` until the Lilly launch path exists.

## Acceptance limits

Reaching `SAC>` proves firmware entry, ACPI, PM timer, virtio-blk-pci boot and
EMS. It does not prove Windows networking, timekeeping under load, the Lilly
launch path, readiness, trust, terminals, workspace delivery or fleet
distribution of a 32 GiB sparse template. Unit tests cannot establish native
isolation; the launcher runs without the jailer and host network guard.
