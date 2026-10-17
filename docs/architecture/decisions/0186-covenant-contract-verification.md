# ADR-0186: Covenant contract verification across Elixir applications

- **Status:** accepted
- **Date:** 2026-10-17

## Decision

All twelve Elixir Mix applications maintain Covenant 0.2 development/test
contracts. Contract obligations live beside each application under `contracts/`
and executable evidence lives under `test/contract/`. Covenant is test-only and
never enters production releases or runtime configuration.

The contracts provide a deterministic, machine-readable inventory baseline and
may be expanded with behavior-specific evidence. Existing `CONTRACTS`, ADR,
HLDD, native, and integration evidence remains authoritative for guarantees
Covenant cannot exercise.

## Consequences

Every application runs static Covenant coverage in its precommit path and
ordinary test formatters record runtime contract results. The baseline detects
missing or renamed declared modules, while explicit limitations prevent Elixir
unit tests from being treated as evidence of native isolation, KVM, physical,
or multi-host behavior.
