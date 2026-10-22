# ADR-0257: Trace every Marshall LiveView callback

- ID: ADR-0257
- Date: 2026-10-22
- Status: accepted
- Implementation: partial
- Components: Marshall, overalls_diagnostics
- Supersedes: none
- Superseded by: none

## Context

[ADR-0256](0256-batched-page-authorization-snapshots.md) added
`marshall.live.refresh` spans to the refreshes of four machine pages. Every
other Marshall LiveView still had no span: its mounts, events and messages
appeared only as the HTTP dead render (`marshall.http`) or not at all. The
connected mount and every later event run in the LiveView's own process, over
the WebSocket, outside any HTTP request span.

Session revalidation runs in `on_mount` and attached hooks, before the view's
own callbacks. A wrapper around the view's callbacks alone would miss that
cost.

The user asked for tracing and diagnostics on every Marshall view.

## Decision

Every Marshall LiveView callback produces one reviewed span and one metric
measurement:

- **Sources.** Phoenix already emits Telemetry spans for mount,
  `handle_params` and `handle_event`, covering hooks. `use MarshallWeb,
  :live_view` adds an equivalent `[:marshall, :live_view, :handle_info]`
  Telemetry span around a view's `handle_info/2`, at compile time.
- **Handler.** `MarshallWeb.LiveObservability`, attached once by
  `MarshallWeb.Telemetry`, turns each start/stop/exception pair into one
  `marshall.live.callback` span and one `[:marshall, :live, :callback]`
  measurement. The span ends in error status on an exception.
- **Labels.** Only a closed `live_view` label from a literal registry and the
  `phase` (`mount`, `handle_params`, `handle_event`, `handle_info`). Event
  names, params, session, URI, messages and assigns never become attributes.
  An unregistered view gets the closed label `unregistered_live_view`; a
  registry test fails until every LiveView module is registered.
- **Values.** Duration and the number of database queries the callback's
  process issued, via nesting-safe query scopes.
- **Library.** `Overalls.Diagnostics.Tracing` gains `start/2` and `finish/3`
  for callers that see only begin and end events. Both fail open, restore the
  previous context and set only a closed status.
- **Aggregates.** Per-minute totals by phase (`liveview_<phase>_*`) in
  `marshall.runtime_metrics`, admitted to Prometheus, with two operations
  dashboard panels. Per-view detail stays in traces, keeping metric
  cardinality fixed.

## Alternatives

- **Wrap every view callback at compile time.** Rejected for mount, params and
  events: it would miss `on_mount` and attached hooks. Kept for `handle_info`,
  which Phoenix does not span.
- **Label metrics per view.** Rejected for the runtime aggregate: thirty-one
  views times four phases times three values would add 372 event keys and
  gauges. Traces carry the per-view label.
- **Use event names as labels.** Rejected: clients choose event names, so they
  are unbounded and untrusted.

## Consequences

- Every connected LiveView interaction is visible in Tempo with its view,
  phase, duration and query count, including session-revalidation cost.
- Periodic `handle_info` ticks add one span each; for `/machines` that is one
  per second per open tab, the same rate as its refresh span.
- A Telemetry handler that raises would be detached by `:telemetry`; the
  handler catches everything to stay attached.

## Invariants and verification

- **Registry complete.** Every module whose `__live__/0` reports a view has a
  unique label the trace vocabulary admits.
  [`live_observability_test.exs`](../../../marshall/test/marshall_web/live_observability_test.exs).
- **Closed measurement.** Mount, an event and a message on `/overview` each
  record exactly `live_view` and `phase` metadata and integer duration and
  queries. Same file.
- **Exact outcome.** The `handle_info` wrapper returns the callback's exact
  result and re-raises its exact exception without leaking process state.
  Same file.
- **Paired spans.** A started span is current until its finish, which ends it
  with a closed status, keeps only reviewed attributes and restores the parent.
  [`sdk_test.exs`](../../../elixir/diagnostics/test/sdk_test.exs).

## Implementation evidence

| Component | Files |
|---|---|
| Handler, registry and `handle_info` wrapper | [`live_observability.ex`](../../../marshall/lib/marshall_web/live_observability.ex), [`marshall_web.ex`](../../../marshall/lib/marshall_web.ex), [`telemetry.ex`](../../../marshall/lib/marshall_web/telemetry.ex) |
| Query scopes and per-phase aggregates | [`observability.ex`](../../../marshall/lib/marshall/observability.ex), [`events.ex`](../../../marshall/lib/marshall/events.ex) |
| Span start/finish and metric | [`tracing.ex`](../../../elixir/diagnostics/lib/overalls/diagnostics/tracing.ex), [`metrics.ex`](../../../elixir/diagnostics/lib/overalls/diagnostics/metrics.ex) |
| Gauges and panels | [`default.nix`](../../../nix/domains/system/logging/default.nix), [`default.nix`](../../../nix/domains/system/otel-fleet/default.nix), [`operations-dashboard.nix`](../../../nix/domains/system/otel-fleet/operations-dashboard.nix) |

Remaining gaps:

- No machine test observes `marshall.live.callback` spans arriving in Tempo.
- Live components are not wrapped; Marshall has none today.
- Page-level objectives consume the callbacks through the independent
  `marshall_live` recorder ([ADR-0258](0258-marshall-page-service-levels.md)),
  not through these measurements.

## Open questions

- None. Page service levels are decided in
  [ADR-0258](0258-marshall-page-service-levels.md).

## Related decisions

- [ADR-0256](0256-batched-page-authorization-snapshots.md): page refresh
  spans and query counting.
- [ADR-0149](0149-independent-observability.md): observability independence.
- [ADR-0258](0258-marshall-page-service-levels.md): page service levels.
