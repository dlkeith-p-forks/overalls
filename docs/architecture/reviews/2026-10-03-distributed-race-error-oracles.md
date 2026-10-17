# Distributed race error oracles

## Architecture impact

Baseline `1470ab5d8a80fa78289da37b84aa1af16b15b112`. Verification changes
preserve ADR-0055 clone queue and activation authority and the inherited
capacity admission decisions. No production lock order, transaction, protocol,
domain, persistence or recovery behavior changes.

## Source gap and repaired oracle

The [capacity race interpreter](../../../marshall/test/marshall/compute/distributed_capacity_race_test.exs)
previously accepted any returned clone activation error when no destination row
existed. A rolled-back SQL failure could therefore leave a valid accounting
inventory and pass as an ordinary placement refusal. Raised or exited peer
operations already failed the supervising task.

Every returned coordinated step now rejects recursively retained structured
Postgrex deadlock evidence. Clone activation additionally admits only success
or the existing documented atom refusal class, before either destination-state
branch. Opaque Ash/Postgrex errors cannot pass as ordinary clone refusals.
Diagnostics contain fixed classifications, rather than arbitrary error payloads.

The regression property constructs a real Postgrex deadlock and passes it through
the pinned `Ash.Error.to_ash_error/1`, then tests the actual step validator across
nested maps, lists and tuples. Generated depths 0/1/3/8 include fixed 0/8
witnesses. Known refusals and success remain accepted; error-like strings/atoms
do not become SQL evidence.

Pinned Ash/Splode can flatten an underlying exception into opaque error text.
Recursive structured inspection cannot recover every SQL code from that text.
The clone result class rejects opaque failures without substring classification;
opaque errors in other step families are not universally identified as deadlocks.
The existing cleanup deadlock retry belongs to fixture teardown, not mutation
evidence or an application retry policy.

## Verification

The focused distributed suite passed both properties, seed `202304`, in 60.2
seconds, with warnings-as-errors and terminal exit0. Log:
`/tmp/overalls-deadlock-oracle-focused.log`.
This includes the existing generated histories across three independent Marshall
BEAMs and the new error-wrapper regression. Fresh review of this source found no
concrete blocker. The full Marshall test phase passed 1,423 checks (222
properties, 1,201 tests), with two exclusions, seed `59328`, in 1,465.7 seconds.
Forced Dialyzer passed in 44.48 seconds with zero errors, skips or unnecessary
skips. The combined all-file, handbook, generated-reference, evaluated Nix HLDD
and Marshall precommit command exited0. Log:
`/tmp/overalls-deadlock-oracle-full-gates.log`. After recording this evidence,
all-file/static, ADR, handbook, generated-reference and evaluated Nix HLDD
publication checks passed with terminal exit0. Log:
`/tmp/overalls-deadlock-oracle-publication-gates.log`.

## Remaining schedules

This repairs error acceptance in existing histories; it adds no new database
lock schedule. Explicit overlapping-host clone activation/relocation/lifecycle
barriers, opposite-source relocations, physical ingress versus activation,
account/team foreign-key cycles, evacuation approval locks and background-job
retry masking remain separate targets. Native host execution and hosted fault
exploration are not established by these properties.
