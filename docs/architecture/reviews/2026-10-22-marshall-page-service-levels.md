# 2026-10-22: Marshall page service levels

## Scope

[ADR-0258](../decisions/0258-marshall-page-service-levels.md) covers:

- the independent `marshall_live` request-recorder source for LiveView callbacks;
- the suffixed recorder configuration;
- the `latency` objective kind;
- two provisional objectives;
- the `overalls-marshall-pages` Grafana dashboard.

Dimensions: operation (observability), access and data (socket groups and
labels), capacity (rule and series cardinality), recovery (recorder loss) and
verification.

## Findings

1. **High, resolved. Pages had no objective.** `marshall_web` counts HTTP
   responses only, so WebSocket callbacks were invisible to service levels.
   Callbacks are now admitted to their own recorder.
2. **High, resolved. Objective independence.** Deriving SLIs from the callback
   metric or traces would breach ADR-0129/0149. The objectives read only the
   recorder-backed collector series, and the dashboard titles gauge and trace
   panels as diagnostics. Contract `marshall-pages-dashboard-sources`.
3. **Medium, resolved. Two recorders in one unit.**
   - **Problem.** Sharing the environment variables would make both producers
     write to one recorder.
   - **Fix.** A validated suffix separates the socket and marker variables.
   - **Guard.** An evaluation assertion refuses a duplicate unit and suffix
     pair.
4. **Medium, resolved. Latency without data.** A missing duration series could
   divide to success. The latency query is guarded on the source's request,
   coverage and freshness series. Contract
   `latency-objective-missing-duration-fails`.
5. **Medium, open. Ticks in the denominator.** Periodic `handle_info` ticks
   count as interactions and may mask interactive latency. ADR-0258 records
   this as an open question.
6. **Low, open. Provisional targets.** There is no production baseline and no
   seven-day eligibility yet.

## Security assessment

- The new source adds no labels beyond the fixed `service.name`.
- The Marshall UID reaches only its own recorder socket. The exporter holds only
  the source-read and `overalls-otel-marshall-live` collector groups.
- An unavailable recorder leaves callbacks unrecorded and never alters a result
  or grants access.

## Checks run

Recorded in the commit that introduced ADR-0258:

- `cargo test`, through the receiver package build: 47 passed.
- `elixir/request_accounting`: `mix test`, 32 passed.
- `mix test test/marshall_web/live_observability_test.exs`: 4 passed.
- Nix evaluation checks `otel-slo-rules` and `telemetry-diagnostics` passed.
- `elixir/request_accounting`: `mix precommit` passed with zero Dialyzer
  errors.
- Marshall `mix dialyzer --force-check` reported only the existing
  `model_calls.ex:512` warning.
- NixOS machine checks passed: `otel-marshall`, including the new subtest
  "real LiveView callbacks reach the independent marshall_live recorder";
  `log-store`; `public-grafana`; `otel-burn-delivery`.
- `otel-fleet` passed its Marshall pages dashboard assertions, then failed at a
  later guest-receiver upload assertion. The same assertion fails on the
  pre-change baseline (22f529128).
- `otel-request-recorder` fails in the `producer_recorder_history` property on
  `systemctl reset-failed` ("Unit not loaded"). It fails the same way on the
  baseline.
- The Nix `hldd` check passed.
