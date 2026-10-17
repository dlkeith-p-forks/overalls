# Capacity history

Marshall retains the latest accepted host/pool report and two summary resolutions:

| Resolution | Retention after bucket end | Entity |
| --- | --- | --- |
| 10 seconds | 24 hours | Each host and each storage pool |
| 5 minutes | 30 days | Each host and each storage pool |

[ADR-0023](architecture/decisions/0023-retained-capacity-telemetry.md) defines the
transaction, aggregation and retention rules. Apply the Marshall migrations
before starting binaries with retained telemetry. Earlier history is absent;
there is no synthetic backfill.

## Reading summaries

History is internal physical-host information. Use an authorized administrative
release console; the ordinary user API does not expose it. The Ash read action
enforces the existing Cedar system-actor boundary:

```elixir
alias Marshall.Authorization.SystemActor
alias Marshall.Telemetry.Summary

page =
  Summary
  |> Ash.Query.for_read(:history, %{
    host_id: host_id,
    entity: "host", # or an enrolled storage-pool UUID
    period_seconds: 10, # or 300
    from: ~U[2026-09-16 00:00:00Z],
    until: ~U[2026-09-17 00:00:00Z]
  }, actor: SystemActor.compute())
  |> Ash.read!(page: [limit: 100])

page.results
# Ash.page!(page, :next) retrieves the next keyset page.
```

The time range selects bucket starts, including `from` and excluding `until`.
The default page contains at most 100 rows; the maximum is 1,000. Expired rows
are excluded even when cleanup has fallen behind. Recent buckets may still be
updated by accepted reports. Paging does not freeze an immutable snapshot.

Each metric carries its unit, `known`/`unknown` sample counts, `sum`, `mean`,
`min` and `max`. Unknown-only metrics have null mean and extrema. Known zero
remains zero. Means use the known reported samples with equal weight and floating
point arithmetic. Integer-valued sums and extrema retain integer precision. In
particular, disk latency is a mean of reported interval averages; it is neither
an operation-weighted latency nor a percentile.

Use `sample_count`, `first_sample_at` and `last_sample_at` to describe observations.
They do not establish full time coverage. Missing buckets are gaps. The `context`
map holds the newest sample's source, architecture/device details and flags;
`context_changed` warns that the bucket combines different contexts.

Reserved and allocatable metrics sample the current reservation ledger when the
report commits. They are not a complete record of reservation transitions. Use
current host freshness, execution readiness, the capacity ledger and admission
actions to decide whether a new VM can be provisioned.

## Retention operations

The AshOban `Marshall.Telemetry.Workers.ExpireSummaries` schedule runs every
minute on the `default` queue. It removes at most 1,000 expired rows per
transaction and schedules another batch when that limit is reached. Deletion
and scheduling commit together; failed jobs retry. Structured
`telemetry_retention` logs include `deleted_count`.

Watch failed/retrying Oban jobs and the oldest expired summary if storage grows.
Physical deletion depends on a working queue and database. History reads still
exclude expired rows while that work is delayed. Summaries have no archival or
audit copies. Each entity retains about 17,280 non-expired rows plus active
boundary buckets when reports are continuous; database bytes and write costs
depend on the collected metrics and PostgreSQL maintenance.

Fleet throughput, terminal load alongside telemetry and a second physical host
remain acceptance work. These checks do not establish support for a specified
number of provisioner hosts or 100 control-plane instances.
