# ADR-0173: Windows images on Desktop Experience with pinned winget packages

- ID: ADR-0173
- Date: 2026-10-15
- Status: proposed
- Implementation: partial
- Components: nix-packages, Lyra
- Supersedes: none
- Superseded by: none

## Context

The user asked (2026-10-15) for winget in the Windows guest template image, and
for every tool the image needs to come through winget: Git, GitHub CLI
(`gh`), Claude Code, the Codex CLI, Podman, Microsoft runtimes, Visual Studio
Community, and WSL 2 with its optional features enabled by DISM.

Observed facts:

- The image was Windows Server 2025 **Server Core** (`SERVERSTANDARDCORE`).
  On the fleet guest `win-accept-3` (26100, Server Core, as SYSTEM and as the
  roster user over SSH) every supported way to install winget failed: DISM has
  no AppX provider (`Add-AppxProvisionedPackage` and
  `dism /Add-ProvisionedAppxPackage`: "No providers were found that support the
  command", `0x8007007e`), SYSTEM cannot register packages
  (`Add-AppxPackage` `0x80073CF9`), and an sshd key logon cannot either
  (`0x80073D19`, "a user was logged off"). winget is a Desktop Experience
  feature of Windows Server 2025.
- The installation already runs offline in a KVM sandbox behind QEMU
  `user,restrict=on`, from hash-pinned inputs only
  (`firmware-image-offline-assembly`, ADR-0169/0171). A normal
  `winget install` downloads from the live winget source.
- QEMU's `guestfwd` forwards one guest address and port to a host command per
  connection and keeps working under `restrict=on`.
- Git came from a pinned MinGit unpacked onto the media; its only consumer was
  the workspace receiver's hard-coded `C:\overalls\git\cmd\git.exe`, and nothing
  put Git on the machine PATH, so an agent's `exec_command` had no `git`.
- The Desktop Experience edition installs through the unchanged unattended
  pipeline (every serial checkpoint through `OVERALLS-SETUP-COMPLETE`,
  2026-10-15).

## Decision

1. Windows images install the **Desktop Experience** edition
   (`Windows Server 2025 SERVERSTANDARD`) from the same pinned evaluation ISO.
   Headless operation is unchanged: EMS/SAC on COM1, no autologon, the
   Administrator retirement of ADR-0171.
2. **winget is pinned, not fetched.** `winget.json` records the winget-cli
   release assets (App Installer bundle, license, framework-dependency
   archive) and, per package, every winget-pkgs manifest at one commit and the
   single x64 installer the image installs, all by SHA-256. It is regenerated
   only by the operator tool `update-winget-pins.py` and reviewed like any
   pin; package dependencies (`PackageDependencies`) are resolved there and
   pinned too, dependencies first. The build stages them with
   `stage-winget.py`: manifests go on the boot media with the installer
   manifest reduced to the pinned entry, whose `InstallerUrl` points at
   `http://10.0.2.100/<sha256>/<upstream file name>`.
3. **The installation guest stays offline.** Its only reachable endpoint is
   `10.0.2.100:80`, a QEMU `guestfwd` to `serve-pinned.py`, which answers GET
   for exactly the staged installers and nothing else. winget verifies every
   installer against the manifest SHA-256 before running it.
4. SetupComplete (as SYSTEM) provisions the pinned App Installer with its x64
   framework packages (`Add-AppxProvisionedPackage`). The packages install in
   the build's **one interactive logon**: the answer file logs the bootstrap
   Administrator on once (`AutoLogon` with `LogonCount 1`) and runs
   `FirstLogon.cmd` from `FirstLogonCommands`. winget has no package identity
   as SYSTEM (`0xC0000135`) and, in a non-interactive session-0 task, its shell
   launch of `.exe` installers never returns (Git and the Visual C++
   redistributable stalled while MSI, zip and portable packages installed;
   evidence 2026-10-15). There it registers App Installer for the account,
   enables local manifests only for the step, installs each package with
   `--manifest … --scope machine --architecture x64 --skip-dependencies`
   (an upstream entry without a scope is staged as machine scope), and
   requires `git`, `gh`, `claude`, `codex`, `rg`, `podman` and `wsl` to answer
   `--version` from the machine PATH, with the installing account's own PATH
   unchanged. winget marks every download with its URL's security zone and
   starts `.exe` installers through the shell, which raises a security prompt
   for an Internet-zone file that nobody can answer during the build (winget
   owned a dialog while Git, the Visual C++ redistributable and Podman stalled;
   the same Git installer started directly completed). For the step only, the
   build server address `10.0.2.100` alone is mapped to the Local Intranet zone
   for the installing account, in `ZoneMap\EscRanges` (read under Internet
   Explorer Enhanced Security Configuration, on for administrators on Windows
   Server) and `ZoneMap\Ranges`; the step refuses to start unless the URL
   resolves to Intranet and removes both mappings afterwards. It then turns DHCP off, removes `AutoAdminLogon`,
   `DefaultPassword` and `AutoLogonCount` and proves they are gone, publishes
   the logs and powers off. The image derivation refuses an installation whose
   serial log lacks `OVERALLS-WINGET-COMPLETE` or `OVERALLS-AUTOLOGON-CLEARED`;
   contract `windows-serial-console` now reads "the finished image MUST NOT
   autologon". Every package reports `OVERALLS-WINGET-PACKAGE-BEGIN-<n> <id>`
   and `…-INSTALLED-<n>`/`…-FAILED-<n>` on COM1.
5. The pinned set is Git for Windows (`Git.Git`), GitHub CLI (`GitHub.cli`),
   Claude Code (`Anthropic.ClaudeCode`), Codex (`OpenAI.Codex`) with its
   dependencies ripgrep (`BurntSushi.ripgrep.MSVC`) and the Visual C++
   redistributable (`Microsoft.VCRedist.2015+.x64`), WSL (`Microsoft.WSL`) and
   Podman (`RedHat.Podman`). MinGit is removed; the workspace receiver uses
   `C:\Program Files\Git\cmd\git.exe` with the same empty environment, no
   system or global configuration and the OpenSSL backend.
6. **WSL 2 features via DISM.** `specialize.cmd` enables
   `Microsoft-Windows-Subsystem-Linux` and `VirtualMachinePlatform` with
   `dism /Online /NoRestart /Enable-Feature /All`, because Windows Setup
   restarts after the specialize pass and completes them during the build;
   enabled later, they would leave a restart for the first Firecracker boot,
   which treats a guest reboot as an exit. The image refuses an installation
   without `OVERALLS-SPECIALIZE-FEATURES-ENABLED`.
7. **Visual Studio Community 2026** (`Microsoft.VisualStudio.Community`
   18.11, C++ desktop and .NET desktop workloads with recommended components,
   en-US) installs through winget from a **pinned offline layout**. Its winget
   installer is a web bootstrapper, so the operator tool
   `update-vs-layout.ps1` runs the pinned bootstrapper's `--layout` on a
   Desktop Experience guest and records every layout file in `vs-layout.json`:
   1 057 files by their `download.visualstudio.microsoft.com` URL and SHA-256
   (payloads matched by digest against the layout's catalog; `Catalog.json`
   from the channel's manifest URL; `vs_installer.opc` from the
   content-addressed URL the bootstrapper log records; the bootstrapper copies
   from the pin), the eight small files the layout generates by content, and
   the installer signer's intermediate certificate (Microsoft Windows Code
   Signing PCA 2024), which an offline machine cannot fetch. The build fetches
   each file once by digest, serves it through the same file server, rebuilds
   `C:\vslayout` in the install step (every digest checked), imports the
   intermediate into the machine's intermediate store (no trust is granted by
   it) and runs the bootstrapper with `--in <absolute-path response>
   --installLayoutPath C:\vslayout --noWeb --quiet --wait --norestart`, then
   deletes the layout; `vswhere` must report both workloads. A layout response
   file's relative paths and a bootstrapper outside the layout do not work
   (`LayoutLocation` empty, install cancelled); `--installLayoutPath` and
   absolute channel and catalog paths do.
8. **Disk:** the image disk and `minimum_disk_bytes` are 64 GiB (about 29 GiB
   used: the Desktop Experience base 10 GiB and Visual Studio 18.7 GiB), and
   both hosts' `imageTemplates.budgetBytes` rise from 48 to 96 GiB so the
   Windows template stays cacheable beside the Linux templates (the budget
   counts apparent sizes; the disk file is sparse).
9. **Copies skip holes.** `lilly-image-copy` transfers only the source's data
   extents (`SEEK_DATA`/`SEEK_HOLE`) in both its kernel-offload and userspace
   paths and sizes the destination afterwards (contract
   `image-copy-source-extents`), so the 64 GiB disk moves its 22 GB of data
   rather than 64 GiB of mostly zeros; the nested Windows machine test, whose
   300 s `image_copy` deadline the full 64 GiB copy exceeded, motivated it
   (user decision over a configurable timeout or a smaller test image).
   Filesystems that cannot report holes behave as before.
10. **Per-pool image I/O deadline.** Inside the nested test VM the image comes
   from a shared store that reports no holes, so the copy still reads all
   64 GiB. Lilly's root-disk image copy and flush deadline becomes a pool
   setting, `image_io_timeout_ms` (Nix `services.lilly.imageIoTimeoutSeconds`,
   1 s..4 h, default 300 s so production is unchanged; contract
   `disk-image-io-deadline`); template copies use the same pool value. The
   nested Windows probe builds its pool with 1 800 s, and the fixture has a
   96 GiB mirrored pool (user decision). The host lock owner's frame bound
   rises from 600 s to the same 4 h (`native-command-frame-bounds`), and
   `Lilly.Host.Command` allows a deadline over 600 s only for `image_copy`
   and `sync` (`utility-timeout-bounds`). *Correction (2026-10-16):* an
   earlier revision said the copy holds "the host lock" and blocks other
   host mutations. That was wrong. The copy and its flush run through the
   placement's own lock owner while holding a shared lease on the image
   template (`disk-copy-outside-pool-lock`). They block only that
   placement's other operations and exclusive operations on that template.
   Other placements and pool accounting carry on. On the fleet, root-disk
   copies are block-cloned and take about 0.1 s. The long copy happens only
   on stores that cannot clone, such as the nested test's 9p share. The
   measured contention and the redesign are in
   [ADR-0176](0176-host-concurrency-single-writers-and-effects.md).

## Alternatives

- **Stay on Server Core.** No supported winget install exists there (above);
  tools would remain individually pinned archives such as MinGit.
- **Unpackaged winget.** `winget.exe` extracted from the bundle with framework
  DLLs copied beside it runs `--version` as SYSTEM, but `install` fails
  (`0x80040154` Class not registered) and copying runtime DLLs by hand was
  rejected by the user.
- **winget online at first boot.** Every VM's start would depend on the
  internet and on the source's current versions, and the workspace receiver
  would wait for Git.
- **winget in a SYSTEM or session-0 scheduled task.** Tried 2026-10-15: SYSTEM
  cannot load winget's framework DLLs, and in an elevated batch-logon task
  (High integrity, session 0) `.exe` installers never start, with or without
  silent UAC elevation. Kept the no-autologon rule at the cost of every
  `.exe` package.
- **Network access during the build.** Replaces the offline-assembly decision:
  non-reproducible images and unpinned upstream code in every guest.

## Consequences

- Larger image and slower installation (Desktop Experience plus the packages,
  about 700 MB of installers), more RAM and boot time per guest, and a larger
  patch surface (Explorer, Edge components). The disk minimum rises to 64 GiB
  and the template budget to 96 GiB per host; every rebuild copies the larger
  sparse image to dungarees.
- Every new tool is a reviewed `winget.json` change; versions move only when
  an operator regenerates the pins.
- Git is on the machine PATH, so agents and SSH sessions get `git`, `gh`,
  `claude`, `codex`, `podman` and `wsl` without setup.
- winget itself is present for roster users on Desktop Experience; its live
  sources are used only after boot, by users.
- WSL 2 and Podman machines need hardware virtualization inside the guest:
  the hosts expose AMD SVM to guests (nested KVM, Lilly's Inception proof), but
  Windows' own hypervisor under Firecracker is unproven (open question 2).

## Invariants and verification

- The installation network is `restrict=on`; the only forward is
  `guestfwd=tcp:10.0.2.100:80` to `serve-pinned.py` over the staged installer
  directory (`nix/tests/evaluation/windows-guest.nix`).
- Every winget input is in `winget.json` and fetched by Nix against its
  SHA-256; `stage-winget.py` re-verifies each digest; winget verifies each
  installer again (contract `windows-winget-pinned-offline`).
- An image whose installation lacks `OVERALLS-WINGET-COMPLETE` or
  `OVERALLS-SPECIALIZE-FEATURES-ENABLED` is not produced.
- Disproved by: any build-time fetch outside Nix, a package command missing
  from the machine PATH of a new SSH session, or a first Firecracker boot that
  reboots to finish feature installation.

## Implementation evidence

- Builder: [default.nix](../../../nix/packages/guest/windows/default.nix)
  (edition, `wingetPins`, `wingetPayload`, `--serve-command`, marker checks),
  [winget.json](../../../nix/packages/guest/windows/winget.json),
  [update-winget-pins.py](../../../nix/packages/guest/windows/update-winget-pins.py),
  [stage-winget.py](../../../nix/packages/guest/windows/stage-winget.py),
  [serve-pinned.py](../../../nix/packages/guest/windows/serve-pinned.py),
  [install.py](../../../nix/packages/guest/windows/install.py) (`guestfwd`),
  [overalls-winget.ps1](../../../nix/packages/guest/windows/overalls-winget.ps1),
  [SetupComplete.cmd](../../../nix/packages/guest/windows/SetupComplete.cmd),
  [FirstLogon.cmd](../../../nix/packages/guest/windows/FirstLogon.cmd),
  [autounattend.xml](../../../nix/packages/guest/windows/autounattend.xml)
  (one-shot `AutoLogon`, `FirstLogonCommands`),
  [specialize.cmd](../../../nix/packages/guest/windows/specialize.cmd).
- Git consumer: [overalls-workspaced-windows.rs](../../../lyra/src/bin/overalls-workspaced-windows.rs).
- Evaluation gate: [windows-guest.nix](../../../nix/tests/evaluation/windows-guest.nix).
- Recorded installation (2026-10-15, `mqj5w29p…-lilly-windows-server-2025-x86_64`,
  500.6 s): features enabled (DISM 3010/3010), the build server's zone
  Intranet for the step, all eight packages installed (Git 24 s, GitHub CLI
  12 s, Claude Code 17 s, ripgrep 1 s, VC++ redistributable 3 s, Codex 11 s,
  WSL 37 s, Podman 20 s), the zone mapping removed, every command answering
  from the machine PATH (`git 2.55.0.windows.5`, `gh 2.102.0`, Claude Code
  `2.1.292`, `codex-cli 0.161.0`, `ripgrep 15.2.0`, `podman 5.8.3`, WSL
  `2.7.13.0`), `OVERALLS-AUTOLOGON-CLEARED`, and the file server log showing
  exactly the eight pinned GETs. Review:
  [2026-10-15 Windows images with winget](../reviews/2026-10-15-windows-images-winget.md).
- `checks.windows-lilly-guest-agents` on that image: pass (2026-10-15
  12:36–13:20 UTC).
- Visual Studio: [vs-layout.json](../../../nix/packages/guest/windows/vs-layout.json),
  [update-vs-layout.ps1](../../../nix/packages/guest/windows/update-vs-layout.ps1);
  offline install on fleet VM `win-dx-1` (exit 0, 571 s); image
  `hd2bvg1n…-lilly-windows-server-2025-x86_64` (64 GiB disk, 22.0 GB used,
  1 491 s installation): layout rebuilt in 110 s (1 057 files, 5.95 GB), nine
  packages including Visual Studio (756 s), `OVERALLS-WINGET-INSTALLED`,
  `vswhere` reporting Visual Studio Community 2026 18.11 with both
  workloads, autologon cleared.
- Fleet deploy of `ecdede1af` healthy on dungarees 15:38:06 Z and overalls 15:41:07 Z; new VM `win-vs-1` (catalog image `sha256:625787ae…`, default 1 vCPU, 2 GiB, 64 GiB) over SSH as the roster user: git 2.55.0.windows.5, gh 2.102.0, Claude Code 2.1.292, codex-cli 0.161.0, ripgrep 15.2.0, `vswhere` Visual Studio Community 2026 with both workloads, `cl` 19.51.36260 for x64 through VsDevCmd, `dotnet` 10.0.402, no layout left, 30 GiB free.
- `checks.windows-lilly-guest-agents` on the 64 GiB Visual Studio image, run
  from `2fc0be43f` on a heavily loaded overalls (2026-10-16). Passed:
  - Inception refusal: 565 s;
  - placement: 1 730 s, including the full 64 GiB copy and flush over 9p
    under the 1 800 s pool deadline; trust delivery; readiness; pool usage
    under the 28 GiB bound;
  - SAC boot with MMDS addressing;
  - the host reaching the guest.

  Not passed: the `stop` subtest hung for more than an hour in `windows-lilly
  stop 2`. The driver's 600 s command timeout never fired. The run was
  stopped by hand, and the cause is not diagnosed. Two earlier runs failed
  for reasons fixed since: a 600 s utility bound, then a sync over 600 s.
- Gaps:
  - WSL 2 usability under Firecracker is unproven.
  - The nested stop/restart/delete subtest has not passed on the 64 GiB
    image.

## Open questions

1. Visual Studio's layout is regenerated by hand (`update-vs-layout.ps1`)
   when its version moves; Lilly's transparent proxy (Brady) answers plain HTTP
   to Microsoft's rotating Akamai PKI addresses with 400 when its own lookup
   differs (contract `brady-http-authority-original-ip`), so Windows guests on
   the fleet cannot fetch intermediates or CRLs over HTTP. The tool needs the
   pinned intermediate imported first; the proxy behaviour itself is a
   separate decision.
2. Whether WSL 2 (and therefore `podman machine`) starts inside a Firecracker
   Windows guest: VirtualMachinePlatform needs the guest to launch Windows'
   hypervisor on nested SVM alongside the Hyper-V CPUID leaves Firecracker
   installs (ADR-0169).

## Related decisions

- [ADR-0169](0169-firmware-booted-windows-guests.md): firmware-booted Windows
  guests and the offline installation.
- [ADR-0171](0171-windows-guest-agents.md): Windows guest agents; its gate 5
  MinGit pin is replaced by this decision's Git for Windows.
- [ADR-0172](0172-windows-workstation-client.md): the Windows workstation
  client, whose installer offers winget's OpenSSH.
