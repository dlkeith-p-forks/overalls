# NotificationService extension (not yet wired into Xcode)

The sources here decrypt Mila's end-to-end encrypted pokes (ADR-0224,
ADR-0225) into a local notification. They cannot be built in Nix, and the
target is **not** in `Runner.xcodeproj` yet: adding a target by hand-editing
`project.pbxproj` without Xcode is too error-prone. Until these steps are done
on a Mac, iOS shows the relay's fallback alert (`loc-key`
`MILA_NEEDS_INPUT_TITLE`) without decryption or a tap link.

## Xcode steps

1. File > New > Target > **Notification Service Extension**.
   - Product name: `NotificationService`; language Swift; embed in `Runner`.
   - Bundle identifier: `dev.overalls.mila.NotificationService`.
   - Minimum deployment: iOS 15.0 (same as Runner).
   - Delete the template `NotificationService.swift` and `Info.plist` Xcode
     creates, then add the files in this directory to the target:
     `NotificationService.swift`, `PokeOpener.swift`, `PokeKeychain.swift`,
     `Info.plist` (set `INFOPLIST_FILE = NotificationService/Info.plist`) and
     every `*.lproj/Localizable.strings` (as one localized variant group).
2. Signing & Capabilities for **NotificationService**: Keychain Sharing with
   group `dev.overalls.mila.shared`; set
   `CODE_SIGN_ENTITLEMENTS = NotificationService/NotificationService.entitlements`.
3. **Runner** target: no source files to add (AppDelegate carries its own
   Keychain helper for the same items). Only set
   `CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements` (Push Notifications
   with `aps-environment`, Keychain Sharing group `dev.overalls.mila.shared`;
   Xcode's provisioning switches `aps-environment` to `production` for
   distribution). Until then Runner still builds; poke keys are then stored
   in Runner's default Keychain group, which the extension cannot read.
4. **RunnerTests** target: add `NotificationService/PokeOpener.swift` to its
   membership; `RunnerTests/PushPokeTests.swift` checks the shared vectors
   from `protocol/test/fixtures/push_pokes.json`.
5. Run `RunnerTests` and send a sandbox push with `mutable-content: 1` and a
   `poke` field to verify decryption on a device.

## What was verified here

`swiftc -parse` (Swift 5.10 on Linux) accepts every Swift file. Nothing was
type-checked against the iOS SDK or run; CryptoKit, the Keychain and APNs are
unavailable outside Apple platforms. The Android opener, which implements the
same format, passes the same vectors on the JVM.
