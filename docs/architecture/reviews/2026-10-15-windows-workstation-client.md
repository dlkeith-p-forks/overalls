# Review: Windows workstation client (ADR-0172)

Date: 2026-10-15. Scope: installing and updating the `overalls` CLI on Windows
workstations and connecting to Linux and Windows guests through Audi.

## Scope and impact

- Lyra (`overalls` binary): the bin-only modules no longer use `std::os::unix` or
  `libc` outside `cfg(unix)`. The shared helpers live in `lyra::platform`
  (local user name, null device, RNG, owner-only directories and files, link-safe
  opens). Windows paths, the recorded OpenSSH client (`ssh_program`), Windows
  ProxyCommand quoting, `overalls ssh`, and the update rename-aside are new.
  Linux and macOS behaviour is unchanged: identical paths, the same config block
  and the same activation.
- Packaging: the release adds `bin/windows-amd64` to the manifest, and the Lyra
  check type-checks the client for Windows.
- Marshall: `/bin/install.ps1`, the `windows-amd64` allowlist, and the machine
  page's "Windows (PowerShell)" section.
- Governance: ADR-0172 (proposed, partial), HLDD 08 "Windows workstations",
  scenario `windows-workstation-client`, quickstart docs.

## Findings

1. **The original client was Unix-only by construction.** A Windows type check
   of `--bin overalls` reported 33 errors. Beyond the compile errors, the
   runtime depended on Unix in several ways:
   - `id -un` and `/dev/null`;
   - `/dev/urandom` and `$HOME`;
   - POSIX ProxyCommand quoting;
   - a rename over the running binary.

   All of these now go through platform helpers or `cfg` branches. The check
   keeps them from coming back.
2. **The in-box Windows OpenSSH is too old for the hostname gate.** Win32-OpenSSH
   9.5p1 accepts `invalid;hostname`. The gate stays as it is. The installer
   offers winget's `Microsoft.OpenSSH.Preview` and records the verified client,
   and `overalls ssh` uses that client, because `System32\OpenSSH` precedes user
   PATH entries.

## Validation performed

| Check | Result |
| --- | --- |
| `lyra`: `cargo clippy --all-targets -D warnings`, `cargo test` (Linux) | pass; CLI suite 64/64 including the new quoting, target and date tests |
| `cargo check --target x86_64-pc-windows-gnu --bin overalls` (pinned toolchain) | pass (was 33 errors) |
| `legacyPackages.lyra` | pass: `bin/windows-amd64` PE32+ x86-64, 3 281 408 bytes, in the manifest with its digest |
| `checks.overalls-install-ps1` | pass: parses under PowerShell; refuses http origin, foreign host, foreign zone and hosts outside the zone |
| `marshall`: `overalls_controller_test`, `machines_live_test` | pass (37/37) |
| `checks.windows-lilly-guest-agents` on the rebuilt image `1h61y3il…-lilly-windows-server-2025-x86_64` (the Lyra change rebuilds the Windows agents) | pass, 2026-10-15 06:22–07:13 UTC; final bundle-restart subtest 1 206.92 s |
| Fleet deploy of `8efd4c45a` | `update.healthy` on dungarees 07:11:10 Z and overalls 07:14:11 Z |

## Remaining gaps

- Nothing has run on a real Windows workstation yet: installation, `config-ssh`
  against Porsche, `overalls ssh` to Linux and Windows guests, `overalls open`, an
  update activation. The planned proof uses a Windows Server 2025 fleet VM as
  the workstation.
- `winget` is absent on Windows Server, where the installer prints the manual
  Win32-OpenSSH step instead.
- There is no native `windows-arm64` artifact.
