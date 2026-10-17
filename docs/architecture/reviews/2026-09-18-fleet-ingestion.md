# Fleet ingestion and minute history

## Scope and architecture impact

This extends [ADR-0060](../decisions/0060-detailed-fleet-monitoring.md) with the
versioned HTTP boundary, bounded cache, minute persistence, deduplication and
administrative history reads. It preserves ADR-0023's scheduling reports and
history unchanged. New transactions lock only monitor hosts. Detailed persistence
explicitly refuses an existing caller transaction, preventing accidental inclusion
in compute admission or lifecycle transactions.

## Evidence and findings

The HTTP plug (`marshall/lib/marshall_web/fleet_api.ex` at kittens revision `a99f74f0`, repository deleted) handles and halts
monitor requests before generic parsing/logging, requires actual HTTPS, reads at
most 4 MiB and uses fresh monitor credentials. Malformed values return fixed
errors. The cache (`marshall/lib/marshall/fleet/cache.ex` at kittens revision `a99f74f0`, repository deleted) validates before
acceptance, stores compressed bounded observations for up to 10,000 hosts (or the
256 MiB payload cap), preserves newer live samples
against reordering, and coalesces small notifications every five seconds. It does
not acknowledge persistence on live acceptance.

History (`marshall/lib/marshall/fleet/history.ex` at kittens revision `a99f74f0`, repository deleted) locks the monitor host,
rechecks buffered credentials and sample age, and commits statistics, digest-bound
receipts and flush time together at most once per minute per host. Expired or
revoked buffered entries cannot indefinitely block fresh entries. Receipt failure
rolls back history and flush time. Receipts survive cache loss; replay does not
increase observation counts. Each flush admits at most 128 samples, and each
host/scope/time JSON bucket is capped at 16384 entities and 8 MiB. Those bounds
are backpressure limits, not evidence that maximum-size traffic is economical.

Statistics (`marshall/lib/marshall/fleet/statistics.ex` at kittens revision `a99f74f0`, repository deleted) retain known
counts, extrema, latest values and context changes. Gauge means are sample means;
rate means weight measured intervals and assign those observations to the interval
end bucket. Neither weights nor first/last timestamps are coverage percentages.
Missing buckets and fields remain absent. Physical pools, logical datasets and
workload scopes are not summed together by persistence.

History reads (`marshall/lib/marshall/fleet/read_history.ex` at kittens revision `a99f74f0`, repository deleted) recheck
current administrator permission and use SQL JSON extraction for one entity,
avoiding loading a whole host's JSON for a single chart. Reads enforce expiry and
bounded keyset pages. Retention (`marshall/lib/marshall/fleet/expire.ex` at kittens revision `a99f74f0`, repository deleted)
deletes at most 1000 expired rows per table and atomically schedules continuation.
Authority and audit are outside that cleanup.

## Remaining obligations

- Cache global naming coalesces connected BEAMs. Actual production connectivity,
  disconnected-replica replay fairness and recovery need native verification.
  PostgreSQL throttling/deduplication does not prove live-cache coherence.
- The 100-host × 100-workload benchmark must measure JSON/WAL/storage cost,
  capture/flush/query latency, backlog recovery and overload. No scale claim is
  established by source bounds or the small fixtures.
- Native verified-TLS delivery, collector/server restarts and real cgroup/ZFS/
  namespace attribution remain. The current plug tests establish transport checks,
  not a complete TLS connection.
- Deployment credential enrollment/rotation wiring, detailed dashboards, coverage
  and weighted fleet projections are still in progress.
- A digest conflict rolls back the batch and remains unacknowledged; operator
  diagnostics and recovery from a poisoned host batch need further checks.
- Jobs count-query coalescing, the wider admin controls and evacuation remain in
  the full implementation ledger.

## Verification performed

The initial 19 focused tests passed; three additional cases bring the focused run
to 22, covering nested-transaction rejection, expired-buffer recovery and bounded
node pages with live demotion. The full Marshall test phase passed 581 checks
before those final three additions; its Dialyzer phase subsequently passed. Ten collector
tests pass, including rotating replay windows. Ash snapshot consistency passed.
These are fixture and source checks; no native fleet or production deployment is
claimed.

## Contracts

Reviewed root/Marshall/Fleet/web/test contracts and the AshOban scheduling helper.
Its insertion raises on failure, preserving retention-continuation atomicity.
New notes cover scoped ingestion, durable ACKs, once-per-minute commits, bounded
projections and independent retention. Final gates, native acceptance and the
[complete ledger](../../history/ledgers/admin-implementation.md) remain required.

## 2026-09-22 Galileo schema reconciliation

Live Dungarees enrollment produced valid `galileo.service` observations with
`galileo_ready`, `galileo_active_requests` and `galileo_total_requests`, but the
strict Marshall validator omitted those already-emitted collector fields and
rejected the complete batch with HTTP 400. This was implementation drift inside
ADR-0060's existing closed monitoring schema, not a new authority or protocol
decision.

The validator now allowlists the three gauges only for `galileo.service`, bounds
them as nonnegative integers and restricts readiness to zero or one. It continues
to reject unknown fields and cross-service reuse. Focused sample tests pass, and
the complete Marshall precommit gate passed 852 checks (787 tests and 65
properties), 19 contract-checker regressions, the logging and ADR checks,
browser-side suites and Dialyzer with zero errors. Production delivery still
requires deployment of the fix and a fresh accepted sample; this review does not
claim the remaining scale or native-recovery obligations complete.
