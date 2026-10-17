# Legacy VM journal import review

Date: 2026-09-21

## Scope and architecture impact

[ADR-0088](../decisions/0088-legacy-vm-journal-import.md) adds a single
compatibility boundary for raw version-3 VM execution journals written before
[ADR-0074](../decisions/0074-durable-lifecycle-state-machines.md). This changes
host-local persistence and recovery, but not the protocol, physical execution
authority, resource accounting, isolation or application domain boundaries.
The review covers the importer, its tests, retained production state and the
automatic-update failure it must resolve.

## Findings and resolution

- Production Lilly was fenced because all 67 retained actor journals had the
  exact pre-lifecycle eleven-field shape. The current parser required a lifecycle
  envelope and `phase`; deleting the records would violate ADR-0017 durability.
- Merely reading the old shape was insufficient. Every later `attempt`, `record`
  or `acknowledge` would still fail because lifecycle publication refuses to
  replace a non-envelope file. The importer therefore performs a permanent
  atomic conversion during `open/4`.
- Phase inference is intentionally non-authoritative. A validated outcome maps
  to its closed state and no outcome maps to `idle`; native observation and
  command reconciliation still determine physical facts.
- Import reuses every existing identity, revision, coherence and outcome guard,
  then acquires the nested audit lock and byte-compares the source before atomic
  publication. Extra keys and other near-miss formats remain untouched.
- The initialization event records adoption time and is delivered through the
  existing bounded outbox. It cannot release capacity or authorize execution.
  Sixty-seven actors create sixty-seven one-event outboxes, handled by the
  existing 16-event delivery batch limit.

## Validation

- `mix test test/vm/journal_test.exs` passed in the pinned devenv runtime: eight
  tests, including one property. The new cases cover exact running import,
  authority preservation, valid lifecycle output, stable reopen, idle import
  and byte-preserving refusal of extra-key and identity-mismatch near misses.
  The import cases hold the actor lock required by `open/4` and prove a later
  ordinary lifecycle mutation succeeds through the imported envelope.
- The applicable `journal-lock-and-identity`,
  `lilly-independent-guest-lifetime`, `lilly-v3-only-execution`, and
  unprivileged-test contracts were reviewed against the implementation.
- Lilly's full `mix precommit` gate passed with the pinned Elixir 1.20.4/OTP
  29.0.6 runtime: ADR structure, code-contract structure and tooling tests,
  catalogued logging, 380 application tests including 43 properties, formatting,
  compilation and forced Dialyzer with zero errors.

## Remaining gaps

After deployment, verify all retained journals decode as lifecycle envelopes,
Lilly reports ready, the updater records the exact revision healthy, and no guest
process or durable execution identity is replaced. The audit-lock byte recheck
and uncertain atomic-write retry are enforced by the implementation and shared
private-file primitive but do not have importer-specific fault injection.
