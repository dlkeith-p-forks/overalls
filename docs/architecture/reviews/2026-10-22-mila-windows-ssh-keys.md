# Mila Windows authenticated SSH keys (2026-10-22)

Scope: the Windows/.NET Mila client path for account SSH-key listing and
revocation over an already certificate-authenticated Porsche session.

The WinUI projection now supplies the existing Rust session handle to typed
interop wrappers for `mila_session_ssh_keys` and
`mila_session_ssh_key_revoke`. Listing bytes cross into managed code only in a
caller-owned, size-bounded buffer and are decoded into `MilaSshKey` records.
Revocation accepts only canonical UUID identities and a generated
`porsche-` request id. The controller fences stale listing completions when a
refresh or sign-out supersedes them, and marks the device's own fingerprint so
the current key cannot be revoked from the list.

Evidence is present in
`mila/windows-dotnet-smoke/Program.cs`: malformed request/session inputs are
refused, the bounded listing decoder and controller projection are exercised,
and the production ABI version check requires the staged native library. A
Windows host and live Porsche journey were not available in this environment;
the receipt therefore does not claim native transport or CNG/TPM execution.

Architecture impact: this preserves ADR-0220's Porsche-only authenticated
transport and ADR-0235's Windows custody boundary. No Marshall API, protocol
wire shape, Ash domain, or deployment placement changes.
