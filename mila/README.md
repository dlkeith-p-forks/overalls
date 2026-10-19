# Mila

Mila is the Overalls client for iOS and Android, with a Linux desktop build for
testing. It manages machines over one SSH connection to a deployment's Porsche
gateway, signs in by approving a per-deployment device key in the browser, and
opens `overalls://` links.

```sh
devenv shell
mila-check                                   # format, analyze and test everything
cd mila/app && flutter run -d linux --dart-define=MILA_DEMO=true   # in-memory demo
nix build .#tool-mila-linux                  # Linux bundle
```

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
