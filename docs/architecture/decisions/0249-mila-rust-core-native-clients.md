# ADR-0249: Mila Rust core with native platform clients

- ID: ADR-0249
- Date: 2026-10-20
- Status: accepted
- Implementation: partial
- Components: Mila
- Supersedes: none
- Superseded by: none

## Context

Mila's shipped client is Flutter and currently contains transport, protocol,
cryptographic and state-transition code beside its widgets. The product must
ship native clients on Apple (iOS and macOS), Android, Linux and Windows while
keeping behavior consistent and auditable. Windows is supported on the latest
.NET SDK only.

## Decision

1. Shared protocol, cryptography, transport orchestration, state transitions,
   persistence contracts and test models live in typed Rust crates under
   `mila/rust`. Crates are split by dependency and compile-time boundary.
2. Platform applications are thin UI and OS integration layers: SwiftUI for
   iOS/macOS, Jetpack Compose for Android, GTK4/libadwaita for Linux, and WinUI
   3 targeting the latest .NET SDK for Windows. They call the Rust core through
   typed, versioned FFI adapters and do not reimplement authorization or
   protocol rules.
3. Device key custody, push registration, secure storage, terminal surfaces,
   deep links and platform lifecycle remain OS-specific adapters behind core
   traits. Secrets and raw transport bytes never cross a UI boundary.
4. Rust behavior is verified with Hegel property tests and shared fixtures;
   native integration tests verify adapter and lifecycle invariants. Flutter is
   retained until native parity evidence is recorded, then removed.

Authorization: the approved native rewrite request (2026-10-20).

## Alternatives

- **Keep Flutter and add platform plugins.** Rejected: core behavior would
  remain coupled to one UI runtime and native lifecycle guarantees would be
  incomplete.
- **Duplicate domain logic in each native client.** Rejected: divergence would
  undermine protocol and authorization invariants.

## Consequences

Rust compilation and FFI versioning become release dependencies, but protocol
behavior is shared and property-tested. Native build toolchains are required
for release evidence. Platform accessibility, lifecycle and secure-storage
behavior must be tested per OS.

## Invariants and verification

- All externally reachable routes and mutations pass through the Rust core;
  malformed input is rejected and mutations are at-most-once.
- FFI surfaces use typed handles and bounded buffers; no UI receives private
  keys or unvalidated terminal data.
- Hegel properties and shared fixtures run in the Rust workspace; native CI
  builds each target and exercises adapter smoke tests.

## Implementation evidence

The initial workspace and adapters are in [`mila/rust/Cargo.toml`](../../../mila/rust/Cargo.toml),
[`mila/native/apple`](../../../mila/native/apple),
[`mila/native/android`](../../../mila/native/android),
[`mila/native/linux`](../../../mila/native/linux) and
[`mila/windows-dotnet`](../../../mila/windows-dotnet). The Rust workspace,
Hegel fixtures and Nix checks pass on Linux. Transport, secure-storage,
feature-complete screens, native-host builds and Flutter removal remain open.

The terminal attachment reducer is ported from Dart in
[`terminal.rs`](../../../mila/rust/mila-runtime/src/terminal.rs), with private
state, current-generation headers, replay reset accounting, closed outcomes,
retry exhaustion and server/user permission gates. Hegel action sequences in
[`terminal.rs`](../../../mila/rust/mila-runtime/tests/terminal.rs) exercise the
pure reducer; native PTY transport and renderer integration remain unverified.

## Open questions

None blocking the direction; platform key-storage and release-signing details
remain implementation work under ADR-0235.

## Related decisions

[ADR-0220](0220-mila-client-over-porsche-ssh.md),
[ADR-0222](0222-porsche-client-commands.md),
[ADR-0225](0225-marshall-notifications-domain.md),
[ADR-0235](0235-mila-desktop-clients.md).
