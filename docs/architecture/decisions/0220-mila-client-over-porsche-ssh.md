# ADR-0220: Mila, the Overalls client over Porsche SSH

- ID: ADR-0220
- Date: 2026-10-18
- Status: accepted
- Implementation: partial
- Components: Mila, Porsche, protocol
- Supersedes: none
- Superseded by: none

## Context

Overalls has no mobile client. Users want to manage machines, chat with the
agent, attach terminals and open published web apps from iOS and Android, with
a Linux desktop build for testing. Every capability already exists behind
Marshall's Ash domains and is reachable through Porsche's `--json` SSH
commands ([ADR-0046](0046-porsche-ssh-management.md)). Porsche already signs
users in by browser approval of an SSH key. A new HTTP API would duplicate the
authority checks that the SSH path already enforces.

## Decision

1. Mila is a Flutter application (`mila/`) for iOS, Android and Linux. All
   deployment interaction goes through **one SSH connection to Porsche** per
   deployment, running `--json` commands. Mila adds no HTTP API; authority
   stays in Marshall ([ADR-0142](0142-overallsprotocol-control-websocket.md)).
2. Each deployment gets its own **P-256 device key**: Secure Enclave on iOS,
   StrongBox (or TEE Keystore without StrongBox) on Android, and a software
   key in an owner-only `0600` file on Linux. Private keys are
   non-exportable on mobile; only public points and DER signatures cross the
   platform channel. Separate keys keep deployments from correlating a device.
3. Sign-in reuses browser key approval: Porsche returns `approval_url`, Mila
   opens it in the system browser and keeps the connection open, re-checking
   `whoami` on new exec channels until approval or a 600-second link expiry.
4. Mutations use client-allocated `porsche-<32 hex>` request ids with
   `--no-wait`, then poll `request show`; a request is never resubmitted.
5. Envelopes are decoded strictly. `result` bodies tolerate unknown keys,
   because store-distributed clients lag servers; this deviation is recorded
   here deliberately.
6. Pure protocol and state-machine code lives in `mila_core` (no Flutter);
   SSH, keys and trust live in `mila_transport` (no Flutter); the app holds
   presentation, platform channels and localization.

Authorization: the approved Mila plan (2026-10-18).

## Alternatives

- **A Marshall REST/GraphQL API.** Rejected: it duplicates authorization and
  session handling that Porsche already proves, and widens the public surface.
- **One device key for all deployments.** Rejected: a shared public key lets
  deployments link one device across operators.
- **Ed25519 device keys.** Rejected: neither Secure Enclave nor StrongBox
  generates non-exportable Ed25519 keys; P-256 is the common hardware curve.
- **Polling `whoami` on new connections.** Rejected: each connection would be
  a new approval candidate. One connection keeps one pending approval.

## Consequences

The client inherits Porsche's command catalog, refusal reasons and receipts.
Every new client feature needs a Porsche command (ADR-0222/0223). Hardware key
custody needs native code on each platform, which Nix cannot build for iOS.

## Invariants and verification

- Command lines are produced only by `encodeCommand` and must parse back with
  the shared lexer; Elixir and Dart share `protocol/test/fixtures/ssh_command_lines.json`.
- A mutation is submitted at most once; terminal polls absorb later outcomes
  (Hegel `StateMachine` over the request poll).
- An approval link already shown is never replaced; expired links stay
  expired (Hegel `StateMachine` over sign-in, mutation-checked).
- Device keys are P-256 and owner-only on Linux; a world-readable key file is
  refused, not used.
- Porsche accepts `ecdsa-sha2-nistp256` client keys and proves possession only
  after a signature.

## Implementation evidence

- `mila/packages/mila_core/lib/src/{ssh_command,porsche_reply,request_poll,sign_in,machine}.dart`
  with tests in [`mila/packages/mila_core/test/`](../../../mila/packages/mila_core/test) (53 tests, Hegel properties
  and stateful machines); run by the `mila-core` Nix check.
- `mila/packages/mila_transport/lib/src/{device_key,ssh_porsche}.dart` and
  `test/` (19 tests, including a stock OpenSSH server); run by `mila-transport`.
- [`mila/app/`](../../../mila/app) sign-in and machine screens with widget and golden tests (28
  tests); run by `mila-test`.
- [`porsche/test/ssh_proof_test.exs`](../../../porsche/test/ssh_proof_test.exs) proves a P-256 device key through real
  OpenSSH; [`protocol/test/ssh_key_test.exs`](../../../protocol/test/ssh_key_test.exs) bounds P-256 key parsing.
- [`mila/app/ios/Runner/AppDelegate.swift`](../../../mila/app/ios/Runner/AppDelegate.swift) and
  [`mila/app/android/app/src/main/kotlin/dev/overalls/mila/MilaPlatform.kt`](../../../mila/app/android/app/src/main/kotlin/dev/overalls/mila/MilaPlatform.kt)
  implement hardware custody. **Gap:** neither has been compiled or run on a
  device in this change.
- [`nix/verification/tests/machines/mila-porsche/`](../../../nix/verification/tests/machines/mila-porsche) drives the production
  transport against the real Porsche release and passed
  ([M1 review](../reviews/2026-10-18-mila-m1.md)).

- M5 device features ([device review](../reviews/2026-10-18-mila-device.md)):
  - push registration
    ([`push_registration.dart`](../../../mila/packages/mila_core/lib/src/push_registration.dart),
    a Hegel `StateMachine`), with the relay key client and registrar in
    [`susan.dart`](../../../mila/packages/mila_transport/lib/src/susan.dart) and
    [`push_registrar.dart`](../../../mila/packages/mila_transport/lib/src/push_registrar.dart);
  - poke opening against the shared vectors
    ([`push_poke.dart`](../../../mila/packages/mila_core/lib/src/push_poke.dart));
  - the app lock policy
    ([`app_lock.dart`](../../../mila/packages/mila_core/lib/src/app_lock.dart));
  - the owner-only offline machine snapshot
    ([`snapshot_cache.dart`](../../../mila/packages/mila_core/lib/src/snapshot_cache.dart),
    [`snapshot_store.dart`](../../../mila/packages/mila_transport/lib/src/snapshot_store.dart)).

  The `mila-core`, `mila-transport` and `mila-test` checks run them
  (90, 32 and 39 tests).
- [`nix/verification/tests/machines/mila-desktop/`](../../../nix/verification/tests/machines/mila-desktop)
  drives the Linux bundle with real X input against packaged Marshall and
  Porsche through browser approval, the machine list, forwarded `overalls://`
  links and a restart; it passed (7 subtests, recorded in the device review).

  **Gap:** the iOS notification extension, the Android messaging service and
  `local_auth` have not been built or run on a device.

Remaining: threads, terminal and web (M2–M4).

## Open questions

None for this decision; per-feature questions are in ADR-0222 to ADR-0225.

## Related decisions

[ADR-0046](0046-porsche-ssh-management.md),
[ADR-0124](0124-unified-ssh-host-ca.md),
[ADR-0221](0221-canonical-app-routes.md),
[ADR-0222](0222-porsche-client-commands.md),
[ADR-0226](0226-monospace-web-on-flutter.md),
[ADR-0227](0227-flutter-toolchain-and-dartssh2-overlay.md),
[ADR-0228](0228-strict-host-certificates-in-mila.md).
