# Underclass durable proxy SLO

## Scope and architecture

ADR-0132 requires source durability before candidate promotion. ADR-0102 retains
independent host pools, private provider state, distinct proxy/admin credentials
and a separate tokenless local monitor. This change adds a Rust-only fixed proxy
outcome source to the pinned `3e35c3b` package, reusing its SQLite dependencies.
It introduces no guest identity, cross-host provider coordination or replay.

Admission commits before provider selection/effects. Terminal completion updates
one aggregate and removes the pending UUID atomically. Clean body EOF is required;
SSE additionally needs a dispatched completion marker and no sticky error or
malformed/oversized frame. Dropped streams are failures. Restart finalizes pending
work as failures with unknown duration. A live-owner lock prevents another process
from recovering active admissions. Uncertain persistence fences effects/export.

Journal files remain owner-private. The separate exporter UID reads only a
mode-0640 snapshot in an owned mode-0750 source directory. Provider state and the
runtime credential file are hidden from its mount namespace; it receives no
credential environment. Only the exporter joins the proxy collector group.
Collector provenance is fixed separately from the existing monitor probe.

Nix adds a thirteenth provisional objective, two burn warnings and three Grafana
panels. Marshall's fixed roster includes the same proxy path. Seven-day history,
traffic and freshness guards remain required; absent history stays unknown.

## Verification

The copied pinned Cargo source passed ten Rust checks, including three Hegel
generated properties covering arithmetic, chunk framing and restart/replay
histories. Explicit checks include private journal ownership, capacity refusal,
uncertain completion fencing, EOF/dropped bodies, oversized framing and restricted
source-group snapshot mode. Rust compiler checks passed for the synthetic provider
fixture. These are local source checks, not native systemd or production evidence.

The focused Marshall reader/burn suite passed eleven checks (seven properties,
four tests). Promtool passed its short-window, seven-day and burn fixtures with
new proxy cases for complete observations, missing host, stale requests and
missing source markers. The extended long-window fixture also passed a complete
synthetic seven-day two-host proxy window. These fixtures do not measure actual
production history.

Native fixture evaluation initially rejected mixed module configuration and an
overlong Unix username; those were corrected. Its first execution found omitted
Nginx TLS certificate directives. After fixing that fixture, native startup exposed
an accounting custody refusal: systemd reapplied the shared RuntimeDirectory mode
before launching each command, undoing an earlier chmod. The source now creates
its own mode-0750 child below the unchanged mode-0755 monitor directory.
The final custody oracle was corrected to run as the exporter UID; a root
namespace entrant can bypass file permission checks.

The native fixture passed in 39.04 seconds: packaged service startup, empty
lifetime restart, distinct-credential and malformed-JSON refusal, real local
provider TLS, successful/unterminated/error stream outcomes, numeric collector
export, SIGKILL pending recovery without provider replay and unknown interrupted
duration. The exporter UID differs from the producer and cannot read the provider
database, credential file in its namespace or producer process environment.
These are isolated native process/TLS checks, not production or power-loss evidence.
Production activation is recorded below.

## Freshness and final review

Freshness review found collector caching can preserve source values while scrape
timestamps advance. All fixed application exports now include the validated
snapshot sampling clock; the Underclass local probe includes its observation
clock. Reader guards reject missing clocks, age of 45 seconds or greater and
future skew beyond two seconds. The receiver Rust suite passed 20 tests, including
a generated probe-clock property. Promtool regressions cover frozen, absent,
future and live clocks separately. The native fixture passed in 91.21 seconds
including stopped exporter clock retention beyond 45 seconds. This demonstrates
collector caching; complementary Promtool regressions establish reader refusal.

Ingress freshness had the same indirect-health gap. A direct localhost HAProxy
scrape retains only scrape-generated health; counters still enter through OTLP.
Seven-day, burn and reader guards require this source health within 45 seconds.
Promtool passed absent, down, stale and live direct health cases. The fleet
fixture now stops/restores HAProxy while retaining collector health.

The initial expanded fleet fixture passed in 532.42 seconds, including 36-panel
provisioning, fixed collector provenance and both restart/outage trace recovery
paths. The initial Marshall browser fixture passed in 74.73 seconds; its scope
is ordinary-reader access, unknown seven-day data and login/remembered-token
revocation. The explicit proxy-card browser fixture passed in 84.10 seconds,
including its 99% provisional target, unknown seven-day value and unknown burn
windows. The direct-ingress fixture observed HAProxy health become zero, then
its collector oracle incorrectly included forwarded host-origin scrape metrics.
The corrected oracle uses the production empty-origin selector. The final fleet
fixture passed in 583.80 seconds, including HAProxy stop, simultaneous healthy
collectors and direct source-health recovery.

Semantic contract review traced admission, finalization, body drop, restart,
group snapshot publication, fixed exporter allowlist, source clock guards and
their Nix catalog/Grafana/Marshall consumers. No violations were found within
that scope. SQLite fsync latency, real providers and physical guest boundaries
remain unverified. Unified-patch blank context lines retain their required
leading space; whitespace checks exclude blank-line trailing-space diagnostics.

Marshall's isolated full `mix precommit` passed 1,392 checks (200 properties,
1,192 tests, two excluded) in 1,103.9 seconds of test execution. Forced Dialyzer
reported zero errors, skips and unnecessary skips. The dedicated
`otel_slos_20261002` partition kept these tests out of the shared default database.
The merged source contract checker and its regression tests passed; ADR, generated
topology and option-reference checks also passed. These structural gates do not
establish production or physical guest reliability.

Upstream common-runtime startup tests landed during publication. The merged
startup and SLO reader suite passed 13 checks (eight properties, five tests),
followed by forced test-environment Dialyzer with zero errors or skips. The
1,392-check full run above predates this test-only upstream addition; production
SLO code is unchanged by the merge. Its scenario/configuration evidence was
preserved and generated coverage reviewed again.

## Deployment verification

Both hosts activated `3ef521c57df0bf1fffd1f625eeb98f484fd3b663` from origin/main
and reported healthy with zero updater failures. Read-only checks verified
separate exporter/producer UIDs, mode-0750 source directories, mode-0640 snapshots,
mode-0600 journals, exporter snapshot read-only access, provider database refusal
inside the exporter namespace and producer-environment refusal. Fixed clocks were
fresh. The journal and snapshot agreed on lifetime, incarnation, outcome counters,
duration count/sum and bucket totals on both hosts. Overalls carries live traffic;
an initial comparison observed normal snapshot lag, and a bounded repeated
read-only comparison captured agreement without stopping or replaying requests.

Overalls' Prometheus API reported thirteen objective rules and 26 burn evaluators
with healthy rule status. Its authenticated loopback Grafana API reported 36
panels including the durable proxy candidate. The running Marshall BEAM process
referenced the thirteen-entry guarded catalog and 99% proxy target. Production
ordinary-reader browser rendering remains unverified; the packaged browser result
above covers that UI scope. No provider inference request was made for deployment
verification. This confirms activation and configuration, not seven-day compliance
or notification delivery.

## Remaining work

SQLite FULL fsync throughput,
power loss, real upstream providers, guest/tailnet journeys, complete seven-day
baseline, final targets and notification delivery remain separate acceptance gaps.

## Handbook browser verification

The integrated native `hldd-browser` check passed after correcting its fixture
revocation to invalidate both the login and remembered credential issued by
ADR-0131. The Nix build completed in 71 seconds; its execution archive is
`/home/ghuntley/.local/state/nix/build-logs/1790951376966-920070-0.jsonl`.
The real-release single-machine TLS browser visited every section, rendered the
Ash and deployment diagrams, checked navigation teardown, history, theme and
mobile layout, and refused mounted and fresh requests after credential revocation.
This preserves the accepted authentication design; changing only the isolated
fixture has no production architecture impact. It does not verify production
browser rendering or independent-host revocation.
