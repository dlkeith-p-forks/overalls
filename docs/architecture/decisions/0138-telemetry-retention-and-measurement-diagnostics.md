# ADR-0138: Telemetry retention and measurement diagnostics

- ID: ADR-0138
- Date: 2026-10-03
- Status: superseded
- Implementation: partial
- Components: NixOS, Rust, Underclass, Prometheus, Tempo, Grafana, Marshall
- Supersedes: none
- Superseded by: ADR-0159

> Superseded by [ADR-0159](0159-remove-legacy-compatibility.md) only for the separate versioned Underclass latency histogram. ADR-0159 carries every other requirement of this record forward unchanged.

## Context

A production query audit found 49 of 57 dashboard panels without finite values
over seven days. Collectors and recording rules were healthy. Idle eligible
journeys, incomplete observation history and minimum volume intentionally
withheld ratios. Underclass's ten-second histogram overflow also withheld p95.
The user requested ninety-day data collection, retained seven-day objectives,
selected a longer histogram with durable migration, and authorized tests and
deployment of the resulting plan.

## Decision

Retain metrics and traces for ninety days by default through typed NixOS options,
separately from seven-day SLO evaluation and burn arithmetic. Remove the metrics
size-triggered deletion policy; warn above its previous ten-GiB budget. Keep
Tempo's twenty-GiB quota and alert at seventy/eighty-five percent and predicted
exhaustion within the retention horizon. A quota is a failure boundary, not proof
that future trace volume fits ninety days.

Nix generates fixed numeric diagnostic states from the same source catalog as
the measurements. Missing/stale sources precede inactivity. Grafana and Marshall
show source availability, warmup, recording gaps, request volume, history and
latency limitations independently of compliance. No absent ratio becomes zero
or success. Candidate queries require each declared host.

Underclass adds a separate versioned latency histogram with a fresh migration
clock and finite buckets through twenty-four hours. Its original journal totals,
identity and buckets remain intact. Schema initialization and terminal aggregate
updates are atomic. Unknown recovered durations remain unmeasured; old infinity
counts cannot be redistributed. The Rust exporter validates bounds, conservation,
source identity and monotonic transitions before publishing distinct metrics.

## Alternatives

Replacing seven-day objectives with ninety-day objectives would change target
and burn semantics, and was explicitly declined. Filling empty graphs with
success values would violate unknown-data contracts. Rebuilding historical
histogram buckets from infinity totals is impossible. Merely changing retention
time while retaining size-triggered deletion would silently shorten history.

## Consequences

The metrics store loses its automatic ten-GiB deletion limit and requires capacity
monitoring. A dedicated loopback Rust probe reads only aggregate storage sizes
and root availability; its sandbox exposes read-only telemetry stores and hides
other state and runtime credentials. It has no application or admission authority.
New diagnostics and latency history accumulate after deployment. Neither selected
dashboard range nor configured retention creates past observations.

## Invariants and verification

Property tests exercise state parsing, numeric allowlists, histogram conservation,
legacy migration and unknown recovery. Prometheus fixtures verify prioritized
missing/stale/warming/gap/idle/history states. Native NixOS fixtures exercise real
long provider responses, migration, interruption, exporter custody, authenticated
dashboards, effective retention and source placement. Ninety days of observed
production retention remains a future acceptance requirement.

## Implementation evidence

[Retention and dashboard provisioning](../../../nix/domains/system/otel-fleet/default.nix),
[diagnostic rules](../../../nix/domains/system/otel-fleet/diagnostics.nix),
[storage monitoring](../../../nix/domains/system/otel-fleet/storage.nix),
Underclass accounting (`nix/domains/artifacts/underclass/slo.rs` at kittens revision `9fe1e493`, repository deleted),
export validation (`nix/domains/system/otel-guest/receiver/src/slo.rs` at kittens revision `9fe1e493`, repository deleted) and
signed-in diagnostics (`marshall/lib/marshall/telemetry/slo_status_read.ex` at kittens revision `a99f74f0`, repository deleted)
implement the decision. Exact passing scopes and remaining gaps are recorded in
the [review](../reviews/2026-10-03-telemetry-retention-and-diagnostics.md).
The Underclass links are permalinks to the separate-histogram implementation.

Carry-forward evidence (ADR-0159, Push 9): the separate versioned latency
histogram, its migration and the `latency_v2` metrics are removed. Underclass now
keeps one totals record with a single fifteen-bound histogram through twenty-four
hours in a fresh `slo-totals.sqlite` journal
([accounting](../../../nix/domains/artifacts/underclass/slo.rs)); the
[exporter](../../../nix/domains/system/otel-guest/receiver/src/slo.rs) fixes one bound set
per service, and the [p95 rule](../../../nix/domains/system/otel-fleet/rules.nix) reads the
ordinary duration histogram. Every other requirement of this record, including
finite buckets through twenty-four hours, unmeasured unknown recovery durations
and pre-publication validation, is unchanged.

## Open questions

Future trace volume must be monitored against the current quota. Recorded
ninety-day retention and complete eligible seven-day compliance are pending.

## Related decisions

This extends [ADR-0132](0132-seven-day-provisional-fleet-objectives.md) without
changing its objective horizon, and [ADR-0136](0136-durable-application-request-accounting.md)
without changing application admission. Public access remains governed by
[ADR-0137](0137-public-authenticated-grafana.md).
