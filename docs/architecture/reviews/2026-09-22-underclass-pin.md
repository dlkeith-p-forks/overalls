# Underclass pin advancement

## Scope and architecture impact

This review covers advancing the fleet's Underclass package from `18a7aa1` to
`b256419`. The update stays within ADR-0081's independent host-local pool,
authentication and diagnostic boundaries. No replacement decision is required.

## Findings and resolution

Upstream commit `a0ed73d` adds cross-proxy request correlation. It accepts an
incoming `x-request-id` only when the value satisfies bounded character and
length validation, otherwise generates a UUID, and forwards the resulting value
to provider requests. This improves correlation while preserving ADR-0081's
rule that authorization data and prompt bodies do not enter diagnostics.
Upstream tests cover accepted, rejected and generated identifiers and end-to-end
forwarding.

The remaining change updates `lru` from 0.12.5 to 0.16.3. Underclass's bounded
sticky-binding behavior and persisted SQLite cap remain unchanged. The Kittens
module, secret wiring, endpoint authorization, loopback bind and publication
model are unchanged.

## Verification

The pinned derivation builds from the immutable Git revision and locked Cargo
dependencies. Kittens package, evaluation and NixOS service checks exercise the
resulting package, configuration invariants, endpoint authorization, diagnostic
redaction and persistence. ADR and code-contract validation cover the updated
evidence and unchanged deployment contracts.

## Remaining gaps

ADR-0081 remains partial for the previously recorded live tailnet ACL,
second-host provider enrollment, backup and isolated-restore acceptance work.
