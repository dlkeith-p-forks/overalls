# ADR-0060: Detailed fleet resource monitoring

- ID: ADR-0060
- Date: 2026-09-18
- Status: superseded
- Implementation: partial
- Components: Marshall, Lilly, NixOS, PostgreSQL
- Supersedes: none
- Superseded by: ADR-0149

## Context

[ADR-0149](0149-independent-observability.md) replaces application diagnostic
transport, persistence and presentation, with Lilly v4 and Ziggy v2 documents.
It carries forward unrelated authority, isolation, transactional audit/accounting
and recovery requirements. The original rationale and historical evidence follow.

The approved admin plan requires a detailed fleet/node utilization interface,
including all physical platform hosts and attributed VM/service consumption.
Per-second database persistence would add excessive load. Existing capacity
reports and their history are authoritative scheduling inputs and have a different
cadence and transaction boundary from observational monitoring.

## Decision

Run an independent host collector with five-second CPU, memory, pressure, disk,
network and cgroup sampling. Collect ZFS accounting every 30 seconds; retain each
measurement's actual sampling context. Identify physical hosts using the same
application-specific machine-ID derivation as Lilly, deduplicating colocated
Marshall/Lilly/Audi/Porsche roles. Bind reusable devices to their incarnation and
workloads to the launched unit invocation plus placement/epoch for VMs. Unit
descriptions carry versioned placement/epoch/generation metadata, never secrets.
Old units without that binding have unknown attribution until restarted normally.

Use a dedicated host-bound credential delivered through existing runtime secret
custody and verified HTTPS to a versioned ingestion API. Collection and delivery
run independently of Lilly and must never stop guests or modify execution state.
Keep a private bounded retry spool for at most 30 minutes, 360 samples and a byte
budget. Only durable acknowledgments remove samples; expiry/overflow is visible.

Monitor credentials are random 256-bit secrets returned once to deployment
tooling. Store a SHA-256 digest for constant-time verification; this credential
does not need plaintext recovery. Rotation/revocation serialize on the separate
monitor host, retain secret-free audit and do not affect Lilly execution authority.
Queued persistence rechecks current monitor authority before committing history.

Marshall uses bounded, non-authoritative live caches and coalesced refreshes across
replicas. Persist minute batches outside compute transactions. Retain host/device
minute history for 24 hours and 15-minute history for 30 days; retain VM/service
minute history for 24 hours and hourly history for 30 days. Existing Lilly report
cadence, freshness and 10-second/5-minute capacity history remain unchanged.

Unknown, stale, reset and mixed-context observations remain explicit. Rates use
actual monotonic elapsed time. CPU guest time is not counted twice; physical
storage, recursive logical dataset use, VM promises and workload consumption are
distinct views. Fleet percentages use weighted denominators and report coverage.
No guest-process collection is authorized.

## Alternatives

Adding detailed workload writes to the capacity-locked recorder would increase
admission contention. Logging raw process lists would expose guest information.
Summing every device, dataset and workload would count nested resources multiple
times. Per-second persistence is explicitly excluded by the user's load goal.

## Consequences

The new monitoring plane requires its own credential lifecycle, schema, bounded
cache and retention work. Read-only ZFS/network-namespace inspection requires host
privileges but confers no application authority. Data begins at deployment; cache
loss is recoverable from the collector buffer until expiry. Missing metrics are
not proof of idle capacity. A 30-minute buffer is bounded, not a lossless-outage
guarantee. Fleet database/storage budgets require measured acceptance.

## Invariants and verification

- Physical hosts and nested resources are not double counted.
- Counter reset, boot, invocation, epoch and device reuse cannot create false rates.
- Unknown values remain distinct from measured zero; gaps are never interpolated.
- Export failures and overflow cannot affect guests or scheduling authority.
- Credentials cannot cross hosts or enter samples/logs; redirects are rejected.
- Collector, API, history and UI remain bounded at 100 hosts × 100 workloads.
- Verify minute batching, durable deduplication, retention, WAL cost and UI latency.
- Native NixOS tests establish actual cgroup, ZFS and namespace observations.

## Implementation evidence

The [fleet refusal histories](https://github.com/antithesishq/kittens/blob/a99f74f06542798dc9ef288e77c99d480433fc57/marshall/test/marshall_web/fleet_version_history_test.exs)
use actually issued credentials and preserve complete public-table hashes and
exact timer-free monitoring cache state after each refused surface corpus.
They reproduced malformed monitor JSON entering the generic 503 arm; the
[ingestion plug](https://github.com/antithesishq/kittens/blob/a99f74f06542798dc9ef288e77c99d480433fc57/marshall/lib/marshall_web/fleet_api.ex) now maps parser
errors to its existing permanent 400 invalid-samples class before cache admission.
Current dispatch and actual sample acceptance/flush calibrate the state oracles.
The [property audit](../reviews/2026-09-29-antithesis-property-audit.md) records
local scope and retained TLS, native, scale and client-retry gaps.

Ziggy extends this existing monitoring path through
[bounded local numeric probes](https://github.com/antithesishq/kittens/blob/a99f74f06542798dc9ef288e77c99d480433fc57/nix/domains/system/fleet-monitor/runtime.py),
[proxy chart specifications](https://github.com/antithesishq/kittens/blob/a99f74f06542798dc9ef288e77c99d480433fc57/marshall/lib/marshall/fleet/dashboard_catalog.ex)
and [per-Lilly links](../../../marshall/lib/marshall_web/live/admin/lilly_nodes_live.ex).
Proxy monitoring remains observational; unknown/stale data grants no inference or
compute authority. See [ADR-0063](0063-private-services-and-ziggy.md) and the
[verification ledger](../../services/ziggy.md) for its separate implementation gaps.

Galileo uses the same bounded local-proxy projection. The
[strict sample validator](https://github.com/antithesishq/kittens/blob/a99f74f06542798dc9ef288e77c99d480433fc57/marshall/lib/marshall/fleet/sample.ex) now
accepts its three closed numeric gauges only on the `galileo.service` record and
keeps readiness boolean-coded. A production Dungarees sample exposed the missing
server allowlist even though the collector already emitted those fields; the
[regression test](https://github.com/antithesishq/kittens/blob/a99f74f06542798dc9ef288e77c99d480433fc57/marshall/test/marshall/fleet/sample_test.exs) covers the
accepted record, cross-service rejection, invalid readiness and negative counts.
The complete Marshall precommit gate passed with 852 checks (787 tests and 65
properties), contract/logging/ADR checks, browser-side suites and zero Dialyzer
errors. This fixes schema agreement but does not complete the remaining native
transport and scale obligations.


[Measurements](https://github.com/antithesishq/kittens/blob/a99f74f06542798dc9ef288e77c99d480433fc57/nix/domains/system/fleet-monitor/metrics.py) implement bounded
Linux/ZFS parsing and identity-aware rates. The independent
[runtime](https://github.com/antithesishq/kittens/blob/a99f74f06542798dc9ef288e77c99d480433fc57/nix/domains/system/fleet-monitor/runtime.py) collects allowlisted
systemd metadata, rechecks invocation stability, buffers samples and accepts only
durable acknowledgments. The [NixOS module](https://github.com/antithesishq/kittens/blob/a99f74f06542798dc9ef288e77c99d480433fc57/nix/domains/system/fleet-monitor/default.nix)
is opt-in with runtime credential paths and service budgets.
[Lilly launch metadata](../../../lilly/lib/lilly/vm/unit.ex) binds the actual
launched revision rather than later intent. Ten
[isolated collector tests](../../../nix/verification/tests/evaluation/fleet-monitor.py) pass;
these are not native fleet acceptance. HTTP ingestion, deployment enrollment,
caches, history persistence, dashboards and scale/native acceptance were pending
at the collector checkpoint below; subsequent server evidence follows.

The [Fleet resources](https://github.com/antithesishq/kittens/blob/9fe1e493b2090d44bacd16089049cd12b316d58a/marshall/lib/marshall/fleet.ex) now model unique
physical hosts and dedicated credentials. The
[credential coordinator](https://github.com/antithesishq/kittens/blob/9fe1e493b2090d44bacd16089049cd12b316d58a/marshall/lib/marshall/fleet/credentials.ex)
implements fresh authentication, rotation and revocation. The
[sample validator](https://github.com/antithesishq/kittens/blob/a99f74f06542798dc9ef288e77c99d480433fc57/marshall/lib/marshall/fleet/sample.ex) implements the
bounded version-one allowlist. Seven
[focused tests](https://github.com/antithesishq/kittens/blob/a99f74f06542798dc9ef288e77c99d480433fc57/marshall/test/marshall/fleet/credentials_test.exs) (including
[sample checks](https://github.com/antithesishq/kittens/blob/a99f74f06542798dc9ef288e77c99d480433fc57/marshall/test/marshall/fleet/sample_test.exs)) passed.
A real local collector envelope also passed the Marshall validator. Deployment
enrollment wiring remains pending.

The [ingestion plug](https://github.com/antithesishq/kittens/blob/a99f74f06542798dc9ef288e77c99d480433fc57/marshall/lib/marshall_web/fleet_api.ex) now requires
actual HTTPS and a dedicated bearer, bounds JSON reads and bypasses generic request
logging. The [cache](https://github.com/antithesishq/kittens/blob/a99f74f06542798dc9ef288e77c99d480433fc57/marshall/lib/marshall/fleet/cache.ex) keeps bounded
compressed observations and pending samples, coalesces notifications every five
seconds and flushes at most 128 samples per host per minute. Connected BEAM nodes
share a globally named cache; PostgreSQL serializes writes even if cache owners
split. Disconnected-replica fairness and deployment connectivity still need native
and scale verification. Collectors rotate through buffered replay windows while
including the newest sample, allowing backlog to drain without waiting on the
same initial window every time.

[History](https://github.com/antithesishq/kittens/blob/a99f74f06542798dc9ef288e77c99d480433fc57/marshall/lib/marshall/fleet/history.ex) commits per-host/scope/
period JSON statistics, short-lived digest-bound receipts and flush time together.
Sample receipt rows expire after two hours; per-host bucket payloads are capped at
16384 entities and 8 MiB. Only committed receipts authorize ACKs. Sampled gauges
retain counts/extrema, while rate means weight observed intervals and assign them
to the interval end bucket; these weights are not time-coverage percentages.
Mixed contexts and unknowns remain explicit. [Read projection](https://github.com/antithesishq/kittens/blob/a99f74f06542798dc9ef288e77c99d480433fc57/marshall/lib/marshall/fleet/read_history.ex)
extracts one entity in PostgreSQL and filters expiry before bounded cleanup.
Twenty-two focused tests cover persistence, rollback, replay, revocation, API
limits, history extraction and retention. The ingestion checkpoint passed 581
Marshall tests and Dialyzer (before its final three focused additions).

The [inventory action](https://github.com/antithesishq/kittens/blob/9fe1e493b2090d44bacd16089049cd12b316d58a/marshall/lib/marshall/fleet/inventory.ex) returns
bounded authenticated physical-host pages under [ADR-0119](0119-authenticated-control-room-reads.md), including offline identities.
The [fleet projection](https://github.com/antithesishq/kittens/blob/a99f74f06542798dc9ef288e77c99d480433fc57/marshall/lib/marshall/fleet/utilization.ex) weights
known CPU/RAM numerators by matching denominators, excludes stale/cross-boot
records and keeps physical pools separate from logical datasets. It reports
contributing-host counts and excludes incomplete storage summaries. The
[fleet page](https://github.com/antithesishq/kittens/blob/a99f74f06542798dc9ef288e77c99d480433fc57/marshall/lib/marshall_web/live/admin/fleet_live.ex) refreshes
cached measurements every five seconds, inventory every minute, and calculates
totals/rankings across all enrolled inventory pages while keeping host rows
bounded. The [node page](https://github.com/antithesishq/kittens/blob/a99f74f06542798dc9ef288e77c99d480433fc57/marshall/lib/marshall_web/live/admin/node_live.ex)
shows bounded resource pages and explicitly requested historical means/extrema
with observation counts and unjoined gaps. Twenty-six focused Fleet/domain/UI
tests pass at this checkpoint. Workload ranking, capacity explanations and
control-plane health are implemented; ADR-0062 now supplies shared retained-range controls and graphical
fleet/host/workload drill-downs. Native transport/replica tests and production
database/WAL benchmarks remain required; see the
[dashboard review](../reviews/2026-09-18-fleet-dashboards.md).

[ADR-0062](0062-interactive-monitoring-dashboards.md) adds the interactive dashboard
workspace, bounded multi-metric projections, per-core heatmaps and dedicated
workload views. Its [review](../reviews/2026-09-18-interactive-dashboards.md) records
validation separately from the original native/scale obligations.

Brady monitoring extends this path under [ADR-0069](0069-brady-egress-cache.md),
using fixed aggregate request/cache metrics and the existing authorized history
and dashboard machinery. Runtime service integration remains partial; this does
not change the acceptance status of the previously implemented monitoring path.

## Open questions

The terminal master plan adds a passive numeric terminal-service projection:
Lilly stream readiness, channels, dial failures/proxy errors, and recent
per-placement/epoch/generation guest dial observations. The
[collector decoder](https://github.com/antithesishq/kittens/blob/a99f74f06542798dc9ef288e77c99d480433fc57/nix/domains/system/fleet-monitor/terminal_metrics.py)
rejects unknown fields, wrong host identity and oversized responses, while
failed observation remains absent. The
[completion ledger](../../history/ledgers/terminal-v2-completion.md) tracks current source and
verification; these metrics must not authorize execution or replace freshness
gates. End-to-end monitoring acceptance remains pending.

No unresolved product choices. Measured storage/WAL/UI budgets and native
acceptance remain required before claiming the requested scale is supported.

## Related decisions

[ADR-0023](0023-retained-capacity-telemetry.md) retains its independent scheduling
history semantics. [ADR-0042](0042-host-observability.md) retains diagnostic custody
and log export. [ADR-0058](0058-administrative-authority.md) gates admin access.
