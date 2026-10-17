# Fleet dashboard foundation

## Scope and architecture impact

The fleet and node pages implement read projections under
[ADR-0060](../decisions/0060-detailed-fleet-monitoring.md), with current
administrator authority from ADR-0058. No new persistence or compute admission
semantics are introduced. The existing accepted decisions remain partial.

## Evidence and findings

The inventory action (`marshall/lib/marshall/fleet/inventory.ex` at kittens revision `9fe1e493`, repository deleted) returns
at most 128 enrolled identities per keyset page, including offline/disabled hosts.
It checks current Cedar permission and exposes no credential or machine-ID data.
The LiveViews use existing stored-login/current-role hooks before navigation,
events and refresh. Demotion closes the mounted fleet view in a browser-state test.

The utilization projection (`marshall/lib/marshall/fleet/utilization.ex` at kittens revision `a99f74f0`, repository deleted)
weights CPU by cores and memory by bytes, requiring known numerator/denominator
pairs. Disabled, stale, future-skewed and different-boot/collector measurements do
not contribute. Physical pools remain separate from logical datasets. Truncated,
stale or failed ZFS collections cannot be presented as complete storage totals.
Every total has contributing-host coverage; offline inventory remains visible.
Fleet totals and rankings now cover every enrolled inventory page while the
visible host table remains keyset-bounded. The fleet page
also aggregates fresh external-interface receive/transmit rates, disk
read/write rates and bounded observed resource-kind counts; node pages retain
the detailed per-device records.

The cache's summary selection now restricts the primary host record to its
canonical `host` ID; arbitrary additional host records cannot exceed the stated
64-record summary bound. It separately carries at most 20 bounded VM/service rows
for fleet ranking. Node resource pages have a stable entity-key cursor and
at most 100 records. The fleet page reads enrolled inventory once per minute and
cached observations every five seconds. Fresh authorization still requires DB
reads; these are not eliminated by the observational cache.

History loads only on explicit form submission through the existing bounded
single-entity SQL extraction action. The first screen covers the latest 100
selected intervals. Gauge means use observation weights, rate means measured
interval weights. SVG points are not joined across missing buckets. The table
exposes actual known/observation counts and extrema; none are time-coverage claims.

## Remaining obligations

- The original checkpoint ranked 20 workloads by memory. The
  [interactive dashboard follow-up](2026-09-18-interactive-dashboards.md) adds
  CPU/memory ranking, per-core heatmaps and bounded 24-hour/30-day navigation.
  Its evidence is separate from the original checkpoint below.
- External-NIC totals still need explicit non-overlapping interface
  configuration; VM traffic remains a separate detailed observation.
- Capacity explanations, intended versus observed roles/collector identity and
  non-destructive database/HTTP/BEAM/job health are implemented. The collector
  now exports validated intended candidate and observed healthy revisions, and
  the node view reports matched or drifted state without exposing updater paths
  or repository metadata.
- Enrollment wiring, native transport/replica correctness, database/WAL/retention
  measurements for 100 hosts × 100 workloads and visual browser inspection remain
  required. The in-process projection smoke test now exercises that shape and
  enforces the bounded 20-row ranking.
- No production deployment, account promotion or physical evacuation is claimed.

## Verification and contracts

Twenty-six focused Fleet/domain/UI tests passed, including heterogeneous weighted
totals, stale/disabled/cross-boot exclusion, logical-storage separation, current
inventory authorization, offline host rendering and node/history rendering.
Ash schema consistency and both pinned collector Nix checks passed. Subsequent
full Marshall gates pass through 618 checks with Dialyzer. The ADR checker passed
56 decisions (structure and links only). Reviewed ancestor Fleet/web/component contracts and consumers of the
new inventory action; new notes specify bounded reads and unknown/weighted
semantics. Structural checks do not establish native or fleet-scale acceptance.
