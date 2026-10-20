# Mila

Mila is the Overalls client for iOS, Android, macOS and Windows, with a Linux
desktop build for testing (ADR-0235). It manages machines over one SSH connection to a deployment's Porsche
gateway, signs in by approving a per-deployment device key in the browser, and
opens `overalls://` links.

```sh
devenv shell
mila-check                                   # format, analyze and test everything
cd mila/app && flutter run -d linux --dart-define=MILA_DEMO=true   # in-memory demo
nix build .#tool-mila-linux                  # Linux bundle
mila-build macos dev                         # any platform: linux|android|ios|macos|windows, dev|release
```

`mila-build <platform> <dev|release> [--demo] [--dry-run]` (from
[`tool/`](tool/lib/src/plan.dart)) is the one entry point for every target. A dev
build is a debug build with the push sandbox where one exists; a release build
refuses demo mode, software keys and any missing signing input, and verifies
its signatures. Signing inputs come from `MILA_*` environment variables
(`MILA_APPLE_TEAM`, `MILA_APPLE_IDENTITY`, `MILA_NOTARY_PROFILE`,
`MILA_ANDROID_UPLOAD_*`, `MILA_WINDOWS_PUBLISHER`, `MILA_WINDOWS_CERT_SHA1`, …);
release CI supplies them from the protected `mila-release` environment.

Without `MILA_APPLE_TEAM`, `mila-build macos dev` makes an unsigned app with
owner-only software keys and no push; with it, the build is development-signed
with Secure Enclave keys and the APNs sandbox. Windows builds run on Windows
outside Nix, from the `tool-mila-source-bundle` flake output, which carries the
patched dartssh2, fonts and Monocypher; `mila-build windows dev` stages a layout
to register with `Add-AppxPackage -Register` for the package identity WNS needs.

iOS and Android release builds run outside Nix with Flutter 3.47.0
(`flutter build ipa`, `flutter build appbundle`) after `devenv shell` has linked
the patched dartssh2 and the fonts. The iOS project includes the
`NotificationService` extension target; see
[its README](app/ios/NotificationService/README.md) for the signing steps
that need a Mac. An optional Android
build is a flake package outside CI: `nix build .#tool-mila-android` produces a
debug-key-signed arm64 release APK offline, from the Gradle dependency lock
`nix/domains/artifacts/mila/android-deps.json`. Re-record that lock (see the
header of `android.nix`) whenever the Android Gradle plugin, Kotlin, Firebase,
a Flutter plugin or Gradle changes. That APK has no FCM configuration.

Mila bundles JetBrains Mono and, as fallbacks, the Noto faces Marshall pins
for Arabic, Indic, CJK and symbols (ADR-0207, ADR-0226). The Noto files are not
committed. `nix/domains/artifacts/mila/fonts.nix` fetches them by digest from
Marshall's font manifest. `devenv shell` links them into
`app/assets/fonts/noto`, and the Nix builds copy them there. Outside
`devenv shell`, the app does not build or test without that directory.

See [AGENTS.md](AGENTS.md) for the layout and working rules, and
[ADR-0220](../docs/architecture/decisions/0220-mila-client-over-porsche-ssh.md)
for the design.
