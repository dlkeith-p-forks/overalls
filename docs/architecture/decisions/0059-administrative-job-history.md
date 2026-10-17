# ADR-0059: Administrative job history and intervention

- ID: ADR-0059
- Date: 2026-09-18
- Status: superseded
- Implementation: partial
- Components: Marshall, PostgreSQL, AshOban
- Supersedes: none
- Superseded by: ADR-0119

## Context

[ADR-0119](0119-authenticated-control-room-reads.md) replaces the administrator-only
read restriction and carries forward the other requirements below.

Administrators need queued, running, successful and failed job views, including
attempts and timing. Oban's short raw retention cannot provide the requested
30-day history. Raw arguments and exception strings can contain credentials.
Job completion also does not prove that asynchronous Lilly work has completed.

## Decision

The approved admin plan authorizes a separate Administration Ash domain. Persist
allowlisted job snapshots and transition events transactionally with Oban changes.
Keep terminal history for 30 days, independently of raw pruning; keep active job
snapshots until terminal or pruned. Do not retain raw arguments, raw exceptions
or job metadata. Only known worker/primary-key pairs may identify related domain
operations. Backfill surviving raw jobs in bounded background batches; missing
predeployment history remains unavailable.

Current Cedar administrator permission gates projections and interventions.
Expose bounded filtered pages, attempt counts, execution timing, redacted failure
indication and the independently read related operation state. Retry only raw
retryable/discarded jobs through Oban's API. Serialize retry with membership
changes, lock and recheck the job, and atomically record an actor/request-bound
audit receipt. Do not expose raw argument editing, queue control, or cancellation
of durable compute operations through Oban.

## Alternatives

Reading raw Oban rows directly would lose history at pruning and risk exposing
payloads. Asynchronous event capture alone could miss transitions on crashes.
Replacing raw-job retention with 30 days would unnecessarily retain sensitive
payloads. A job-success indicator alone would misrepresent physical completion.

## Consequences

A PostgreSQL trigger adds bounded writes to each meaningful Oban transition and
depends on its installed schema. Upgrade checks must exercise insert, transition,
retry and pruning behavior. Read filters exclude expired history before bounded
cleanup runs. Capture failure rolls back the job change, preserving consistency
at an availability cost. Backfill cannot reconstruct transitions already lost.

## Invariants and verification

- Job and history mutations commit or roll back together.
- All supported states, including suspended, have safe projections.
- Pruning preserves history but removes retry eligibility.
- Expired records are invisible before cleanup; active snapshots survive cleanup.
- Retry receipts are idempotent and cannot be reused for another job.
- Stale/forged roles cannot read or retry; live revocation blocks further events.
- Raw payload/error markers never appear in retained rows or browser replies.
- Pagination and cleanup stay bounded; capture overhead needs load measurement.

## Implementation evidence

The [migration](../../../marshall/priv/repo/migrations/20260918032925_admin_job_history.exs)
captures snapshots/transitions in the raw job transaction. The
[domain coordinator](../../../marshall/lib/marshall/administration/jobs.ex)
projects safe fields, checks authority and commits retries with audit receipts.
[Retention](../../../marshall/lib/marshall/administration/expire_job_history.ex)
and [backfill](https://github.com/antithesishq/kittens/blob/9fe1e493b2090d44bacd16089049cd12b316d58a/marshall/lib/marshall/administration/backfill_job_history.ex)
process at most 1000 rows per table per transaction. The
[Jobs LiveView](../../../marshall/lib/marshall_web/live/admin/jobs_live.ex)
implements filters, detail, transition history and retries. The
[domain tests](../../../marshall/test/marshall/administration/jobs_test.exs) and
[LiveView tests](../../../marshall/test/marshall_web/admin_jobs_live_test.exs)
exercise those boundaries. Campaign 019 adds [generated histories](../../../marshall/test/marshall/administration/job_history_test.exs),
[three-Marshall schedules](../../../marshall/test/marshall/administration/job_history_distributed_test.exs)
and a [packaged worker/browser journey](../../../nix/verification/tests/machines/job-history/default.nix).
The [review](../reviews/2026-09-25-job-history-verification.md) records passing
focused histories and ordering, the actor account-lock correction, detected
omission mutant, captured full application gate and complete native browser/worker
journey in 65.85 seconds. Database overhead measurement remains separate.
This superseded record retains its historical status.

## Open questions

No open product decisions. Multi-replica refresh coalescing and capture overhead
remain implementation/verification work within the approved database-load goal.

## Related decisions

[ADR-0003](0003-control-plane-coordination.md) retains durable domain coordination.
[ADR-0058](0058-administrative-authority.md) defines administrator membership.
