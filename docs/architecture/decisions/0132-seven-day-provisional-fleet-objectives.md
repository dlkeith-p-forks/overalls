# ADR-0132: Seven-day provisional fleet objectives

- ID: ADR-0132
- Date: 2026-10-02
- Status: superseded
- Implementation: partial
- Components: Marshall, NixOS, Prometheus, Grafana
- Supersedes: ADR-0129
- Superseded by: ADR-0149

## Context

[ADR-0149](0149-independent-observability.md) replaces application diagnostic
transport, persistence and presentation, with Lilly v4 and Ziggy v2 documents.
It carries forward unrelated authority, isolation, transactional audit/accounting
and recovery requirements. The original rationale and historical evidence follow.

ADR-0129 deferred targets and alerts until after a 28-day baseline. The user
subsequently directed one-pass target and burn-alert configuration around a
seven-day window and display in Marshall. The production store has fewer than
seven days of samples. Several application sources still report narrower
candidate outcomes and can lose unexported counts on restart.

## Decision

Retain ADR-0129's host-local collectors, private Grafana and Tempo topology,
trusted outer-source isolation, Rust guest receiver, Audi binding gate, and
signed-in fixed-projection Marshall read boundary. Nix owns an explicit roster
and provisional seven-day target for every existing trusted candidate:
99.9% for fleet collector availability, 99.5% for public ingress HTTP
completion, and 99% for each application candidate and Underclass local
monitor readiness. These are provisional indicators of their named paths;
they do not establish end-to-end user journey reliability.

A seven-day ratio exists only when both collector scrapes have all 20,160
expected samples, every enrolled application source has the same
request-series coverage, its source-start marker predates the window, and its
current source is fresh. Application and ingress ratios also require at least
100 requests in seven days. Missing data remains unknown. A source restart
with non-durable counters restarts the seven-day observation window.

Prometheus evaluates paired 5-minute/1-hour fast and 30-minute/6-hour slow
error-budget burn expressions. The fast threshold is 3.36 times the error
budget, consuming 2% of a seven-day budget in one hour; the slow threshold is
1.4 times, consuming 5% in six hours. Each requires at least 20 requests per traffic
window and a fresh eligible seven-day recording. Alerts are labeled
`status=provisional`; there is no configured production notification receiver.
[ADR-0139](0139-private-slo-burn-delivery.md) adds optional private webhook delivery
without changing these objective semantics. Marshall
shows the limited candidate name, five-minute reading, seven-day reading,
provisional target and actual fast/slow rule states to signed-in users. Rule
states require the exact 40-rule roster extended by ADR-0133, reviewed labels, healthy evaluation
and per-rule evaluation within 90 seconds. Missing eligible objective history
also makes the displayed burn state unknown. Grafana retains private operator detail.
Both readers repeat current collector and source readiness guards so a
retained recording disappears after its source vanishes between rule runs.

Final targets, paging routes and promotion from candidate to service SLO
require durable accounting, source-boundary tests, complete user-journey
evidence and a measured baseline. A seven-day provisional target is not a
claim that a path met it in production.

## Alternatives

Retaining the 28-day wait would defer the user's requested configuration.
Treating sparse or absent traffic as success would manufacture reliability.
Paging from unproven source accounting could generate misleading incidents.

## Consequences

The first seven-day result cannot exist until a full eligible window has
elapsed. A collector outage or source restart can delay it. The single
Overalls Prometheus remains the alert evaluation failure boundary. The
provisional warning state is visible to operators but does not notify anyone.

## Invariants and verification

- Guest diagnostic series never enter outer-fleet objective arithmetic.
- Missing, sparse, restarted or out-of-roster source data never produces a
  valid seven-day ratio or burn state.
- The signed-in Marshall reader accepts only its fixed Nix-owned roster and
  validates the exact recording name and result cardinality.
- Promtool fixtures cover missing history and a complete two-host seven-day
  window. Property tests cover malformed or duplicate Marshall observations;
  NixOS tests cover the provisioned UI and dashboard.

## Implementation evidence

The [objective roster](../../../nix/domains/system/otel-fleet/objectives.nix) and
[rules](../../../nix/domains/system/otel-fleet/objective-rules.nix) provision targets,
coverage guards and burn expressions. The [signed-in catalog](../../../nix/domains/system/otel-fleet/slo-catalog.nix)
feeds Marshall's bounded reader (`marshall/lib/marshall/telemetry/slo_read.ex` at overalls revision `a99f74f0`, repository deleted)
and SLO page (`marshall/lib/marshall_web/live/slo_live.ex` at overalls revision `a99f74f0`, repository deleted).
The [Promtool fixture](../../../nix/verification/tests/evaluation/otel-slo-rules.nix) and
[browser machine fixture](../../../nix/verification/tests/machines/otel-marshall/default.nix)
check the boundaries. The [provisional objective review](../reviews/2026-10-02-provisional-seven-day-slos.md)
records passing checks, production rollout and remaining acceptance gaps.

## Open questions

Ziggy's [checkpoint](../../../ziggy/lib/ziggy/slo_checkpoint.ex) and
[spool](../../../ziggy/lib/ziggy/spool.ex) now preserve terminal aggregates
across process restart, including acknowledged slot removal. Generated histories
and the packaged service fixture exercise replay, private custody and interrupted
admission without provider replay. Reader-first deployment remains required:
the default-disabled producer may be enabled only after compatible readers
reach all hosts; existing checkpoints survive disabling the producer switch.
Both production hosts reached the compatible reader revision `8704fac5` with
healthy updater and Ziggy states before their configurations enabled creation.
Producer activation at `4f2f7186` was verified healthy on both hosts with private
mode-0600 checkpoints agreeing with live source lifetimes and aggregate counters.
Power-loss and native Firecracker provider-path acceptance remain open.

Underclass's private [Rust journal](../../../nix/domains/artifacts/underclass/slo.rs)
and [pinned instrumentation patch](../../../nix/domains/artifacts/underclass/instrumentation.patch)
extend the fixed roster with a separate durable proxy completion candidate.
Authorized parsed admission commits before effects; completion requires response
EOF and, for SSE, a dispatched terminal marker without errors. Pending work
becomes one failure with unknown duration after restart, without provider replay.
The independent exporter reads only a source-group numeric snapshot and receives
no provider credentials. The isolated native fixture passed; two-host activation
at `3ef521c5` and live journal/snapshot agreement were verified in
the [proxy review](../reviews/2026-10-02-underclass-proxy-slo.md).

Application exporters and the local monitor probe include explicit source sampling
clocks. Fresh collector scrapes cannot establish source freshness: absent clocks,
clocks older than 45 seconds or more than two seconds in the future suppress the
reading even when the collector retains previous values.
Ingress guards additionally require a fresh successful direct localhost HAProxy
health scrape. That job discards application metrics; ingress SLIs retain their
OpenTelemetry collection path.

[ADR-0133](0133-durable-physical-service-level-accounting.md) adds three durable
measurement sources for creation-to-ready, physical lifecycle and operation-linked
SSH physical completion, with the same provisional 99% policy. Their native
publication and serial NixOS/Ubuntu physical journeys have recorded passing
execution. Both hosts activated the physical and four workflow sources, bringing
the roster to twenty objectives and forty burn alerts; ADR-0133 records the
revisions and scope. Native retry/cancellation measurement acceptance, live
provider behavior and seven-day compliance remain open. ADR-0136 adds durable
recorders to the eight application request sources; complete per-source fault
acceptance remains separate. Final targets and production notification routes
await source and operational evidence.

## Related decisions

[ADR-0138](0138-telemetry-retention-and-measurement-diagnostics.md) adds ninety-day
data retention and prioritized diagnostics while preserving seven-day objectives
and burn thresholds.

[ADR-0137](0137-public-authenticated-grafana.md) amends the private Grafana access
boundary with opt-in authenticated public HTTPS on Overalls.


The [reporter receipt history review](../reviews/2026-10-03-ziggy-reporter-histories.md)
checks independently calculated lifetime outcomes, known-duration sums and every
duration bucket through refusal, exact acknowledgement and spool restart. The
focused property passed seed203368 in7.6seconds. This local evidence preserves
unknown usage and does not establish live SLO compliance. Full Ziggy precommit passed 64
checks (15 properties, 49 tests), seed 521050, in 61.7 seconds. Forced Dialyzer passed
in 5.33 seconds with zero errors, skips or unnecessary skips; terminal exit0.

[ADR-0129](0129-fleet-otel-slos.md), [ADR-0042](0042-host-observability.md).
