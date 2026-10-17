# Namespace sweep planner properties

## Architecture and source scope

This test-only change preserves Lilly's accepted fenced ZFS cleanup behavior,
privilege boundary, configured limits and production helper. Reviewed source:
`lilly/native/zfs-namespace-unmount/src/lib.rs`, `plan` and its `sweep` consumer.
The existing native descriptor-only, hidden-proc and busy-user captures retain
their original revisions and scopes. No native safety claim follows from the
pure planner tests.

The previous success oracle checked boundedness and consecutive deduplication
without requiring target preservation. The mixed-state property now requires
independent exact target-set equality and cardinality. New Hegel properties
exercise generated counts/keys/duplicates plus fixed 511/512/513 distinct-target
and 32,767/32,768/32,769 total-observation boundaries. The total-observation
property verifies `plan` inputs, not the separate native `/proc` scan counters.

## Validation

Final pinned Cargo execution passed eight checks in 0.48 seconds. Cargo fmt and
Clippy across all targets with warnings denied passed. Log:
`/tmp/kittens-namespace-final-properties.log`.

Two isolated mutants copied into `/tmp` failed the targeted new property:
dropping the last target failed expected 511 versus observed 510 cardinality
(0.54 seconds); refusing one target before the configured cap failed the
bounded exact-inventory witness (2.89 seconds). Logs:
`/tmp/kittens-namespace-omission-mutant.log` and
`/tmp/kittens-namespace-cap-mutant.log`. Both failures were assertion failures
in `exact_namespace_cap_preserves_all_targets`; compiler failure alone would
not establish mutant detection. Production source was not mutated.

Fresh source review found no blocker and identified the nonadjacent duplicate
oracle gap, now closed by exact cardinality. Pinned Lilly `mix precommit` passed
474 checks (84 properties and 390 tests) in 65.8 seconds with seed 637027;
forced Dialyzer passed with zero errors in 15.31 seconds. Runtime, ADR and
structural contract checks passed in the same execution. Log:
`/tmp/kittens-namespace-lilly-precommit.log`. Final handbook and repository
publication gates remain pending.

## Remaining evidence

Arbitrary process/descriptor churn, denied native inventory, changing aliases
or descendants, descriptor closure during inspection, and real namespace
enter/unmount failures remain separate native scenarios. A successful pure plan
does not establish custody or permit force/lazy unmount, process termination,
or reservation release without confirmed physical deletion.
