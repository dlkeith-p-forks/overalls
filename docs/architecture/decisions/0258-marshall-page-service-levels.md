# ADR-0258: Marshall page interaction service levels

- ID: ADR-0258
- Date: 2026-10-22
- Status: accepted
- Implementation: partial
- Components: Marshall, request_accounting, otel-fleet, Grafana
- Supersedes: none
- Superseded by: none

## Context

[ADR-0257](0257-liveview-callback-observability.md) traces every Marshall
LiveView callback. It left an open question: which page-level service-level
indicators should consume these callbacks?

The existing `marshall_web` source counts HTTP responses only. Connected
LiveView mounts, events and messages run over the WebSocket, outside every HTTP
request, so slow or failing pages never reach an objective.

Under [ADR-0129](0129-fleet-otel-slos.md) and
[ADR-0149](0149-independent-observability.md), objectives may come only from an
independent request recorder. Log gauges, traces and self-reported counters are
excluded.

The user asked for page SLIs and SLOs in Grafana.

## Decision

- **New source `marshall_live`.**
  - Every LiveView callback is admitted to a second, independent request recorder
    (`Marshall.LiveRecorder`) before it runs.
  - The callback settles once: success when it returns, failure when it raises,
    throws or exits.
  - The recorder settles a callback whose process dies as a failure.
  - The source has its own Rust recorder socket, its own exporter and its own
    collector socket group, `overalls-otel-marshall-live`, so it is isolated from
    `marshall_web`.
  - Its deadline is 60 seconds.
- **Environment suffix.**
  - One Marshall unit hosts two recorders.
  - `Overalls.RequestAccounting.Config.from_environment/2` and
    `request-recorder.nix` therefore take a validated suffix (`_MARSHALL_LIVE`)
    for the socket and marker variables.
  - An evaluation assertion refuses two bindings with the same unit and suffix.
- **Two provisional seven-day objectives.**
  - `marshall_live`: callback completion of 99%. This is a candidate-style ratio
    of successes to requests.
  - `marshall_live_latency`: 99% of callbacks within 1 s. This uses a new
    `latency` objective kind, measured as the `le="1"` duration bucket over
    requests.
  - Both objectives keep the existing minimum-request (100), warmup, exact-host,
    freshness and coverage guards.
  - A latency objective whose duration series is missing yields no value, never
    success.
- **Burn rules.** Each objective gets the standard fast and slow burn rules.
  The roster becomes 24 objectives and 48 burn evaluators.
- **Grafana dashboard `overalls-marshall-pages`.**
  - **Objectives:** two objective stat panels.
  - **SLIs:** the completion, latency, p95 and rate time series.
  - **Burn and status:** the burn alert and status tables.
  - **Diagnostics:** four gauge panels and a Tempo panel listing traces slower
    than 500 ms. These panels are titled as diagnostics.
  - p95 is shown on the dashboard only; it is not an objective.

## Alternatives

- **Derive SLIs from the `marshall.live.callback` metric or traces.** Rejected:
  ADR-0129/0149 forbid self-reported objective sources.
- **Reuse the `marshall_web` recorder.** Rejected: it would mix HTTP responses and
  WebSocket callbacks in one denominator and couple their failure domains.
- **Per-view objectives.** Rejected: thirty-one views would multiply rule and
  series cardinality. Per-view detail stays in traces and diagnostic gauges.
- **A p95 objective.** Rejected: quantile objectives cannot be aggregated over
  seven days. The threshold ratio expresses the same intent additively.

## Consequences

- Each callback costs two calls to the local recorder. An unavailable recorder
  leaves the callback unrecorded and never changes its result.
- Periodic `handle_info` ticks count as interactions. `/machines` ticks every
  second per open tab, so idle tabs dominate the denominator.
- A view that blocks longer than the 60 s deadline is settled as a failure by the
  recorder.

## Invariants and verification

- **Admission before work, single settlement.**
  [`live_observability_test.exs`](../../../marshall/test/marshall_web/live_observability_test.exs).
- **Suffix isolation.** A suffixed configuration reads only its own variables.
  [`config_test.exs`](../../../elixir/request_accounting/test/config_test.exs).
- **Source allowlist.** The Rust recorder and exporter accept `marshall_live`.
  [`slo.rs`](../../../nix/domains/system/otel-guest/receiver/src/slo.rs).
- **Rule arithmetic.** Completion and latency ratios, empty seven-day windows
  and empty negatives.
  [`otel-slo-rules.nix`](../../../nix/verification/tests/evaluation/otel-slo-rules.nix).
- **Native path.** Real LiveView callbacks reach the independent recorder and the
  collector.
  [`otel-marshall`](../../../nix/verification/tests/machines/otel-marshall/default.nix).
- **Dashboard sources.** Objective panels read only catalog queries.
  [`marshall-pages-dashboard.nix`](../../../nix/domains/system/otel-fleet/marshall-pages-dashboard.nix),
  asserted in
  [`otel-fleet`](../../../nix/verification/tests/machines/otel-fleet/default.nix).

## Implementation evidence

| Component | Files |
|---|---|
| Admission and settlement | [`live_observability.ex`](../../../marshall/lib/marshall_web/live_observability.ex), [`application.ex`](../../../marshall/lib/marshall/application.ex) |
| Suffixed configuration | [`config.ex`](../../../elixir/request_accounting/lib/overalls/request_accounting/config.ex), [`producer.ex`](../../../elixir/request_accounting/lib/overalls/request_accounting/producer.ex), [`request-recorder.nix`](../../../nix/domains/system/otel-fleet/request-recorder.nix), [`request-sources.nix`](../../../nix/domains/system/otel-fleet/request-sources.nix) |
| Recorder source | [`durable_slo.rs`](../../../nix/domains/system/otel-guest/receiver/src/durable_slo.rs), [`slo.rs`](../../../nix/domains/system/otel-guest/receiver/src/slo.rs) |
| Collector, rules and objectives | [`default.nix`](../../../nix/domains/system/otel-fleet/default.nix), [`rules.nix`](../../../nix/domains/system/otel-fleet/rules.nix), [`objectives.nix`](../../../nix/domains/system/otel-fleet/objectives.nix), [`objective-rules.nix`](../../../nix/domains/system/otel-fleet/objective-rules.nix), [`slo-catalog.nix`](../../../nix/domains/system/otel-fleet/slo-catalog.nix), [`diagnostics.nix`](../../../nix/domains/system/otel-fleet/diagnostics.nix) |
| Dashboard | [`marshall-pages-dashboard.nix`](../../../nix/domains/system/otel-fleet/marshall-pages-dashboard.nix) |

Remaining gaps:

- The targets are provisional. No production baseline has been measured, and
  seven-day eligibility has not been observed.
- No browser test renders the Grafana dashboard.
- **Live check** on `panterloons` (2026-10-22), through Grafana's API and the
  live Prometheus:
  - Six anonymous page loads reached the live `marshall_live` recorder as six
    successes.
  - The SLI panels returned completion 1, within-1 s 1 and p95 0.038 s.
  - The callback diagnostic panels returned a 6.3 ms mean mount.
  - Tempo returned `marshall.live.callback` spans.
  - The objective panels stay empty until 100 requests and warmup, as
    designed.
  - The per-view refresh panels need signed-in refreshes.
- Live components are not counted; Marshall has none today.

## Open questions

- Should periodic `handle_info` ticks be excluded from the denominator once
  production baselines show whether they mask interactive latency?

## Related decisions

- [ADR-0257](0257-liveview-callback-observability.md): the callbacks measured.
- [ADR-0129](0129-fleet-otel-slos.md): durable request-recorder objectives.
- [ADR-0149](0149-independent-observability.md): observability independence.
