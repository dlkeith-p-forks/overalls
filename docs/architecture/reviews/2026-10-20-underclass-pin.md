# Underclass package pin (2026-10-20)

## Scope and architecture impact

Advance the immutable Underclass package in
[`nix/domains/artifacts/underclass/default.nix`](../../../nix/domains/artifacts/underclass/default.nix)
from `7169223709693504882d0f7c3d2f34660682c936` to upstream `main`
revision `dbaf7b8fc62fdb447c00f4b8746a66ff51db3c1c`. The source archive hash
was refreshed. The upstream `Cargo.lock` and `Cargo.toml` are unchanged, so the
vendored Cargo hash remains `sha256-trXMnTioYNjr74HjFcDjMvJ8GYUG0UTiPVi68PNBzEk=`.

The revision retries a streamed request on another pool account when upstream
fails it with a capacity code before any output (upstream ADR 0022). It also
records a stream `error` event's nested error code. Both changes stay inside the
proxy process and the host-local pool. Credentials, the loopback listener, the
tokenless monitor and egress are unchanged. This is a package-input refresh
within ADR-0081 and ADR-0102. No domain, protocol, persistence, authorization,
isolation or deployment topology boundary changes.

The instrumentation patch still applies: its two `src/proxy.rs` hunks land on
the admission and the successful-response wrap, and the second hunk needs fuzz
only because a new match arm follows it. A request that retries on another
account stays one admission and records one outcome. When every account
overloads, the replayed upstream error drops its admission and records one
failure, as other pool-exhausted responses already do.

## Validation and remaining gaps

- `nix build .#tool-underclass` succeeded offline, producing
  `underclass-0.1.0-dbaf7b8`.
- On the upstream source with the instrumentation patch and `slo.rs` applied,
  `cargo test` passed: 110 library tests (including the SLO journal tests), 7
  e2e tests (three new failover cases) and 22 Hegel properties.
- NixOS machine tests were not run.
- Live provider failover and production activation remain unverified.
