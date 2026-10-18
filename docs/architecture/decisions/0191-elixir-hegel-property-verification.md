# ADR-0191: Elixir Hegel property verification

- ID: ADR-0191
- Status: accepted
- Date: 2026-10-17
- Implementation: partial
- Components: protocol, marshall, lilly, verification
- Supersedes: none
- Superseded by: none

## Context

Elixir applications already use generated tests alongside fixed examples,
contracts and machine verification. Their property engine needs bounded input
generation, deterministic replay, isolated fixtures and redacted diagnostics.
The existing suite is not yet fully migrated, and a test dependency alone cannot
establish either migration completion or native acceptance.

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

## Alternatives

Retaining StreamData alone would preserve the current generator APIs but would
not establish the shared replay and diagnostic policy. Replacing machine tests
with BEAM properties would lose native isolation and recovery evidence. Hegel is
therefore test-only and complements the existing verification layers.

## Invariants and verification

Generators remain bounded and typed; fixed seeds and replay metadata reproduce
failures without exposing drawn secrets. Every generated fixture is cleaned up
on success, refusal and failure. Application compiler, contract, Dialyzer and
ExUnit gates remain required. Passing BEAM properties never establishes KVM,
storage durability, physical recovery or deployed fleet behavior.

## Implementation evidence

- [Elixir Hegel testing guide](../../development/testing-with-hegel.md)
- [Hegel Elixir skill](../../../.agents/skills/hegel-elixir-tests/SKILL.md)
- [Protocol test-only dependency pin](../../../protocol/mix.exs)
  currently selects frontend ref `02cd8bd`,
  as do Marshall and Lilly. The historical complete protocol gate at
  `2c9f7a4a9f2cf156de063bbc8058bcf297be5cf0` passed 299 tests and properties;
  the linked review retains that source hash and the earlier `6a62795` result.
  Those results do not establish execution at the current pin. The frontend now
  propagates standalone `check all` options; context-pattern expansion, tuple
  bindings and filter compatibility still require narrow consumer repairs.
  These repairs preserve generated assertions and production interfaces.
- [Protocol terminal properties](../../../protocol/test/hegel_terminal_test.exs)
  define bounded frame round trips and truncation cases with deterministic seeds.
  Their presence does not record execution or completion of the wider migration.
- [Protocol bounded generators](../../../protocol/test/support/test_generators.ex)
  retain exact alphabets, collection bounds, malformed peer shapes and unsigned
  64-bit values within the pinned engine's signed integer interface.
- [Protocol draw boundary](../../../protocol/test/support/test_properties.ex) and
  its [native failure replay test](../../../protocol/test/hegel_support_test.exs)
  keep generated values out of draw diagnostics while preserving the original
  exception. Control transport cases clean up owned listeners and supervised
  children before another generated case or replay.

Migration status is tracked by the test inventory and review record; properties
are only marked migrated after the new test has executed successfully with the
pinned native engine. StreamData removal is a completion criterion, not an
implicit result of adding the dependency.

## Open questions

Remaining application migrations need an inventory, executed property and replay
results, and verified fixture cleanup before their existing engines are removed.
Native Hegel smoke and full consumer gates retain their own execution records.
Protocol still retains StreamData for its workspace-source and View properties;
the pinned frontend does not provide every accepted stateful/concurrent API.

## Related decisions

- [ADR-0186: Covenant contract verification](0186-covenant-contract-verification.md)
- [Elixir Hegel verification review](../reviews/2026-10-17-elixir-hegel-property-verification.md)

## Consequences

Each application gate must run the Hegel native smoke/replay checks and its
normal compiler, contract, Dialyzer, and ExUnit checks. Fixture-heavy and
multi-node suites may migrate incrementally, but must retain their existing
contract and machine evidence until equivalent coverage is recorded.
