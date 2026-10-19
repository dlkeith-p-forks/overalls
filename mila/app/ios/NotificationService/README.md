# NotificationService extension

The sources here decrypt Mila's end-to-end encrypted pokes (ADR-0224,
ADR-0225) into a local notification. They cannot be built in Nix.

## Xcode project wiring

`Runner.xcodeproj` has a `NotificationService` app-extension target:

- **Sources:** `NotificationService.swift`, `PokeOpener.swift` and
  `PokeKeychain.swift`.
- **Info and resources:** `Info.plist` (`INFOPLIST_FILE =
  NotificationService/Info.plist`) and the `Localizable.strings` variant group
  of every `*.lproj`.
- **Bundle and deployment target:** bundle identifier
  `dev.overalls.mila.NotificationService` and iOS 15.0, both matching Runner.
- **Configurations:** Debug, Release and Profile, based on Flutter's
  `Debug.xcconfig` and `Release.xcconfig` so that `FLUTTER_BUILD_NAME` and
  `FLUTTER_BUILD_NUMBER` version it with the app.
- **Entitlements:** `CODE_SIGN_ENTITLEMENTS =
  NotificationService/NotificationService.entitlements`, the Keychain
  Sharing group `dev.overalls.mila.shared`.
- **Runner:** depends on the extension and embeds it in an "Embed Foundation
  Extensions" phase. That phase runs before "Thin Binary", the order Flutter
  documents to avoid a build cycle. Runner signs with
  `Runner/Runner.entitlements`: Push Notifications with `aps-environment`
  and the same Keychain group. Xcode's provisioning switches
  `aps-environment` to `production` for distribution.
- **RunnerTests:** compiles `PokeOpener.swift` and `PushPokeTests.swift`, which
  checks the shared vectors from `protocol/test/fixtures/push_pokes.json`.

## Still required on a Mac

1. Select a development team for **Runner** and **NotificationService**.
   Enable the Push Notifications and Keychain Sharing capabilities for both
   App IDs in the developer account.
2. Build, then run `RunnerTests`.
3. Send a sandbox push with `mutable-content: 1` and a `poke` field to check
   decryption on a device.

## What was verified here

- `swiftc -parse` (Swift 5.10 on Linux) accepts every Swift file.
- The project file parses with an OpenStep property-list parser
  (`openstep-parser` 2.0.3), and every object reference resolves.

Nothing was type-checked against the iOS SDK, built, signed or run. Xcode,
CryptoKit, the Keychain and APNs are unavailable outside Apple platforms. The
Android opener implements the same format and passes the same vectors on the
JVM.
