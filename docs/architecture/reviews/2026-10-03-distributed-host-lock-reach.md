# Distributed host-lock reach property

## Architecture impact

Baseline `be98725ccde295ffa46b29e70a389da048b175a7`. This verification change
preserves shared PostgreSQL authority, host-before-VM serialization and ADR-0055's
separation of clone queue acceptance from activation. Production actions, lock
order, protocols, persistence and deployment are unchanged.

## Scenario and oracle

Three independent Marshall BEAM peers attempt clone activation and opposite-source
relocations for three distinct stopped VMs on two fixture hosts. Fixed peer
rotations accompany generated endpoint direction. A separate holder retains both
fixture host rows in sorted order. Each real action tags its checked-out database
connection and restores the preceding application name, preserving both action
and restoration failures.

Before release, the observer requires all three tagged backend blocking chains
to reach the holder, plus an actual non-granted transaction-ID wait against its
granted exclusive transaction lock. Soft queue edges are not presented as direct
row ownership. Both production paths scan all retained hosts in sorted order;
unrelated rows remain intact. Ordinary destination eligibility must contain only
the fixture pair; a unique image alone does not constrain ordinary relocation.

Every successful relocation is checked against its requested VM, captured source
and opposite destination. Clone activation requires durable active workflow and
destination rows. At least one real transfer must commit; queue acceptance and
an all-refusal schedule cannot satisfy reach. Existing independent raw committed
accounting and exact fixture-restoration oracles remain in use. Partial peer
acquisition now stops acquired peers before propagating failure.

## Verification

The focused property passed seed `219491` in 51.6 seconds, warnings-as-errors,
terminal exit 0 (one passed, two unselected properties excluded).
Log: `/tmp/overalls-capacity-host-lock-focused.log`. This records actual three-peer
blocking-chain reach, committed oracle checks and complete fixture restoration.
The complete distributed-capacity file passed all three properties, seed `396307`,
in 162.6 seconds, warnings-as-errors, terminal exit 0.
Log: `/tmp/overalls-capacity-host-lock-history.log`. Fresh source review found no
blocker in result validation, transaction custody or cleanup. Partial-acquisition
and tag-restoration failure branches have source review but no injected-failure
execution evidence. Full publication gates exited 0: all-file static checks,
ADR and handbook/reference/coverage/view checks, evaluated Nix HLDD, and Marshall
precommit. Marshall passed 1,424 checks (223 properties, 1,201 tests), two excluded,
seed `893479`, in 1305.7 seconds. Forced Dialyzer passed in 48.96 seconds with zero
errors, skips or unnecessary skips. Log: `/tmp/overalls-capacity-host-lock-full-gates.log`.
This execution predates integration of remote `d651c460`; merged checks remain required.

## Local mutation check

An isolated worktree reversed only `RelocationAdmission`'s host-ID order while
clone placement retained ascending order. The same focused seed `219491` failed
after zero successful generated runs, rotation 0 and forward endpoint direction,
in 22.4 seconds, exit 2. PostgreSQL reported `40P01` with a two-backend
transaction wait cycle. The blocking witness had completed; the property failed
when its closed relocation-refusal classifier rejected the Ash-wrapped deadlock
in `absorb_step/3`. This is evidence for the complete property, not evidence that
the preceding recursive structured-error detector recognized this wrapper.
Log: `/tmp/overalls-capacity-host-lock-mutant.log`; exact patch:
`/tmp/overalls-host-lock-descending-mutant.patch`. The primary worktree received no
mutation. Restored source passed the same seed in 50.0 seconds, warnings-as-errors,
exit 0 (one passed, two unselected properties excluded).
Log: `/tmp/overalls-capacity-host-lock-restored.log`. Fresh review confirmed the
failure attribution. The complete one-line mutant was:

```diff
-            |> Enum.sort_by(& &1.id)
+            |> Enum.sort_by(& &1.id, :desc)
```

## Remaining gaps

This is a controlled PostgreSQL schedule, not native transfer execution or hosted
fault search. Physical ingress, lifecycle, evacuation and account/team lock
cycles require separate reachable scenarios. Structured returned deadlocks and
closed clone activation results are rejected; opaque errors in other mutation
families retain the preceding oracle's limitation. This local mutation check does
not establish a hosted SDK falsification or universal lock-order detection.
