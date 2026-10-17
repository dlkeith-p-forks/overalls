# Fleet OpenTelemetry baseline review

Date: 2026-09-28. Decision: [ADR-0129](../decisions/0129-fleet-otel-slos.md).
Scope: Audi guest ingress, restricted Rust receiver, fleet collector, central
Prometheus/Tempo/Grafana placement and initial collection-health baseline.

## Boundaries and findings

- **Guest provenance:** Audi's private TLS frontend uses Lilly's current
  pre-NAT binding and streams to a host-local Unix socket. The receiver checks
  the Audi UID, validates the binding, removes arbitrary resource, datapoint,
  span-event and link data, and admits eight reviewed `kittens.guest.*` names
  under per-VM and host-wide minute budgets. Host metrics
  follow a separate collector pipeline with host provenance. Ordinary guest
  claims cannot enter the current host collection-health rule. A host-local
  process with loopback access can send directly to the collector; no SLO rule
  treats its OTLP claims as trusted application outcomes.
- **Storage and failure:** Both hosts collect independently; Overalls owns the
  only Prometheus, Tempo and Grafana. Prometheus pulls over the authenticated
  WireGuard transport and marks missed scrapes absent. Tempo receives traces
  over that tunnel from a bounded collector disk queue. The trace and metrics
  query paths disappear with Overalls. The 10 GB Prometheus cap and 35-day
  maximum retain a potential 28-day baseline only if actual volume stays below
  the cap. Tempo's seven-day, 20 GiB ZFS trace limit is diagnostic, not SLO arithmetic.
- **Ingress SLI:** HAProxy's local exporter provides unsampled frontend request
  and response-class counters through the collector. A draft recording rule
  counts 2xx/3xx/4xx completions over all ingress requests. A missing request
  denominator yields no ratio. The rule excludes the local metrics frontend.
  It does not measure route-specific latency or whether an authorized workflow
  completed after the proxy response.
- **User authority:** Grafana binds loopback and requires a generated persistent
  local password and encryption key. The signed-in Marshall `/slos` page queries
  only two fixed local recording rules, validates the expected result shapes,
  and reports missing data as unknown. It is a collection-health baseline and
  must not be presented as a completed user-journey SLO.

## Verification actually run

- `cargo test --manifest-path nix/domains/system/otel-guest/receiver/Cargo.toml`:
  twelve passing tests, including generated binding, metric, rate, trace and chunk
  boundary properties.
- `cargo clippy --manifest-path nix/domains/system/otel-guest/receiver/Cargo.toml
  --all-targets -- -D warnings`: passed.
- Both enrolled NixOS `system.build.toplevel` derivations built with collector
  configuration validation enabled.
- `nix build .#checks.x86_64-linux.otel-fleet`: passed after correcting the
  test fixture's fleet-address startup order. The NixOS VM started collector,
  Prometheus, Tempo, Grafana and receiver, scraped a real host metric, accepted
  one guest protobuf metric, and refused a non-Audi Unix peer and a forged
  outer metric name. A subsequent passing run observed exported
  `kittens_guest_requests` and HAProxy response series and authenticated to
  Grafana with its generated local operator password.
- A later two-node NixOS run passed: the worker collector exported host metrics
  on its test network address and central Prometheus scraped the worker as up.
  Stopping the worker collector made its central scrape report `up=0`, and
  restarting it restored `up=1`.
  This fixture uses a shared test network, not the production WireGuard keys.
- `nix build .#checks.x86_64-linux.otel-slo-rules`: passed a Prometheus rule
  test with mixed 2xx/4xx/5xx outcomes and an empty no-traffic result.
- Marshall's focused SLO parser and LiveView suite passed six checks (two properties, four tests),
  including missing/forged samples, signed-in access,
  anonymous refusal and revoked-session refresh.

The fixture supplies an Audi UID and fixed binding rather than a running Audi,
Lilly or Firecracker guest. Its original run did not test a two-host WireGuard
outage, trace backfill, production data or an actual guest SDK. A later scoped
queue-replay extension is recorded below.

The extended `otel-fleet` NixOS check passed on 2026-09-29 after admitting
Tempo's port 4317 in the disposable central fixture, as the evaluated
production Overalls fleet network already does. The worker collector accepted
one current, identity-free Rust-generated OTLP trace while central Tempo was
stopped. After a twelve-second batch flush, the worker collector restarted
while Tempo remained down. Once Tempo returned, its trace query initially
returned 404 and then returned HTTP 200 with `otel.replay.fixture` and the
fixed trace ID. This proves persisted worker queue replay across its process
restart and a central Tempo outage within the configured retry window. The
first attempt without the fixture firewall allowance failed because worker
traffic could not reach Tempo; it was not passing replay evidence. The test
uses a direct local worker OTLP input and test network addresses, so guest TLS,
Audi/Lilly binding, physical WireGuard outage, long-duration queue capacity
and production trace retention remain unverified.

The dedicated `otel-guest-native` variant now composes the existing agent
NixOS fleet journey with a local collector and Rust receiver on each Lilly host.
Its assertion waits for a real acknowledged Lyra tool result, then queries the
selected host's Prometheus exporter for a nonzero guest tool counter.
`nix build .#checks.x86_64-linux.otel-guest-native --no-link` passed on
2026-09-28. The run covered Firecracker guest TLS, Audi routing, Lilly's
current binding, the Rust receiver and collector export. The first attempt
exposed a missing `end` in the shared fleet operator fixture. A later attempt
reached the guest but timed out in the unrelated agent reset and recovery
check; the telemetry variant now uses the already verified updated binary.
The next run reached the exporter with no sample and exposed Lyra's separate
Rustls client, which lacked the fleet trust path. The passing run used the
existing verified private TLS client for `otel.integration.internal`.
The test does not cover a binding change during upload, Customer refusal,
trace delivery or physical WireGuard transport.
After the TLS correction, the full local Lyra Rust suite, Clippy with warnings
denied, `nix build .#checks.x86_64-linux.lyra --no-link`, and the Nix HLDD
check passed. The NixOS test driver also passed its composed lint and type
checks before booting the fleet.
Marshall's broad `mix precommit` was attempted again for the handbook change.
Its structural gates passed, but
`Marshall.Agents.AgentRevocationHistoryTest` failed on a generated `[:same]`
case with an existing `agent_cli_sessions_code_hash_index` value. The run was
interrupted after this unrelated failure; it is not a passing Marshall gate.

## Lyra guest instrumentation addendum

The Rust Lyra executor now emits only cumulative tool call and error counters
and a duration histogram after the terminal transition RPC is acknowledged.
Its fixed protobuf names and absence of tool attributes preserve the receiver's
guest namespace and privacy boundary. The verified HTTPS upload is best effort
with a two-second deadline; collection loss cannot turn a tool failure into
success or interrupt the terminal result. `cargo test --locked --offline` passed
the full Lyra suite, and a focused rerun of
`generated_tool_outcomes_keep_bounded_cumulative_points` passed after its
expanded generated sequence assertions. `cargo clippy --all-targets --locked
--offline -- -D warnings` passed after the expanded property. The Nix Lyra
test gate reached and passed that property, but its pre-existing
`failed_check_after_rollback_keeps_the_rejection_cooldown` test failed once
while the cross-platform package build ran concurrently. An isolated rerun then reached an existing generated workspace
URL test and found its assertion rejected `0..` inside an otherwise valid
repository name. The parser and shared Elixir grammar allow that inert name;
the property now rejects only a standalone `..` component, while retaining
the stricter branch-ref check. The focused workspace property and the full
`nix build .#checks.x86_64-linux.lyra` gate passed after that test correction.
`nix build .#packages.x86_64-linux.lyra` passed the four-platform production
package build with the updated Cargo vendor hash.
The repository-wide code-contract checker passed after separating three
pre-existing adjacent contract comments in Marshall and the relocation test;
those are comment-only changes. ADR, generated coverage, views, options,
review-receipt and Nix HLDD checks passed. Marshall `mix precommit` passed its
structural gates, then encountered an unrelated `Porsche.Listener` setup
failure in the broad SSH transport tests. A focused run reproduced seven
`ssh_listener_unavailable` setup failures before the test bodies. The broad
run was interrupted after that confirmed failure; it is not a passing gate.
This source-level check does not prove
the real guest TLS path or live collector acceptance; those remain open below.

## Open implementation findings

The reviewed outcome boundaries below define the candidate journeys. Later
sections record which sources now have unsampled counters and latency
histograms; several outer workflow boundaries remain open. Each numerator must
come from the trusted component that owns the final result, with fixed
operation labels and no account or VM identity:

| Component | Source boundary reviewed | Candidate service level journey |
| --- | --- | --- |
| Marshall | `MarshallWeb.Endpoint` and provisioner API | Signed-in HTTP completion, VM creation to durable ready or terminal failure |
| Lilly | `Lilly.Lifecycle` and control runtime | Fenced VM start/stop completion and guest readiness latency |
| Audi | `Audi.Private.Front` and SSH proof | Bound private request and guest SSH session establishment |
| Porsche | `Porsche.Observability` | Management SSH command completion after proof |
| Ziggy | `Ziggy.HTTP` and spool | Admitted inference request to terminal result, excluding caller cancellations |
| Galileo | `Galileo.HTTP` | Authorized integration attempt to complete upstream response |
| Enrico | `Enrico.HTTP` and mirror updater | Registered mirror refresh to readable revision |
| Brady | `Brady.Metrics` | Private cache request to completed result |
| Underclass | Pinned external package monitor socket | Local provider readiness and authorized proxy completion |
| Lyra | `kittens agent` and guest executor | Guest tool outcome as segregated diagnostics only |

The nine deployed candidate paths cover Marshall HTTP, two Audi boundaries,
and Brady, Galileo, Enrico, Porsche dispatch and Ziggy. They do not yet cover
Marshall VM creation to ready, Lilly's fenced physical lifecycle, Underclass
provider readiness, or Porsche's later physical command completion. Lyra is
guest diagnostics and cannot enter outer SLO arithmetic.

The existing minute summaries are interval values and cannot provide durable
Prometheus denominators after missed exports. The production work must use
source-owned cumulative counters with restart semantics, plus histograms for
latency. No guest or external monitor claim can attest an outer service result.

1. **High:** The public ingress completion counter is narrower than a full
   user-journey SLO. Brady, Galileo, Enrico, Porsche and Ziggy now have candidate source-owned outcomes,
   but the remaining user-facing and internal application journeys lack trusted
   outcome counters and latency histograms. Lyra's guest histogram is diagnostic
   and does not fill that gap. Target SLOs and burn rates would be misleading
   until those instruments are added and validated.
2. **Medium:** Native browser admission and revocation now pass against packaged
   Marshall and local Prometheus. A production signed-in browser read remains
   unverified.
3. **Medium:** Guest TLS, live Lilly rebinding during upload, cross-host
   delivery and outage replay need native NixOS coverage.
4. **Medium:** Prometheus retention's size cap can expire data before 28 days;
   actual ingestion volume and target budgets need a measured baseline.
5. **High:** Brady now has resolved terminal request counters and a duration
   histogram, exported by a Rust host process from a private snapshot. Generated
   arithmetic and snapshot properties pass. The separate application OTLP
   listener now uses a group-restricted Unix socket. The NixOS fixture uses a
   synthetic Brady snapshot. A scoped native Firecracker run observed real
   attributed requests exported to the collector; its later restart subtest
   timed out, so the full machine gate remains open. A Nix recording rule and Grafana panel show an explicitly labeled
   candidate ratio with no target or burn alert; no SLO compliance rule uses it.
6. **High:** Brady's original application pipeline fixes `service.name=brady`.
   [The fleet module](../../../nix/domains/system/otel-fleet/default.nix) now gives
   Galileo its own Unix intake, peer group and collector-owned identity, so its
   datapoints cannot be mislabeled as Brady's. Every further application must
   gain an equivalently isolated intake or a comparably isolated Rust broker;
   reusing either service group would permit cross-service submissions.

Galileo now counts each Marshall-authorized attempt after admission in a
serialized source-owned cumulative snapshot. It classifies a complete upstream
response below 500 as success and records every terminal attempt in one fixed
duration bucket; failures and exceptions remain in the denominator. Its private
Unix `/slo` read refuses an integration host. `galileo/test/slo_test.exs` passed
one generated property, and `galileo/test/http_test.exs` passed its exception
accounting check (two focused checks total). The Rust exporter now validates
both Brady file and Galileo Unix HTTP snapshot shapes. Galileo has a separate
group-restricted collector socket whose processor assigns `service.name=galileo`.
Nix provisions a Galileo candidate recording rule and Grafana panel without a
target or burn alert. `nix build .#checks.x86_64-linux.galileo-service --no-link`
passed on 2026-09-28: the packaged Galileo/Audi journey observed an authorized
upstream request in `/slo` and refused an integration-host `/slo` read. The
`Rust exporter delivers Galileo-owned outcomes to the isolated collector`
subtest then observed a nonzero application-origin Galileo series in Prometheus
and denied the ordinary Galileo UID direct collector socket access. This uses
fixture binding and control replies; the scoped Firecracker result below adds
native admission, while revocation classification and measured targets remain
unverified, so this is still a candidate SLI.

The `otel-galileo-native` Firecracker run on 2026-09-28 passed the full NixOS
machine gate, including the scoped
`real Galileo guest outcome reaches isolated Rust OTLP collector intake`
subtest. It observed a real authorized guest outcome in Galileo's snapshot,
a nonzero Galileo application series after Rust export, ordinary Galileo UID
collector socket refusal, and no denominator increase for a detached guest
request. The fixture reloaded its rotated SOPS credential bundle and restarted
Galileo before readiness. The later upload, execution stop, cross-host peer,
relocation and control-outage scenarios also passed in the same full run.
This proves the tested guest-to-collector path and fixture recovery, not
production collection, live revocation classification or a measured target
baseline.

Enrico's manager now records one success or failure and one fixed duration
bucket when a unique admitted refresh reaches a terminal result. Replaying an
attempt does not count again, and an invalid or busy request never enters the
denominator. Its Unix health socket exposes only the fixed numeric snapshot to
a Rust exporter. An Enrico-only collector socket and processor assign
`service.name=enrico`; Grafana shows a candidate five-minute ratio only with a
nonzero request rate. `enrico/test/slo_test.exs` passed a generated outcome
property, and Enrico's `mix precommit` passed three tests and Dialyzer on
2026-09-28. `nix build .#checks.x86_64-linux.enrico-service --no-link` passed:
the packaged service refreshed and browsed a mirror, exported a nonzero
application-origin Enrico series, refused direct collector access from the
ordinary Enrico UID, kept duplicate attempts out of the denominator, and
counted a failed refresh during a source outage. The fixture uses local Git
and a single NixOS machine; cross-host Marshall scheduling, manager-crash
accounting, live collection and a measured target remain open.

The focused Brady source suites passed eight checks (one generated property,
seven tests), including a validated HTTP exchange followed by a duplicate-Host
refusal that left the SLO denominator unchanged. The full Brady precommit first
ran against an intermediate source revision and reached Dialyzer, which found an
unreachable match that was subsequently removed; that run is not a passing gate.
The Rust exporter generated property and Clippy with warnings denied passed.
`nix build .#checks.x86_64-linux.otel-fleet --no-link` then passed on
2026-09-28 after staging the new Rust binary so Nix included it. That two-node
machine run started the packaged Rust exporter as the Brady UID, read a private
synthetic snapshot and observed `kittens_outer_brady_requests_total` at the
collector's Prometheus endpoint. It did not run Brady, Lilly's attribution path
or a Firecracker request for this new candidate series.
After moving application intake to a group-owned Unix socket, the same NixOS
check passed again. It denied an ordinary Brady UID socket connection, allowed
only the exporter service's supplementary group, and observed the candidate
request counter with collector-assigned `application` origin and `brady` service
labels. The Nix recording-rule test passed a mixed candidate ratio and the
empty no-traffic result. Brady's full `mix precommit` passed 62 checks
(14 properties) and Dialyzer after the admission marker correction.
The collector's application socket group also reaches its process, so the
collector state directory is forced to mode 0700. A further
`nix build .#checks.x86_64-linux.otel-fleet --no-link` passed with the packaged
Rust binary's custody test, exact exported service/origin labels, ordinary
Brady UID socket refusal, and exporter-group trace-queue refusal. The fixture
still uses a synthetic Brady snapshot.
The next NixOS run passed after the application socket's 4096-byte intake limit
was exercised with a small valid OTLP protobuf accepted and a larger valid
unknown-field protobuf refused. An initial assertion requiring exactly HTTP
413 failed because the collector used a different rejection status; the
revised check accepts HTTP 400 or 413 and still rejects a transport failure.
Marshall's broad `mix precommit` was run for this handbook increment. Its ADR,
HLDD, code-contract and logging gates passed, but the full suite reported
`Marshall.Accounts.RegistrationTest` failures: an organizational mailbox user was present
where those tests expected an empty user table. This is not a passing Marshall
gate; the run was interrupted after that failure. The focused telemetry tests
cited above retain their narrower scope.

Two `brady-fleet` native runs observed a real guest's two attributed HTTP
requests and a private Brady SLO snapshot with cumulative successes and closed
histogram buckets. The second run additionally passed the Rust exporter and
collector assertion for `kittens_outer_brady_requests_total` with collector-owned
`application` origin and `brady` service labels. Both complete runs failed later
in the existing Brady/Lilly restart-attribution subtest with `Fleet condition
timed out; private diagnostics withheld`. This is scoped request-to-collector
evidence, not a passing full Brady fleet gate. Execution records are
`1790621784438-2545003-0.jsonl` and `1790622477803-2831483-0.jsonl` under
`/home/ghuntley/.local/state/nix/build-logs/`.

Porsche's command runner already emits terminal SSH telemetry, but its prior
interval summary could not survive a missed export as an SLO denominator.
The new source-owned accumulator records fixed cumulative outcomes and duration
buckets for terminal command dispatches. Exit statuses 2 and 3 are excluded as
invalid or forbidden results; other terminal results and crashes count once.
The private mode-0600 snapshot is read by the Rust exporter through a
Porsche-only collector socket. Nix assigns the service identity and provisions
a candidate dispatch ratio and Grafana panel without targets or burn alerts.
The generated arithmetic property, refusal exclusion and metadata privacy
checks passed. Porsche `mix precommit` passed 86 checks, including 12 properties,
and Dialyzer. Rust `cargo test --locked` and Clippy with warnings denied passed;
the Prometheus candidate rule test passed mixed and absent denominators. The
two-node `otel-fleet` machine check passed with the fourth isolated intake.
`nix build .#checks.x86_64-linux.porsche-service --no-link` passed with the
packaged Porsche release: its private mode-0600 snapshot reached the Rust
exporter and isolated collector as a zero-valued source series, and the
ordinary Porsche UID could not connect directly to that collector socket.
The first machine attempt reached the snapshot but waited for a series because
the shared Rust exporter initially treated Porsche's file as a Unix HTTP
socket. That run was interrupted after the source-selection bug was identified;
the corrected packaged rerun passed. The fixture has no authorized Marshall
command, so it does not prove a nonzero command-to-collector outcome. Accepted
asynchronous dispatch does not establish physical VM completion, and process
crash accounting, an authorized command-to-collector journey, live collection
and the measured target baseline remain open.

Ziggy's spool now records a candidate inference outcome only after a newly
terminal completion is durably persisted. A duplicate completion cannot add a
second outcome; recovered incomplete admissions count as failures with unknown
duration, and cancelled streams stay outside the denominator. The fixed
cumulative snapshot contains no model, provider, owner, VM, request or content
labels. A Rust exporter sends it through a Ziggy-only collector socket with
collector-assigned identity; Nix provisions a candidate ratio and panel without
a target or burn alert. The focused Ziggy suite passed six checks, including
one generated arithmetic property and recovery/idempotence checks. Rust tests,
Clippy with warnings denied and the Prometheus rule test passed. The two-node
`otel-fleet` check passed with the dedicated Ziggy intake. The first
Ziggy `mix precommit` stopped at a pre-existing unformatted test line in
`test/update_artifact_test.exs`; its formatting was corrected before rerunning.
The complete Ziggy `mix precommit` then passed 45 checks, including four
properties, logging, code contracts and forced Dialyzer with zero errors.
`nix build .#checks.x86_64-linux.ziggy-service --no-link` passed with two
local provider completions in the private numeric snapshot, Rust OTLP export
into the Ziggy-only collector socket, and a refused direct ordinary-UID socket
connection. The first NixOS attempt was interrupted because the fixture used
`jq` without including it in the VM; the corrected fixture passed. The fixture
uses synthetic control authority and does not prove a native guest admission.
HLDD coverage, view, option, review-receipt and Nix gates passed; the
`hldd-browser` NixOS check passed the updated section rendering.
Marshall `mix precommit` passed its ADR, HLDD, contract and logging checks,
then its distributed suite reported at least five failures in registration
and agent approval history tests unrelated to the Ziggy change. The run was
interrupted after those failures; it is not a passing full gate. Its formatter
also removed an existing excess blank line in `executor_session.ex`.
Post-acknowledgment counter recovery, live collection and the measured target
remain open.

Audi private now counts completed non-OTLP transport requests only after its
current Lilly binding and TLS checks. It excludes pre-binding refusals and
guest telemetry uploads; a completed response below 500 is success, while 5xx
or stream loss is failure. The source publishes a mode-0600 fixed cumulative
snapshot with duration buckets and no request or VM labels. A Rust exporter
checks its schema and custody, then uses an Audi-private-only collector socket
with Nix-assigned identity. The Audi property and publication tests passed
three focused checks; the existing OTLP route properties also passed two.
Rust tests and Clippy passed, as did the Prometheus candidate rule test after
replacing an exact 0.8 float expectation with 0.5. The two-node `otel-fleet`
NixOS check passed synthetic Audi source-schema export and ordinary Audi UID
socket refusal. The `otel-galileo-native` Firecracker run reached and passed
`real Galileo guest outcome reaches isolated Rust OTLP collector intake`:
it observed an Audi-owned success after current guest binding, the exported
`kittens_outer_audi_private_requests_total` series with application provenance,
and refusal of an ordinary Audi UID at the collector socket. The complete
`nix build .#checks.x86_64-linux.otel-galileo-native --no-link` gate passed on
2026-09-28, including its later upload, execution stop, cross-host peer,
relocation and control-outage scenarios. Audi's complete `mix precommit` passed
154 checks, including 34 properties, with forced Dialyzer reporting zero errors.
Both enrolled NixOS host toplevels built with the Audi-only exporter placement.
The Nix `hldd` and `hldd-browser` gates passed after the handbook and scenario
evidence update; the browser gate checked rendered section navigation. Audi
process crashes can lose unexported counts; public gateway and DNS outcomes,
live production collection and measured targets remain open.

The change remains partial against ADR-0129. It must not be merged or deployed
as a completed fleet SLO rollout before the findings are resolved.

## Audi public DNS candidate addendum

The separate public Audi DNS release now classifies ordinary, well-formed
questions for its delegated zone before a candidate observation is admitted.
NOERROR and NXDOMAIN with an authoritative response are successful completions;
stale-publication SERVFAIL and socket send failure are failures. Malformed,
out-of-zone, transfer and truncated UDP requests are excluded. The source
records one outcome after its UDP or TCP send attempt and publishes fixed
cumulative counts and latency buckets in an owner-only snapshot. A Rust
exporter validates and sends that snapshot to a DNS-only collector socket;
Nix assigns `service.name=audi_dns`. The candidate Grafana ratio has no target
or burn alert, and no query name or guest identity becomes a metric label.
The public DNS path increments atomic in-memory counters without a GenServer
mailbox or per-request file write; a five-second timer publishes the snapshot.
A concurrent 1,000-outcome test passed closed counts and bucket totals after
publication.
The packaged `audi-dns` NixOS gate passed again after periodic publication
replaced per-request writes; its real UDP/TCP source assertions now exercise
the final counting path.

Focused Audi DNS and snapshot tests passed 17 checks, including four generated
properties. The Rust receiver/exporter suite passed twelve library and three
binary tests; Clippy passed with warnings denied. The Prometheus rule test
passed its ratio and absent-denominator cases. The two-node `otel-fleet` NixOS
check passed synthetic DNS snapshot export, collector-assigned identity and
ordinary Audi DNS UID socket refusal. `nix build .#checks.x86_64-linux.audi-dns
--no-link` passed a packaged source journey: real UDP and TCP SERVFAIL replies
entered the failure count, out-of-zone REFUSED replies stayed out, later
authoritative answers entered success, and the mode-0600 snapshot remained
owned by Audi DNS. The first machine run stopped in an older fixture's
`p3000.<name>` alias query; the accepted flat-label grammar is
`p3000-<name>`, and the corrected rerun passed.
After correcting an Elixir typespec that cannot express literal string values,
Audi's complete `mix precommit` passed 158 checks, including 36 properties,
and forced Dialyzer reported zero errors. An initial complete gate run with the
new 1,000-task counter test running asynchronously had three failures in older
short-TTL HTTP authority/proxy properties during concurrent Nix builds. Moving
that counter test to `async: false` and rerunning the complete gate passed. The
rejected typespec run and the first enrolled-host build both stopped at that
compiler error. Both enrolled host toplevels then built successfully after the
counter publication change. The Nix `hldd` and `hldd-browser` checks passed;
the browser check rendered the updated periodic-publication chapter text.

This measures the source's authoritative response and local socket send, not
recursive resolution or client use of the returned address. A process crash
can lose unexported counts. Production collection, restart accounting and a
measured target remain open; the SSH/public gateway and the other unfinished
application journeys still need trusted indicators.
The candidate Prometheus ratio aggregates the observed DNS hosts. A missing
host can disappear from that aggregate, so this rule is unsuitable for
compliance until it requires both enrolled DNS sources and distinguishes a
silent source from a zero-traffic source.

The follow-up Nix recording rule now requires one recent, collector-assigned
request-counter series from each enrolled DNS host (`overalls` and
`dungarees`). Samples older than 45 seconds suppress the ratio. A Prometheus
rule test passed the two-source 50% ratio, missing-replica case and a
one-minute-old source case. This
closes the identified silent-host arithmetic gap for the current roster, but
the rule remains a candidate: production source freshness and failover are
unobserved, source crashes can lose counts, and no measured target exists.
The two-node `otel-fleet` NixOS test passed again with an assertion that the
Audi DNS metric carries the collector-assigned `host_name=central` label.
This establishes the label path in that fixture, not the live enrolled hosts.

## Marshall browser HTTP candidate addendum

Marshall's existing minute diagnostic summaries reset their counters and are
unsuitable for an SLO denominator. A separate source process now consumes the
browser endpoint's terminal telemetry event after its privacy, health and
early machine-API filters. HTTP 2xx-4xx is a completed transport response;
5xx, an exception or a missing final status is a failure. The source updates
fixed cumulative counts and latency buckets atomically in memory, publishing
a mode-0640 snapshot in a dedicated source-group directory every five seconds.
Paths, account identity, tokens and VM identifiers do not enter the snapshot
or OTLP resource. A static Rust exporter reads the file through the source
group and connects through a Marshall-only collector socket. Nix passes the
bounded `overalls` replica identity, and the collector overwrites service and
host provenance. This is a
candidate browser HTTP transport indicator with no target or burn alert.

Marshall's focused SLO suite passed three checks, including one generated
property and a real in-process endpoint call that excluded `/health/live` and
counted an ordinary completed 404. The Rust receiver/exporter suite passed
fourteen library and three binary tests; Clippy passed with warnings denied.
Prometheus rule tests passed a nonzero 70% ratio and absent-denominator case.
The two-node collector fixture initially passed a synthetic Marshall export
and ordinary UID socket refusal under a static fixture account. A follow-up
with two units sharing the Marshall dynamic username failed: systemd exposed
the first unit's private runtime file as UID 65534 outside its id-mapped
namespace, while the active dynamic UID was 64878. The design now uses a
dedicated source-group directory and a separate static exporter. The
two-node collector test passed the revised group-custody path: the dynamic
source wrote a group-owned mode-0640 file, its ordinary UID could not connect
to the collector, and the static Rust exporter emitted the fixed-instance
Marshall series. The final two-node rerun passed with the exporter filesystem
mounted read-only. The enrolled Overalls NixOS toplevel built with the revised
runtime directory, group assignments and Rust package. These source and
synthetic tests do not establish packaged Marshall request delivery through
the collector, browser TLS, guest creation, asynchronous operation
completion or live production collection. Process crash can lose unexported
counts. The candidate ratio checks the single enrolled replica for a sample
newer than 45 seconds, but production freshness and the measured baseline
remain unverified.

A final custody review found that the first root-owned source directory granted
group write, so the static exporter account could replace a snapshot outside
its systemd sandbox. Marshall now owns a mode-0750 runtime directory through its
dynamic UID; the static exporter group can read the mode-0640 file but cannot
write the directory. The separate release-temp directory is tightened to
mode 0700 by the Marshall launch wrapper. The Rust exporter also rejects an
incorrect parent directory mode or group. The hardened Rust suite passed
fourteen library and three binary tests, and Clippy passed with warnings denied.
The first two-node machine attempts exposed systemd resetting an
`ExecStartPre` directory chmod to mode 0700; setting `RuntimeDirectoryMode`
directly corrected the observed mode. The final two-node NixOS check passed:
it observed source directory mode 0750 under the dynamic UID, refused exporter
directory write, refused ordinary source access to the collector socket, and
exported the fixed-instance Marshall counter through the collector. This is
synthetic source evidence, not a packaged browser request or live production
collection.

The packaged NixOS browser check passed after staging the new Marshall module;
the first run had evaluated the unstaged tree and omitted that module from the
release. Marshall's focused browser SLO suite passed three checks, including
one property. Separate legacy revocation and magic-link tests assumed an empty
shared test database and produced non-SLO failures during broad precommit runs.
Their assertions now check the intended VM or email scope; the corrected
revocation focused suite passed nineteen checks, including three properties,
and the magic-link focused suite passed seven tests. A broad Marshall
`mix precommit` run passed its structural checks but reported one
`Marshall.Access.CustomerIsolationTest` terminal-fixture
`machine_identity_mismatch` while unrelated worktrees were using the shared
test database. The run was interrupted after later database connections began
rolling back; it is not a passing broad gate. The failing case passed in an
isolated rerun (`mix test test/marshall/access/customer_isolation_test.exs:83
--warnings-as-errors`, one passed). A clean broad gate remains to be recorded.

The new `otel-marshall` NixOS check passed on 2026-09-29. It booted a packaged
Marshall release and central collector with disposable WireGuard peers, sent a
real HTTPS request that completed as 404, and observed Marshall's private
cumulative request counter increase. The static Rust exporter delivered the
`kittens_outer_marshall_web_requests_total` series with collector-assigned
application provenance and the fixed `overalls` instance identity. The same
run verified source-directory mode 0750, snapshot mode 0640, exporter refusal
to write the source directory, and ordinary Marshall UID refusal at the
collector socket. The fixture disabled guest intake because this check
targets Marshall's trusted application pipeline. It does not establish a
signed-in browser journey, restart loss accounting, VM creation completion,
production collection or a measured target.

The extended `otel-marshall` NixOS check passed on 2026-09-29 with the actual
packaged LiveView and local Prometheus. Its disposable WireGuard fixture left
the worker collector down: the recorded collector ratio displayed `0.00%`,
while absent ingress data displayed `Unknown`. A Chromium reader was refused
before sign-in, admitted with a private magic-link token as an ordinary user,
and refused on reload and in a second browser context after that exact stored
login was revoked. The browser helper passed ty against its packaged Playwright
interpreter. This establishes native browser admission, unknown-data display
and revocation with test credentials; it does not establish production browser
access, a full 28-day baseline, or source restart accounting.

The Nix HLDD and packaged `hldd-browser` checks passed after the handbook and
scenario evidence update; the browser check rendered the changed sections.

## Audi guest SSH establishment candidate addendum

The public Audi SSH channel now admits a candidate outcome only after a
Marshall grant passes the existing exact host, placement and selector checks.
A failed local guard or Lilly connector after that valid grant counts as
failure; a guest socket followed by an acknowledged SSH exec counts as success.
Invalid selectors, unproved keys, denied or malformed grants and diagnostic
guidance stay outside the denominator. The `audi.ssh_open` diagnostic event
now follows the same acknowledged boundary. Cumulative counters and fixed
duration buckets have no key, account, VM, command or session label. The
Audi-owned, source-group-readable snapshot feeds a separate static Rust
exporter and Audi-SSH-only collector socket. The Nix candidate rule requires
fresh request counters from both enrolled Audi hosts and nonzero traffic; it
has no target or burn alert.

Audi SSH snapshot property passed in the focused `audi/test/slo_test.exs`
run: five checks, including three generated properties. Rust receiver and
exporter tests passed fourteen library and three binary tests, and Clippy
passed with warnings denied. The Prometheus rule test passed the two-host
ratio, missing-source and stale-source cases. The two-node collector fixture
passed synthetic Audi SSH snapshot export, collector-assigned application
identity, exporter directory-write refusal and ordinary Audi UID socket
refusal. A subsequent focused `Audi.SSH.TransportTest` run passed all 17 tests,
including the local real-SSH source-boundary assertion for a denied grant,
valid-grant connector failure and acknowledged guest stream. The fixture's
explicit raw-key callback now advertises Ed25519 without a certificate; the
production callback retains certificate-first negotiation. This local listener
test does not prove that a native guest outcome reaches the collector. A full
Audi precommit run passed 160 tests (37 properties) after the listener change,
but found an unreachable failure branch around OTP's `:ssh_connection.reply_request/4`
return type. The channel now turns a raised or exited reply into a failed
establishment outcome; its Dialyzer rerun passed with zero errors. A second
full test run passed 158 of 160 checks: two existing lease-expiry properties
used 80–180 ms leases and failed when the loaded runner started their guard
after expiry; both passed in a focused rerun. Their generated leases and
assertion windows were widened to preserve the expiry property under load.
The final broad `mix precommit` passed: 160 tests (37 properties) and zero
Dialyzer errors. The packaged `audi-service` NixOS check passed on
2026-09-29: it booted the actual Audi release and isolated Rust exporter,
observed the zero-valued application-origin SSH counter in the collector,
verified source directory and snapshot custody, and refused ordinary Audi UID
access to the collector socket. Its first attempt exposed that widening Audi's
shared runtime directory violated the status socket's mode-0700 startup
requirement. The passing configuration keeps `/run/audi` at 0700 and creates a
separate mode-0750 SSH source directory through tmpfiles. The service test has
no authorized Marshall guest, so it does not establish a real SSH outcome.

The `otel-audi-ssh-native` variant now uses disposable WireGuard peers and the
production fleet collector module on its two Lilly hosts. Its first full Audi
scenario run passed the real authorized Firecracker SSH session and then
observed positive request and success counters at the host collector with
collector-assigned Audi application provenance. That full run failed later in
the existing Lilly crash-recovery scenario: fresh SSH admission did not return
within 90 seconds, while Audi control exchanges reported unauthorized and
Marshall's proxy temporarily lost healthy fleet backends. This is an open
recovery finding, not a passing full scenario. The dedicated SLO variant is
bounded before that recovery scenario.
The focused `otel-audi-ssh-native` NixOS check then passed on 2026-09-29.
It completed the authorized guest SSH journey and waited for both
`kittens_outer_audi_ssh_requests_total` and
`kittens_outer_audi_ssh_successes_total` to exceed zero at the host collector
under collector-assigned `audi_ssh` application provenance. The test used the
real Audi source snapshot and isolated static Rust exporter; it supplied no
synthetic outcome. This records source-to-collector delivery for one admitted
native guest session, not crash recovery or a production nonzero sample.
A subsequent exact-source rerun failed before SSH when the inherited live HTTP
revocation fixture service entered `failed`. The focused variant now applies
the same private policy directly, retains the full browser and authorized SSH
setup, and ends immediately after the two collector assertions. The full Audi
scenario retains both the live HTTP refusal and Lilly crash-recovery checks;
neither failure is treated as a passing recovery result.
The narrowed focused variant passed the NixOS check on 2026-09-29. Its final
run again observed positive Audi SSH request and success counters at the host
collector after the authorized Firecracker guest session; the test ended at
that evidence boundary.

This measures Audi gateway-to-guest stream establishment after a valid grant,
not the guest's inner user authentication or command completion. Source-process
crash accounting, the full scenario's Lilly restart recovery finding,
production nonzero collection and a measured target remain open.

## First production collection and collector-health rule correction

After `d05416f6` reached `origin/main` on 2026-09-29, both enrolled hosts
reported that revision healthy through their automatic updater. Overalls ran
Prometheus, Tempo, Grafana and the collector; both collectors and Audi SSH
exporters were active. Dungarees exported rising application-origin Audi
private request and success counters, and both hosts exported fixed
zero-valued Audi SSH counters. Central Prometheus reported both collector
scrape targets as `up=1`. These observations establish initial live collection
for those sources, not 28-day retention, target compliance or a real guest SSH
outcome.
On Overalls, one ordinary public HTTPS request completed as 404. Marshall's
application-origin request and success counters increased from zero to one,
and central Prometheus subsequently returned the value one for the Marshall
request series. This is a single live transport completion, not a signed-in
browser journey or durable counter recovery. A later source restart returned
the in-process cumulative request value to zero, confirming the documented
restart-loss gap.

The live Prometheus query also exposed a third `up{job="kittens-otel"}` series:
the Overalls collector exported HAProxy's own scrape result with
`kittens.telemetry.origin=host`. The initial collector-health recording rule
included that series, so Marshall's exact two-result `/slos` parser would show
Unknown despite two healthy collectors. The corrected rule selects only raw
Prometheus collector scrapes, and its rule test includes the extra host-origin
series. After `6dd6573e` deployed on both hosts, the active Prometheus rule
expression returned exactly the two raw collector targets. The previously
recorded host-origin series remained queryable during Prometheus's lookback
window, so the unqualified recorded-metric query temporarily still returned
three rows. Marshall and Grafana now select only the unlabeled collector
recordings, including during that transition. At 2026-09-29 02:31:47 UTC,
the unqualified live recording query itself returned exactly two rows:
`10.90.0.1:9464` at 1.0 and `10.90.0.2:9464` at approximately 0.9722,
with no HAProxy-origin row. Both automatic updater timers were active.
Signed-in browser rendering against live Prometheus remains unverified.
The changed Marshall SLO parser suite passed four checks, including three
generated properties; the new property rejects a third retained host-origin
recording. The changed two-node `otel-fleet` NixOS check passed on 2026-09-29:
central Prometheus returned exactly the two enrolled collector instances for
the filtered recording query, and Grafana's provisioned dashboard contained
that same selector. It also repeated the prior collector outage and guest
receiver boundary checks. This fixture uses test network addresses and does
not exercise Marshall's signed-in browser against Prometheus.
`nix build .#checks.x86_64-linux.otel-slo-rules --no-link` passed the
Prometheus rule test with the extra HAProxy-origin `up` series present and
excluded from the expected collector result.

## Production application collection at `04a448fb`

Both Overalls and Dungarees reported `04a448fb` as `lastHealthy.revision`
with zero automatic-updater failures. A read-only central Prometheus query at
2026-09-29 05:16:48 UTC returned exactly two collector availability recordings,
both 1.0. Every deployed candidate application had a source-assigned request
series; only Audi private, Audi DNS and Porsche had nonzero requests at that
instant. The selected application-origin cumulative triples below came from
the host collectors with assigned service and host identity:

| Source | Host | Requests | Successes | Failures |
| --- | --- | ---: | ---: | ---: |
| Audi private | Overalls | 2242 | 2242 | 0 |
| Audi private | Dungarees | 2306 | 2242 | 64 |
| Audi DNS | Overalls | 1 | 1 | 0 |
| Audi DNS | Dungarees | 18 | 18 | 0 |
| Porsche dispatch | Overalls | 45 | 45 | 0 |

Audi private production counters were 2242/2242/0 on Overalls and
2306/2242/64 on Dungarees. Audi DNS production counters were 1 on Overalls
and 18 on Dungarees. Porsche production dispatch counters were 45 requests
and 45 successes on Overalls.

The three corresponding five-minute candidate recording rules returned 1.0
at the subsequent live query. Audi SSH, Brady, Galileo, Enrico, Marshall web
and Ziggy request counters were zero at this point, so their live outcome
paths remain unproved by production traffic. These observations verify current
collection and rule evaluation, but a cumulative sample is not a 28-day
baseline, an end-to-end authorized outcome, crash-safe accounting or a target.
In particular, Porsche dispatch success does not establish physical VM
completion, and Audi DNS success does not establish recursive client use.

## Source restart window guard

Source-owned application counters reset when their source process restarts.
The prior candidate rules could evaluate `rate()` across that reset while
some completions after the last exported snapshot were missing. The Rust host
exporter now forwards the validated snapshot start time as a fixed numeric
gauge. Every five-minute application candidate rule requires a fresh start
marker matching each request series by host and replica, and waits until each
source has run longer than
the full window. A reset therefore removes the candidate ratio for five
minutes rather than offering an incomplete value. The rule keeps the existing
Audi DNS and SSH host-roster freshness checks.

The exporter property covers the marker's fixed name and value; Prometheus
rule fixtures cover a source counter reset, a missing marker, and a marker
from the wrong host, all yielding an absent ratio.
The two-node `otel-fleet` test now asserts that the source marker reaches the
host collector. These checks do not prove durable outcomes: an abrupt crash
can still discard completions since the previous snapshot, and an outage can
hide both source and exporter. ADR-0129 remains accepted and partial, with
targets and burn alerts pending the 28-day baseline and durable accounting.
The changed Rust property suite, Prometheus rule fixture and two-node NixOS
`otel-fleet` check passed on 2026-09-29. The latter observed the Brady source
start gauge through the real collector's Prometheus endpoint; it used a
synthetic source snapshot and disposable test hosts.

After `dec1518a` reached `lastHealthy.revision` on both enrolled hosts, the
Dungarees collector and central Prometheus exposed trusted source-start gauges
from both hosts. Both collector availability recordings remained present. A
read-only central query at 08:15:25 UTC still returned the Audi DNS candidate
ratio `1` from a sample recorded at 08:13:04 UTC, before Prometheus restarted.
Overalls' new DNS source started at 08:13:43 UTC, so the active guarded rule
correctly produced no new ratio, but Prometheus's instant-vector lookback
continued to expose the old recording. This is a real display gap across a
Prometheus restart, separate from the source-counter arithmetic.

The Grafana candidate panels now apply the same source-readiness expression
directly to the recorded ratio. The helper is shared with the recording rules,
so a retained old recording cannot render while a current source marker is
younger than five minutes, missing, stale, or from the wrong host/replica.
The Prometheus fixture includes a retained recording and new source marker;
the two-node NixOS fixture checks the provisioned DNS panel uses the guard.
Both checks passed on 2026-09-29. The NixOS run also admitted the configured
Grafana operator, refused a wrong password and denied worker-node access to
Overalls' loopback listener.
These checks do not restore lost completions or establish the 28-day baseline.

The real guest trace extension stays within ADR-0129's diagnostic boundary.
Lyra now emits one fixed-name span only after a terminal tool transition is
acknowledged. Its trace ID comes from a SHA-256 domain-separated command-ID
hash; the raw ID, arguments, response, user labels, attributes, events and
links are absent. The Rust receiver still replaces resource provenance from
Audi's current Lilly binding and enforces its request, byte and span limits.
The native `otel-guest-native` test now configures disposable local Tempo on
both possible Lilly hosts and queries the exact acknowledged command trace at
the selected host. It neither injects host-side OTLP nor changes production
Tempo placement. Lyra's generated trace property and metric property passed
locally on 2026-09-29; its full local suite, Clippy and the pinned Lyra Nix
check also passed. `nix build .#checks.x86_64-linux.otel-guest-native --no-link`
passed twice on 2026-09-29. The final source run observed the real guest tool
metric at the selected host's collector and returned `lyra.tool_result` from
that host's Tempo for the acknowledged command's hashed trace ID. This proves
guest-to-Tempo delivery through Audi TLS and the current Lilly binding in the
disposable native fleet; it does not prove central Tempo delivery over the
physical WireGuard tunnel. Binding change during upload, customer-profile
refusal, guest trace delivery across the authenticated tunnel, production guest
traces and the 28-day baseline remain open.

## Authenticated collector tunnel and outage replay

The `otel-fleet` NixOS fixture now imports the production fleet WireGuard
module on both disposable nodes. Generated test keys stay in the isolated
fixture; collector and Tempo endpoints bind to tunnel addresses. The test
observes peer handshakes and worker scraping, refuses a direct physical-address
collector request, and marks the worker scrape down when its tunnel is disabled.
One direct local OTLP trace reaches central Tempo after a central Tempo outage
and worker collector restart. A distinct trace is accepted while the worker
tunnel is down, survives a collector restart, and becomes queryable at central
Tempo after the WireGuard service restores its route. The first run failed
because merely raising the disabled link did not restore peer routing; the
corrected test restarts the WireGuard unit and checks tunnel reachability before
querying Tempo. `nix build .#checks.x86_64-linux.otel-fleet --no-link` passed on
2026-09-29; the final machine script finished in 209.92 seconds.

This extends ADR-0129's verification without changing production placement or
trust policy. The traces originate at the host's local collector receiver, so
guest TLS, Audi binding, customer-profile refusal, and real guest-to-central
delivery across WireGuard remain separate gaps. The test does not establish
physical-host outage duration, long queue capacity, or production retention.

## Candidate duration coverage for instrumented applications

The first nine application candidate ratios had fixed cumulative duration
histograms but no latency recording or Grafana panel. Nix now uses one reviewed
candidate roster to provision a five-minute p95 observed-duration recording
and panel beside each application's completion ratio. The recording requires
the existing ratio and fresh, five-minute-old source markers. It also requires
the duration count rate to equal the admitted request rate, and the last
finite 10-second bucket to equal the infinite bucket; otherwise the latency
result is absent. This avoids presenting a sampled fast subset after an
operation ends without a measured duration or exceeds the histogram range.
Application titles preserve
their actual boundary: Porsche is dispatch, Audi SSH is establishment, and
Marshall web is HTTP completion, not a completed user workflow.

`nix build .#checks.x86_64-linux.otel-slo-rules --no-link` passed on
2026-09-29 with a 0.4600000000000001-second Brady p95, absent/no-traffic
output, partial-duration refusal, overrange refusal and query-time refusal of
a retained p95 recording during source warmup. The updated two-node
`otel-fleet` NixOS check passed Grafana provisioning for all 20 panels and
checked first and last latency queries retain their source-readiness guard.
A read-only production Prometheus query before this change observed duration
count series for all nine named application sources; this establishes metric
presence, not nonzero traffic, latency coverage, live panel rendering or a
measured objective. No user-journey end-to-end latency target is claimed.

Revision `46435eaca8531969c008cacf42c9b4799b3f18e7` reached the healthy
phase with zero updater failures on both enrolled hosts on 2026-09-29;
Dungarees then advanced to descendant `0b5f52f2` while Overalls remained
healthy on `46435eac`. A read-only Overalls Prometheus rules API query found
all nine candidate duration recordings with `health=ok`. The authenticated
loopback Grafana API returned 20 panels and source-readiness guards on the
first and last latency panels. An instant query immediately after activation
returned zero candidate duration series; this is unknown data during the
five-minute marker warmup, not a measured fast or slow result. These API checks
do not establish operator browser rendering, steady-state traffic coverage,
an end-to-end latency objective, or production behavior during a real source
outage.

At 2026-09-29 14:28:42 UTC, after the warmup, a read-only instant query
returned three guarded candidate p95 series: Audi private `0.0095` seconds,
Audi DNS `0.0095` seconds, and Marshall web `0.095` seconds. The other six
candidates were absent at that instant. Histogram interpolation produces these
estimates within fixed buckets; one snapshot does not establish request volume,
28-day distribution, latency compliance or a user-journey deadline.

A follow-up read-only query found Marshall web's recorded p95 still visible
while its current five-minute admitted request rate was zero. Prometheus can
retain an old recording within its instant-vector lookback after the source
stops producing a candidate. The shared Grafana query now also requires a
nonzero current request rate for both completion and duration panels. Promtool
fixtures cover retained recordings with an old, fresh source marker and zero
request rate; the provisioned-dashboard NixOS assertion checks the guard on
the first and last latency panels. The Promtool `otel-slo-rules` check and
the two-node `otel-fleet` check passed on 2026-09-29; the latter finished in
208 seconds. This closes the observed stale-panel gap
in configuration, while deployment of the follow-up and live source-outage
behavior remain separate verification steps.

## Underclass local monitor candidate

The pinned Underclass source at `3e35c3b` exposes a read-only `GET /monitor`
over a host-local Unix socket. Its `last_minute.attempts` and 60 minute bins
count upstream attempts from the usage ledger, not admitted proxy requests;
the `recent` list contains at most 20 outcomes. Neither field can supply an
honest authorized proxy-completion denominator. The independent Rust probe
therefore measures only the local monitor boundary. It bounds and validates
the HTTP response and snapshot timestamp, emits a fixed readiness bit every
15 seconds, and sends no account, model, token or request content to OTLP.
The collector assigns `service.name=underclass_monitor` and host provenance
at a separate Unix intake. Underclass failure produces a zero if the probe
can still report; a probe or collector outage remains missing data.

The Nix five-minute rule requires exactly one fresh series for each enrolled
host and at least ten scraped samples per host. Its two-host average retains
observed zero rather than dropping it. The Grafana panel repeats the guard to
hide retained recordings after a source disappears. This candidate cannot
claim tailnet reachability, bearer authorization, an upstream provider result,
or an approved SLO target. The full 28-day baseline and a separate trusted
proxy-completion source remain open.

On 2026-10-02, the Rust receiver suite passed all 19 tests, including the
generated monitor freshness and accounting property. The Promtool SLO fixture
passed. The two-node `otel-fleet` NixOS test passed in 579 seconds with actual
pinned Underclass instances: both enrolled host labels produced a complete
five-minute readiness recording, stopping one monitor reduced the recording,
and restarting it restored the exported gauge. The fixture also checked the
21 provisioned Grafana panels and existing collector and trace recovery paths.
This is disposable VM evidence, not live tailnet or provider-path evidence.
