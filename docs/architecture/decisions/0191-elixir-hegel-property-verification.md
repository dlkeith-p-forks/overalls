# ADR-0191: Elixir Hegel property verification

- ID: ADR-0191
- Status: accepted
- Date: 2026-10-17
- Supersedes: none

## Decision

Elixir applications use the pinned `hegel_ex` binding as the property engine for
new and migrated test-only properties. The dependency is development/test only,
runtime disabled, and is consumed from a reviewed upstream revision. Properties
must use bounded, typed generators; deterministic seeds and replay metadata; and
redacted diagnostics by default. Fixture-backed properties create and tear down
isolated state for each generated case. Stateful and concurrent properties
explicitly define a model, command history, oracle, and schedule boundary.

Hegel properties complement ordinary ExUnit tests, Covenant contracts, native
Rust tests, and NixOS machine tests. A BEAM property does not establish KVM,
physical isolation, host recovery, deployment, or production guarantees.
Those claims require the corresponding native or machine evidence.

## Rationale

The existing StreamData suite provides broad input coverage but has inconsistent
replay, shrinking, fixture cleanup, and diagnostics. Hegel gives the applications
one engine shared with the native verification stack while preserving the
separation between BEAM and machine evidence. Redacted traces avoid leaking
credentials, terminal bytes, command arguments, or payloads into CI artifacts.

## Implementation evidence

- [Elixir Hegel testing guide](../../development/testing-with-hegel.md)
- [Hegel Elixir skill](../../../.agents/skills/hegel-elixir-tests/SKILL.md)
- `hegel_ex` test-only dependency declarations in each migrated Mix project
- property tests under each application's `test/` tree

Migration status is tracked by the test inventory and review record; properties
are only marked migrated after the new test has executed successfully with the
pinned native engine. StreamData removal is a completion criterion, not an
implicit result of adding the dependency.

## Consequences

Each application gate must run the Hegel native smoke/replay checks and its
normal compiler, contract, Dialyzer, and ExUnit checks. Fixture-heavy and
multi-node suites may migrate incrementally, but must retain their existing
contract and machine evidence until equivalent coverage is recorded.
