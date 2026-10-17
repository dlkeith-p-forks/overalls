# Interactive dashboard review

## Scope and architecture impact

[ADR-0062](../decisions/0062-interactive-monitoring-dashboards.md) supplements
ADR-0060 with curated graphical dashboards, a shared admin shell, bounded Ash
read projections and a vendored chart dependency. ADR-0058 authorization and
ADR-0023's independent scheduling history remain unchanged. No migrations,
collector changes, execution authority or retention extensions are introduced.

## Findings and implementation

- Historical queries extract curated metric statistics in PostgreSQL, retain
  weighted means and paired denominators, and exclude expired rows before cleanup.
- Fleet totals cover matching enabled hosts independently of visible host pages.
  Heatmaps and entity series are paged separately from aggregate contributions.
- The live cache retains the union of the top 20 memory and top 20 CPU workload
  candidates per host (at most 40); final rankings remain bounded to 20. Freshness,
  boot and collector identities are checked before ranking.
- Workload monitoring links resolve compute and monitoring hosts by machine identity
  inside the existing authorized inventory action, exposing only the monitor UUID.
- Stored-login and current-admin hooks remain installed. Async history completion
  also verifies current authority. Cache access is bracketed by fresh admin checks.
- ECharts is locally bundled with pinned integrity and original license/notice.
  Rich-text tooltips and normal HEEx escaping keep labels out of HTML execution.
- The raw resource inspector remains available, with links to workload dashboards.

## Verification

Marshall's first complete `mix precommit` passed 672 checks (60 properties,
612 tests), six existing terminal checks, four chart-option checks, ADR/contract
validation and forced Dialyzer analysis (only the existing documented exclusion).
Two additional cache tests passed shared concurrent query execution, successful
result reuse, failure retry and refusal of a fifth concurrent distinct request.
A follow-up regression assertion verifies that Last 24 hours uses minute history.

Minified assets built using the Nix-provided Tailwind 4.3.3 and esbuild 0.27.2,
matching the repository's Nix packaging approach. The generic downloaded Tailwind
binary could not execute directly on NixOS; no source configuration was changed
to work around that environment limitation.

A separate disposable test database and six-host fixture backed Chromium checks.
Fleet, host and workload charts rendered without JavaScript errors. Browser checks
covered pause controls, preserved-range drill-downs, light/dark appearance, heatmap
metric selection and cell navigation, physical slider drag, chart zoom events/reset, 30-day selection,
empty filters, keyboard sidebar toggling and a 390-pixel mobile viewport with no
horizontal page overflow. Desktop and mobile screenshots were visually inspected.
These representative checks are not a production or fleet-scale acceptance claim.

The subsequent normal-concurrency rerun passed 673 of 674 checks but hit the
unchanged ingress publication test's 1.5-second SQL deadline. That test passed in
isolation with the original deadline. Repeating the complete gate with ExUnit
`max_cases: 2` passed all 674 checks (60 properties, 614 tests), the JavaScript
checks and forced Dialyzer. After the final breadcrumb adjustment, all ten focused
dashboard/domain/cache checks, forced Dialyzer and the ADR validator passed again.
No test budget or production setting was relaxed. The breadcrumb regression ensures
returning from a host resource tab restores the fleet overview while retaining
the selected time range.

The completion audit added populated 30-day history regressions: 29-day-old host
summaries merge rates by interval weight (100 × 1 and 300 × 9 produce 280), and
28-day-old workload summaries retain explicit gaps between hourly observations.
Both verify the 600-point response bound. All seven dashboard projection tests
passed against PostgreSQL. These additions strengthen evidence for ADR-0062;
they introduce no architecture or production behavior changes.
The final complete `mix precommit` with ExUnit `max_cases: 2` passed 677 checks
(60 properties, 617 tests), all ten terminal/chart JavaScript checks, contract and
ADR validation, and forced Dialyzer with only the existing documented exclusion.

## Limitations

History begins with retained telemetry; unavailable metrics remain unknown.
Summed resource extrema are bounds assembled from individual extrema, not measured
simultaneous peaks. The accessible values table shows the latest 100 plotted
intervals per series. External-interface non-overlap remains the deployment
configuration obligation recorded in ADR-0060. Production deployment is not claimed.
The user explicitly waived the proposed 100-host by 100-workload benchmark;
no new scale acceptance claim is made.
