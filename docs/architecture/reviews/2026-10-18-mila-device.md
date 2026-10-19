# Mila M5: push registration, poke decryption, app lock and offline cache (2026-10-18)

Scope: the Mila client side of
[ADR-0220](../decisions/0220-mila-client-over-porsche-ssh.md),
[ADR-0224](../decisions/0224-susan-push-relay.md) and
[ADR-0225](../decisions/0225-marshall-notifications-domain.md). Reviewed
against the uncommitted working tree on branch `feat/mila-mila-device`,
based on `e4259258`. Susan, Marshall's notifications domain and Porsche's
`device` commands are other workstreams; this review covers only what Mila
sends and accepts.

## Findings

1. **Boundary:** Mila still adds no HTTP API to Marshall. It makes one new
   outbound call: `POST https://notifications.overalls.dev/api/push/v1/keys`.
   The origin is a constant; the transport refuses any other URI, follows no
   redirects, uses no proxy and trusts only the system store
   (`mila-susan-fixed-origin`). Device registration goes through Porsche as
   `device register --platform P --push-key - --enc-pubkey K`.
2. **Secrets on the wire:** The push key goes only on the exec channel's
   stdin, never on the command line. The platform token goes only in the
   Susan request body. Neither is persisted: the registration record keeps a
   non-reversible digest of the token, the device id, the key id and the
   expiry. Widget tests assert that no command line and no saved setting
   contains the token or the push key.
3. **End-to-end encryption:** Pokes are opened in pure Dart
   (`openPoke`), Swift (CryptoKit) and Kotlin (BouncyCastle X25519 and
   ChaCha20-Poly1305). All three follow `protocol/test/fixtures/push_pokes.json`.
   Dart matches every vector, including a byte-for-byte deterministic reseal.
   Hegel properties show that any flipped byte, truncation or extension is
   refused. The plaintext schema is closed: `{v:1, kind:"needs_input",
   route}`, where the route must parse as a canonical app route on the same
   host. A notification shows only fixed localized text; the route is used
   only as the tap link (`mila-native-notification-fixed-text`).
4. **Key custody:** Poke X25519 keys are per deployment. On iOS they live in
   a Keychain group shared with the NotificationService extension
   (`AfterFirstUnlockThisDeviceOnly`). On Android they are wrapped by a
   Keystore AES key. Only the 32-byte public key crosses the platform
   channel. Removing the device deletes the key.
5. **Registration state machine:** `PushRegistration` is pure and checked by
   a Hegel `StateMachine` against a fake server. That run had 1500 cases,
   80 steps each, and covered delayed, reordered and stale replies. The
   properties are:
   - no registration leaks after the user turns notifications off;
   - a stale reply never changes state;
   - each retry is a fresh operation;
   - a key is rotated within 14 days of expiry;
   - `push_disabled` stops retries.

   Five hand-made mutants of the machine were each killed by these
   properties.
6. **App lock:** `AppLock` fails closed. A saved lock covers Mila from the
   first frame. The content under the lock is offstage and left out of the
   semantics tree, so it is never painted or exposed. An unlock result from
   an older attempt is ignored. Linux reports the lock as unavailable, and
   the setting says so.
7. **Offline cache:** Snapshots hold machine rows only. They are capped at
   500, decoded under a closed schema (`mila-snapshot-closed-schema`), merged
   newest-wins, and kept per deployment in owner-only files
   (`mila-owner-only-files`). A group- or world-readable file is deleted, not
   read. While a saved list is shown, the actions on it are disabled.
8. **Desktop journey:** `mila-desktop` drives the Linux bundle with real X
   input against packaged Marshall and Porsche (see below). The runner is now
   single-instance: a second `mila overalls://…` forwards its link over the
   platform channel to the running window. The integration flavour adds only
   a screen probe that reports what the screen already shows
   (`mila-integration-probe-scope`).
9. **Gap — native builds:** Swift (NotificationService, AppDelegate) and the
   Firebase service have not been built or run on a device. Kotlin
   `PokeOpener` was compiled with kotlinc 2.3.21 and passed 4 JUnit tests
   against the fixture. The Xcode target for the extension needs the manual
   steps in `mila/app/ios/NotificationService/README.md`.
10. **Gap — server side:** Susan, the Marshall `Device` resource and Porsche's
    `device` commands are not in this tree. Mila's argument formats are listed
    in the workstream handoff for reconciliation. The desktop test cannot
    exercise registration because Linux has no push service.

## Verification

- `mila-check` (devenv): `mila_core` **90 passed**, `mila_transport`
  **32 passed**, app **39 passed**; format and `--fatal-infos` analysis
  clean.
- Nix checks `mila-core`, `mila-transport`, `mila-test` and `mila-lock-sync`
  built successfully.
- `node scripts/check_contracts.mjs` passed once a pre-existing note-grouping
  error in `nix/domains/artifacts/guest/android.nix` was patched locally.
  That file is outside this change, and the patch was not kept.
- `nix build .#checks.x86_64-linux.mila-desktop`: `mila-desktop` **7 subtests
  passed** (test script finished in 79 s) on this tree:
  - pending approval;
  - browser approval leading to the machine list;
  - owner-only settings and snapshot;
  - notifications unavailable, with the docs link;
  - forwarded links in one window;
  - restart persistence with the offline list and the unavailable lock;
  - no approval link or token in Mila's log.

  The live list is empty because the fixture has no Lilly host.
