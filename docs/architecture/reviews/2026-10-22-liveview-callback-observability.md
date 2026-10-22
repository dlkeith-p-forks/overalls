# 2026-10-22: LiveView callback observability

## Scope

[ADR-0257](../decisions/0257-liveview-callback-observability.md): spans and
metrics for every Marshall LiveView callback, the library's start/finish span
API, per-phase runtime gauges and operations panels. Dimensions: operation
(observability), access and data (attribute privacy), capacity (cardinality)
and verification.

## Findings

1. **High, resolved. Most views had no trace.** Only four machine-page refreshes
   were spanned; connected mounts, events and messages of the other views ran
   outside any span. Every callback phase now has one span.
2. **Medium, resolved. Hook cost.** Session revalidation in `on_mount` and
   attached hooks runs before view callbacks. Using Phoenix's own Telemetry
   spans for mount, params and events includes it.
3. **Medium, resolved. Untrusted labels.** Event names and params come from the
   client. Only the registered view label and the phase become attributes;
   unregistered views share one closed label and a registry test fails.
4. **Medium, resolved. Handler detachment.** `:telemetry` detaches a raising
   handler permanently. The handler catches every failure.
5. **Low, open. No end-to-end span evidence.** No machine test asserts the spans
   in Tempo.

## Security assessment

Spans and metrics carry only closed labels and integers. The `handle_info`
Telemetry metadata carries the socket, never the message, and the handler reads
only `socket.view`. Tracing fails open and cannot change a callback's result.

## Checks run

- `mix test test/marshall_web/live_observability_test.exs test/marshall/observability_test.exs test/marshall_web/overview_live_test.exs` passed 22 tests.
- `elixir/diagnostics`: `mix test` with the start/finish test; `mix schema.check`.
