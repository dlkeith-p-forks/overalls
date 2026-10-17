# ADR-0062: Interactive monitoring dashboards

- ID: ADR-0062
- Date: 2026-09-18
- Status: superseded
- Implementation: implemented
- Components: Marshall Fleet domain, administrative web interface, browser assets
- Supersedes: none
- Superseded by: ADR-0119, ADR-0149

## Context

[ADR-0149](0149-independent-observability.md) replaces Marshall diagnostic views
with automatically provisioned Grafana dashboards. Original rationale and evidence
remain below with their historical scope.

[ADR-0119](0119-authenticated-control-room-reads.md) replaces the administrator-only
read restriction and carries forward the other requirements below.

The administrative fleet page exposed numeric observations and the host inspector
required manual metric selection. The user approved built-in graphical fleet,
host and VM/service dashboards, a complete interface redesign, curated panels and
existing 30-day retention. They explicitly removed the proposed 100-host by
100-workload benchmark from this change's acceptance criteria.

## Decision

Provide a shared administrative sidebar and responsive monitoring workspace.
Fleet, host and host-scoped workload views share UTC time controls, filters,
interactive history, heatmaps, drill-downs and accessible values tables. Keep the
original raw host inspector available as a secondary route. VM administrative
inventory links through the physical machine identity to the monitor host; neither
identity's authority is changed.

Vendor Apache ECharts 6.0.0 with verified package integrity, license and notice.
Bundle it locally through the existing application asset entrypoint. LiveView hooks
own chart lifecycle, resizing, theme changes and visibility notifications. Tooltip
rendering uses canvas rich text, never interpolated HTML. No runtime CDN, external
Grafana service or editable-dashboard persistence is introduced.

Administrator-authorized Ash actions own historical chart projections and retained
workload discovery. SQL extracts curated fields, merges stored sums and weights
within entities, then aggregates selected entities. CPU and memory ratios retain
paired denominators; nested logical datasets remain separate. All matching enabled
hosts contribute to fleet totals irrespective of visible pagination. History
coverage counts observed contributing hosts, not uptime or scheduling eligibility.

Queries exclude expired rows using PostgreSQL time and retain existing resolutions.
Responses cap each series at 600 time points, each entity page at 50 identities and
rankings at 20 workloads. Cache projections for at most 60 seconds in a node-local
single-flight cache bounded to four concurrent requests, 16 entries and 16 MiB.
Recheck persisted administrator authority before and after cache access. Mounted
views recheck the login and current administrator authority on asynchronous result
completion as well as ordinary events and refreshes.

Historical panels refresh at most once per minute for relative windows; live
summaries refresh every five seconds. Pause and hidden-tab state stop polling.
Fixed intervals refresh on demand. Gaps remain absent; mixed-context points are
excluded from connected lines and remain inspectable in values tables. Workload
incarnations use separate series. Summed extrema are explicitly described as sums
of individual extrema, not simultaneous measured peaks.

## Alternatives

Actual Grafana adds an independent service, data source and access lifecycle.
Extending the manual dot plot would leave metric discovery, heatmaps and interaction
incomplete. Per-point or per-entity database calls amplify query counts. Loading
whole retained JSON documents into LiveViews makes browser memory depend on raw
collector cardinality.

## Consequences

The browser bundle grows by the vendored chart library. SQL projections remain
observational and cannot authorize compute changes. Storage retention, ingestion
and existing capacity-history semantics remain unchanged. The browser plots at
most 600 points per series; the accessible table shows the latest 100 intervals.
Missing metrics, limits and historical samples must not be replaced by zero.

## Invariants and verification

- Persisted administrator membership and stored login gate all mounted views.
- Unknowns, expired rows and missing denominators cannot manufacture capacity.
- Workload incarnation boundaries remain visible and do not create false trends.
- User-controlled names cannot introduce HTML or executable chart configuration.
- Hooks release observers, timers and chart instances on navigation.
- Validate representative browser fixtures and ordinary responsiveness; this change
  does not require or claim the waived 100-by-100 scale benchmark.

## Implementation evidence

Ziggy extends this existing monitoring path through
bounded local numeric probes (`nix/domains/system/fleet-monitor/runtime.py` at kittens revision `a99f74f0`, repository deleted),
proxy chart specifications (`marshall/lib/marshall/fleet/dashboard_catalog.ex` at kittens revision `a99f74f0`, repository deleted)
and [per-Lilly links](../../../marshall/lib/marshall_web/live/admin/lilly_nodes_live.ex).
Proxy monitoring remains observational; unknown/stale data grants no inference or
compute authority. See [ADR-0063](0063-private-services-and-ziggy.md) and the
[verification ledger](../../services/ziggy.md) for its separate implementation gaps.


Dashboard actions (`marshall/lib/marshall/fleet/dashboard.ex` at kittens revision `a99f74f0`, repository deleted),
entity discovery (`marshall/lib/marshall/fleet/dashboard_entities.ex` at kittens revision `a99f74f0`, repository deleted),
cache (`marshall/lib/marshall/fleet/dashboard_cache.ex` at kittens revision `a99f74f0`, repository deleted),
LiveView (`marshall/lib/marshall_web/live/admin/dashboard_live.ex` at kittens revision `a99f74f0`, repository deleted) and
[chart hooks](../../../marshall/assets/js/dashboard.js) implement the projection
and presentation boundaries. See the
[review](../reviews/2026-09-18-interactive-dashboards.md) for executed validation and
remaining limitations.

Brady extends the existing host/fleet panel catalog with aggregate proxy traffic,
errors, cache outcomes and storage pressure under [ADR-0069](0069-brady-egress-cache.md).
Runtime service integration is partial; no deployed Brady telemetry is claimed.

## Open questions

No unresolved product choices. Production deployment and production-scale behavior
are separate from representative local dashboard acceptance.

## Related decisions

[ADR-0060](0060-detailed-fleet-monitoring.md),
[ADR-0058](0058-administrative-authority.md),
[ADR-0023](0023-retained-capacity-telemetry.md).
