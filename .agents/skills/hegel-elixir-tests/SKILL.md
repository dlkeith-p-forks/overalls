---
name: hegel-elixir-tests
description: Create, migrate, run, and review Elixir property tests using the repository's Hegel engine; use for StreamData migration, generator design, stateful/concurrent BEAM verification, replay, and evidence reporting.
metadata:
  short-description: Maintain Hegel property tests in Elixir
---

# Hegel property tests for Elixir

Use this skill when changing generated tests in an Overalls Mix application or when
reviewing a Hegel property. It applies to BEAM-level behavior and test tooling; it
does not replace NixOS machine tests, native Rust tests, browser probes, or fixed
ExUnit tests where those provide the required evidence.

## Before editing

1. Read the repository `AGENTS.md`, the target application's `AGENTS.md`, ancestor
   `CONTRACTS` files, relevant ADRs, and the current HLDD testing section.
2. Find the application's reviewed Events catalog before adding diagnostics. Hegel
   failures and test telemetry must use catalogued metadata and must not expose
   credentials, tokens, terminal bytes, command arguments, or payloads.
3. Identify the existing property runner, dependency pin, fixtures, sandbox ownership,
   and whether the property crosses a native, host, distributed, or machine boundary.
   Record architecture and HLDD impact before implementation.

## Write properties

- Keep Hegel development/test-only (`runtime: false`) and use the repository-pinned
  native engine. Fail clearly when the NIF or ABI version is unavailable.
- Prefer explicit typed generators and bounded values. Give collections finite size;
  do not generate arbitrary atoms, PIDs, references, resources, secrets, or unbounded
  terms implicitly. Use assumptions only for genuinely unreachable combinations.
- Draw values through the explicit test-case API (`Hegel.draw/2` or `/3`) and label
  draws. Keep process-dictionary convenience APIs at the boundary rather than in
  domain helpers.
- Set up and tear down every mutable fixture per generated case and replay: SQL
  sandboxes, processes, sockets, temporary files, registries, and distributed nodes.
  Cleanup errors are failures and must not be swallowed. Make setup idempotent so
  shrinking and replay cannot observe leftovers from a previous case.
- For stateful behavior, model commands, preconditions, transitions, postconditions,
  and invariants separately. Use engine-managed pools for values produced by earlier
  commands; rejected commands should be distinguishable from failed assertions.
- For concurrency, use controlled Hegel schedules and inspect the complete history
  against a reference model or linearizability oracle. Keep real multi-node, KVM,
  isolation, and recovery claims in their existing machine/integration suites.
- Preserve refusal, malformed-input, stale-generation, duplicate, restart, and
  redaction assertions from the migrated property. A Hegel property may strengthen
  coverage but must not weaken an existing contract.
- Keep diagnostics redacted by default. Include labels, locations, seeds, and bounded
  structural metadata; opt into values or replay blobs only when the test explicitly
  proves they are safe. Failure rendering must preserve the original exception.

## Migration and review

When replacing StreamData, first inventory all `property`, `check all`, generator,
fixture, and dependency usages. Convert mechanical syntax with an AST-assisted tool,
then review every property for Hegel size, shrinking, assumptions, context setup,
and replay cleanup. Remove stale `StreamData`/`ExUnitProperties` dependencies and
lock entries only after all applications compile.

Review each property for:

- a precise input/output type and bounded generator;
- deterministic seed/replay behavior;
- setup and teardown ownership on pass, failure, rejection, and timeout;
- secret-safe diagnostics and catalogued events;
- evidence limits (BEAM behavior versus native or deployment guarantees);
- meaningful shrinking rather than filtering away the interesting state space.

## Run and report

Run the smallest focused property or replay first, then the target application's
`mix precommit`. Shared protocol changes require both Marshall and Lilly consumer
checks. Run contract, ADR, logging, conflict-marker, and HLDD checks required by the
repository. Record exact seeds/replay identifiers, test counts, and known skipped
boundaries; do not describe a passing BEAM property as proof of physical isolation or
production recovery.

For failures, retain the minimized replay and original exception, identify whether the
cause is a generator, oracle, fixture cleanup, engine, or product defect, and add a
regression property when appropriate. If the engine or NIF cannot load, report the
pinned version and reproducible build command rather than silently falling back to a
weaker runner.

## References

- Existing machine Hegel patterns and redaction rules: [`docs/development/testing-with-hegel.md`](../../../docs/development/testing-with-hegel.md)
- Contract scope and evidence limits: [`docs/development/code-contracts.md`](../../../docs/development/code-contracts.md)
- Architecture review requirements: [`architecture-review`](../architecture-review/SKILL.md)
- Contract discovery and enforcement: [`code-contracts`](../code-contracts/SKILL.md)
