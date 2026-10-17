# Maintenance evacuation foundation

## Scope and architecture impact

[ADR-0061](../decisions/0061-maintenance-evacuation.md) adds persisted evacuation
authority alongside ADR-0026 drain and ADR-0037 relocation. This changes persistence,
maintenance admission and administrative authorization; accepted intent comes from
the full admin plan. Lilly/shared protocol and ordinary relocation behavior remain
unchanged. The new decision is accepted and partial, not native acceptance.

## Evidence

Request locks the source host, rechecks current admin authority, fixes a bounded
cohort, records the requester and creates a periodic job in the same transaction
as entering enabled `evacuating` mode. Existing ingress/SSH enabled checks therefore
retain serving eligibility, while normal-host admission continues to reject the
source. Actual serving continuity still needs native tests.

Advancement rechecks candidate hosts under sorted locks, then the campaign/item/VM.
At most one cohort item enters existing relocation reservation/slot/job creation;
the item link commits with those effects. Source admission requires the exact
active campaign and stable placement/epoch/state, independently of later requester
demotion. Only matching campaign moves can pass evacuation source eligibility in
the stop coordinator and cancellation retry. Destinations require normal mode.

Full-stop fallback of a running guest requires a per-item approval retaining the
approving administrator and timestamp. Approval is not reused after a placement,
epoch or desired-state change. Fixed blocker codes are recorded in a separate
host-serialized transaction after failed admission rolls back. This preserves
capacity atomicity and lets other pending items receive later attempts.

Pause changes future scheduling only. Ready/resume/retire require fresh host and
pool observations, no current VMs or held resources, and no unfinished relocation.
Resume restores admission; retirement revokes host credentials. Controller identity
is retained in PaperTrail changes. Forward-only migrations preserve campaign and
approval history. Composite FKs bind the campaign to its relocation source host,
the cohort placement to its VM, and the relocation link to that VM/campaign.

## Findings and remaining obligations

- Preview, administrator console controls, detailed movement/cleanup progress and
  per-workload re-planning are now implemented. Campaign requests, controls, approvals
  and replans now emit redacted transactional administrator audit events. Correlation
  across those audit rows, jobs and physical observations remains bounded and partial.
- Changed cohort workloads and cancelled moves remain blocked until explicit
  administrator re-planning binds a new epoch and invalidates earlier downtime
  approval; it must not silently expand authority.
- **Unverified concurrency:** current tests are serialized fixtures. Concurrent
  request/control/worker races and late blocker writes need independent peers.
- **Unverified physical behavior:** actual two-Lilly movement, data/state/sharing/
  address preservation, ingress/SSH continuity and source cleanup remain required.
- The 128-host/1000-workload request bounds are explicit failure limits, not proof
  of useful scheduling/DB latency. The source transfer slot still limits concurrency.

## Verification and contracts

Five new evacuation tests and eighteen existing relocation-capacity tests pass,
including requester demotion, paused scheduling, scoped source eligibility,
per-workload full-stop approval and stale-readiness rejection. A regression in the
optional-campaign boolean guard was caught by existing ordinary relocation tests
and fixed before this checkpoint. The full Marshall test phase then passed 595
checks; its Dialyzer phase subsequently passed. ADR validation passed 56 decisions and structural
contract checks passed. Native acceptance remains unverified. Subsequent console
and re-planning work is recorded in the [maintenance console review](2026-09-18-maintenance-console.md).

Reviewed ancestor compute/authorization contracts, Ledger transaction semantics,
relocation resource/capacity/coordinator/restoration and existing drain behavior.
New notes specify fixed authority, approval binding, bounded scheduling and physical
readiness. Do not infer whole guest recovery from the source eligibility unit check.
