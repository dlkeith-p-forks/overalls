# Mila native parity matrix

This matrix is the migration gate for ADR-0249. It compares the behavior in
the retained Flutter client with the native shells. A row is **implemented**
only when the native UI, its Rust adapter, and a platform test or build
receipt cover the behavior. A controller, command classifier, or localized
label by itself is **partial** evidence; it does not prove an end-to-end
workflow.

## Status legend

- **partial**: native code or a focused test exists, but an end-to-end user
  workflow, persistence, OS integration, or release evidence is missing.
- **open**: no native implementation has been found for the Flutter behavior.
- **implemented**: native workflow and platform verification cover the listed
  behavior. No row currently meets this bar for every platform.

## Feature matrix

| Flutter behavior (source of truth) | Rust/core evidence | Apple (SwiftUI) | Android (Compose) | Linux (GTK4/libadwaita) | Windows (WinUI/.NET 10) |
| --- | --- | --- | --- | --- | --- |
| Deployment list, add, forget, select (`features/deployments_screen.dart`, `forget_deployment.dart`) | Route and host validation; device-key policy | partial: `MilaNativeUI.swift` host/route surface; no durable deployment store or sign-in journey | partial: `MilaDeployments.kt`, persisted deployment/approval, authenticated session binding, and typed reconnect overload; complete UI trust/signer flow remains open | partial: host entry, route validation, durable XDG store, and restore; no complete sign-in journey | partial: host entry, connect state, and durable LocalApplicationData store; approval lifecycle remains open |
| Sign-in, approval, reconnect (`sign_in_screen.dart`, `session.dart`) | `mila-session` SSH listing, certificate checks and bounded `whoami --json` approval envelope | partial: FFI/session scaffolding; approval and lifecycle not wired | partial: persisted deployment, one live certificate-authenticated session, validated HTTPS approval browser action and same-session `whoami` polling; device/release journey remains open | partial: `SignInCoordinator` validates the endpoint, reconciles pinned/fetched HTTPS trust in Rust, and `FileDeviceSigner` enforces owner-only P-256 key files with signature tests; HTTPS transport and GTK approval journey remain open | partial: generation-scoped approval/expiry/reconnect reducer and typed approval-page launcher; live browser approval outcome and backend reconnect transport remain open |
| Machine list/detail/snapshot (`machines_screen.dart`, `machine_screen.dart`) | bounded machine snapshot/list projection | partial: shell only; no complete list/detail | partial: authenticated Rust session listing, Compose machine selection/detail and typed mutation state; packaged device journey remains open | partial: authenticated session listing projection, bounded GTK machine rows/detail, and permission-aware display; live deployment journey remains open | partial: authenticated Rust listing FFI, bounded typed rows, selection/detail projection and mutation gating; live Windows backend journey remains open |
| Machine create/resize/start/stop/pause/resume/delete (`machine_form.dart`, `machine_actions.dart`) | command parsing/classification and policy | partial: no mutation dispatch | partial: `MilaMachineControls.kt` classifiers/tests and authenticated session mutation seam; complete UI session binding remains open | partial: classifier buttons only | partial: authenticated Rust start/stop/pause/resume/delete and bounded resize dispatch; create and live Windows backend journey remain open |
| Machine sharing (`sharing_controller.dart`) | authorization policy primitives | partial: typed SwiftUI controller and FFI request boundary; authenticated share transport remains open | partial: typed principal validation and authenticated mutation seam; share UI/backend binding remains open | partial: authenticated Rust share mutation seam and bounded command tests; GTK session binding remains open | partial: share command classification only |
| Threads, turns, prompts, answers, plan approval (`threads/*`) | route and command validation; bounded thread response decoding | partial: route/shell and typed machine workflow; authenticated session lifecycle remains open | partial: authenticated Rust/JNI thread listing and closed-command actions with bounded Compose state/input; packaged device journey remains open | partial: thread command validation only | partial: bounded typed thread listing and Show/Turns/Read/Prompt/Answer/Plan controls; live backend remains open |
| Terminal attach/stream/input/resize/reconnect/kill (`terminal/*`) | bounded terminal reducer, permission/dimension validation and text bounds | partial: `MilaTerminal.swift` and live-session adapter; native PTY stream remains open | partial: bounded renderer with authenticated-session-gated attach/input/resize and sanitized receive projection, reconnect tests; live PTY transport/device journey remains open | partial: `TerminalStream` generation-scoped attach/output/reconnect/kill, bounded text renderer, GTK lifecycle controls, and input/resize validation; `HostPtyTransport` binds an injected host channel to the authenticated session generation with lifecycle tests; Porsche SSH/PTY backend and GTK stream wiring remain open | partial: attach/resize/input validation; no PTY stream/renderer |
| Web controls/webview (`web/*`) | bounded web endpoint projection and web command classification | partial: typed HTTPS endpoint and native WKWebView wrapper; authenticated web transport remains open | partial: authenticated Rust web show/set, machine-bound endpoint validation, optimistic revision requirement, and Compose WebView; packaged device journey remains open | partial: authenticated `LiveSession` web show/set with optimistic revision and bounded HTTPS endpoint projection; GTK browser launch and host transport journey remain open | partial: authenticated Rust web-show binding and session-gated WinUI controls; web-set revision UI and embedded WebView remain open |
| SSH keys (`ssh_keys/*`) | key policy and device signer boundaries | partial: device signer plus typed authenticated key list/revoke FFI and Settings UI; CI Swift verification remains open | partial: `MilaSshKeys.kt` authenticated-session store, bounded JSON decoder, opaque-id revoke with at-most-once request IDs, and controller tests; packaged device approval/reconnect journey remains open | partial: revoke command validation only | partial: authenticated Rust FFI list/revoke wrappers, generation-fenced controller and WinUI projection; live Windows CI journey remains open |
| Push notifications/devices (`notifications/*`) | push registration/poke validation | partial: UserNotifications authorization and device metadata store; APNs delivery integration remains open | partial: `MilaNotifications.kt` OS-permission-gated provider registration, Rust-validated app/deployment metadata, durable identifier/toggle/remove CRUD, and tests; FCM token delivery and server-side device CRUD remain open | partial: authenticated Rust device list/remove/preferences projections with bounded command formatting and refusal tests; Linux has no push provider or registration journey | partial: typed WNS channel metadata validation/controller and runner provider hooks; live channel exchange, Susan delivery and Porsche device CRUD remain open |
| App lock (`lock/*`) | lock/device-key persistence boundaries | partial: design/settings surface; authenticator lifecycle remains unverified | partial: lifecycle, persisted lock state, and Android BiometricPrompt integration; broader device coverage remains open | partial: explicit unavailable capability state | implemented: typed Windows Hello broker and lock/unlock verification controller; CI smoke coverage |
| Settings, appearance, locale (`settings_screen.dart`, `preferences.dart`) | locale policy and generated catalogs | partial: design tokens, catalog loader, and persisted preferences | partial: design tokens, catalog loader, persisted SharedPreferences deployment/settings, and canonical BCP-47 locale validation | partial: catalog loader, GTK controls, and XDG settings persistence | partial: catalog loader, GTK controls, and XDG settings persistence |
| Deep links and share/open actions (`routes.dart`, web/share providers) | canonical route parser in Rust/Linux adapter | partial: route tests, app integration open | partial: `MilaDeepLinkController` accepts only canonical typed targets and rejects stale lifecycle generations, malformed IDs, and command-like query links; Android intent wiring/share provider remains open | partial: bounded typed multi-URI activation now classifies unknown, signed-out and authenticated deployment targets; target widgets and share-provider integration remain open | open |

The matrix deliberately records gaps even where a native button calls a Rust
classifier. ADR-0249 requires the Rust core to authorize real mutations and
the native layer to verify lifecycle, secure storage, and release behavior.

## Verification commands

Run from the repository root inside `devenv shell` where the platform toolchain
is available:

```sh
cargo test --manifest-path mila/rust/Cargo.toml --workspace
cargo test --manifest-path mila/native/linux/Cargo.toml --locked
./gradlew -p mila/native/android test
swift test --package-path mila/native/apple
dotnet test mila/windows-dotnet/Mila.Windows.csproj
```

The first two commands provide current Rust/core and Linux evidence. Android,
Apple, and Windows commands require their respective SDKs and are expected to
be run by native CI; a successful compile alone does not change a row to
implemented. Before Flutter removal, each row must have a native end-to-end
receipt on all applicable platforms and the Flutter source/build references
must be absent.

## Review record

This is a migration review artifact for ADR-0249, not a claim of completion.
It has no server schema or protocol impact. The current repository lacks the
Elixir runtime needed to run `scripts/check_hldd.exs`; the parent change must
run the mandatory HLDD status/record/check commands and attach receipts for
this path before merging.
