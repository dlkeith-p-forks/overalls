# Mila native Apple custody review

Scope: native Swift Secure Enclave adapter under ADR-0220, ADR-0235 and
ADR-0249. The accepted custody boundary is unchanged: one non-exportable P-256
key per deployment; Swift exports public material and signatures only.

The adapter preserves the existing keychain application tag and macOS
data-protection scope. Lookup errors refuse signing rather than generating a
replacement identity. Only item-not-found permits creation. Existing items must
identify the Secure Enclave token and expose a valid P-256 point. Messages are
bounded to 64 KiB and signatures are converted from Security DER to Rust's
fixed-width representation. No private-key export or diagnostics are present.

Open findings: signed Apple execution is required to establish actual key reuse,
non-exportability and entitlement behavior. Unsigned macOS development software
custody is not implemented by this adapter; unavailable hardware fails closed.
The signer is not yet connected to live-session callbacks. Native release
packaging must verify entitlements independently. Tests cover host validation
and signature conversion only, and were not executed on this Linux host.
