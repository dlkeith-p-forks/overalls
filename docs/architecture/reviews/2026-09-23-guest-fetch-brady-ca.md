# Guest web fetch and fleet Brady CA architecture review

## Scope and decisions

This review covers the guest HTTP execution boundary, Marshall capability and
command authority, Brady signing custody, fleet activation and guest trust.
It reconciles ADR-0069, ADR-0100, ADR-0103, ADR-0108 and ADR-0109.

## Findings

Marshall remains the authority for profile-scoped tools, persistent commands,
fencing and audit. `web_fetch` is dispatched only after the existing executor
claim; the Rust CLI reports `started` before making a network request. Its
blocking HTTP client uses the guest network path, native certificate roots,
bounded redirects, time, downloaded bytes and serialized result size. The
result may contain untrusted remote text and stays in authorized thread data.
The CLI emits only closed fetch state events; the existing command transition
receipts carry no URL or body. The primitive HTML projection is intentionally
limited to readable headings, lines and text; complex page structure is not
preserved.

The public Brady fleet root is the one trust anchor installed on hosts and
both guest image types. Its signing key is recovery-only ciphertext. Each host
has a separate encrypted intermediate signer, supplied as a private systemd
credential. Brady includes that intermediate in the generated leaf chain.
The auto updater now checks Brady with the other required health units. A
host missing or unable to decrypt its signer cannot start Brady successfully.

The existing Brady fleet machine test uses a synthetic issuer and tests real
guest interception, attribution, restart behavior and content-free logs. It
does not prove that the new production encrypted signers can be decrypted by
both hosts or that a guest trusts their chains after relocation. Those claims
require live activation and a cross-host guest probe.

## Verification and rollout boundary

Rust unit tests cover URL rejection, a real loopback fetch, HTML projection and
serialized result bounds. Marshall property tests cover profile combinations
and forbidden calls. Rust tests, Clippy, formatting, Marshall precommit (including
Dialyzer), the Python static gate, ADR and contract structure checks, the secret
inventory check, guest configuration evaluations and Nix package checks passed.
The public root fingerprint and 2046 expiry were checked with OpenSSL. The NixOS
and Ubuntu agent fleet checks exercise the full guest model/tool round trip and
local fetch; their result is recorded below. Live activation of
Brady on both hosts, auto updater health and trusted intercepted HTTPS from
both guest image types after placement on either host remain unverified.

## Native guest checks

The NixOS and Ubuntu agent fleet machine tests passed. Each real guest completed
the model/tool round trip, fetched from a VM-local HTTP service through the Rust
CLI, and kept the fetched content out of audit events.
