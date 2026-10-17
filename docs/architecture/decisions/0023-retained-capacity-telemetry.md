# ADR-0023: Retained capacity telemetry

- ID: ADR-0023
- Date: 2026-09-16
- Status: superseded
- Implementation: implemented
- Components: Marshall telemetry, hosts and scheduling
- Supersedes: none
- Superseded by: ADR-0149

## Context

[ADR-0149](0149-independent-observability.md) replaces application diagnostic
transport, persistence and presentation, with Lilly v4 and Ziggy v2 documents.
It carries forward unrelated authority, isolation, transactional audit/accounting
and recovery requirements. The original rationale and historical evidence follow.

ADR-0006 requires the latest one-second observation, ten-second summaries for
24 hours and five-minute summaries for 30 days. Latest host/pool observations
already exist. Retained summaries must survive Marshall failover without counting
retries twice or interpreting a missing measurement as free capacity.

## Decision

The user's implementation instruction authorizes this refinement of the accepted
retention policy. A separate Ash Telemetry domain owns per-host and per-pool
summary resources. Every accepted report updates both resolutions inside the
existing PostgreSQL transaction holding the host row lock. Admission continues
to use current observations and durable reservations, never historical summaries.

Buckets are half-open UTC intervals aligned to Unix time, using the report's
accepted sample timestamp (future timestamps are clamped to database time).
Reports may correct a recently closed bucket within the existing five-second
freshness allowance. Expiry is bucket end plus 24 hours or 30 days respectively.
No raw report history is retained. Each resolution is accumulated directly;
five-minute summaries do not depend on a later rollup job.

Allowlisted metrics carry units, known/unknown counts, sum, sample mean, minimum
and maximum. Missing, malformed, negative or out-of-range values are unknown;
zero is a measurement. Sample means are not duration-weighted rates, operation-
weighted latency or percentiles. Sample count is not a coverage percentage.
Missing buckets remain absent. First/last sample timestamps expose the observed
span. Context records bounded source/device/architecture details, the latest
sample's context and whether context changed inside the bucket. A maximum IOPS
measurement requires provenance. Mixed-source buckets must not be described as
measurements from a single unchanged source.

Reserved and allocatable capacity are sampled from the same locked ledger using
admission's budget arithmetic. They describe that report instant, not every
reservation transition. Enabled/execution readiness accompany the observation;
historical allocatable bytes or cores do not imply current scheduling eligibility.

Cedar permits summary operations only to the internal system actor. History is a
bounded, keyset-paginated read action for one host, entity, resolution and time
range. PostgreSQL statement time determines read expiry, independent of each
Marshall node's wall clock or the database session's time zone. It excludes
expired rows even while physical cleanup lags. It does not
grant ordinary users access to physical host inventory. Operator access remains
part of the enrollment/operations workflow.

An AshOban scheduled action runs every minute. Each transaction physically
deletes at most 1,000 expired rows using an indexed, ordered `SKIP LOCKED` query
with a single bound database-clock cutoff.
A full batch atomically schedules a uniquely identified continuation. Duplicate
workers are harmless; failed transactions roll back both deletion and continuation.
Telemetry deliberately has no archival or paper-trail copy: either would defeat
retention. Deleting a host cascades its summaries. Existing audited lifecycle
resources retain their separate policies.

## Alternatives

Raw per-second history increases storage and replay work. Asynchronous rollups
need an additional durable ingestion checkpoint to prevent loss and duplication.
Updating both resolutions under the existing host lock gives one commit boundary,
at the cost of database writes on each accepted report. Per-row expiration jobs
create unnecessary job volume. Unbounded deletion can monopolize database work.

## Consequences

The protocol and Lilly are unchanged. The new table must be migrated before new
Marshall binaries accept reports. Historical summaries begin at deployment;
missing earlier data is not backfilled. A telemetry write failure rejects the
whole report, preserving consistency but potentially making that host stale.
Database cost and retention backlog require fleet-load measurement. A bucket
whose context changed can mix capacities or devices; extrema and the change flag
must remain visible to consumers.

## Invariants and verification

- Duplicate, reordered, invalid and stale-epoch reports add no samples.
- Both resolutions and the latest report commit or roll back together.
- Concurrent control planes serialize accepted observations through the host lock.
- Unknown values never lower a mean as though they were zero.
- Bucket assignment, counts, extrema and expiry are property-tested.
- Cleanup cannot delete unexpired observations; bounded continuations drain backlog.
- Public users cannot read or mutate internal physical-host history.

## Implementation evidence

[Summary resource](https://github.com/antithesishq/kittens/blob/a99f74f06542798dc9ef288e77c99d480433fc57/marshall/lib/marshall/telemetry/summary.ex),
[recorder](https://github.com/antithesishq/kittens/blob/a99f74f06542798dc9ef288e77c99d480433fc57/marshall/lib/marshall/telemetry/recorder.ex),
[metric extraction](https://github.com/antithesishq/kittens/blob/a99f74f06542798dc9ef288e77c99d480433fc57/marshall/lib/marshall/telemetry/observations.ex),
[statistics](https://github.com/antithesishq/kittens/blob/a99f74f06542798dc9ef288e77c99d480433fc57/marshall/lib/marshall/telemetry/statistics.ex) and
[retention action](https://github.com/antithesishq/kittens/blob/a99f74f06542798dc9ef288e77c99d480433fc57/marshall/lib/marshall/telemetry/expire.ex) implement
the persistence and transaction boundary. The
[migration](../../../marshall/priv/repo/migrations/20260916012936_retained_capacity_telemetry.exs)
creates the table, uniqueness and expiry indexes, and host cascade.
[Statistics properties](https://github.com/antithesishq/kittens/blob/a99f74f06542798dc9ef288e77c99d480433fc57/marshall/test/marshall/telemetry/statistics_test.exs),
[observation checks](https://github.com/antithesishq/kittens/blob/a99f74f06542798dc9ef288e77c99d480433fc57/marshall/test/marshall/telemetry/observations_test.exs),
[database tests](https://github.com/antithesishq/kittens/blob/a99f74f06542798dc9ef288e77c99d480433fc57/marshall/test/marshall/telemetry/retention_test.exs) and
[three-node tests](../../../marshall/test/marshall/compute/distributed_admission_test.exs)
verify aggregation, privacy, rollback, retention and concurrent retry behavior.
The [review](../reviews/2026-09-16-retained-telemetry.md) records the passing
168-case Marshall suite, host checks and static-analysis gates. Fleet performance
is a separate acceptance obligation and remains open.

## Open questions

Measure write amplification, report latency and retention lag at fleet load.
Percentiles and duration-weighted aggregates are not requested guarantees.
Operator presentation and credentials belong to the operations milestone.

## Related decisions

[ADR-0006](0006-capacity-accounting.md),
[ADR-0010](0010-capacity-admission-transactions.md),
[ADR-0013](0013-capacity-collection-and-local-receipt.md).

Interface references: [AshOban scheduled actions](https://hexdocs.pm/ash_oban/dsl-ashoban.html),
[PostgreSQL function volatility and index conditions](https://www.postgresql.org/docs/current/xfunc-volatility.html).
