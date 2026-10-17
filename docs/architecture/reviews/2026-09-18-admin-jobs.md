# Administrative jobs

## Scope and architecture impact

This review covers the Administration domain, retained job projections, PostgreSQL
capture trigger, retry coordinator and authenticated LiveViews in the admin
worktree. [ADR-0059](../decisions/0059-administrative-job-history.md) records the
new persistence boundary; [ADR-0058](../decisions/0058-administrative-authority.md)
supplies current administrator authority. ADR-0003's durable domain coordination
remains in force. Neither job success nor retry acceptance establishes physical
VM completion.

## Evidence and findings

The [capture migration](../../../marshall/priv/repo/migrations/20260918032925_admin_job_history.exs)
copies a field allowlist in the Oban transaction. Raw args/errors are excluded;
only recognized worker primary keys are retained for correlation. The
[coordinator](../../../marshall/lib/marshall/administration/jobs.ex) never projects
raw Oban rows. It rechecks persisted Cedar authority, locks the membership latch
before retry, locks the raw job, uses Oban's retry API and commits a receipt in
the same transaction. Pruned rows remain readable but cannot be retried.

- Fixed implementation defects found by tests: PostgreSQL enum/text comparison,
  Ash aggregate query options and omitted optional action arguments. These fixes
  are in the undeployed draft migration and implementation.
- Fixed timing projection: old terminal timestamps must not describe a newly
  queued/running attempt. Terminal time is selected by the current state.
- Remaining verification: capture/backfill load and WAL measurement, concurrent
  retry versus worker transitions and demotion, and final full-gate result.
- Remaining implementation: shared refresh coalescing to bound the cost of many
  open admin tabs/replicas. Current reads are paginated but counts remain global
  retained-raw aggregations. Do not claim the database-load target is satisfied.
- Retained capture depends on the installed Oban schema. Future Oban upgrades
  must rerun transition/retry/pruner tests before rollout.

## Verification performed

Fourteen focused domain and LiveView tests passed, covering all eight job states,
transaction rollback, pruning, expiry, safe projection, pagination, retry
idempotency, stale role denial, displayed-job binding and active login revocation.
Tests use sandbox ownership on the private port-55439 PostgreSQL fixture. The
full Marshall test phase passed 561 checks. A subsequent isolated three-peer
retry race passed: all callers received acceptance while one receipt and one
new-attempt transition persisted. The focused 14 tests passed again against the
database containing retained distributed fixture history; collection tests now
filter their own queue. Dialyzer subsequently passed, completing that gate. No production migration or fleet
acceptance is claimed.

## Contracts and follow-up

Reviewed Administration's current-authority, allowlisted-projection and bounded
read contracts against coordinator and LiveView callers; retry, retention and
backfill notes state atomicity and limits. Contract syntax is a structural check,
not evidence of semantic correctness. Remaining work stays in the
[full acceptance ledger](../../admin-implementation.md); this review does not
reduce the approved monitoring, operations or evacuation scope.
