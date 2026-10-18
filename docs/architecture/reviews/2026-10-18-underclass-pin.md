# Underclass package pin (2026-10-18)

## Scope and architecture impact

Advance the immutable Underclass package in
[`nix/domains/artifacts/underclass/default.nix`](../../../nix/domains/artifacts/underclass/default.nix)
from `469aff4c797e14052285d64d9acfa4b2fc0c73a3` to upstream `main`
revision `7169223709693504882d0f7c3d2f34660682c936`. The source archive hash
was refreshed. The upstream `Cargo.lock` is unchanged, so the vendored Cargo
hash remains `sha256-trXMnTioYNjr74HjFcDjMvJ8GYUG0UTiPVi68PNBzEk=`.

This is a package-input refresh within ADR-0081 and ADR-0102. The existing
instrumentation patch, host-local pool ownership, private credentials,
loopback proxy, and tokenless monitor boundary remain unchanged. No domain,
protocol, persistence, authorization, isolation, or deployment topology
boundary changes.

## Validation and remaining gaps

The upstream revision and source archive hash were inspected on 2026-10-18;
`Cargo.lock` byte content matches the preceding pin. Tests and package builds
were not run, per request. The existing `doCheck = false` package policy and
prior pin evidence remain applicable; live provider behavior and production
activation still require separate verification.
