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
| Deployment list, add, forget, select (`features/deployments_screen.dart`, `forget_deployment.dart`) | Route and host validation; device-key policy | partial: `MilaNativeUI.swift` host/route surface; no durable deployment store or sign-in journey | partial: `MilaDeployments.kt`, `MilaSignInState.kt`, unit tests; no complete UI persistence flow | partial: host entry, route validation, durable XDG store, and restore; no complete sign-in journey | partial: host entry, connect state, and durable LocalApplicationData store; approval lifecycle remains open |
| Sign-in, approval, reconnect (`sign_in_screen.dart`, `session.dart`) | `mila-session` SSH listing and certificate checks; approval/browser orchestration remains open | partial: FFI/session scaffolding; approval and lifecycle not wired | partial: typed sign-in states and session listing tests; approval/reconnect not wired | open: route validation only | partial: connection status and session listing projection; approval/reconnect not wired |
| Machine list/detail/snapshot (`machines_screen.dart`, `machine_screen.dart`) | bounded machine snapshot/list projection | partial: shell only; no complete list/detail | partial: session listing, machine detail, and typed action state in Compose; authenticated live backend evidence remains open | partial: shell controls; no list/detail | partial: list projection and selection in `SessionListing.cs`; no complete detail |
| Machine create/resize/start/stop/pause/resume/delete (`machine_form.dart`, `machine_actions.dart`) | command parsing/classification and policy | partial: no mutation dispatch | partial: `MilaMachineControls.kt` classifiers/tests and authenticated session mutation seam; complete UI session binding remains open | partial: classifier buttons only | partial: classifier buttons plus create entrypoint; no mutation dispatch |
| Machine sharing (`sharing_controller.dart`) | authorization policy primitives | partial: typed SwiftUI controller and FFI request boundary; authenticated share transport remains open | partial: typed principal validation and authenticated mutation seam; share UI/backend binding remains open | partial: authenticated Rust share mutation seam and bounded command tests; GTK session binding remains open | partial: share command classification only |
| Threads, turns, prompts, answers, plan approval (`threads/*`) | route and command validation; turn/session models remain incomplete | partial: route/shell and typed machine workflow; authenticated session lifecycle remains open | partial: typed thread detail/action state, payload validation, and authenticated action seam; live turn UI/session binding remains open | partial: thread command validation only | partial: bounded typed thread listing and Show/Turns/Read/Prompt/Answer/Plan controls; live backend remains open |
| Terminal attach/stream/input/resize/reconnect/kill (`terminal/*`) | bounded terminal reducer, permission and dimension validation; native PTY renderer remains open | partial: `MilaTerminal.swift` and live-session adapter; no verified PTY stream | partial: attach/resize state and tests; no verified PTY stream/input renderer | partial: `TerminalStream` generation-scoped attach/output/reconnect/kill and input/resize validation; GTK PTY renderer remains open | partial: attach/resize/input validation; no PTY stream/renderer |
| Web controls/webview (`web/*`) | web command classification and route validation | partial: typed HTTPS endpoint and native WKWebView wrapper; authenticated web transport remains open | partial: typed HTTPS WebView and authenticated web show/set FFI seam; full session/UI verification remains open | partial: web command validation only | partial: web show/set controls; no embedded webview |
| SSH keys (`ssh_keys/*`) | key policy and device signer boundaries | partial: device signer and typed authenticated key list/revoke FFI; complete Swift UI verification remains open | partial: `MilaSshKeys.kt` controller/tests; no authenticated list/revoke | partial: revoke command validation only | partial: bounded typed listing/revoke controller and WinUI projection; authenticated backend wiring remains open |
| Push notifications/devices (`notifications/*`) | push registration/poke validation | partial: UserNotifications authorization and device metadata store; APNs delivery integration remains open | partial: `MilaNotifications.kt` state/tests and durable metadata store; Android OS provider registration remains open | open | partial: local toggle only; no OS registration/device CRUD |
| App lock (`lock/*`) | lock/device-key persistence boundaries | partial: design/settings surface; authenticator lifecycle unverified | partial: lifecycle, persisted lock state, and Android BiometricPrompt integration; broader device coverage remains open | partial: explicit unavailable capability state | implemented: typed Windows Hello broker and lock/unlock verification controller; CI smoke coverage |
| Settings, appearance, locale (`settings_screen.dart`, `preferences.dart`) | locale policy and generated catalogs | partial: design tokens, catalog loader, and persisted preferences | partial: design tokens, catalog loader, and persisted SharedPreferences deployment/settings | partial: catalog loader, GTK controls, and XDG settings persistence | partial: catalog loader, GTK controls, and XDG settings persistence |
| Deep links and share/open actions (`routes.dart`, web/share providers) | canonical route parser in Rust/Linux adapter | partial: route tests, app integration open | partial: route parser instrumentation only | partial: `route.rs` parser/tests, multi-URI desktop activation, and durable deployment restore | open |

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
