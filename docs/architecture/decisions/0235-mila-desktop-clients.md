# ADR-0235: Mila desktop clients for macOS and Windows

- ID: ADR-0235
- Date: 2026-10-21
- Status: accepted
- Implementation: partial
- Components: Mila, protocol, Marshall, mila-build
- Supersedes: none
- Superseded by: none

## Context

[ADR-0220](0220-mila-client-over-porsche-ssh.md) made Mila an iOS and Android
client with a Linux build for testing. Users also want first-class macOS and
Windows desktop apps. The code treated every platform that was not a phone as
Linux: file-backed keys, chmod-only storage, no push, and a hard-coded
`ios`/`android` device platform. Marshall and the protocol accepted only
`ios` and `android` for `device register`. No platform had distinct dev and
release build targets; release signing for iOS and Android was manual.

Facts that constrain the design:

- macOS has the Secure Enclave and APNs, but Secure Enclave keys and a push
  entitlement need a signed build with a provisioning profile; an unsigned
  local build has neither.
- Windows has no Secure Enclave. CNG's Microsoft Platform Crypto Provider holds
  non-exportable keys in a TPM 2.0, but many machines and VMs have no TPM. A TPM
  cannot hold an X25519 key.
- WNS, Windows' push service, needs a package identity (MSIX) and a new Susan
  provider ([ADR-0236](0236-susan-wns-provider.md)).
- POSIX permission bits mean nothing on NTFS; access is governed by DACLs.
- Windows CI hosts cannot run Nix, which ADR-0227 relies on to provide the
  patched dartssh2.

## Decision

Authorization: the approved Mila desktop plan (2026-10-20), with the user's
choices of hardware key custody, macOS APNs plus Windows WNS, signed release
artifacts, "for windows, if no tpm, no refusal. software is fine", and software
keys for unsigned macOS dev builds.

1. **Platform profile.** A single `PlatformProfile` per operating system fixes
   hardware-key custody, the push provider and device platform, the web view
   and the app lock. No code path infers Linux from "not a phone". Devices
   register as `ios`, `android`, `macos` or `windows`; the protocol and
   Marshall accept exactly these four.
2. **macOS.** Device keys live in the Secure Enclave and poke keys in the
   data-protection keychain group shared with a Notification Service extension.
   macOS uses APNs under the iOS topic `dev.overalls.mila`. The Swift for keys,
   poke keychain and poke opening is shared with iOS from `mila/app/darwin/Shared`.
   An unsigned dev build sets `MILA_SOFTWARE_KEYS`: owner-only software keys
   and no push. A release build that carries the define refuses to start.
3. **Windows.**
   - Device keys are non-exportable CNG ECDSA P-256 keys, one per host. The
     Platform Crypto Provider (TPM) is used when it works; otherwise the
     Software Key Storage Provider is used with no refusal. A key is always
     reopened from the provider that created it.
   - The X25519 poke key is generated natively, sealed with DPAPI (user scope)
     in the owner-only data directory, and only its public key crosses the
     platform channel.
   - Mila's files carry a protected DACL granting only the current user and
     SYSTEM, and Mila refuses to read a file whose DACL admits anyone else.
   - Push uses Windows App SDK raw notifications through WNS. The native poke
     opener decrypts the poke and shows a notification with fixed localized
     text, under the same `mila-native-poke-open-v1` contract as iOS and
     Android.
   - The app runs as a single instance, and `overalls://` links reach the
     running window.
4. **Build targets.** One typed planner, `mila-build <platform> <dev|release>`,
   defines a dev and a release target for Linux, Android, iOS, macOS and
   Windows.
   - A release plan refuses demo mode, software keys, another host's target and
     any missing signing input, and it verifies signatures as its final step.
   - Signing secrets arrive only through the environment and are redacted from
     printed plans.
   - Linux dev and release targets are Nix packages.
5. **Windows sources.** Windows builds run outside Nix from a Linux-built
   source bundle. The bundle holds the tracked Mila sources, a copied patched
   dartssh2 and the pinned native dependencies, so nothing resolves dartssh2
   from pub.dev (ADR-0227).

## Alternatives

- **Refuse Windows machines without a TPM.** Rejected by the user. A software
  CNG key is non-exportable and DPAPI-protected per user, which is the same
  custody as the Linux build.
- **Ad-hoc signed macOS dev builds with Secure Enclave keys.** Not possible: the
  Secure Enclave and keychain groups need a team-signed build with entitlements.
- **Electron or a separate desktop codebase.** Rejected: it would duplicate the
  transport, authority and localization already in the Flutter client.
- **A WebSocket or long-poll push channel for Windows.** Rejected: it would need
  a resident process and a new relay protocol, while WNS uses the existing
  push-key model.

## Consequences

- Desktop users get the same identity, push and link model as phone users.
  Marshall's device list can show which kind of device is registered.
- Custody on Windows varies by machine. The provider in use is not reported to
  Marshall, so a deployment cannot require a TPM-backed key.
- Release builds need Apple Developer ID, notarization, Android upload and
  Windows code-signing material in a protected CI environment.
- Native code for Windows (C++) adds a third implementation of the poke opener,
  which must stay byte-compatible with the shared vectors.

## Invariants and verification

- Every platform registers under its own wire name and provider (Dart unit test).
- A Windows DACL other than protected owner-plus-SYSTEM is refused (Dart unit and
  Hegel property tests, plus a Windows-only `icacls` round trip).
- Release plans never enable demo or software keys and keep secrets out of
  arguments (Hegel property over platform, host and inputs).
- The macOS and iOS poke openers pass the shared vectors (XCTest `RunnerTests`);
  the Windows opener passes the same vectors (CTest).
- A WNS token that is not a `notify.windows.com` channel is never sent to Susan.
- `device register --platform` accepts exactly ios, android, macos and windows
  (protocol and Marshall tests).

No NixOS machine test can host a macOS or Windows client. Native evidence comes
from XCTest, CTest, Dart tests and CI builds.

## Implementation evidence

- Profile and push selection:
  [`platform.dart`](../../../mila/app/lib/transport/platform.dart);
  [`push_registrar.dart`](../../../mila/packages/mila_transport/lib/src/push_registrar.dart)
  (`DevicePlatform`; only APNs has a sandbox; WNS shape check).
- Windows owner-only storage:
  [`owner_only_windows.dart`](../../../mila/packages/mila_transport/lib/src/owner_only_windows.dart)
  with [`owner_only_test.dart`](../../../mila/packages/mila_transport/test/owner_only_test.dart).
- macOS: [`MilaPlatform.swift`](../../../mila/app/macos/Runner/MilaPlatform.swift),
  shared [`MilaKeys.swift`](../../../mila/app/darwin/Shared/MilaKeys.swift) and
  [`PushPokeTests.swift`](../../../mila/app/darwin/SharedTests/PushPokeTests.swift).
  The unsigned dev build ran locally on aarch64-darwin with 0700/0600 data files.
- Windows runner: [`mila/app/windows/runner`](../../../mila/app/windows/runner)
  and the portable poke opener [`mila/app/native`](../../../mila/app/native).
- Build planner: [`plan.dart`](../../../mila/tool/lib/src/plan.dart) and
  [`plan_test.dart`](../../../mila/tool/test/plan_test.dart). Linux targets:
  [`default.nix`](../../../nix/domains/artifacts/mila/default.nix).
- Platform enum: [`ssh_command.ex`](../../../protocol/lib/overalls_protocol/ssh_command.ex)
  and [`device.ex`](../../../marshall/lib/marshall/notifications/device.ex).
- CI: [`mila-builds.yml`](../../../.github/workflows/mila-builds.yml) and
  [`mila-release.yml`](../../../.github/workflows/mila-release.yml).

Remaining gaps:

- No signed macOS build has run, so the Secure Enclave and APNs paths on macOS
  are unverified.
- The Windows runner has not been compiled or run on Windows, and no TPM or
  software-provider key has been exercised.
- The release workflows have not run with real signing material.

## Open questions

- Whether Marshall should record and display the custody kind (hardware or
  software) of a desktop device key.

## Related decisions

Extends [ADR-0220](0220-mila-client-over-porsche-ssh.md) and
[ADR-0227](0227-flutter-toolchain-and-dartssh2-overlay.md); depends on
[ADR-0236](0236-susan-wns-provider.md) for Windows push;
[ADR-0225](0225-marshall-notifications-domain.md) (device platforms);
review [2026-10-21-mila-desktop](../reviews/2026-10-21-mila-desktop.md).
