# ADR-0129: Fleet OpenTelemetry SLOs and guest diagnostic ingestion

- ID: ADR-0129
- Date: 2026-09-28
- Status: superseded
- Implementation: partial
- Components: Marshall, Lilly, Audi, fleet applications, NixOS, Grafana, Prometheus, Tempo
- Supersedes: none
- Superseded by: ADR-0132

## Context

The user requested configuration-as-code SLOs for all Overalls platform journeys
and internal applications, self-hosted Grafana in the fleet, guest Overalls
telemetry through Audi, property-based and NixOS integration evidence, and
production validation. The existing Fluent Bit pipeline exports diagnostic
logs and one-minute numeric summaries; its summary values are gauges and do
not provide durable request denominators or latency distributions. Overalls is
the sole Marshall/PostgreSQL host; Dungarees is a worker. Audi already owns
private DNS, TLS, and a Lilly-derived current VM binding.

## Decision

Each host runs a bounded OpenTelemetry collector independently of application
and guest lifetime. Unsampled, low-cardinality counters and histograms define
SLIs; sampled traces aid diagnosis but never determine SLO compliance. Overalls
hosts Prometheus, Tempo, and Grafana with explicit retention and storage limits.
Dungarees exports over verified, authenticated fleet transport. Collection
outages make data unknown, never successful. Metrics and trace storage do not
authorize VM operations or replace Ash/PostgreSQL authority.

SLOs are declared in reviewed NixOS configuration, which provisions recording
rules, dashboards, and visible draft burn states. The first 28 days establish a
baseline; notifications and enforced targets require a subsequent reviewed
configuration change. Marshall presents only allowlisted recorded SLO series
to every signed-in user under its existing current-login boundary. The full
Grafana query interface stays private to operators.

Overalls processes in eligible guests use `https://otel.integration.internal`
with OTLP/HTTP protobuf metrics or traces. This name fits the existing
`*.integration.internal` certificate. Audi accepts only the exact OTLP paths,
verifies TLS name and Lilly's pre-NAT VM/placement/epoch binding, and forwards
through a restricted local Unix socket. A separate bounded ingestion service
validates and sanitizes payloads and assigns outer provenance before local
collection. Customer guests retain their private-network prohibition. Ordinary
guests are user-controlled: their telemetry is a diagnostic claim, even when it
uses a platform process name, and cannot enter outer-fleet SLO arithmetic.

## Alternatives

Putting protobuf decoding and storage inside Audi would couple its access
gateway to telemetry volume and failures. A public collector listener would
bypass Audi's guest identity and isolation boundary. Guest-provided identity
labels or credentials cannot attest a process in a user-controlled VM.
Using `otel.internal` would require rotating the offline fleet certificate;
the named integration zone already provides the separate TLS identity.

## Consequences

The central SLO read path shares Overalls' failure boundary. Dungarees retains
bounded local export state during an outage, but this does not create an
independent paging path. Guest diagnostics need explicit rate, payload,
cardinality, and privacy limits and must be segregated from trusted series.
No existing guest disk is implicitly rewritten; guest instrumentation follows
the supported image and CLI update paths.

## Invariants and verification

- No sampled trace, guest claim, expected refusal, or absent observation can
  silently improve an outer-fleet SLO numerator or denominator.
- OTLP guest requests require exact method, path, media type, TLS name, current
  Lilly binding, and bounded body. A changed binding fences the upload.
- Destination credentials and payload content never enter Nix store text,
  ordinary logs, or user-facing SLO queries.
- Property tests cover request grammar, label and payload bounds, outcome
  deduplication, and missing-data arithmetic. NixOS tests cover a real guest
  through Audi, both hosts' export, outage replay, isolation, and browser
  admission/revocation. Production evidence must verify live collection.

## Implementation evidence

[Audi private OTLP routing](../../../audi/lib/audi/private/front.ex) provides
the exact route and bounded forwarding; its [property tests](../../../audi/test/private_otel_test.exs)
exercise the request grammar and declared size limits. The
[Rust guest receiver](../../../nix/modules/otel-guest/receiver/src/lib.rs)
sanitizes payloads and has property tests. The
[fleet module](../../../nix/modules/otel-fleet/default.nix) enables collectors,
Prometheus, Tempo and loopback Grafana on enrolled hosts. The
[NixOS machine test](../../../nix/tests/machines/otel-fleet/default.nix)
passes central service startup, hostmetric scrape, valid guest metric export,
and socket/namespace refusal. Its extended two-node run passed persisted
worker trace-queue replay after a collector restart during a central Tempo
outage. A subsequent run uses disposable peers of the production fleet
WireGuard module and passes trace backfill after a worker tunnel outage and
collector restart. These fixtures send direct local OTLP traces; they do not
establish guest TLS over the central tunnel or production trace retention. The
[signed-in SLO page](https://github.com/antithesishq/kittens/blob/a99f74f06542798dc9ef288e77c99d480433fc57/marshall/lib/marshall_web/live/slo_live.ex)
reads only two fixed recording rules and preserves unknown data. HAProxy supplies
an unsampled draft public ingress completion ratio; application-specific SLIs,
real guest trace delivery across WireGuard and production trace validation
remain outstanding. The
[Rust Lyra guest executor](../../../lyra/src/telemetry.rs) now emits fixed cumulative
tool counts, a duration histogram and one fixed-name span after the terminal
transition. The trace ID is derived from a one-way hash of the command ID;
the command ID, arguments, result and user data are absent from OTLP. These are
diagnostic claims and do not enter fleet SLO arithmetic. The recorded
[native guest journey](../../../nix/tests/machines/fleet/scenarios/agent.py)
passes an acknowledged tool result through Audi private TLS, Lilly's current
binding, the restricted Rust receiver and the host collector. The extended
native journey queries the acknowledged command's trace at disposable local
Tempo after the same guest TLS and receiver path. Binding changes during
upload and live production guest collection remain open.
Brady now writes a private [cumulative outcome snapshot](../../../brady/lib/brady/metrics.ex)
for resolved terminal requests. A [Rust host exporter](../../../nix/modules/otel-guest/receiver/src/bin/slo_exporter.rs)
validates fixed fields, file custody, freshness and monotonicity before local
OTLP export through a group-restricted Unix socket. This is candidate
instrumentation: a scoped Firecracker request-to-collector assertion passed,
while the complete Brady fleet run later failed in restart recovery. The
measured target baseline remains pending. No fleet compliance rule consumes the
candidate series. The Galileo source now records admitted terminal outcomes
and fixed duration buckets. A separate collector intake assigns its service
identity, and a Rust exporter reads Galileo's bounded private Unix snapshot.
The packaged Galileo/Audi journey passed through the Rust exporter and isolated
collector, including an ordinary Galileo UID socket refusal. The full
Firecracker Galileo fleet variant passed, including guest-to-collector delivery,
detached-request denominator refusal, relocation and recovery. The target
baseline remains open. Further applications need their own
source-isolated identity before export.
Enrico's mirror manager now counts unique admitted terminal refreshes and fixed
durations. Its owner-only Unix health frontend exposes a numeric snapshot, and
a Rust exporter sends it through an Enrico-only collector intake with
collector-assigned identity. A packaged NixOS source-to-collector test and a
generated arithmetic property passed; cross-host Marshall scheduling, live
collection and a target baseline remain open.
Porsche now records cumulative terminal SSH command dispatch outcomes and fixed
duration buckets, excluding invalid and forbidden results. Its private numeric
file is validated by a Rust exporter and sent through a Porsche-only collector
intake with collector-assigned identity. This is a candidate dispatch SLI:
accepted asynchronous work does not establish physical VM completion, and
source-process crash accounting, a full authorized management journey and the
target baseline remain open. At 2026-09-29 05:16:48 UTC, a read-only production
Prometheus query observed 45 Porsche dispatch requests and 45 successes on
Overalls under assigned application provenance. This establishes collection,
not physical completion or a measured SLO target.
Ziggy now counts newly durable terminal inference completions in its source
spool and excludes caller-cancelled streams. Incomplete recovered admissions
remain failures with unknown duration. A private numeric file feeds a Rust
exporter through a Ziggy-only collector intake with collector-assigned
identity. Its candidate ratio has no target or burn alert. Post-acknowledgment
counter recovery, live collection and the target baseline remain open.
Audi private now counts transport completion only after an accepted current
Lilly binding for non-OTLP private service requests. Pre-binding denials and
guest telemetry uploads cannot improve the candidate ratio. Fixed cumulative
counts and durations feed a private numeric snapshot and a Rust exporter through
an Audi-private-only collector socket with collector-assigned identity. The
source process can lose unexported counts on restart; this is candidate
instrumentation, not yet a production SLO or a complete guest journey.
At 2026-09-29 05:16:48 UTC, production Prometheus observed Audi private
requests/successes/failures of 2242/2242/0 on Overalls and 2306/2242/64 on
Dungarees under assigned application provenance. These cumulative values
establish live collection, not a source restart guarantee or measured target.
Audi DNS now counts ordinary in-zone authoritative NOERROR/NXDOMAIN replies as
completed candidate outcomes, and stale-publication SERVFAIL or socket send
failure as failures. Malformed, out-of-zone, unsupported transfer and truncated
UDP packets are excluded. The DNS-only process publishes a fixed private
snapshot for a Rust exporter with its own group-restricted collector socket and
collector-assigned identity. Runtime increments use atomic memory counters;
the source publishes one bounded snapshot every five seconds rather than
writing for each public DNS reply. This remains a candidate response SLI: it does not
prove recursive resolution or client use of an address, and unexported counts
can be lost on process restart.
At 2026-09-29 05:16:48 UTC, production Prometheus observed Audi DNS requests
and successes of 1 on Overalls and 18 on Dungarees under assigned application
provenance. This establishes nonzero source collection on both hosts, not
recursive resolution or a 28-day baseline.
The DNS candidate recording rule now requires a recent request counter from
each of the two enrolled authoritative hosts, `overalls` and `dungarees`.
Prometheus drops the ratio when either source is absent or its last sample is
older than 45 seconds. This protects the aggregate from silently treating one
missing replica as a healthy fleet; a zero-traffic host still exports its
cumulative zero counter. The roster is explicit Nix configuration and must be
updated with any DNS placement change. This guard does not establish an SLO
target or replace live source-to-collector verification.
Audi's public SSH role now counts only valid granted guest-stream establishment:
local connector or guard failure after a valid grant is failure, and an
acknowledged exec request with a connected guest socket is success. Invalid
keys, selectors and denied or malformed grants are excluded. Fixed cumulative
numbers and durations go to a mode-0640 snapshot in an Audi-owned directory;
a separate static Rust exporter reads through a nonwritable source group and
sends to an Audi-SSH-only collector intake with assigned application identity.
The candidate ratio requires a fresh source from both enrolled hosts and has
no target or burn alert. It does not measure guest user authentication or
terminal command completion, and a process restart can lose unexported counts.
The local SSH transport suite passed 17 tests, including denied-grant exclusion,
valid-grant connector failure and acknowledged stream success; this does not
establish a native guest-to-collector result. A dedicated native Audi variant
now composes the real guest SSH journey with disposable WireGuard peers and the
production collector; its first full run passed positive collector assertions
but failed later in Lilly crash recovery. The focused native variant passed the
authorized guest SSH journey through the source snapshot, static Rust exporter
and host collector. The crash-recovery finding remains open.
Marshall's browser endpoint now counts completed responses after its privacy,
health and public machine-API prefilters. 2xx-4xx responses are transport
successes; 5xx, exceptions and missing final status are failures. Fixed
cumulative counters and durations enter a mode-0640 per-instance snapshot in a
dedicated mode-0750 directory owned by Marshall's dynamic UID. The source
group may read but cannot replace the mode-0640 file; a separate static Rust
exporter reads it through that group and alone
receives the Marshall-only collector socket group. Nix supplies the bounded
replica identity.
The candidate ratio requires a fresh source and a nonzero denominator, with
no target or burn alert. This does not measure VM creation, asynchronous
completion or a complete signed-in user journey. Unexported counts can be
lost on process restart.
The packaged `otel-marshall` NixOS check passed a real Marshall HTTPS response
through the private snapshot, static Rust exporter and central collector, with
source-directory and collector-socket refusals. It does not prove a signed-in
browser journey or restart accounting.
Initial live collection after `d05416f6` reached both enrolled hosts showed
application-origin counters and both collector scrape targets up. A third
HAProxy-origin `up` sample exposed an overbroad collection-health rule; the
corrected rule selects only raw collector scrapes. This production observation
does not establish a 28-day baseline, a target or signed-in browser rendering.
The active corrected rule expression returned the two raw collector targets on
Overalls after both hosts deployed `6dd6573e`. A previously recorded HAProxy
series remained visible during the Prometheus lookback interval, so the
Marshall and Grafana read queries also select only unlabeled collector series.
The live unqualified recording query returned exactly the two enrolled host
series after the old sample aged out on 2026-09-29.
The updated two-node `otel-fleet` NixOS check also passed the filtered
recording and provisioned Grafana query assertions; the Marshall parser's
third-series rejection passed as a generated property. The extended
`otel-marshall` NixOS check passed anonymous refusal, ordinary-reader admission,
known-down collector and absent-ingress display, and current-login revocation
against packaged Marshall and local Prometheus. Production browser access and
the 28-day baseline remain open.

The [Rust exporter](../../../nix/modules/otel-guest/receiver/src/slo.rs) now
publishes a fixed source-start-time gauge beside every trusted application
snapshot. [Nix recording rules](../../../nix/modules/otel-fleet/rules.nix)
withhold each five-minute candidate ratio until every request series has a
matching host/replica start marker that is fresh and at least five minutes old.
[Prometheus rule fixtures](../../../nix/tests/evaluation/otel-slo-rules.nix)
exercise a counter reset with a changed start time; the
[host collector test](../../../nix/tests/machines/otel-fleet/default.nix)
checks the gauge reaches the collector. This protects the reset window but
does not recover outcomes lost before a crash or make source accounting durable.
The [Grafana candidate panels](../../../nix/modules/otel-fleet/default.nix)
also apply the shared [source-readiness expression](../../../nix/modules/otel-fleet/source-ready.nix)
and a nonzero current five-minute request rate through their
[query guard](../../../nix/modules/otel-fleet/candidate-query.nix). Live deployment showed that Prometheus could retain an older
recording for its instant-vector lookback after restart, even while the new
recording rule emitted no value. Query-time gating prevents that retained
sample from appearing as a valid current candidate ratio. The dashboard guard
has a Prometheus fixture and a provisioned-dashboard NixOS assertion. After
revision `46435eac` reached healthy on Overalls, its live authenticated
Grafana API returned all 20 panels and Prometheus reported all nine candidate
duration rules healthy. Those checks establish provisioning, not a measured
latency value or production proof of the query-time guard under a source outage.

The same Nix configuration now provisions a guarded five-minute p95 observed
duration candidate for each of the nine instrumented application paths. A
candidate is absent unless its success-ratio recording exists, all source
markers are ready, the duration count covers every admitted request in
the window, and none exceeds the last finite 10-second bucket. The [shared roster](../../../nix/modules/otel-fleet/candidate-sources.nix)
also creates one Grafana latency panel per path. These p95 values are baseline
observations, not latency objectives: the named paths have different completion
boundaries, and no measured target or burn alert has been approved.

Underclass now has a separate host-owned local monitor readiness candidate.
The [Rust probe](../../../nix/modules/otel-guest/receiver/src/underclass_probe.rs)
reads the pinned service's read-only Unix monitor endpoint without proxy or
administrator credentials and exports only a fixed 0/1 gauge through an
Underclass-only collector socket. The Nix rule requires exactly one fresh,
complete five-minute probe series from each enrolled host. A failed monitor
check is zero; lost probe or collector data is unknown. This is not an
authorized proxy-completion or live-provider SLI: upstream's monitor counters
represent provider attempts, and its recent request list is bounded.

## Open questions

Measured production volume and final SLO targets require the baseline. The
chosen single-host storage topology cannot independently page during an
Overalls outage.

## Related decisions

[ADR-0042](0042-host-observability.md), [ADR-0063](0063-private-services-and-ziggy.md),
[ADR-0064](0064-customer-workspace-isolation.md), [ADR-0111](0111-private-service-tls-names.md),
[ADR-0127](0127-fleet-log-store-viewer.md).
