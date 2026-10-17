# Review: Windows images with pinned winget packages (ADR-0173)

Date: 2026-10-15. Scope: the Windows guest template image's edition, winget,
the packages it installs, WSL features, and how the offline build reaches them.

## Scope and impact

- Image builder (`nix/domains/artifacts/guest/windows`): Desktop Experience edition;
  winget and packages from `winget.json`; the installation guest's only
  reachable endpoint is a QEMU `guestfwd` file server over the staged
  installers; WSL optional features via DISM in specialize; a one-shot
  interactive build logon runs the package installs; the image is refused
  without the winget, feature and cleared-autologon markers.
- Lyra: the Windows workspace receiver uses winget's Git for Windows instead of
  the removed MinGit pin.
- Contracts: `firmware-image-offline-assembly` (pins and file server) and
  `windows-serial-console` ("the finished image MUST NOT autologon"),
  new `windows-winget-pinned-offline`.
- Governance: ADR-0173 (proposed, partial); ADR-0171 gate 5 evidence points at
  the replacement; HLDD 07 "Tools in Windows images"; `docs/guests/windows-guests.md`.

## Findings

1. **Server Core cannot run winget.** On `win-accept-3` every supported path
   failed: no DISM AppX provider, `Add-AppxPackage` as SYSTEM `0x80073CF9`, and
   over an sshd logon `0x80073D19`. Decision: Desktop Experience (user).
2. **winget needs package identity and an interactive logon.** As SYSTEM the
   provisioned `winget.exe` fails to load (`0xC0000135`). In an elevated
   session-0 task it ran, but every `.exe` installer stalled while MSI, zip and
   portable packages installed. Decision: one-shot `AutoLogon` (`LogonCount 1`)
   with `FirstLogonCommands`; the image proves the autologon values are gone
   (user approved the contract amendment).
3. **The stall was a security prompt in winget's own process.** Window titles
   during the stall showed a dialog owned by `winget.exe`; the same Git installer
   started directly completed in 25 s. winget marks downloads with the URL's
   zone; `http://10.0.2.100` was Internet zone because Internet Explorer
   Enhanced Security Configuration (on for administrators) ignores
   `ZoneMap\Ranges`. Fix: map only that address to Intranet in `EscRanges` and
   `Ranges` for the step, refuse to continue unless the zone is Intranet, and
   remove both afterwards.
4. **Smaller defects found by the runs:** libslirp hands the `guestfwd` command
   the socket as stderr too (the server logs to a file); SetupComplete turned
   DHCP off before the installs (moved after); WinINet instead of Delivery
   Optimization; unscoped upstream MSI entries are filtered by
   `--scope machine` (staged as machine scope); Windows PowerShell 5.1 reports
   no exit code without an opened handle; `Select-Object -First` ended a
   `--version` pipeline early.

5. **Visual Studio's web bootstrapper needs a pinned offline layout.**
   `update-vs-layout.ps1` records the layout of the pinned 18.11.0 bootstrapper
   (C++ and .NET desktop workloads, recommended components, en-US): 1 057
   files, 5.95 GB, every one by its `download.visualstudio.microsoft.com` URL
   and SHA-256 or, for eight generated files (157 KB), by content. The layout
   renames payloads (`payload.vsix`), so they are matched by digest; its
   `Catalog.json` is byte-identical to the channel manifest's catalog URL (the
   size and digest the channel lists describe another form); `vs_installer.opc`
   comes from a content-addressed URL found only in the bootstrapper log.
6. **The installer's signer chain needs an intermediate offline.** The OPC is
   signed by a certificate issued by Microsoft Windows Code Signing PCA 2024;
   without it the bootstrapper fails with `0x80096004` "Certificate is
   invalid". The intermediate is pinned and imported into the machine's
   intermediate store (no trust is granted by it). On the fleet the same
   failure appears because Lilly's transparent proxy (Brady) answers plain
   HTTP to Microsoft's rotating Akamai PKI addresses with 400 when its own
   lookup returns another address (`brady-http-authority-original-ip`); Linux
   guests on overalls see the same 400. Recorded as ADR-0173 open question 1.
7. **A bootstrapper outside the layout needs explicit layout arguments.** With
   the layout's `Response.json` (relative paths) setup found no channel and
   cancelled (`0x8013153B`); with absolute channel and catalog paths it still
   had no layout location. `--installLayoutPath C:\vslayout` with the absolute
   response file installs (exit 0, 571 s on `win-dx-1`, +18.7 GiB). Hence the
   64 GiB disk and the 96 GiB template budget (user decision).
8. **Installers may add per-account PATH entries.** The .NET SDK that Visual
   Studio installs adds `%USERPROFILE%\.dotnet\tools` for the installing
   account; that entry alone is allowed (the SDK is on the machine PATH), and
   the image now also requires `KITTENS-WINGET-INSTALLED`, so a failed install
   phase can no longer hide behind a passing verify phase.

## Validation performed

| Check | Result |
| --- | --- |
| `checks.windows-guest-unit` (evaluation gate) | pass |
| ruff, ruff format, ty on the new Python | pass |
| `serve-pinned.py` local test (GET, HEAD, traversal, unknown, POST) | pass |
| Installation `mqj5w29p…-lilly-windows-server-2025-x86_64` | pass, 500.6 s; all eight packages, every command on the machine PATH, autologon cleared; file server log shows only the eight pinned GETs |
| `checks.windows-lilly-guest-agents` on that image | pass, 2026-10-15 12:36–13:20 UTC (placement 818.75 s, bundle restart 1 159.40 s) |
| Fleet VM `win-dx-1` (new image, 4 vCPU, 8 GiB, 96 GiB) over SSH as the roster user | git, gh, claude, codex, rg, podman and wsl on the machine PATH; no autologon value; 17 GiB used; `winget` itself not registered for an SSH-only account (gap) |
| Offline Visual Studio install on `win-dx-1` from the recorded layout | exit 0 in 571 s, `vswhere` reports Visual Studio Community 2026 18.11.12306.390 |
| Image build with Visual Studio (first attempt) | layout rebuilt from the file server in 108 s (1 057 files, 5.95 GB, digests checked); all nine packages installed (Visual Studio 801 s); verify passed; install phase refused the `.dotnet\tools` PATH entry (finding 8) |
| Fleet proof of the Visual Studio image | Fleet deploy of `ecdede1af` healthy on dungarees 15:38:06 Z and overalls 15:41:07 Z; new VM `win-vs-1` (catalog image `sha256:625787ae…`, default 1 vCPU, 2 GiB, 64 GiB) over SSH as the roster user: git 2.55.0.windows.5, gh 2.102.0, Claude Code 2.1.292, codex-cli 0.161.0, ripgrep 15.2.0, `vswhere` Visual Studio Community 2026 with both workloads, `cl` 19.51.36260 for x64 through VsDevCmd, `dotnet` 10.0.402, no layout left, 30 GiB free |
| Image `hd2bvg1n…-lilly-windows-server-2025-x86_64` | pass, 1 491 s; 64 GiB disk, 22.0 GB used; all nine packages (Visual Studio 756 s), `KITTENS-WINGET-INSTALLED`, every command on the machine PATH, `vswhere` both workloads, autologon cleared |

## Remaining gaps

- `winget` is not registered for accounts that only ever log on over SSH
  (AppX registration needs an interactive logon); every package works for
  them, running `winget` does not.
- Visual Studio Community (C++ and .NET desktop workloads) needs the pinned
  offline layout (ADR-0173 open question 1).
- WSL 2 and `podman machine` inside a Firecracker guest are unproven (nested
  SVM under Windows' hypervisor).
- The finished image keeps Internet Explorer Enhanced Security Configuration
  and the default UAC policy; nothing the build changed for the step remains.
