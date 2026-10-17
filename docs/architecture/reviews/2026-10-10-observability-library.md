# Shared Elixir observability library review

Review baseline: refreshed `origin/main` `d4499c4c`, isolated worktree
`overalls-observability`, branch `codex/observability-redesign`.

## Architecture impact

This change implements the shared application observability boundary already
accepted by [ADR-0149](../decisions/0149-independent-observability.md). The
library remains outside `protocol/`, has no Ash or control authority, and does
not participate in lifecycle, capacity, authorization, SLO settlement or
durable request accounting. Application event catalogs remain domain-owned;
the shared code supplies projections, privacy helpers, canonical formatting and
bounded metric admission. No ADR replacement is required. ADR-0042's source
redaction and ADR-0138/0136's durable accounting boundaries remain in force.

## Changes reviewed

- `Overalls.Diagnostics.Events.Catalog` now exposes independent reviewed log and
  trace projections. Catalog emission can select log-only or trace-only events.
- `Overalls.Diagnostics.Metrics` is supervised with a finite typed registry,
  fixed ETS storage, validated measurements/metadata, cumulative or interval
  snapshots and explicit overflow-to-`:unknown` behavior. Unknown paths and
  labels are rejected before Telemetry emission.
- `Overalls.Diagnostics.Privacy` provides a finite OTP/source redaction helper,
  while existing application filters retain their application-specific
  operational metadata policies.
- `Overalls.Diagnostics.Formatter` is the canonical JSON Logger formatter for
  all eight applications. It emits a stable envelope and catalog-validated
  metadata, with fixed redacted fallback messages.
- Audi, Lilly, Marshall and Porsche producers use the typed metric admission
  API. Lilly backoff/fence measurements are count-only; Marshall error
  classification is event-specific; Porsche proof totals are cumulative and
  eligible SLO histogram updates no longer queue per-completion casts.

## Verification

The shared project passes 21 ExUnit tests, formatting, warnings-as-errors
compilation, schema generation/checks, code-contract checks and forced Dialyzer.
Lilly's focused observability tests pass; Porsche's focused
observability/SLO/SSH suite passes 17 tests. The structured logging checker
passes all eight applications. Lilly's full precommit reaches 553/554 tests;
the one failure is the unrelated historical-fence expectation for an upstream
fixture. Marshall's precommit reaches compilation, contracts and logging
checks, then its database setup is blocked by the missing devenv PostgreSQL
socket. Native journal/collector recovery, production traffic sizing and
seven-day retention remain separate evidence gaps.

## Remaining boundaries

Marshall's LiveDashboard telemetry definitions and collectors for Phoenix,
Oban and Repo events remain application-owned adapters. They are not silently
treated as shared metric producers. Native NixOS journal/collector recovery,
production traffic sizing and seven-day retention remain the separate evidence
gaps recorded in the HLDD and ADR-0149.
