# ADR-0186: Covenant contract verification across Elixir applications

- ID: ADR-0186
- Date: 2026-10-17
- Status: accepted
- Implementation: partial
- Components: Elixir applications, contract verification, test tooling
- Supersedes: none
- Superseded by: none

## Context

The repository already records guarantees through colocated `CONTRACTS`
annotations ([ADR-0028](0028-colocated-code-contracts.md)), ADRs, the HLDD and
native and machine tests. It had no machine-readable, per-application inventory
of declared modules that a Mix test run could check deterministically.

## Decision

All twelve Elixir Mix applications maintain Covenant 0.2 development/test
contracts. Contract obligations live beside each application under `contracts/`
and executable evidence lives under `test/contract/`. Covenant is test-only and
never enters production releases or runtime configuration.

The contracts provide a deterministic, machine-readable inventory baseline and
may be expanded with behavior-specific evidence. Existing `CONTRACTS`, ADR,
HLDD, native, and integration evidence remains authoritative for guarantees
Covenant cannot exercise.

## Alternatives

The adopting change recorded no alternatives. Relying only on `CONTRACTS`
annotations stays in place alongside Covenant rather than being replaced.

## Consequences

Every application runs static Covenant coverage in its precommit path and
ordinary test formatters record runtime contract results. The baseline detects
missing or renamed declared modules, while explicit limitations prevent Elixir
unit tests from being treated as evidence of native isolation, KVM, physical,
or multi-host behavior.

## Invariants and verification

- Covenant MUST remain a `:dev`/`:test`, `runtime: false` dependency and never
  enter a production release.
- Each application's precommit MUST run static Covenant coverage
  (`covenant.check --no-run`).
- Covenant results MUST NOT be cited as evidence of native isolation, KVM,
  physical or multi-host behaviour.

## Implementation evidence

- [`marshall/mix.exs`](../../../marshall/mix.exs) declares the test-only
  dependency and runs `covenant.check --no-run` in precommit.
- [`marshall/contracts/README.md`](../../../marshall/contracts/README.md) and
  [`lilly/contracts/README.md`](../../../lilly/contracts/README.md) hold the
  per-application obligations.

Implementation is partial: the obligations are module-loadability baselines,
not behaviour-specific evidence.

## Open questions

- Which behaviour-specific obligations should extend the module baselines.

## Related decisions

- [ADR-0028](0028-colocated-code-contracts.md): colocated code contracts, which
  remain authoritative.
