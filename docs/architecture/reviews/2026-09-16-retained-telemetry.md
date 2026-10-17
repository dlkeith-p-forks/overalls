# Retained capacity telemetry review

## Scope and architecture impact

ADR-0023 implements the retention policy in ADR-0006 through a new Ash Telemetry
domain. ADR-0010's host lock and transaction remain authoritative for admission;
ADR-0013's existing report format supplies measurements. Lilly and the shared
protocol are unchanged. Accepted reports now commit latest capacity and both
summary resolutions together. Summaries remain internal physical-host data.

The implementation adds the summary table, a unique entity/bucket key, an expiry
index, a cascading host reference and an AshOban scheduled action. It deliberately
uses physical deletion without audit/archival copies. Other domains retain their
existing audit, archival and encryption requirements.

## Findings and resolution

- **High, retry correctness:** capture occurs after epoch/sequence validation
  while holding the existing host lock. Three separate Marshall nodes submitting
  nine copies of a report produce one accepted sample. Both summary resolutions
  and latest capacity roll back if either resolution cannot be written.
- **High, unknown capacity:** absent, malformed and out-of-range measurements
  remain unknown. Known zero is retained. Sample means do not claim time coverage,
  operation-weighted latency or percentiles. Integer sums/extrema preserve byte
  counts; displayed means use floating point. A maximum IOPS observation requires
  provenance. Source changes remain visible in the bucket.
- **Medium, corrected clock authority:** inspection of the installed Ash SQL
  implementation showed that generic `now()` uses the application clock.
  History now uses UTC PostgreSQL statement time. Cleanup binds one database
  timestamp for each batch. Read and deletion expiry do not depend on Marshall
  node clock agreement.
- **Medium, corrected cleanup query cost:** a volatile per-row clock predicate
  cannot provide an index range condition. The bound cutoff allows the expiry
  index to skip unexpired rows. An `EXPLAIN` with sequential scans disabled
  confirmed index-condition eligibility; this is not a fleet performance test.
- **High, retention retry boundary:** deletion and continuation insertion share a
  transaction. An injected Oban insertion failure against committed fixtures
  preserves the entire expired batch; subsequent real AshOban jobs drain it.
  Jobs delete at most 1,000 rows and leave unexpired observations intact.
- **Medium, bounded reads and access:** history uses keyset pagination with a
  1,000-row maximum and filters host/entity/resolution/range. Cedar denies ordinary
  users reads and cleanup actions. Operator access is still an administrative
  release-console workflow, with no new public host-history API.
- **Open acceptance work:** report latency, write amplification, retention lag
  and concurrent terminal traffic need representative fleet measurement. The
  historical summary path adds work under the host lock and rejects the report
  if persistence fails; the host can consequently become stale. This is explicit
  accepted behavior, not evidence of completed fleet acceptance.

## Verification

Final Marshall precommit passed 168 cases (15 properties, 153 tests), six
browser-state checks, the compiler, Elixir 1.20.4/OTP 29.0.6 runtime gate and
Dialyzer. Dialyzer retains the existing single upstream typespec exclusion.
The UTC/session-time-zone regression passes. All four live Linux/ext4/TLS host
checks passed with summary persistence enabled. `mix ash.codegen --check` found
no missing schema changes. The ADR checker passes all 23 decisions.

Focused checks cover bucket boundaries (including pre-epoch timestamps), unknown
counts, order-independent integer statistics, large integer serialization, source
allowlists, provenance, sampled reservations/materialization credit, late-sample
context, absent buckets, authorization, physical retention, continuation rollback
and three-node duplicate ingestion. Database teardown left no summary fixtures.
The expected injected database failures emit Postgrex rollback diagnostics;
they do not represent failing cases. The final command log is
`/tmp/kittens-telemetry-final-checks.log` in this development environment.

The new migration creates only the summary table and its indexes/reference.
Review used the touched source files and generated migration: the current Git
repository has no commits and all project paths are untracked, so a historical
Git diff is unavailable. Existing project files and Git state were preserved.

## Decisions and follow-up

ADR-0023 refines accepted ADR-0006 under the user's instruction to implement the
plan. ADRs 0006, 0010 and 0013 and the overview now point to retained telemetry.
No accepted rationale is superseded. Migration must precede the new Marshall
release; there is no backfill of missing historical reports.

The full platform remains incomplete: production email, protected enrollment,
drain and deployment workflows, a second physical host, terminal failover and
workload/fleet acceptance remain separate obligations. The selected retention
implementation does not resolve them.

## Evidence

[Summary resource](https://github.com/antithesishq/kittens/blob/a99f74f06542798dc9ef288e77c99d480433fc57/marshall/lib/marshall/telemetry/summary.ex),
[recorder](https://github.com/antithesishq/kittens/blob/a99f74f06542798dc9ef288e77c99d480433fc57/marshall/lib/marshall/telemetry/recorder.ex),
[observations](https://github.com/antithesishq/kittens/blob/a99f74f06542798dc9ef288e77c99d480433fc57/marshall/lib/marshall/telemetry/observations.ex),
[statistics](https://github.com/antithesishq/kittens/blob/a99f74f06542798dc9ef288e77c99d480433fc57/marshall/lib/marshall/telemetry/statistics.ex),
[retention action](https://github.com/antithesishq/kittens/blob/a99f74f06542798dc9ef288e77c99d480433fc57/marshall/lib/marshall/telemetry/expire.ex),
[statistics properties](https://github.com/antithesishq/kittens/blob/a99f74f06542798dc9ef288e77c99d480433fc57/marshall/test/marshall/telemetry/statistics_test.exs),
[observation checks](https://github.com/antithesishq/kittens/blob/a99f74f06542798dc9ef288e77c99d480433fc57/marshall/test/marshall/telemetry/observations_test.exs),
[database tests](https://github.com/antithesishq/kittens/blob/a99f74f06542798dc9ef288e77c99d480433fc57/marshall/test/marshall/telemetry/retention_test.exs),
[three-node tests](../../../marshall/test/marshall/compute/distributed_admission_test.exs),
[operator guide](../../history/ledgers/capacity-history.md).
