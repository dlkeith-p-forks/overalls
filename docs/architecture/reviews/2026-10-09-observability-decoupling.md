# Observability decoupling implementation review

Review baseline: `a99f74f06542798dc9ef288e77c99d480433fc57`, isolated worktree
`kittens-observability-decouple`, branch `codex/observability-decouple`.
The user authorized implementation, coordinated breaking documents, all source
observability improvements and normal publication to origin/main.

## Architecture impact

ADR-0149 replaces application diagnostic transport, history and presentation while
carrying forward native state/ownership, Ash transitions, transaction/fencing,
security audit, request authority, accounting and durable SLO settlement.
ADRs 0023, 0037, 0060, 0062, 0063, 0074, 0127, 0132 and 0133 retain historical rationale
and reciprocal supersession. ADRs 0042, 0136, 0138, 0140 and 0142 retain their
unrelated requirements. No diagnostics can release capacity or establish physical
absence. The shared observability application does not belong to the wire library.

## Inspected boundaries

- Ziggy completion loses timing/bytes/provider IDs/status on the wire, while its
  private spool and SLO schema retain them. Replay against an old full completion
  compares accounting fields without rewriting the old receipt or double counting.
  Final guest SSH login still rechecks current authority and records security audit.
- Marshall retires diagnostic resource/read paths, preserves control and security
  views and accounting, and keeps historical identity/credential/FK tables.
  Monitoring credentials are revoked by forward migration; rollback restores none.
  Only unfinished jobs of the retired history/summary workers are cancelled.
  An actual SQL regression preserves other workers and all terminal history,
  including idempotent cancellation timestamps.
- Infrastructure collection exposes bounded numeric values and explicit validity
  over loopback. VM identifiers/incarnations and updater revisions cannot become
  metric labels. ZFS observations retain their original collection age; recursive
  parent datasets do not add into the leaf aggregate.

## Verification recorded during implementation

These executions precede integration of origin/main `1cd8be40` and use the
isolated worktree and pinned runtime. Native tests use
disposable NixOS machines; no production deployment or live notification was
performed. Compiler, syntax and documentation checks retain their structural
scope. The final integration results are recorded separately below.

| Scope | Recorded passing execution and assertion boundary |
| --- | --- |
| Protocol | Full precommit: 250 checks, 97 properties and 153 tests; forced Dialyzer has zero errors. Pure schemas and authenticated transport properties, not deployed version skew. |
| Lilly | Final full precommit: 524 checks, 103 properties and 421 tests; forced Dialyzer has zero errors. Lilly focused lifecycle checks passed 59, including >64 state transitions, exact v1 archive, corrupt primary refusal, independent actor resume and native writer release before slow diagnostic acceptance. The final suite additionally covers archive custody during terminal pruning. Physical guest composition is separately recorded. |
| Marshall | Marshall root targets passed 26 checks, 3 properties and 23 tests: legacy completion ACK/accounting conservation, retired ingestion/body refusal, runtime metrics and Control room. Protocol/readiness targets passed 107, 8 properties and 99 tests. The final full suite remains an integration gate. |
| Fleet exporter | Thirteen collection and three exporter checks pass with ruff/ty. Native exporter verifies actual procfs/cgroup collection, SIGKILL recovery without workload PID change and malformed updater unknown handling. |
| Provisioning benchmark | Twenty-five checks pass with ruff/ty; strict host-local catalogued template timing refuses missing/duplicate/foreign observations. Diagnostics are not control or readiness authority. |
| Durable trace custody | Final native trace custody passed in 34.27 seconds against the final generated schema: canonical hierarchical producer cgroup and exact UID, wrong-unit/UID 403, SIGKILL, reboot, immutable upstream-ACK archive and replay, malformed OTLP 400, corrupt-archive startup refusal and producer work during observer loss. Separately, nine Rust checks cover orphan/mismatched pending indexes and missing-table startup refusal. The 128-span, 21,148-byte batch fixture accepted 192 and refused 64 of 256 requests in 1.869966 seconds; physical SQLite footprint was 4,597,833 bytes. First/last 32 maximum latencies of 11.634/6.104 ms describe this fixture, not deployed throughput. An earlier run passed the same scope in 34.30 seconds before the final finite `minor_device` enum addition. |
| Shared SDK | Final full precommit passed 10 tests, 19 contract regressions and zero-error Dialyzer. Injected SDK start/end/status failures preserve exact callback returns and original throws; decoded actual OTLP IDs match reviewed logger context. Actual Porsche formatter/privacy checks passed nine, including four numeric producer-health fields while trace intake is absent and the processor suspended, without recursive spans. Routine and committed export failures increment the reviewed health counter. |
| Supporting Elixir services | Full suites and zero-error Dialyzer passed Audi (186 checks), Galileo (32), Porsche (95), Ziggy (68), Enrico (14) and Brady (84). Final packaged Porsche, Enrico, Ziggy, Brady and Galileo releases built successfully. Brady and Enrico test fixtures now isolate their log emitter and temporary state across concurrent runs. |
| Lyra | Pinned Nix Rust test/Clippy gate passed in 201 seconds. A fixed 16-entry observer queue and one worker isolate TLS/HTTP from executor completion; blocked-worker saturation exercises 1,000 refusals while preserving numeric totals. |
| Collector and Tempo | Final native otel-fleet passed in 545.92 seconds. Dedicated application Unix intake 200 survives immediate Collector restart while Tempo is unavailable, then exact trace `00112233445566778899aabbccddee02` becomes queryable. Guest, tunnel, ingress-health and provisioned dashboard assertions also pass. An earlier native otel-fleet run passed in 468.47 seconds before the final numeric bridge additions. |
| SDK/runtime metric bridge | Final native fixture verifies real formatter/journal → Fluent Bit → loopback 9468 → host Collector → central Prometheus, with trusted host/service/unit, source-clock freshness, retained application logs, remote-port refusal, BEAM memory and terminal gauges. Publishers are synthetic disposable systemd services; this establishes the transport/configuration graph, not deployed fleet SDK acceptance. Logging-transports, module/enrollment evaluation and all 231 rules plus stale/missing/counter-increment/reset cases pass. |
| Grafana and VictoriaLogs | Native log-store/Grafana passed in 58.45 seconds: actual pinned plugin/datasource provisioning, verified TLS, reader-only credential custody, exact log/trace correlation, query/insert refusals and queued backfill. Grafana maps the entry's reader-only401 to proxy400; direct entry401 assertions remain. |
| Fluent Bit | Native logging passed in 129.29 seconds: independent health, source/destination allowlists, multiple destination routing, SIGKILL and destination outage, retained pre-reboot journal and unread backfill 1.13 seconds after reboot. Logging transports pass native/OTLP/CloudWatch/restricted-audit fixture assertions. The final production SDK/runtime numeric bridge checks are recorded separately when complete. |
| SLO cadence | Four synthetic promtool suites pass. Production 10-second arithmetic explicitly checks 8,640 samples/day and 60,480/week plus elapsed retained-history guard. The pinned 50,000-sample cap prevents a complete 10-second/seven-day synthetic dataset; lower-density two-minute/seven-day 5,040-sample suites retain their own scope. |
| Handbook browser | Native browser navigation, generated diagrams, previous-section hook cleanup and revoked-login refusal passed in 68.25 seconds. Shipping diagrams were pending at this snapshot; the passing combined result is recorded below. |
| Static and deployment | Python all-files ruff-format, ruff and ty pass. Nix module-configuration and enrollment-configuration pass, including cleaned active host credential selections and negative public numeric-exporter/port-collision cases. Contract format/discovery checks and 19 validator regressions pass; this is structural evidence, not a semantic proof of every source. The SDK precommit also enforces the generated trace allowlist without rewriting it or starting application services. |

## Historical evidence boundary

Historical pre-cutover evidence remains scoped to its recorded revision and test.
Removed ingestion/UI/outbox scenarios do not establish the new observability
boundary. Archived source links use the captured baseline; historical execution
records have not been promoted to current passing acceptance.

## Combined origin integration

The isolated branch integrates origin/main
`1cd8be402166361fe21df95ce7bf5f03bfb820f7` in `69559f6e`. ADR-0147's
fresh-install Standard spelling and ADR-0148's safe open-domain eligibility are
preserved. This merge does not import previously applied profile constraints or
Lilly journals. The final Marshall gate uses a fresh isolated PostgreSQL test
partition. Incoming owner-validated standby remount, 120-second native bounds,
claim-first sweeping and continuation after individual refusal coexist with
independent archive custody. Deleted diagnostic UI/history tests remain deleted;
incoming operational, mail, authority and profile tests remain present.

The only finite vocabulary change is `antithesis` to `standard`. The canonical
artifact SHA256 is
`7d447c9a895af310d0d05952ba70cd8787504a875fa43e2544f04eb6b82b5d4c`.
The observed JSON map-order defect is corrected with explicit object ordering.
Fresh VMs with opposing atom-loading orders check the actual production vocabulary
and retain identical artifact bytes; an isolated original-generator mutant fails
that regression. This strengthens existing source/schema enforcement without
changing wire, privacy, custody or application authority. Search coverage now
includes 1,824 Elixir and 105 Rust source files.

| Combined scope | Recorded result and limits |
| --- | --- |
| Shared SDK | Full precommit passed 11 tests, 19 contract regressions, compiler/format/read-only schema checks and forced Dialyzer with zero errors/skips in 6.42 seconds. The standalone dev schema check also passes. |
| Trace spool before response fix | Native merged custody passed in 37.42 seconds with the exact canonical artifact: identity/refusal, SIGKILL/reboot, retained ACK archive/replay, malformed/quota/corrupt-store refusal and producer independence. Its upstream fixture returned an empty success body. The fixture accepted 192 and refused 64 requests in 2.020655 seconds; early/late maximum latencies were 11.429/5.905 ms and physical footprint 4,597,833 bytes. This is fixture evidence, not deployed sizing or real Collector response compatibility. |
| Trace spool response correction | Locked Rust suite passed ten tests, rustfmt and all-target Clippy with warnings denied. Actual Unix forwarding accepts the pinned `0a00`, absent partial success and zero-rejection warnings while refusing nonzero/negative rejection, malformed/truncated or ambiguous framing and oversized replies. The corrected native custody fixture passed in 34.90 seconds against identical production parser and exact pinned success bytes: UID/cgroup refusal, SIGKILL/reboot, immutable ACK retention/replay, corruption/quota and producer independence. Of 256 batches with 128 spans/21,148 bytes each, 192 were accepted and 64 refused in 1.910882 seconds; first/last 32 maximum latencies were 11.094/8.686 ms and physical footprint 4,597,833 bytes. Subsequent additive Rust cases preserve tested production behavior. This fixture establishes response compatibility and custody, not deployed sizing. |
| Trace spool eager delivery | Final locked Rust suite passed 13 checks (seven library and six binary), rustfmt, all-target Clippy with warnings denied and build. A real Unix/Store regression drained 32 accepted batches in 14,115 microseconds, proved network I/O occurs outside the custody mutex and preserved exact IDs, timestamps, expiry and bytes after reopen/replay. Absent upstream and injected delivery/expiry storage refusal retain custody; poisoned expiry publishes finite health before returning. Both fake-upstream helpers bound accept/read/write and join before assertions. The isolated old 250ms-success-delay mutant fails this regression with exit 101 in 2.03 seconds. This bounded fixture is not measured fleet throughput or strict fairness. |
| Eager native custody | Final eager native custody fixture passed in 32.28 seconds (Nix build/test 100 seconds): exact UID/cgroup admission/refusal, SIGKILL/reboot, Collector outage, immutable ACK archive/replay, quota/privacy/corruption and producer independence. Of 256 batches with 128 spans/21,148 bytes each, 192 were accepted and 64 refused in 1.756862 seconds; first/last 32 maximum latencies were 8.979/6.866 ms. The captured production source matches the final eager runtime; subsequent bounded fake-upstream cleanup changes tests only. Output is recorded in `/tmp/kittens-trace-spool-eager-drain.log`. This native fixture does not establish real Lilly transition delivery or deployed sizing. |
| Protocol | Full merged precommit passed 250 checks, 97 properties and 153 tests in 413.5 seconds; Dialyzer has zero errors. Standard retains the reviewed address/policy grammar and independently versioned control/accounting documents. |
| Lilly | Unchanged final merged full precommit passed 524 checks, 103 properties and 421 tests in 114.9 seconds, plus zero-error forced Dialyzer in 17.73 seconds. The superseded first combined attempt failed two utility/reconciliation time budgets while the obsolete distributed Marshall run was active; the unchanged retry passed after that run stopped. |
| Marshall | Actual merged full precommit passed 1,386 checks, 235 properties and 1,151 tests in 1,870.6 seconds, including distributed execution on a fresh PostgreSQL partition. The two default-excluded capacity benchmarks measure 100 gateways/10,000 routes and authenticated refresh of 100 VMs in a 10,000-VM inventory; these were not run. Terminal 32 tests, dashboard four tests and workspace type checking pass. Forced Dialyzer has zero errors, skipped checks or unnecessary skips in 72.86 seconds. |
| Static source | Explicit all-files prek passed logging catalogs, conflict markers, HLDD receipts, ruff format, lint and ty. Actual merge hooks also passed. Generated option, scenario and Ash/deployment view checks and 147 ADR structures/local links pass. These gates do not prove native runtime or production activation. |
| Nix declarations | Combined `hldd`, `module-configuration` and `enrollment-configuration` checks pass, including evaluated topology and option declarations. Native runtime and deployment acceptance remain separate. |
| Handbook browser | Combined native handbook browser passed in 61.56 seconds at output `hljyyywdq40b903g6mrx608vg30v3753` (browser subtest 30.93 seconds): all 22 sections and 28 diagrams, isolated content/previous-hook cleanup, domains/topology, back navigation, theme redraw, mobile/print, token redaction and mounted/fresh-request revocation. The browser helper's type check passes. Subsequent evidence-text updates preserve the tested diagram and navigation sources. |

Final contract review followed the ordered generator and its callers, production
schema/catalog/processor/OTLP/Rust sanitizer, ten operation wrappers, eight catalog
facades and independent committed archive/publication consumers. No blocking
finding was identified in that scope and no 64-caller cap was reached. Searches
covered every inventoried Elixir/Rust path; this is textual coverage and semantic
review of relevant production matches, not a line-by-line audit of all sources.
Retained transactional audits, authenticated FleetEndpoint control, Brady's local
numeric projection, historical migrations and refusal fixtures are intentional.
Generated-schema enforcement runs through SDK precommit; consumer/Nix/prek gates
do not invoke it. The handbook states that exact scope and directs catalog changes
to the independent SDK gate.

The pre-integration direct full Marshall run was stopped after origin integration
and has no completion summary; it is uncompleted and supplies no full-suite pass.
The first combined real Lilly observer-recovery run passed the physical control
assertions during observer loss, including exact VMM survival across Lilly
restarts, surviving guest and old receipt conservation, fresh public stop/start
readiness and durable SLO identity. It then failed the unchanged 180-second
pending-drain assertion after observer restoration; the exact fresh transition
Tempo query and subsequent submission recovery histories were not reached.
Reproduction against the pinned Collector 0.151.0 found its valid HTTP200
`application/x-protobuf` response was `0a00` (explicit empty `partial_success`).
The spool incorrectly rejected every nonempty success body. This failed execution
does not establish end-to-end diagnostic delivery; the response fix and native
retry retain the original physical, drain and Tempo assertions and deadlines.
The original native custody sink returned zero-length success, so its earlier
passing runs did not exercise the pinned Collector reply. The corrected fixture
now returns the captured `0a00` response; its passing result is recorded above.
The second combined Lilly run with the corrected response parser again passed
the physical control sequence, then timed out at pending drain. Its failure-only
helper used Nix driver's `check_output=False`, which skips reading status/output;
the resulting empty counters and false service fields are invalid diagnostic
evidence. This helper runs only after the failed assertion and does not explain
the backlog. The subsequent live investigation preserves the original assertions
and deadlines; its corrected execution is recorded below.

A separate reproduction used the actual spool, pinned Collector and exact
transient producer UID/cgroup, sending 64 requests at eight per second. Before
the eager-drain correction, all 64 were accepted in 8.226 seconds with 32 SQLite
pending and zero export failures. Afterward, the same 64-request workload was
accepted in 8.224 seconds with zero SQLite pending and zero export failures.
The former fixed 250ms delay limited successful draining to four batches per
second, below the SDK's possible routine ten batches per second plus committed
handoffs. Successful durable delivery now advances immediately and yields
between batches; idle/failure retry retains the 250ms backoff and periodic
maintenance/health publication retains its separate cadence. Direct SQLite
counts establish the final backlog: the health snapshot still showed two pending
because publication legitimately lags. These logs are
`/tmp/kittens-trace-rate-before.log` and `/tmp/kittens-trace-rate-after.log`.
The bounded fixture and successful mutant detection establish this regression,
not deployed capacity or scheduling fairness.

The eager-runtime packaged two-host retry passed the complete observer-loss
physical-control subtest in 113.04 seconds: exact VMM/guest and old receipt
conservation across Lilly reopens, fresh public stop/start readiness, durable SLO
identity, the original 180-second pending-drain assertion and retained archive
custody after observers recover. The included real Tempo query passed in 12.29
seconds for the fresh native execution UUID/revision 16, exact enrolled host and
placement, and running transition. This establishes real Lilly-to-Tempo delivery
for that journey, rather than synthetic publisher acceptance. The complete
`lilly-observability-recovery` gate passed with exit 0.
The full test script finished in 686.22 seconds.
Its subsequent explicit both-host and generated before/after
native-submission daemon-loss histories passed in 291.72 seconds, preserving the
original launch barriers and exact-generation outcome oracle.
These histories are fixed l1/reopens1, fixed l2/reopens2 and generated l1/reopens1,
with six real before/after checkpoints (four on l1 and two on l2), matching the
physical outcome, VMM, marker and untouched-survivor oracles. The 12.29-second
Tempo query is included in the 113.04-second observer subtest and is not additional
wall time. The preserved output is
`/nix/store/84zd12k7zm71fiqynsg0wgq81dyskqxy-vm-test-run-kittens-lilly-observability-recovery`,
with log `/tmp/kittens-lilly-observability-native-eager-final.log`. The captured
production spool prefix hash is
`b71297ea8c79d26f4be19dd82473babd655e66802420d6833210463ea3074a9e`,
identical to the final runtime; subsequent fake-upstream helper changes are
test-only. The composed native driver passes lint and type checking. This
disposable fleet establishes scoped native control/observer recovery, not
physical-host power-loss durability, measured production sizing or rollout.

## Completion audit

The post-publication completion audit found that the current log-store fixture
still expected nine operations panels although Nix now provisions fifteen. The
earlier 58.45-second execution retains its captured scope and does not establish
the final expanded inventory. The corrected typed assertion compares all fifteen
stable IDs, titles and visualization types from the actual Grafana HTTP API,
requires the Prometheus datasource binding and checks nonempty query strings.
The current native log-store/Grafana gate passed in 50.56 seconds (68 seconds for
the Nix invocation), including the full inventory, pinned plugin, verified TLS,
reader-only hidden credentials, exact log/trace correlation, path/credential
refusals and queued backfill. Composed-driver typing, Ruff formatting/lint and
contract discovery/format checks pass. Its output is
`/nix/store/hl7q3blr08cixnvfsjdygy4hnq0dwxdp-vm-test-run-kittens-log-store`,
with log `/tmp/kittens-log-store-dashboard-inventory-final.log` and JSONL
`/home/ghuntley/.local/state/nix/build-logs/1791596009969-742376-0.jsonl`.
This is a verification correction for ADR-0149's existing automatic dashboard
requirement; production behavior and the accepted architecture are unchanged.

The same audit found a stale native Control-room reader visit to retired
`/admin/fleet` and stale otel-marshall contract prose describing its removed
diagnostic burn reader. The obsolete visit was removed while retaining all nine
current admin pages. The Marshall contract now describes the forty Prometheus
rules and retired-route/refused-authority assertions that its fixture implements.
These are fixture corrections for ADR-0149, not changes to application authority.

The first current Control-room run passed reader access, virtual WebAuthn
elevation, forged writes and their refused-action audit, revocation, demotion and
mounted current-login expiry/export refusal, but failed its final fresh navigation.
It expired only `purpose='user'` tokens; the independently valid `remember_me`
credential correctly exchanged for a fresh login and required MFA at
`/settings/security` under ADR-0123. A second run shortened both database token
expiry fields and verified zero unexpired stored rows, but again failed final fresh
navigation. The upstream remembered-login preparation validates the signed JWT
and revocation state; shortening its stored row does not expire its signed
credential. The final correction preserves the original mounted current-login
expiry assertions and explicitly revokes independent remembered authority before
the fresh navigation, retaining `/sign-in` and export404 assertions. The stored
row-count check from the second run does not establish absent browser authority.
No production authentication or deadline changed.

The current native Control-room gate passed in 63.59 seconds with exit0
(33.60 seconds for the packaged browser, included in that duration; 367 seconds
for the Nix build/run). Nine retained admin pages, reader authority, virtual
WebAuthn elevation, forged role-write and audit refusal, stored revocation,
demotion, original mounted current-login expiry/export404, and fresh refusal after
real application sign-out all pass. Sign-out confirms one remembered row becomes
zero and increases nonexpired revocation custody. Packaged-helper typing and
composed-driver type/lint gates also pass. The output is
`/nix/store/71j99s7x7hdacy7dgvkqnybnddb5csw2-vm-test-run-kittens-control-room-browser`,
with log `/tmp/kittens-control-room-retirement-signout-final.log` and JSONL
`/home/ghuntley/.local/state/nix/build-logs/1791597135963-924633-0.jsonl`.
This is scoped native browser authority with a virtual authenticator, not
hardware-authenticator or independent-physical-host acceptance.

The first current otel-marshall run passed metric/permission, recorder and producer
loss assertions but failed before receiving a retired-route status: Playwright's
Node HTTP client did not use Chromium's fixture CA trust. Its command now supplies
the exact disposable CA through `NODE_EXTRA_CA_CERTS`; TLS verification remains
enabled and every HTTP404, login and revocation assertion remains intact.

The current native otel-marshall gate passed in 113.32 seconds with exit0.
The actual Prometheus API exposes all forty burn rules; source UID/intake and
exporter-write refusals, real HTTPS request metrics and independent collector
export pass. Recorder SIGKILL preserves application/retained-source continuity
(4.48 seconds); clean application deployment conserves coverage and settled totals
(14.71 seconds); admitted producer loss records exactly one failure without
inventing duration and preserves identity/counters (16.95 seconds). The packaged
verified-TLS browser passed in 12.10 seconds: anonymous and ordinary-reader
HTTP404 for `/admin/slos` and `/admin/logs`, absent overview links, and current plus
copied remembered-browser refusal after exact stored revocation. The output is
`/nix/store/q4qgzxakvmrc90kjg5n3vxh9kddsbvx2-vm-test-run-kittens-otel-marshall`,
with log `/tmp/kittens-otel-marshall-retirement-native-trust-fixed.log`.
Composed-driver type/lint checks also pass. This records the current retirement
and durable-request boundary, not seven-day compliance, notification delivery,
native physical power loss or deployed acceptance.

The first current relocation build failed its composed driver's type gate before
any native scenario ran: narrowing a JSON `object` with `isinstance(..., dict)`
left an unusable `dict[Never, Never]`. The corrected boundary copies validated
string keys into `dict[str, object]`, then validates the receiving state, complete
process inventory, unique transfer helper, its exact ZFS child and numeric byte
count before fault injection. Local received-state reads use the same boundary.
The existing fault-synchronization contract moved from a Python hash comment into
the function's discoverable docstring without changing its obligation. No cast,
manufactured receipt, control mutation, timeout extension or weaker recovery
oracle was introduced. Ruff and repository contract checks pass; all nineteen
contract-validator regressions pass. The native rerun remains separate evidence.

The typed relocation retry completed the real first transfer, destination
readiness, placement handoff, cleanup and guest-data verification, then timed out
waiting for five Lilly native resource types in Marshall's lifecycle table.
That expectation described the retired diagnostic ingestion. Its replacement
requires zero provisioner diagnostic rows for the fresh fixture and a matching
retained transactional Relocation complete/succeeded audit. All existing native
guest, placement, fence and cleanup oracles remain intact. The same obsolete
origin expectations in lifecycle and clone fixtures are reconciled with their
retained human/system audits; no production lifecycle authority changed.

The first current Brady run failed its attribution probe because the fixture still
expected the old `request` event name. Actual reviewed formatter output uses
`brady.request_completed`; captured current logs contained resolved successful
requests. Correcting only that name preserves all identity, epoch and generation
comparisons and the original sixty-second deadline. That failed run never reached
the independent exporter assertion and supplies no current passing exporter claim.

The source audit also found a real health-projection gap: Brady's reviewed formatter
emits flat `brady.observability_health` fields, while normalization required nested
metadata for all eight applications. The corrected branch accepts only the trusted
Brady journal unit, exact health name and absent nested metadata. All finite
numeric allowlists, native timestamps and module/journal identities remain intact;
other services cannot use the flat path. An actual source-built Brady catalog and
formatter now generate the regression input, replacing the synthetic nested Brady
message. The pinned native Fluent Bit pipeline exercises both log-plus-metrics
and metrics-only modes, with additive foreign-unit, malformed-numeric, conflicting
nested-identity and payload-provenance refusals. This repairs ADR-0149's accepted
health boundary; it adds no diagnostic authority or architecture decision.

The current native-process logging-transports gate passed with exit0 in 431.15
seconds for the complete Nix invocation. Actual source-built Brady formatter
output traverses pinned Fluent Bit in both log-plus-metrics and metrics-only
modes. All eight service identities, finite health values, original journal
clock, trusted host/unit labels and malformed/foreign/conflicting-message refusals
pass. Retained runtime/legacy conversion, transport/response privacy, CloudWatch
management, independent logging health and nondestructive checkpoint migration,
source routing/correlation and cursor isolation also pass. Its output is
`/nix/store/h8qj1h046ayniqc1hc36dxv1c6k98ria-kittens-logging-transports`,
with log `/tmp/kittens-logging-brady-flat-health-native-final.log`.
The actual Brady fixture compiled with pinned `elixirc --warnings-as-errors`;
scoped Dialyzer against the existing Brady test PLT and packaged application beams
reports zero warnings. All-files Python formatting, lint and typing pass.
This is native-process/configuration evidence with disposable journal inputs,
not a NixOS VM execution, deployed SDK producer acceptance or physical isolation.
The final source inventory contains 1,825 Elixir and 105 Rust files; the added
Elixir formatter fixture accounts for the increase from the integrated snapshot.

The independent final source audit found two further discrepancies. Five Lilly
comments/contracts still described the removed diagnostic outbox and audit sender.
Twelve inserted and eleven removed comment lines across five production/test files
now describe authoritative journal writers, physical control acknowledgements and
validated legacy backup history. No executable code, assertion, deadline or lock
path changed. The captured comment-only Lilly full precommit passed all 524 checks (103
properties and 421 tests), seed232788, in 98.3 seconds, with forced Dialyzer zero
errors/skips in 16.1 seconds; the whole invocation took 160.09 seconds. Compiler,
format, logging and contract gates also passed. Its log is
`/tmp/kittens-lilly-retirement-comments-precommit-final.log`. Previously captured
native executions retain their runtime scope; source-comment changes do not
establish new native acceptance.

Collector file-storage extensions omitted `fsync`, whose pinned default is false,
despite ADR-0149's accepted queue guarantee. The guest trace path also retained
volatile prequeue batching and a 300-second retry expiry. Both separate 64-entry
trace queues now explicitly fsync storage writes, both exporters retry without
elapsed expiry and neither trace pipeline batches ahead of durable queue custody.
Metric batching and guest/application provenance remain unchanged. An evaluated
module regression requires these actual queue/pipeline settings. The independent
FULL-WAL spool still retained accepted application archive custody before this
correction; earlier native executions do not prove the corrected Collector
configuration or physical power-loss durability. The corrected evaluated
`collectorTraceCustody` regression passed, and the first corrected native
Collector gate passed in 432.85 seconds (597.34 seconds for the combined
module/native invocation). Its output is
`/nix/store/hh20hzz0n8cqa4s87bamwvm9r0nlfyh9-vm-test-run-kittens-otel-fleet`,
with log `/tmp/kittens-collector-fsync-native-final.log`. This execution predates
strengthening all three trace journeys to immediate acknowledgment followed by
Collector SIGKILL. The strengthened native Collector gate passed in 500.09
seconds (500.02 seconds for its nested script, 527.36 seconds for the whole Nix
invocation), with output
`/nix/store/lc896lmvjjzs72pg8hf88p73ay0yyanr-vm-test-run-kittens-otel-fleet`
and log `/tmp/kittens-collector-fsync-sigkill-native-final.log`. All three exact
trace journeys acknowledged intake before immediate SIGKILL and restart, then
became queryable in real Tempo: guest backend outage, authenticated fleet-tunnel
outage and the private application queue. Original source separation, permissions,
refusals and recovery deadlines remain intact. Real Lilly observer recovery is
still pending. Physical host power-loss durability is separate.

The next Brady run passed current attribution, durable accounting restart/loss,
guest survival, legacy attribution, independent exporter and address-reuse
refusals, then failed its instantaneous current-proof setup before the VMM fault.
A bounded exact-identity setup probe addresses ADR-0140's legitimate two-second
proof expiry between subtests, preserving the measured watcher fault body. Its
fresh full retry passed that setup and the same earlier journeys, but failed to
observe the target's native `vm.watch_ended` witness after killing the VMM within
the original polling bound. It supplies no elapsed revocation or full-gate pass.
Current investigation retains the exact reason, timing and refusal oracles.
The diagnostic retry failed again after observing exactly one target VMM,
one matching native watcher and one matching pidfd, with a valid journal cursor.
Target outcome records followed the kill without the expected watcher exit event.
Source inspection identifies a possible observation-before-port-message race:
non-running observations revoke proof rows, then close the current watcher
before its genuine native exit report can be handled. A deterministic regression
and minimal correction are in progress; an observer must not extend stale
authority or manufacture an `exited` reason. The cursor now starts after the
fresh exact-identity setup so earlier events cannot satisfy the fault oracle.
The older diagnostic capture does not validate that corrected observation window.
The renewed fsync Lilly recovery run was interrupted early to avoid testing a
superseded actor; it supplies no passing result. Current base fleet execution
retains its captured pre-correction runtime scope. Remaining native executions
must be captured from the final actor source.

The corrected timeout fixture now distinguishes real stdin EOF from a read
timeout instead of inspecting the inverted status of `! read`. With that fixture,
the original actor fails the targeted port-retention regression (zero of one
selected checks passed, seven excluded). The corrected focused actor module
passed 13 checks (one property and twelve tests) in 1.4 seconds, recorded in
`/tmp/kittens-brady-watcher-race-fixed.log`. The real port fixture delivers
negative observation before actual exit or error; proof is withdrawn immediately,
the same observer remains, and only its genuine terminal report emits the event.
No report or native timing is manufactured.

The actor retains one bound observer until its actual terminal report, explicit
target/command replacement or shutdown. A private volatile `proof_target` tracks
the verified target behind successful proof publication. Only its exact armed
watcher earns the thirty-second backstop; unavailable, unarmed or replacement
targets retain two seconds, and delayed old messages cannot extend authority.
A different verified boot target withdraws old live proof before publishing
roster-only proof; same-target boot evidence does not renew running proof.
Current ordered regressions also exercise ambiguous recovery, held replacement
arming, stale-port refusal and shutdown. Independent contract/source review
found no remaining issue. The first full run passed 530 checks but failed
Dialyzer: a closed two-key helper map declaration did not accept the actor's
larger state. The helper now accepts precisely typed watcher and target fields,
with the same exact-target predicate. The final typed Lilly precommit passed
530 checks (103 properties and 427 tests), seed95478, in 66.8 seconds. Forced
Dialyzer reports zero errors, zero skips and zero unnecessary skips in 11.46
seconds. Runtime, ADR, contract, logging, formatting and compiler gates also
pass. Its log is `/tmp/kittens-lilly-watcher-final-precommit.log`. This is the
current frozen actor source; native Brady acceptance is recorded below, and
actor/port tests alone do not establish kernel pidfd behavior. Preliminary native
captures superseded by the helper correction were stopped during release builds
and supply no native result.

The complete base fleet gate passed in 2324.23 seconds (2323.94 seconds for its
nested script, 2785.364 seconds for the complete Nix invocation), at
`/nix/store/r6n7bdg75gngrblwrpdv63r9r4795p95-vm-test-run-kittens-fleet`, with log
`/tmp/kittens-fleet-observability-retirement-final.log`. Physical stop/deletion
and storage accounting passed in 59.97 seconds; retained owner delete-intent and
system accepted-deleted audits, with zero provisioner diagnostics for both fresh
victims, passed in 0.46 seconds. Real guest convergence, capacity races, network
denial, release and credential-only upgrades, terminal sharing/reconnect,
control-plane/database loss, Lilly daemon loss, staleness and revoked-authority
guest preservation also passed. This capture predates the watcher correction:
it establishes diagnostic-retirement and retained business-audit behavior on that
captured runtime, not the new proof-target or exit-report ordering. Current
Porsche, Brady, relocation and renewed Lilly recovery use the final typed actor.

The current full relocation run passed both running-guest directions (230.09 and
245.54 seconds), stopped-guest movement (166.92 seconds), prehandoff cancellation
with unavailable destination cleanup (49.05 seconds) and final retained-copy
deletion (10.80 seconds). It then failed the first midstream-fault setup's original
300-second local native-receiving predicate. No cancellation fault was injected
and the subsequent matrix did not execute; passing earlier subtests do not make
the full gate pass. Its log is
`/tmp/kittens-relocation-observability-retirement-final.log`. The fixture's procfs
scan treated every kernel thread's absent executable link as an incomplete
userspace inventory. A bounded, typed native-stat parser now excludes only
validated `PF_KTHREAD` entries; missing, malformed or racing userspace observations
still remain incomplete. Six procfs regressions passed in 0.016 seconds, with
output `/nix/store/ndmz5615ld3ib2xa4z9hd5nyplag4sns-kittens-relocation-diagnostics-tests`;
the original helper fails the targeted regression. Pinned Python formatting,
lint and typing pass. The unique helper, exact ZFS child, receiving state and
greater-than-one-MiB fault threshold are unchanged. At this failed capture, full
native relocation acceptance remained pending; the corrected complete passing
capture is recorded below.

The final typed Brady fleet passed its complete native script in 359.64 seconds
(625 seconds for the complete Nix invocation), with output
`/nix/store/xy3r24b2qadnwj7w00lsfgpr5j57vc9x-vm-test-run-kittens-brady-fleet` and log
`/tmp/kittens-brady-fleet-watcher-typed-final.log`. The native pre-kill snapshot
counted one exact target VMM, one bound watcher and one matching pidfd, with a
valid journal cursor. Real VMM SIGKILL produced the genuine `exited` event for
the exact placement and revoked proof in 99 milliseconds, preserving the original
less-than-1000-millisecond bound; the old flow then refused attribution. The
fault subtest passed in 0.64 seconds and address reuse in 69.79 seconds. Actual
guest owner attribution, observer loss, clean restart, idle-producer loss,
Brady/Lilly restart continuity and legacy-owner attribution also passed. The
credential-free infrastructure exporter with no Marshall ingestion passed in
0.56 seconds. This validates the final actor on the captured guest runtime;
incoming Starship defaults and physical host failure are separate scopes.

The final typed focused NixOS Porsche lifecycle fleet passed in 869.30 seconds
(868.92 seconds for the nested script and 1057.869 seconds for the complete Nix
invocation), at
`/nix/store/vhq2w5qkr8448q90y240y8vyv5bzmafd-vm-test-run-kittens-porsche-lifecycle-fleet`.
Its log is `/tmp/kittens-porsche-lifecycle-watcher-native-final.log`. Real browser
and native SSH lifecycle passed in 703.71 seconds, including clone/start and
cross-host copy relocation followed by physical source/copy deletion. The final
exact source/request/workflow/user/system clone audit passed in 0.49 seconds,
preserving both public copies' human enqueue and successful system completion
receipts with zero provisioner diagnostic rows. This final actor execution uses
the captured pre-Starship NixOS image and fixtures; it does not establish merged
prompt rendering, Ubuntu lifecycle or the separate complete clone fault matrix.

The final typed Lilly recovery passed in 707.93 seconds (707.60 seconds for its
nested script), with output
`/nix/store/n30gqwncgn0w9r0j8lahs370x8mb75rp-vm-test-run-kittens-lilly-observability-recovery`.
The complete Nix invocation passed in 796 seconds, with a separately recorded
shell time of 796.360 seconds. The exact capture includes both the final typed
actor and fsynced persistent Collector queues. Real Collector/spool outage,
physical receipt and VMM conservation through Lilly reopens, fresh public
stop/start readiness, original 180-second pending drain, immutable archive
retention and exact fresh native transition delivery to Tempo passed in 113.51
seconds. The whole-daemon native submission histories passed in 299.61 seconds:
fixed l1/one-reopen, fixed l2/two-reopen and generated l1/one-reopen histories
retain all six before/after launch checkpoints and eight settlement reopens.
Original launch markers, exact authenticated physical outcome identity, VMM
ownership, unrelated guests, deadlines and fault schedules are unchanged. The
wrapper is `/tmp/kittens-lilly-observability-watcher-typed-fsync-native-final.log`
and complete JSONL is `1791601944894-1388639-0.jsonl` in the Nix build-log directory.
This supersedes earlier combined recovery for final actor/Collector acceptance,
while preserving their earlier scope and actual failed/interrupted attempts.
Captured guest images/fixtures predate incoming Starship defaults; production
sizing, physical host power loss and notification receipt remain separate.

The subsequent typed procfs relocation run failed after 1958.249 seconds without
a complete output artifact. Its live move/return, stopped move, pre-handoff
cancellation, Delete, occupied midstream cancellation (90.33 seconds) and
both-endpoint restart recovery (368.53 seconds) passed under unchanged bounds.
The next fresh guest failed to reach running before the completed-final-receive
fault was injected. Exact native evidence reports `private_services_unavailable`:
the prior reboot removed the fixture's `/run/galileo-audi-root.pem`; Galileo
startup failed on that missing public root and Audi-private's required dependency
failed. This is a fixture trust-custody failure, not completed fault acceptance
or evidence of shared-host load. The wrapper is
`/tmp/kittens-relocation-kernel-thread-native-final.log`, frozen derivation
`/nix/store/pbdc9djqlng5ld8hk4akpkgzdkg16www-vm-test-run-kittens-relocation-fleet.drv`.
The fixture correction retains the exact public trust root across reboot and
checks actual private-service readiness before continuing. The complete corrected
native acceptance subsequently passes as recorded below; the failed capture
remains evidence of its original fixture boundary.
The first composed driver caught a closure typing issue before any VM launch:
later global reuse of `source` widened its inferred type. Binding the exact
endpoint as the lambda default preserves the predicate and original 120-second
setup bound. The final composed driver's native typing/lint gates pass at
`/nix/store/hp58jifzd3dzlrwjkc9viif6l22sydcx-nixos-test-driver-kittens-relocation-fleet`.
Independent source/contract review, all-files Python checks and a public-only
initial-cache/reboot-restore/missing-trust smoke check pass. The corrected full
native execution uses frozen derivation
`/nix/store/vqmp9ypkb52nnq7w93nl3410wb8vjxkn-vm-test-run-kittens-relocation-fleet.drv`
and `/tmp/kittens-relocation-trust-native-final.log`.

The complete corrected relocation gate exits 0 with all 19 subtests passing.
Its "finished: run the VM test script" footer takes 3643.75 seconds, the
"test script finished in" footer reports 3643.99 seconds and the full Bash
wrapper takes 3654.445 seconds. The composed driver is
`/nix/store/hp58jifzd3dzlrwjkc9viif6l22sydcx-nixos-test-driver-kittens-relocation-fleet`,
with realized output
`/nix/store/11ibfwp2xv1jdf53vn3gr3q22mhdc3hg-vm-test-run-kittens-relocation-fleet`.
The frozen two-source hashes still match. Live move/return, stopped move,
pre-handoff cancellation, logical Delete and occupied native-stream cancellation
pass. Endpoint-restart recovery passes in 381.13 seconds, including physical
source reboot, same public-root restoration, actual private readiness, durable
receipt replay and data/cleanup. Completed final receive before control ACK
passes in 232.39 seconds; stopped-source cancellation passes in 207.57 seconds.
Actual readiness timeout/source fencing/two-copy deletion passes in 328.38
seconds, and unavailable destination cleanup/disk-address retention in 206.12
seconds. Real endpoint update/resumption passes in 336.29 seconds and a new-boot
readiness retry without source rollback in 389.19 seconds. Physical source
pressure selects stopped-copy fallback and preserves guest identity, unrelated
processes/data and cleanup in 484.63 seconds. Destination ENOSPC retains actual
partial-receive/resume evidence and source holds, then completes adoption,
readiness, data verification and cleanup after headroom recovery in 269.67
seconds. No source, fault, oracle or deadline changes occur during execution.

This capture includes the incoming profile-migration and guest source. Subsequent
Nix descriptions, fleet contract comments, separate standby fixture and decision
status edits do not change this fixture's runtime values or assertions. It
establishes the complete captured relocation matrix on disposable machines in
one KVM failure domain, not a retained-state native upgrade, Starship prompt
rendering, the separate clone/Ubuntu matrices, physical-host power loss, live
rollout, retention sizing or notification delivery.
The corrected Collector crash acceptance is recorded above;
prior historical reader executions and an unfinished older relocation run do
not establish the remaining current boundaries.

Current all-files prek passed all eight application logging checks, conflict
markers, reviewed HLDD receipts, Ruff formatting/lint and ty. Evaluated Nix HLDD
passed at `/nix/store/2r2hz01smzkcnl3w3slajl1wgjpfj9rj-kittens-hldd-check`.
Contract validation reports 120 CONTRACTS, 2543 native notes, 225 parsed sources
and 2620 maintained sources, with all 19 validator regressions passing. Marshall's
current architecture/handbook/LiveView suite passed 51 checks (11 properties and
40 tests), seed935455, in 6.8 seconds. Logs use the
`/tmp/kittens-observability-audit-current-` prefix. These current checks supplement
the earlier full runtime gates; final evidence edits receive reviewed receipt
and structural checks again before publication.

## Retained-profile integration

Incoming main through `76c6ce42` adds existing-state profile migration and separate
image-template fault fixtures. Independent review found a custody violation in
its raw Dataset claim rewrite and a host-binding ordering defect. The integrated
correction validates host/version before startup mutation, archives exact v1
bytes under the normal pool lock, and publishes the profile rename through a
same-state Ash transition with preserved identity/state and one revision advance.
Execution deletion bindings are included; native journals and immutable archives
are untouched. The original importer fails the decisive exact-archive regression.
The [focused custody review](2026-10-10-profile-migration-custody.md) records
31 passing Lilly checks and the actual populated PostgreSQL migration test.

This source has persistence/recovery impact. ADR-0147's accepted fresh-install
rationale remains intact; ADR-0151 is proposed/partial for the wider retained-state
extension. HLDD13/16/19/20 distinguish isolated passing checks from the unrun
packaged retained-guest upgrade and physical interruption acceptance. Envelope
validation does not validate every native Dataset binding, and the 16,384-record
admission bound follows wildcard traversal. The incoming image-template slow
property/unmount faults are reviewed, present and unrun. Earlier frozen native
cutover captures predate those changes and retain their precise runtime scope;
the corrected relocation capture above includes the incoming profile/guest source.

The final source inventory is 1,829 Elixir and 105 Rust files. Regeneration adds
only catalog event `lilly.profile_renamed` and finite atoms `migrate`, `plain`,
`profile_migration_failed` and `proof_target`; privacy/provenance contracts are
unchanged. Current canonical schema SHA256 is
`107f7b0872c0f916419a8b56be4e258e2688d6a5230cf3523a8cbf139ad38484`.
Final Lilly precommit passes 541 checks (104 properties and 437 tests), seed95084,
in 75.3 seconds. Forced Dialyzer has zero errors, skipped checks or unnecessary
skips in 14.82 seconds; the complete gate takes 149.527 seconds. Log:
`/tmp/kittens-lilly-profile-custody-final-precommit.log`. The SDK gate passes
11 tests in 3.5 seconds, 19 contract regressions and zero-error forced Dialyzer
in 6.25 seconds at `/tmp/kittens-observability-profile-sdk-final.log`. Locked Rust
spool checks pass all 13 cases, rustfmt and all-target Clippy with warnings denied;
the release build passes in 50.72 seconds. Those parser/custody fixtures and the
reviewed current production schema retain their separate scopes.

All-files prek passes eight logging catalogs, conflict markers, HLDD receipts,
Ruff formatting/lint and ty. Generated options/views/coverage and 149 ADR
structures/local links pass; current contracts cover 120 CONTRACTS, 2555 native
notes, 227 parsed sources and 2625 maintained sources with 19 passing regressions.
After the public-trust fixture correction, the reviewed count is 2556 native
notes with unchanged source-file counts and all 19 contract regressions passing.
Three Nix option descriptions and generated HLDD18 now name current native
copy/template/standby journal and pool-accounting compatibility, preserving every
type, default and runtime value. They no longer imply deploying retired Marshall
diagnostic readers. Regenerated declarations differ only in those three descriptions.
The evaluated Nix handbook passes at
`/nix/store/0sgh40wg1zkrj1r8gaq6vk43v87ldxdw-kittens-hldd-check`. An initial Nix
attempt omitted the newly added untracked review/ADR/test sources and failed their
references; staging those reviewed files fixed the source projection, without
changing gate assertions. Final Marshall precommit exits successfully: 1,387
checks (235 properties and 1,152 tests), two excluded capacity benchmarks,
seed922173, in 1510.0 seconds (40.1 asynchronous and 1469.9 synchronous).
Terminal/accessibility checks pass 32/32 and dashboard checks pass 4/4; the
workspace TypeScript gate completes before forced Dialyzer. Forced analysis
passes with zero errors, skipped checks or unnecessary skips in 61.94 seconds,
after PLT phases of 13.38 and 324.95 seconds. The exact log is
`/tmp/kittens-observability-profile-marshall-final-precommit.log`.
Complete corrected relocation acceptance passes with the exact scope recorded
above; retained-state native upgrade and independent production acceptance remain
separate.

Incoming `e3300040` adds a four-line standby refill before the interrupted-unmount
fixture: the preceding slow claim consumed the last standby. Its author reports
a native pass, production enablement and three standby-source create samples
(10.8, 12.8 and 15.1 seconds). No exact execution wrapper, full native artifact or
matched campaign receipt accompanies that report; these remain attributed
observations rather than independently executed cutover acceptance. Current fleet
declarations enable templates, same-pool block copies and 128 standbys per image
on both hosts. Declared values do not establish live health. Earlier readers-off
campaigns and their failures retain their historical scope. The current slow-claim
and interrupted-unmount fixture is present; this task has not rerun it. Diagnostic
reader prerequisites in ADRs, Nix option descriptions and fleet contract notes
are reconciled with ADR-0149's native state journals and closed pool accounting,
preserving every runtime value, readiness and controlled-benchmark requirement.
HLDD05 now names the actual catalogued standby source and incarnation alongside
the template and verified paths.

Subsequent main commit `e7e2f2e3` records the user's earlier acceptance and
confirmation of ADR-0146. Its current status is accepted/partial; the prior e330
review checkpoint remains historical. Decision acceptance adds no executed
standby-fault fixture, matched timing campaign or retained-state upgrade evidence.

## Open acceptance

The correction milestone is committed as `da81d4ac`. The integration merges
origin/main `ba574d802b6afe978becca615b0f5ee31c52590a`, containing the independent
guest Starship decision ADR-0150. Fixed distribution Bash selection preserves
existing closed diagnostic events, roster identity, account ownership and
mutation refusal. OTLP, trace custody, control documents and authority do not
change. The incoming guest-image identities and terminal/browser fixtures differ,
so current native cutover artifacts remain explicitly scoped to their captured
pre-Starship images and fixtures. Incoming recorded managed SSH/browser results
retain their own integrated `63214e60`/`a2d9e6e` scope. Both scenario sets and
reciprocal ADR relationships are preserved; joint review receipts replace neither
decision's acceptance with the other feature's evidence. Current integration
checks pass: Lyra (including its Clippy gate), guest-toolset and Ubuntu image
properties resolve to `l8984rj4asqxigs1a4vl3szwzvr64s0q`,
`dyki2wjk2i2m294k1lmvjgsb2awm5war` and `ijrlhvrcac0lfiip2m55p46sp2jdklam`
respectively. These exact Nix test outputs were reused from prior successful
executions, rather than rerunning their binaries. All-files prek, ADR structure
(148 decisions), generated options/views/coverage and 19 contract regressions
pass; contracts now cover 120 CONTRACTS, 2550 native notes, 227 parsed sources
and 2621 maintained sources. Evaluated handbook passes at
`/nix/store/j8dk7ya18qakaaiizlyi32fxydhg1vwl-kittens-hldd-check`. Integration
logs use `/tmp/kittens-observability-starship-integration-`. Subsequent native
outcomes are recorded separately above, preserving each captured runtime.

The integrated source gates and captured pre-Starship/pre-profile two-host
recovery and real transition-delivery checks pass. Their exact scopes are
recorded above. Final reviewed HLDD receipts accompany the evidence updates.
Marshall's full gate and combined shipping handbook diagrams and navigation pass.
Production activation, measured retention/traffic, physical host power loss and
independently observed notification receipt are separate from publication. Unit
tests do not establish kernel isolation or independent physical-host availability.

## Retired scenario evidence

### Retired evidence telemetry-retention-diagnostics item 3

Pre-cutover source: `marshall/test/marshall/telemetry/slo_status_read_test.exs` at baseline
`a99f74f06542798dc9ef288e77c99d480433fc57`.
Assertion: only closed numeric diagnostic states reach the UI

Original scope: Generated closed codes, foreign identities, duplicate samples and malformed values.

This retired diagnostic/outbox/view evidence establishes only its historical
boundary. It does not establish the replacement SDK, spool, Grafana or protocol.

### Retired evidence lifecycle item 3

Pre-cutover source: `lilly/test/lifecycle/audit_runtime_test.exs` at baseline
`a99f74f06542798dc9ef288e77c99d480433fc57`.
Assertion: metadata traversal retains the exact suffix after its path budget

Original scope: Configured temporary metadata root and sorted regular files around128/256path boundaries; exact unvisited suffix after each128path batch, including the root visit. No event, transport, native or host-pressure claim.

This retired diagnostic/outbox/view evidence establishes only its historical
boundary. It does not establish the replacement SDK, spool, Grafana or protocol.

### Retired evidence fleet-log-viewer item 1

Pre-cutover source: `marshall/test/marshall/logs/store_test.exs` at baseline
`a99f74f06542798dc9ef288e77c99d480433fc57`.
Assertion: arbitrary text never escapes the quoted phrase

Original scope: Generated arbitrary user text and enum lists; query compilation and response narrowing invariants.

This retired diagnostic/outbox/view evidence establishes only its historical
boundary. It does not establish the replacement SDK, spool, Grafana or protocol.

### Retired evidence fleet-log-viewer item 2

Pre-cutover source: `marshall/test/marshall_web/admin_logs_live_test.exs` at baseline
`a99f74f06542798dc9ef288e77c99d480433fc57`.
Assertion: redirects anonymous browsers and renders for signed-in readers

Original scope: Route authorization, reader/admin rendering, filtering, live tail and halted unknown events against a stubbed store.

This retired diagnostic/outbox/view evidence establishes only its historical
boundary. It does not establish the replacement SDK, spool, Grafana or protocol.

### Retired evidence fleet-monitor-delivery item 1

Pre-cutover source: `marshall/test/marshall_web/fleet_api_test.exs` at baseline
`a99f74f06542798dc9ef288e77c99d480433fc57`.
Assertion: one conflicting sample rolls back neighboring samples until it is removed

Original scope: Local authenticated HTTP, cache and PostgreSQL history with generated conflict position and retries; valid neighbors receive durable acknowledgments after the poison is manually removed

This retired diagnostic/outbox/view evidence establishes only its historical
boundary. It does not establish the replacement SDK, spool, Grafana or protocol.

### Retired evidence fleet-slo-read item 1

Pre-cutover source: `marshall/test/marshall/telemetry/slo_burn_read_test.exs` at baseline
`a99f74f06542798dc9ef288e77c99d480433fc57`.
Assertion: missing duplicated foreign and unhealthy rules cannot imply inactive alerts

Original scope: Generated rule order, state, corruption and clock-age inputs verify the exact fixed burn roster; no native transport or paging route.

This retired diagnostic/outbox/view evidence establishes only its historical
boundary. It does not establish the replacement SDK, spool, Grafana or protocol.

### Retired evidence fleet-slo-read item 4

Pre-cutover source: `marshall/test/marshall/telemetry/slo_read_test.exs` at baseline
`a99f74f06542798dc9ef288e77c99d480433fc57`.
Assertion: a retained host-origin recording cannot add a third collector

Original scope: Generated two-host recording-rule response shapes, invalid arithmetic and retained host-origin third-series refusal.

This retired diagnostic/outbox/view evidence establishes only its historical
boundary. It does not establish the replacement SDK, spool, Grafana or protocol.

### Retired evidence fleet-slo-read item 5

Pre-cutover source: `marshall/test/marshall_web/slo_live_test.exs` at baseline
`a99f74f06542798dc9ef288e77c99d480433fc57`.
Assertion: revoked readers lose the next refresh

Original scope: Authenticated LiveView mount, anonymous redirect and revoked session refresh against a local unavailable Prometheus endpoint.

This retired diagnostic/outbox/view evidence establishes only its historical
boundary. It does not establish the replacement SDK, spool, Grafana or protocol.

### Retired evidence fleet-slo-read item 9

Pre-cutover source: `marshall/test/marshall/telemetry/slo_read_test.exs` at baseline
`a99f74f06542798dc9ef288e77c99d480433fc57`.
Assertion: candidate cards accept only one exact aggregate recording

Original scope: Generated candidate response rows, duplicate and foreign label refusal; fixed catalog validation with an unknown fallback.

This retired diagnostic/outbox/view evidence establishes only its historical
boundary. It does not establish the replacement SDK, spool, Grafana or protocol.

### Retired evidence fleet-envelope-refusals item 1

Pre-cutover source: `marshall/test/marshall_web/fleet_version_history_test.exs` at baseline
`a99f74f06542798dc9ef288e77c99d480433fc57`.
Assertion: wrong fleet body versions preserve durable rows and cache across every control route

Original scope: All current route families and explicit version variants preserve complete row hashes and cache state after each surface corpus; recorded exceptions remain explicit.

This retired diagnostic/outbox/view evidence establishes only its historical
boundary. It does not establish the replacement SDK, spool, Grafana or protocol.

### Retired evidence fleet-envelope-refusals item 2

Pre-cutover source: `marshall/test/marshall_web/fleet_version_history_test.exs` at baseline
`a99f74f06542798dc9ef288e77c99d480433fc57`.
Assertion: malformed fleet envelopes remain permanent without durable or cached effects

Original scope: Syntax/missing/scalar/array/null envelopes retain permanent classes without cached or durable changes; detects parser error incorrectly classified as unavailable.

This retired diagnostic/outbox/view evidence establishes only its historical
boundary. It does not establish the replacement SDK, spool, Grafana or protocol.

### Retired evidence fleet-envelope-refusals item 3

Pre-cutover source: `marshall/test/marshall_web/fleet_version_history_test.exs` at baseline
`a99f74f06542798dc9ef288e77c99d480433fc57`.
Assertion: retired and unknown fleet paths refuse without body reads or state changes

Original scope: Unknown path/method families refuse before reading bodies; recognized retired provisioner actions and both stream-refusal paths retain their reviewed classes and preserve state.

This retired diagnostic/outbox/view evidence establishes only its historical
boundary. It does not establish the replacement SDK, spool, Grafana or protocol.

### Retired evidence fleet-envelope-refusals item 4

Pre-cutover source: `marshall/test/marshall_web/fleet_version_history_test.exs` at baseline
`a99f74f06542798dc9ef288e77c99d480433fc57`.
Assertion: valid current requests calibrate control dispatch and the cache oracle

Original scope: Actually issued credentials reach current service dispatch; real accepted monitor sample changes cache first and durable inventory only after flush.

This retired diagnostic/outbox/view evidence establishes only its historical
boundary. It does not establish the replacement SDK, spool, Grafana or protocol.

### Retired evidence telemetry-retention-diagnostics item 5

Pre-cutover source: `nix/tests/machines/otel-marshall/browser.py` at baseline
`a99f74f06542798dc9ef288e77c99d480433fc57`.
Assertion: retained for 90 days

Original scope: Source-built Marshall displays diagnostic elements and retention explanation to an authenticated reader, preserves unknown compliance and refuses revoked sessions.

This retired diagnostic/outbox/view evidence establishes only its historical
boundary. It does not establish the replacement SDK, spool, Grafana or protocol.

### Retired evidence provisioning-fastpath item 1

Pre-cutover source: `marshall/test/marshall/compute/lifecycle_audit_test.exs` at baseline
`a99f74f06542798dc9ef288e77c99d480433fc57`.
Assertion: template history requires the authenticated host's enrolled pool and no fake placement

Original scope: Marshall validates current authenticated host and enrolled pool before deduplication, refusing a foreign pool or invented placement. The committed audit row correlates evidence but grants no placement or cleanup authority; this is application evidence, not native guest readiness.

This retired diagnostic/outbox/view evidence establishes only its historical
boundary. It does not establish the replacement SDK, spool, Grafana or protocol.

### Retired evidence lifecycle item 1

Pre-cutover source: `lilly/test/lifecycle/recovery_history_test.exs` at baseline
`a99f74f06542798dc9ef288e77c99d480433fc57`.
Assertion: dirty sender restart drains exact events before restored actor effects

Original scope: Actual locked execution-journal backlogs, paused actors, production Runtime connection/readiness callbacks, HTTP Client/audit sender, partial/zero ACKs, fair multi-journal offers and forced sender/task death. Full Lilly gate passed 474 checks (84 properties,390 tests), seed929763. Synthetic session result and fixture peer; no full Runtime ownership/init, authentic Marshall, TLS, native VMM or hosted fault claim.

This retired diagnostic/outbox/view evidence establishes only its historical
boundary. It does not establish the replacement SDK, spool, Grafana or protocol.

### Retired evidence lifecycle item 2

Pre-cutover source: `lilly/test/lifecycle/recovery_history_test.exs` at baseline
`a99f74f06542798dc9ef288e77c99d480433fc57`.
Assertion: pending journals beyond scan and offer bounds are not starved

Original scope: Production journal writers, OS locks, HTTP Client and audit sender; generated real retained inventories through257placements plus fixed129placement scans. Zero ACKs must reach every pending resource; exact event offers and final drain gate readiness. Fixture peer, no TLS/authentic Marshall, native fleet or concurrent appends.

This retired diagnostic/outbox/view evidence establishes only its historical
boundary. It does not establish the replacement SDK, spool, Grafana or protocol.

### Retired evidence lifecycle item 10

Pre-cutover source: `lilly/test/lifecycle/journal_test.exs` at baseline
`a99f74f06542798dc9ef288e77c99d480433fc57`.
Assertion: generated audit backlog release admits exactly after acknowledgment

Original scope: Generated acknowledged prefix at the 64-event cap preserves exact bytes on refused publication and resumes with one new event after capacity is returned; no real network partition.

This retired diagnostic/outbox/view evidence establishes only its historical
boundary. It does not establish the replacement SDK, spool, Grafana or protocol.

### Retired evidence lifecycle item 11

Pre-cutover source: `lilly/test/lifecycle/journal_test.exs` at baseline
`a99f74f06542798dc9ef288e77c99d480433fc57`.
Assertion: generated partial audit acknowledgments preserve new and unacknowledged events

Original scope: Generated partial and repeated local outbox acknowledgements with append after offer; exact durable event maps and reoffer, without cross-service delivery.

This retired diagnostic/outbox/view evidence establishes only its historical
boundary. It does not establish the replacement SDK, spool, Grafana or protocol.

### Retired evidence lifecycle item 12

Pre-cutover source: `marshall/test/marshall/compute/lifecycle_audit_test.exs` at baseline
`a99f74f06542798dc9ef288e77c99d480433fc57`.
Assertion: generated audit reoffers retain gapless cursors and exact rows

Original scope: Generated accepted, reoffered, gap, conflicting and stale-session histories compare every durable audit prefix with its permanent cursor; no Lilly outbox or real restart.

This retired diagnostic/outbox/view evidence establishes only its historical
boundary. It does not establish the replacement SDK, spool, Grafana or protocol.

### Retired evidence lifecycle item 24

Pre-cutover source: `marshall/test/marshall/compute/lifecycle_audit_test.exs` at baseline
`a99f74f06542798dc9ef288e77c99d480433fc57`.
Assertion: expired audit histories retain fences and atomic future prefixes

Original scope: Real Lilly Client and actual Marshall API exchanges over verified loopback HTTPS. One to three HTTP503 substitutions after successful sandbox ingestion exercise unobserved replies before replay and actual production retention sweep. Raw physical event-ID inventory, cursor continuity, obsolete replay suppression, rollback of valid prefix before ownership/conflict/gap refusal, and unchanged VM/reservation/operation/placement records. Four sampled draws each include fixed 1/2/15/16-event and retained-conflict/full-expiry witnesses. No durable commit outside SQL sandbox, real socket loss, independently deployed Lilly outbox, Oban cron, restart, competing process or native/hosted claim. Focused execution and full Marshall precommit passed; merged handbook gates also passed.

This retired diagnostic/outbox/view evidence establishes only its historical
boundary. It does not establish the replacement SDK, spool, Grafana or protocol.

### Retired evidence clone item 1

Pre-cutover source: `marshall/test/marshall_web/provisioner_api_test.exs` at baseline
`a99f74f06542798dc9ef288e77c99d480433fc57`.
Assertion: malformed v3 documents are permanent client errors on every action

Original scope: Generated malformed v3 documents over all lilly.* control-socket ops including clone answer invalid_message and preserve the authenticated host row; malformed JSON is refused by the socket envelope before dispatch. No concurrent transport or Lilly retry claim.

This retired diagnostic/outbox/view evidence establishes only its historical
boundary. It does not establish the replacement SDK, spool, Grafana or protocol.

### Retired evidence fleet-monitor-delivery item 2

Pre-cutover source: `nix/tests/evaluation/fleet-monitor.py` at baseline
`a99f74f06542798dc9ef288e77c99d480433fc57`.
Assertion: test_conflicting_sample_refusal_retains_neighbors_until_poison_removed

Original scope: Isolated Python spool and deliver with generated poison position and retries, stubbed HTTPS 400 response and manual removal before valid ACK

This retired diagnostic/outbox/view evidence establishes only its historical
boundary. It does not establish the replacement SDK, spool, Grafana or protocol.

### Retired evidence fleet-slo-read item 2

Pre-cutover source: `nix/tests/machines/otel-marshall/seed.exs` at baseline
`a99f74f06542798dc9ef288e77c99d480433fc57`.
Assertion: Marshall.Telemetry.SloBurnRead.snapshot()

Original scope: Packaged reader accepted the real local Prometheus 24-rule API; Chromium verified unknown burn states without seven-day history, ordinary-reader admission and active/remembered credential revocation. No native firing alert or production reader claim.

This retired diagnostic/outbox/view evidence establishes only its historical
boundary. It does not establish the replacement SDK, spool, Grafana or protocol.

### Retired evidence fleet-slo-read item 8

Pre-cutover source: `nix/tests/machines/otel-marshall/browser.py` at baseline
`a99f74f06542798dc9ef288e77c99d480433fc57`.
Assertion: expect(page.locator("#slo-ingress p").first).to_have_text("Unknown")

Original scope: Packaged Marshall Chromium journey against local Prometheus with disposable WireGuard peers: anonymous refusal, ordinary magic-link admission, known-down collector, absent ingress and stored-login revocation in active and stale browser contexts.

This retired diagnostic/outbox/view evidence establishes only its historical
boundary. It does not establish the replacement SDK, spool, Grafana or protocol.

### Retired evidence fleet-slo-read item 11

Pre-cutover source: `nix/tests/machines/otel-marshall/browser.py` at baseline
`a99f74f06542798dc9ef288e77c99d480433fc57`.
Assertion: expect(page.locator("#slo-underclass_monitor")).to_contain_text("Seven days: Unknown")

Original scope: Rebased two-node packaged Chromium reader checks the provisional roster remains unknown before seven days, and revokes both the ordinary reader's active login and remembered credential before active and copied browser refusal.

This retired diagnostic/outbox/view evidence establishes only its historical
boundary. It does not establish the replacement SDK, spool, Grafana or protocol.

### Retired evidence underclass-proxy-slo item 4

Pre-cutover source: `nix/tests/machines/otel-marshall/browser.py` at baseline
`a99f74f06542798dc9ef288e77c99d480433fc57`.
Assertion: #slo-underclass_proxy

Original scope: Ordinary signed-in Chromium reader sees the durable proxy card, 99% provisional target, unknown seven-day value and unknown burn windows; revocation still refuses active and copied browser sessions. No production history or alert delivery.

This retired diagnostic/outbox/view evidence establishes only its historical
boundary. It does not establish the replacement SDK, spool, Grafana or protocol.
