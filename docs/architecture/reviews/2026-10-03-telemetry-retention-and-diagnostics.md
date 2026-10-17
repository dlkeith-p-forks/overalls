# Telemetry retention and diagnostics review

## Architecture impact

ADR-0138 adds ninety-day metric/trace retention, fixed prioritized diagnostics,
an isolated loopback capacity probe and an additive Underclass latency journal.
The seven-day objective horizon, source eligibility and authorization remain
unchanged. Review includes root/Nix/application contracts, histogram consumers,
source rosters and signed-in projection boundaries.

## Baseline and findings

The live 57-panel dashboard audit queried every expression over seven days,
confirming empty results at one-minute resolution: 49 panels lacked finite data.
Fourteen idle five-minute completion panels, fifteen latency panels and all
twenty seven-day objectives were empty. Three scrape targets and all recording
groups were healthy. Fresh recorder sources had just started; collector history
had approximately four days. About eighteen percent of recent Underclass
durations exceeded its ten-second finite histogram. The new histogram does not
infer those historical durations.

The public Grafana certificate fix activated healthy at `ef8e997f`. Its temporary
HAProxy recovery override was removed; validated reload and HTTPS login200
passed afterward. No operator credential entered diagnostics.

## Verification

The isolated patched Underclass module passed twelve focused checks, including
generated histogram conservation, legacy migration and refusal of missing
previously initialized histogram state. The focused Marshall selection passed
thirteen checks (six properties and seven tests), seed150245. The generated
Prometheus diagnostic cases passed in81seconds, including missing/stale source
precedence, warmup, coverage gaps, inactivity and history eligibility. These
generated Nix cases are deterministic evaluation fixtures, not randomized
application properties. Subsequent final execution is recorded below.

The final public Grafana native check passed in 100.29 seconds. It exercised
authenticated HTTPS, the 59-panel dashboard, effective `90d` metrics retention
with size deletion disabled, and the hardened read-only loopback capacity probe.
Both Overalls and Dungarees deployment toplevels built successfully in 202 seconds;
these builds do not establish activation. Rust receiver tests and Clippy passed
with the independent versioned histogram sampling clock.

An initial Rust fixture had swapped validator arguments; the Nix compiler gate
refused the build before native execution. The correction preserves the guard.
Existing scalar Prometheus fixtures omitted host placement; the roster check
correctly rejected them. Their reviewed legacy scalar inputs now receive the
declared hosts, while explicit missing-host and stale histories remain unchanged.

The interpolated p95 fixture produced 28.999999999999996 seconds versus the
expected 29 seconds; Prometheus's one-bit fuzzy comparison handles this rounding.
The native histogram assertion initially used Prometheus's normalized `30.0`
label against the direct collector, which exports `30`. The fixture now matches
the direct collector label; production Prometheus rules retain their normalized
labels. Migration preserved totals and measured the twelve-second response before
that assertion correction; final complete native execution remains separate.

The corrected complete Underclass native check passed in 103.41 seconds. It
preserved legacy lifetime and totals through migration, exported the twelve-second
duration into the extended histogram, finalized an admitted SIGKILL interruption
once without inventing a duration, checked independent exporter custody, and
withheld freshness after stopping the exporter.

The existing packaged Marshall crash fixture also exposed a synchronization
race: a snapshot emitted immediately before SIGKILL could satisfy its clock
wait, allowing the next request before the replacement recorder started. The
fixture now waits for the restarted unit and a subsequent snapshot before that
request. Its exact lifetime, totals, producer PID and post-crash accounting
assertions remain intact; this changes fixture ordering only.

The corrected packaged Marshall native check passed in 169.69 seconds. It
exercised source lifetime through recorder and producer crashes, all seven durable
workflow sources, forty healthy inactive burn evaluators, signed-in diagnostic
elements and ninety-day explanation, and revocation refusal in the real browser.
The full Marshall suite passed 1,425 checks (224 properties and 1,201 tests),
two exclusions, seed255881, in1762.1seconds. Its remaining precommit stages are
recorded separately after completion.

Marshall's full `mix precommit` exited zero: compiler, runtime, contracts, logging,
distributed suite, browser/workspace gates and forced Dialyzer passed. Forced
Dialyzer completed in41.41seconds with zero errors, skips or unnecessary skips.
Final receipt and all-file hook rechecks cover subsequent documentation and fixture
corrections; those corrections do not change the tested application behavior.

The two-host collector run reached the existing guest rate-limit assertion,
whose shell comparison incorrectly included literal escaped quote characters
around the numeric status. A standalone shell reproduction rejects even status
429. The fixture now accepts 200 until 429 and immediately rejects any other
status; production receiver limits are unchanged.

The corrected complete two-host collector native check passed in 624.87 seconds.
It exercised authenticated fleet transport, 59-panel provisioning, trusted
application and guest provenance, native intake limits, collector and ingress
outages, and durable trace replay after a worker restart while central was down.
The final Prometheus checks passed nineteen generated diagnostic/latency cases
and the existing SLO rule suite. The extended histogram produces an interpolated
29-second p95; frozen and three-second-future histogram clocks withhold it.

Executed native archives are `1790994353581-2332965-0.jsonl` (Grafana),
`1790994704557-2552766-0.jsonl` (successful Underclass scope; later collector
fixture failure), `1790995278319-2993013-0.jsonl` (Marshall), and
`1790995736317-3298120-0.jsonl` (successful collector and Prometheus checks).
All-file contracts, logging, handbook, Ruff formatting/lint and ty gates passed.
Final diff review preserves ADR-0132/0136 eligibility and accounting authority;
ADR-0138 remains partial because long-term production observation is pending.

Rollout inspection found that versioned histogram clock checks followed the
latency inactivity check, contrary to the diagnostic precedence contract. The
correction checks histogram presence and freshness before warmup and inactivity;
ratios, p95 eligibility and seven-day semantics are unchanged. Twenty-two
generated Prometheus cases passed, including idle missing/frozen/fresh histogram
clocks with respective status codes 1/2/5. The correction's archive is
`1790997325313-333408-0.jsonl`; existing native UI status mappings remain unchanged.

## Production configuration inspection (2026-10-03)

Read-only inspection after rollout observed Prometheus retention `90d` with
size deletion disabled (`0B`), and the active Tempo compactor's block retention
`2160h0m0s`. Unused backend scheduler/worker defaults are not evidence of the
active compactor policy. Public Grafana login returned HTTP 200; its provisioned
dashboard contains 59 panels, defaults to `now-90d`, and includes the source
status and measurement evidence tables. All 272 evaluated rules reported healthy:
20 seven-day objectives, 40 burn alerts and the diagnostic/capacity groups.

The storage probe reported approximately 34 MiB of metrics, 6.5 KiB of traces
and 1.3 TB of available root space. These are current observations, not a future
ninety-day trace capacity guarantee. Comparing the sampled Underclass, Marshall
readiness, Lilly physical and Porsche physical snapshots with their pre-rollout
baseline preserved every incarnation and birth timestamp, nondecreasing counters
and `requests = successes + failures`. No historical durations were invented.
Live diagnostics distinguish idle sources, seven-day history warming, stale
monitoring and incomplete Underclass durations. No synthetic production activity
was generated to make these measurements appear available. This inspection does
not certify the final updater revision; deployment health is verified separately.

## Completion audit after final activation

Both Overalls and Dungarees reached `healthy` on `b7e29b8f` with zero updater
failures. Origin main matched that revision and the implementation worktree was
clean. After the five-minute objective group completed its first evaluation
following configuration reload, all 272 rules reported `ok`. The declared
20-objective roster provides collector target 99.9%, ingress target 99.5% and
the remaining application/monitor targets 99%; these remain provisional under
ADR-0132. Each objective has fast and slow burn evaluators, giving 40 alert rules.
Burn thresholds consume 2% of the seven-day budget in one hour and 5% in six
hours, with paired short/long windows and five-minute persistence.

Marshall's `/admin/slos` renders the fixed catalog, targets, seven-day readings,
fast/slow burn states and diagnostic evidence through its authenticated reader.
The recorded packaged Marshall browser check covers these cards and revoked
reader refusal. Configuration, code and passing fixture evidence establish
the surface; no production authenticated browser session was created for this
inspection. Source-specific full fault acceptance remains a separate gap.

The focused `otel-porsche-native` check passed in **688 seconds overall**, with
the VM script completing in **215.40 seconds**, archive
`1791002853808-94007-0.jsonl` and log
`/tmp/kittens-slo-audit-porsche-native.log`. It executes actual approved-key SSH
dispatch, requires the durable Porsche snapshot to contain at least one request
and success with conserved totals, and requires nonzero independently exported
collector success counters. This closes the prior focused check's driver-gate
gap. It does not establish every Porsche fault, physical lifecycle acceptance,
seven-day history or production notification delivery.

The serial `brady-fleet` check passed in **931 seconds overall**, with the VM
script completing in **472.02 seconds**, archive
`1791003832828-775657-0.jsonl` and log
`/tmp/kittens-slo-audit-brady-native.log`. Actual guest HTTPS requests produced
current-owner/execution attribution, at least two durable requests and successes,
conserved terminal and histogram counts and collector-visible application-labelled
request counters. Brady/Lilly restart preserved the guest process identity and
refreshed attribution; legacy owner-less command attribution left command bytes
unchanged. Fleet history received observations. Retained kernel flow labels
refused attribution after deletion and address reassignment, while a new flow
resolved to its new owner. This closes the earlier serial Brady acceptance gap;
it does not establish all recorder/application fault paths or production history.

The expanded `enrico-service` check passed in **88 seconds overall**, with the
VM script completing in **57.75 seconds**, archive
`1791005392272-1699164-0.jsonl` and log
`/tmp/kittens-slo-enrico-native2.log`. Two stale assertions called the removed
in-memory SLO endpoint; they now inspect the durable source. The actual packaged
Enrico producer remains alive through recorder SIGKILL, preserving source
identity and completed counters after a fresh snapshot. A clean application
restart also preserves these values and the published mirror. The ordinary
Git update/replay, source outage and recovery assertions pass against that
history. Pausing the real TLS Git origin leaves one durable admitted refresh;
killing the producer settles it as exactly one failure without adding a duration
sample. The published mirror remains readable and totals do not change again
during the bounded post-restart observation. This is local native application
evidence, not power-loss, complete overload/storage-fault or production history.

The initial draft failed the composed driver's type gate before execution:
bare dictionary narrowing inferred invalid key types. Explicit validated
`dict[str, object]` construction corrected the boundary; no unchecked cast or
type-gate exception was added. The source and test contracts preserve ADR-0136
accounting and custody. These fixture changes have no architecture impact:
production behavior, authority, protocol, targets and retention are unchanged.

The expanded `audi-dns` native check passed in **108 seconds overall**, with
the VM script completing in **75.34 seconds**, archive
`1791007371668-2818103-0.jsonl` and log `/tmp/kittens-slo-dns-native.log`.
The real packaged DNS role continues serving through recorder SIGKILL without
producer restart, preserving source identity and completed counters while
advancing coverage. Clean producer restart preserves settled history and
coverage; unclean idle producer SIGKILL advances coverage without resetting
completed outcomes. A later real TCP query adds exactly one success and duration
sample. The typed helper matches checkpoint identity, coverage and terminal
counts to the durable publication before comparison. Existing UDP/TCP authority,
expiry, outage and collector assertions also pass. This one-machine verified-TLS
publication fixture does not establish actual Marshall/Firecracker publication,
in-flight DNS producer loss, complete overload/storage faults or power loss.
The fixture-only change preserves ADR-0136 with no architecture impact.

The requested external delivery of burn alerts is incomplete: no notification
destination or credential provision has been supplied. The user has been asked
for the destination. Evaluator health and inactive alert state do not establish
delivery. The overall SLO implementation goal therefore remains active.

The expanded `otel-porsche-native` check passed, with the VM script completing
in **207.62 seconds**. Execution log:
`/tmp/kittens-slo-porsche-fault-native.log`. The composed driver type checks
passed before native execution. After actual approved-key SSH dispatch and
independent collector acceptance, recorder SIGKILL preserves settled checkpoint
identity and completed totals with the producer alive while advancing coverage.
Clean Porsche restart preserves completed history and coverage. Unclean idle
producer SIGKILL advances coverage without resetting completed history; a fresh
approved-key SSH `whoami` adds exactly one success and duration sample. This
fixture-only change preserves ADR-0136 and existing authority, with no architecture
impact. In-flight producer loss, physical lifecycle accounting, overload/storage
faults, power loss and production history remain separate acceptance gaps.

The expanded `brady-fleet` check passed, with the VM script completing in
**460.07 seconds**, log `/tmp/kittens-slo-brady-fault-native.log`. The composed
driver type checks passed before native execution. Actual guest HTTP/HTTPS
outcomes and independent collector acceptance precede the added fault checks.
Recorder SIGKILL preserves settled checkpoint identity and completed counters
with the producer alive while advancing coverage. Clean Brady restart preserves
completed history and coverage. Unclean idle producer SIGKILL advances coverage
without resetting history; a fresh real guest HTTP request adds exactly one
success and duration sample. The guest process identity remains unchanged.
Existing Lilly/Brady restart attribution, legacy command preservation, collector
history and stale-flow refusal after address reuse also pass. This fixture-only
change and correction of stale architecture-overview target wording preserve
ADR-0136 and existing authority, with no architecture impact. In-flight producer
loss, overload/storage faults, power loss and production history remain separate.

### Audi SSH unresolved admission extension (native execution recorded)

The new fixture targets establishment, not an already acknowledged command.
It pauses the actual Lilly connector, observes one durable pending admission,
and kills Audi. It requires exactly one failure without invented duration,
recorder survival, history continuity, fresh registered-key SSH recovery, and
unchanged guest process identity. Cleanup resumes Lilly. This strengthens
ADR-0136 verification without changing architecture or production behavior.

The first expanded execution failed before any admitted loss: the disposable
systemd SSH client exited127 because its executable search path was missing.
The original three restart cases passed. Log:
`/tmp/kittens-audi-inflight-native.log`. The fixture now supplies an explicit
system executable path and `TimeoutStartSec=90`; systemd correctly reported that
`RuntimeMaxSec` does not bound a oneshot service. The corrected native run passed
with the VM script completing in **420.26 seconds** and terminal build exit0;
the admitted-loss subtest passed in **5.07 seconds**. Log:
`/tmp/kittens-audi-inflight-native-fixed.log`. All three existing restart cases
also passed. The real connector pause reached one persisted admission before
SIGKILL. Recovery settled exactly one failure, preserved source incarnation,
original start, successes, duration count and every bucket, advanced coverage,
and retained the independent recorder PID. The disconnected client exited with
a nonzero status and an exit-code result; timeout did not masquerade as failure.
A fresh registered-key guest SSH request added one success and duration, and
the guest process snapshot remained unchanged after the full fault sequence.
Ruff formatting/lint, contract syntax/discovery, and both composed driver
lint/type checks passed. This records Audi SSH admitted establishment loss;
overload/storage faults, power loss, other sources' in-flight loss and production
history remain separate. Production configuration and authority are unchanged.

The same evidence audit corrects ADR-0132's stale 32-rule wording to the actual
twenty-objective/forty-alert roster, and reconciles its physical-journey status
with ADR-0133's recorded native NixOS/Ubuntu execution and production activation.
ADR-0133 now distinguishes recorded retained readiness-journal inspection from
unverified fresh production creation and live provider behavior. Accepted
rationale, targets and partial implementation statuses remain unchanged.

The combined tree preserves main's `cc94a616` waiting-mail authority properties
and `52cd07f1` pending-journal fairness oracle. Full Marshall precommit passed
**1,434 checks (233 properties and 1,201 tests)**, two exclusions, seed745177,
in1770.8seconds. Forced Dialyzer passed in41.75seconds with zero errors, skipped
warnings or unnecessary skips; wrapper exit0. Log:
`/tmp/kittens-audi-inflight-merged-marshall.log`. Full Lilly precommit passed
**475 checks (85 properties and 390 tests)**, seed447363, in70.5seconds; forced
Dialyzer passed in15.68seconds with zero errors or skips and wrapper exit0.
Log: `/tmp/kittens-audi-inflight-merged-lilly-ready.log`. The initial local Lilly
wrapper stopped before tests because this worktree lacked dependencies; fetching
the existing locked versions supplied that prerequisite without a lockfile change.

Combined all-file hooks and evaluated Nix handbook checks passed. Separate ADR,
generated-reference, coverage and topology checks and native helper contract
syntax/discovery also passed. The helper and callers were reviewed against their
directory and local obligations; no contract mismatch was found in this scope.
Nix annotations remain manually reviewed because the pinned CLI does not parse
Nix. These checks preserve the native420.26second acceptance scope above.

Before publication, both hosts were healthy on main `52cd07f1` with zero updater
failures. All272 Prometheus rules, including40 provisional burn alerts, were
healthy; none of the burn alerts fired and all20 objective statuses were warming.
Prometheus reported90-day retention. Tempo's active compactor reported2160hours,
and its runtime service inventory confirmed that the compactor was running;
the inactive backend-worker defaults do not establish active retention.
Grafana HTTPS followed its authentication redirect to HTTP200. These observations
do not establish seven-day compliance, ninety days of collected history or
external notification receipt.

The earlier expanded `otel-audi-ssh-native` check passed serially, with the VM script
completing in **408.40 seconds**, log `/tmp/kittens-request-slo-audi-serial.log`.
The composed driver type gate passed before actual native execution. Registered-key
OpenSSH reaches the real Firecracker guest and independent collector counters
before the shared transport fault helper runs. Recorder SIGKILL preserves settled
identity, terminal totals and histogram buckets with the producer alive while
advancing coverage. Clean producer restart preserves history and coverage,
including after a fresh request. Idle producer SIGKILL advances coverage without
resetting history. Each recovery accepts a real SSH command adding exactly one
success and duration sample; guest process identity stays unchanged. In-flight
loss, overload/storage faults, power loss and production history remain separate.
This fixture-only extension preserves ADR-0136 with no architecture impact.

The initial combined Galileo/Audi run failed Galileo's existing `direct-denied`
assertion before reaching the new fault checks; both fleets logged control-plane
availability failures. The serial Galileo rerun reproduced the same assertion.
Its trace shows Marshall authorization403 and Galileo's unauthorized event;
the fixture incorrectly expected503 despite the documented guest403 behavior.
The fixture now requires403, distinguishing authorization refusal from unavailable
authority. Production behavior is unchanged. Neither failed run is passing native
evidence. The fixture dispatch interface has an explicit typespec. The pinned
contract CLI does not support `.exs`; this declaration's contracts were reviewed
manually, and pinned Elixir parsed the complete script successfully.

The corrected Galileo run passed denial/grant/detach and actual collector
acceptance, then recorder loss and clean producer restart. Its idle SIGKILL
fresh-request check failed while the dependent Audi private service was restarting.
The recovery callback now waits for both Galileo and Audi private readiness
before sending the single measured guest request. No request retry masks a
failed outcome. This failed run does not establish complete transport acceptance.

The following run passed all three Galileo fault subtests but found legitimate
background Audi private requests racing the exact-count assertion. Real guests
refresh SSH authority every two seconds through Audi private. The isolated
accounting interval now stops both fixture guests' refresh timers/services and
restores their timers in `finally`; guest execution and HTTP forwarding remain
real. Production traffic and configuration are unchanged. The diagnostic rerun
was stopped while awaiting an impossible exact total under continuing refreshes;
it is not passing full-check evidence. Counter/identity-only diagnostics contain
no authority tokens, paths, arguments or terminal bytes.

Pausing SSH refresh alone still left one legitimate request: fixture guests also
run an agent supervisor. The pause now includes agent polling and restores its
service in `finally`. With both pollers paused, all six Galileo/Audi private
recorder/producer recovery subtests passed, as did unchanged guest process
identity, upload/load, execution fencing, peer ingress and relocation. The final
control-plane outage assertion exposed another stale use of `direct-denied`:
unavailable authority expects503, authorization refusal expects403. Separate
closed fixture actions now enforce those exact classes. The full check remains
pending its final rerun; passing subtests do not make the failed overall run green.

The current Marshall full precommit gate passed on the combined `feafe943` base
with the transport evidence changes: **227 properties and 1,201 tests passed**,
two excluded, seed213392, 1619.1 seconds; forced Dialyzer reported zero errors.
Log `/tmp/kittens-request-slo-marshall-precommit.log`. Its isolated partition is
`_slo_transport_20261003`. Later native fixture changes do not alter Marshall
application code or test semantics.

Marshall's full precommit gate passed on `c975c445` using the isolated test
partition `_slo_c975_20261003`: **227 properties and 1,201 tests passed**, two
excluded, seed885879; forced Dialyzer reported zero errors. Log:
`/tmp/kittens-slo-brady-marshall-precommit-isolated.log`. The initial run against
the default database found old fixture rows and was stopped; it is not a passing
gate or established application regression. The retained old database was not
modified to obtain the passing result.

The final expanded `otel-galileo-native` check passed, with the complete VM script
finishing in **860.71 seconds**, log `/tmp/kittens-request-slo-galileo-final.log`.
Its composed driver type gate passed. Actual guest forwarding and collector
acceptance precede all six Galileo/Audi private fault assertions. Recorder loss
with producer alive preserves settled identity, terminal totals and histogram
buckets while advancing coverage. Clean restart preserves history and coverage,
including after a fresh request; idle producer SIGKILL advances coverage without
resetting history. Each recovery's single real guest request adds exactly one
success/duration. The guest process remains unchanged. Fixture SSH refresh and
agent polling resume in `finally`; existing upload/load, execution fencing,
cross-host peer ingress, real relocation and all-Marshall outage/recovery pass.
Authorization refusal403 and authority outage503 have separate exact assertions.
These fixture/evidence changes preserve ADR-0136 with no architecture impact;
in-flight producer loss, overload/storage faults and power loss remain open.

## Remaining gaps

Ninety days of production observation, future trace storage capacity, complete
eligible seven-day compliance and external notification delivery remain open.
Existing all-source fault/physical retry-cancellation acceptance gaps are not
closed by diagnostic or histogram tests.

## Recorder whole-VM hard-stop acceptance

The expanded `otel-request-recorder` NixOS check passed: **66.87 seconds** of
VM script execution, including **12.13 seconds** for the whole-VM hard-stop
subtest. Log: `/tmp/kittens-recorder-whole-vm-loss-native.log`. The composed
driver lint and type gates passed. The fixture acknowledges one pending
admission before `machine.crash()` and requires a different kernel boot ID after
restart. Before the unchanged admission deadline, exactly one unknown-duration
failure settles. Source identity, exclusions, successful history, duration sums
and histogram buckets survive; admission IDs are not reused. Late completion
refuses and a fresh authenticated admission succeeds. Existing recorder checks
also pass. This establishes virtual-host recovery of the Rust recorder core;
hardware power loss and per-application host restart remain unverified.

Architecture impact is verification-only: ADR-0136 remains accepted/partial,
with no production behavior or decision change. The monitoring handbook now
corrects stale pre-deployment descriptions of empty source hooks and records
this execution without extending its scope to application adapters.

Published revision `75e8959e8d2815eb56d91b41cc927b2298ff26f9` was verified
healthy on Overalls and Dungarees. Overalls initially recorded activation and
restore failures; its normal automatic retry subsequently succeeded. No cause
was established and no speculative updater fix was applied. Both updater units
then reported successful completion with zero failures, all 272 Prometheus rules
were healthy, all 20 objectives were warming, and both hosts retained metrics
for 90 days. Active Tempo compactors retained traces for 2160 hours. This records
observed recovery, not a diagnosis or additional updater fault acceptance.

## Whole-VM evidence publication and deployment

Revision `125691ca09fc5b231bf3d73ce2c23f15b04fe57a` publishes the passing
recorder-core whole-VM test and handbook corrections. Overalls and Dungarees
both reported healthy activation with zero updater failures; both updater units
finished inactive/dead, Result success and ExecMainStatus 0. Overalls' first
attempt emitted `update.failed` with phase activate and reason activate_failed.
The normal retry succeeded. No cause was established and no updater change
was made; private attempt logs were not disclosed. This is a second observed
activation retry, not a diagnosis or fault-test acceptance.

After deployment, Prometheus reported all 272 rules healthy, including all 40
burn evaluators. All 20 `kittens:slo_status{window="objective"}` series were
warming (code 6). Other window labels are distinct observations and do not
increase the objective roster. Active metric retention remained 90 days.
This establishes deployment/rule health, not seven-day eligibility, external
notification receipt, or the still-running native clone retry/cancellation test.

## Clone retry/cancellation native acceptance in progress

Two initial `cloning-fleet` builds stopped at the composed driver type gate,
before VM execution. A cancellation receipt reused a variable previously
narrowed to a different typed receipt. A distinct object boundary now validates
the string-keyed result and canonical UUID; composed typing and lint then passed.
The following full native run reached the new clone source-restoration retry
accounting subtest, which passed in **8.34 seconds**. Exact public receipt/clone
binding, successful completion within its original deadline, aggregate/histogram
conservation and unchanged terminal row/source totals after replay were checked.
Log: `/tmp/kittens-workflow-retry-cancel-native-validated.log`.

That overall run failed before cancellation at the existing OSS cross-host
placement assertion. Retained shape equality had already passed; this is not
established shape corruption. The fixture still assumed a two-core restart hold
forced another host, although the native provisioners now expose eight cores.
The corrected fixture derives a requested shape exceeding half the uniformly
observed core count and waits for fresh measured headroom on both hosts. The
production startup hold then prevents same-host copy without fabricated capacity
or changes to admission. Cross-host placement and all shape/storage/guest assertions
are preserved. The corrected complete run remains pending; the passing retry
subtest does not establish full clone matrix or cancellation acceptance.
Architecture impact is verification-only; production placement, receipt and
measurement authority are unchanged. Relocation destination retry/cancellation
remain distinct native measurement paths.

## DNS admitted-loss fixture review

The new test-only DNS package wrapper executes the unchanged source-built Audi
release and enables release process control exclusively on loopback, with a
synthetic fixture cookie. EPMD and the role's distribution listener must bind
127.0.0.1; no firewall port is added. Production DNS retains distribution none.
The typed fixture helper suspends Directory and traces only the producer client's
admit return. A reference ticket proves actual acknowledgement before the real
DNS worker is held. The suspending tracer stays alive until whole-producer loss;
its exit would resume the worker. No admissions, outcomes, routes or deadlines
are injected. The private marker contains only a fixed phase word.

The Python driver strengthens history comparisons with duration sums and all
buckets. It sends an actual eligible TCP question, observes one pending admission,
kills the producer and requires one failure before the unchanged deadline with
no invented duration, recorder survival, unchanged completed history, client exit
before its timeout and a fresh successful DNS question. The new fixture is present;
execution is pending. Its initial driver-only build passed composed typing/lint;
later explicit loopback-listener assertions still need the final native run.
Repository contract checks and their 19 regression tests passed. This is a focused
architecture/contract review with verification-only impact under ADR-0136; no
production protocol, authorization, process-control capability or SLO decision
changes. It does not establish production distribution refusal or guest workflow
acceptance. Hardware, overload/storage and other adapters' in-flight gaps remain.

## DNS admitted-loss execution and clone readiness follow-up

The first admitted DNS run blocked in `systemd-run` because a oneshot launch
waits for completion. The client reached its own 25-second timeout before the
driver could kill the producer; no admitted-loss acceptance follows from that
run. Adding `--no-block` preserves the real request and all original bounds.
The corrected native script passed in **89.06 seconds**;
the admitted DNS producer-loss subtest passed in **11.80 seconds**. Composed driver typing/lint,
loopback listener assertions and all earlier fault cases also passed. Log:
`/tmp/kittens-dns-inflight-native-nonblocking.log`. Exactly one failure settles
before the original deadline, without a duration or change to completed history,
identity, sums or buckets. The recorder survives; the client exits unsuccessfully
before timeout and a fresh successful DNS request adds one measured completion.
ADR-0136 remains partial: other adapters and overload/storage/hardware faults
retain their separate acceptance gaps.

The majority-core clone run passed the retry subtest in **7.97 seconds**, retained
OSS shape, cross-host placement and distinct native ZFS identity/origin checks,
then failed the copied guest's public start before cancellation. Physically
running observations did not establish guest readiness; the cause remains
unproven. Log: `/tmp/kittens-workflow-retry-cancel-native-headroom.log`.
The next native run adds fixed-unit activity and marker-presence booleans on
that failure path. Console contents and unit environments remain private; the
original start, placement and cancellation assertions are unchanged. These
fixture changes preserve production readiness and accounting authority.

The readiness-instrumented rerun failed earlier at the existing published-clone
relocation refusal assertion (composed lines 1896/1797), before either new
measurement subtest or OSS copied-guest start. Its destination was running,
native guest content verification passed and both transfer slots were held;
the observed receipt did not satisfy exact `transfer_busy`. The actual refusal
was not retained by the bare assertion, so no cause is established. Log:
`/tmp/kittens-workflow-retry-cancel-native-readiness.log`. A subsequent fixture
change exposes only finite allowlisted refusal labels and retains that exact
assertion; it does not accept alternative refusals or claim cancellation coverage.

Commit `61bb8754` was pushed to `origin/main` and both Overalls and Dungarees
activated it healthy with zero failures, inactive updaters, successful Result
and ExecMainStatus 0. Grafana's public-address HTTPS login returned 200;
Prometheus retained 272 healthy rules including 40 burns. Underclass monitoring
temporarily became unknown while its five-minute sample count was nine per
host; both returned to ten and all twenty objective statuses returned to warming.
The unchanged freshness/sample guards correctly refuse incomplete evidence.

Post-activation retention verification reports Prometheus `90d` and Tempo
2.10.5's active compactor retention `2160h`. Tempo's status configuration also
contains unused legacy/user-configurable fourteen-day defaults. Its running
`tempo_limits_defaults{limit_name="block_retention"}` is zero and no active
tenant override is exposed. Version 2.10.5's `tempodb/retention.go` uses a
nonzero tenant override in preference to the global setting; zero retains the
global value. This confirms the effective ninety-day setting rather than
inferring it from one matching status field. Actual oldest retained history
and trace-capacity acceptance remain separate; no history is backfilled.

The refusal-instrumented native run passed exact `transfer_busy` refusal and
the retry measurement subtest in **9.11 seconds**, then again failed the OSS
copy's bounded public start before cancellation. Shape, cross-host placement
and native ZFS independence assertions passed. The guest diagnostic helper
failed at `connect` with `MatchError`, so no guest service booleans were obtained.
Log: `/tmp/kittens-workflow-retry-cancel-native-refusal.log`. The earlier
intermittent refusal's cause remains unknown; this pass does not erase it.

The fixture now distinguishes terminal intent, boot, claim, vsock, creation and
attachment stages using closed labels. A disposable observer captures thirty
host boot snapshots over sixty seconds while the actual start is pending,
rather than relying only on post-timeout state. Each snapshot contains exactly
nine booleans from validated native intent/boot readers; private file contents,
boot challenges and identifiers do not enter it. Unlocked snapshots may race
transitions and never supply authority or outcomes. The output is a fixed
root-owned mode-0600 file; the typed driver validates its exact schema before
printing. No deadline or native assertion changes. Static formatting/lint and
contract checks passed; composed typing and native execution remain pending.

## Continuing boot adoption and current-generation readiness

Source review found a definite bookkeeping discrepancy: lifecycle start advances
generation even when the VM is already running, while Driver's running/adoption
paths advanced native intent without advancing the boot journal. `Boot.current/3`
then refuses the mismatched generation, and current-generation trust/readiness
cannot finish. This is a source finding; the exact earlier native failure's
journal fields were not captured. The early-observer build failed composed
typing before VM execution because reflective TypedDict key inspection narrowed
external dictionaries to `Never`. An explicit nine-key schema and a validated
string-key object boundary replace that reflection without unchecked casts.

The repair adds `Boot.adopt_generation/2` under placement ownership and proven
native VMM confinement. It requires the exact current running intent, the same
placement and execution epoch, and a nonregressing generation. It preserves
the physical boot challenge and synchronizes durable state. Both production
callers are in Driver: the already-running launch branch now proves confinement,
and existing physical adoption performs the same journal correction. Missing
boot state remains admissible only for legacy physical observation with
provisioning readiness disabled; it creates no proof and `Boot.current/3`
continues to refuse it. Corrupt or foreign state cannot be replaced.

Current-generation trust/readiness remains mandatory before a running outcome.
An unchanged physical boot may reuse its trust receipt under ADR-0113; new
provisioning evidence still uses the current generation and its retained deadline.
The repair neither restarts the VMM nor relaxes current/3, substitutes an older
readiness acknowledgement, or changes measurement/cleanup authority.
Architecture impact: implementation correction within ADR-0004, ADR-0017,
ADR-0113 and ADR-0133. Native continued-process, stale-generation refusal and
full component acceptance remain required before production publication.

The focused journal/adoption run passed **11 checks (2 properties, 9 tests)**,
seed `952978`, in **2.6 seconds**. Log:
`/tmp/kittens-continuing-boot-properties.log`. Generated isolated file histories
cover repeated advances, replay, old authority, foreign placement/epoch,
future-generation, corrupt and missing state. This verifies metadata arithmetic
and durable rereads, not VMM confinement or physical boot/guest availability.
Full Lilly compiler, test and forced Dialyzer gates remain pending.

### Continuing-boot component gate

The serial Lilly `mix precommit` passed **478 checks (87 properties, 391 tests)**
in **77.0 seconds**, followed by forced Dialyzer with **zero errors, zero skips,
zero unnecessary skips** in **15.22 seconds**. Log:
`/tmp/kittens-boot-generation-precommit-serial.log`. The preceding attempt had
one existing 100-millisecond audit-lock helper wait failure under build contention;
its focused rerun passed. That focused run conflicted with the preceding
Dialyzer artifact read, so only the subsequent serial complete gate is recorded
as passing. Contracts structural checks passed for 117 CONTRACTS files and 2,361
native notes; these do not establish semantic correctness or native acceptance.
The evaluated Nix HLDD check also passed. The repaired native clone run is still
pending; no production deployment of this repair is claimed.

### Repaired native continued-boot scope

The repaired `cloning-fleet` run passed composed driver typing/lint and native
retry measurement with exact receipt replay in **8.83 seconds**. It then passed
the OSS cross-host shape and independent ZFS identity checks, **repeated public
Start with unchanged native process snapshot**, inherited guest marker, divergent
writes and subsequent cleanup. The run failed later at composed line 2316:
`assert vm_state(cancelled_destination) == "stopped"`, before public cancellation.
Log: `/tmp/kittens-workflow-retry-cancel-native-generation-fixed.log`.
This records native continued-process readiness for the repaired scope; it does
not establish completed cancellation accounting or a passing full clone matrix.

The cancellation precondition was incorrect: `vm_state` reads observed state,
and allocation defaults to `pending`, while desired state is stopped. No stopped
execution receipt exists before destination publication. The old polling also
allowed `publishing` and did not establish native transfer custody. The corrected
fixture seeds a fixed 512 MiB incompressible witness inside the disposable guest,
requires exact copying phase, one offered unfinished copy effect, an existing
native stream lock with exact contention exit 75, no publication/start operation,
pending observed state and independent absence of a running destination VMM.
No phase, receipt, deadline, capacity or outcome is manufactured. Public
cancellation and all retained cleanup/measurement assertions remain required.
The corrected full native run is pending; seed data and lock contention are not
production configuration or deployment changes.

### Admitted native cancellation scope

The corrected copying-window run passed **native retry measurement in 8.87
seconds** and **native cancellation measurement in 8.48 seconds**, each with
exact receipt replay and unchanged terminal row/source totals. Cancellation
began with an existing occupied stream-owner lock (exact flock contention exit
75), an offered unfinished copy, pending destination observation and no
publication or destination Start operation. Source restoration, original disk
GUID, destination archival/dataset removal and transfer-slot release passed.
The run continued through stopped-source browser cloning and then failed a
later cloned-guest public relocation with **source_unavailable**, at composed
line 2432 (`relocate_porsche_clone`). Log:
`/tmp/kittens-workflow-retry-cancel-native-copy-window.log`. Full matrix acceptance
remains unproven; the completed cancellation checks retain their narrower scope.

Production relocation uses this refusal for source host/pool freshness and
readiness or reservation mismatch. Exact prior failing input was not captured.
The disposable fixture now reads only fifteen boolean source predicates and
waits for settled current observations before its single public admission. It
neither retries a refused relocation receipt nor changes production freshness,
reservations or execution authority. Timeout emits only the validated booleans;
an unlocked preflight is observational and cannot authorize relocation. This
extension awaits native execution.

### Earlier activation refusal in the source-observation rerun

The source-observation rerun failed before retry/cancellation at the existing
published-clone recovery wait (composed lines 2022/1866), after the catalogued
`clone.failed` event with generic `activation_failed`. Source shows this event
is emitted for a terminal queued activation failure; its specific reason was
not recorded in that run. Log:
`/tmp/kittens-workflow-native-source-observations.log`. The new relocation source
preflight was not reached; no native pass for that extension is claimed.
The same observational preflight now precedes the initial faulted clone
submission and requires actual host/pool receipts within one second, leaving
margin for the following public SSH request while production keeps its original
freshness guard. The publication wait fails immediately on terminal activation
failure and emits only an allowlisted reason. It does not retry a physical
failure, remove any assertion or manufacture an accepted admission. Native
execution of this extension remains pending.

### Source freshness observation boundary

The settled-source run failed earlier at original-VM relocation admission with
`source_unavailable` (composed line 1780), before any source preflight was
reached. Log: `/tmp/kittens-workflow-native-settled-source.log`. Applying the
preflight there produced an actual bounded diagnostic in the next run:
all thirteen non-freshness predicates were true, but the two **tightened
one-second freshness predicates were false**. Log:
`/tmp/kittens-workflow-native-all-source-preflights.log`. This does not identify
whether the unchanged production freshness window was violated. The earlier
reader fetched source rows separately before choosing its clock; reader delay
and sampling/startup alignment were not excluded.

The corrected fixture reads one MVCC snapshot with one materialized database
clock and validates an exact sixteen-boolean output schema. Configured host/pool
freshness and the stricter one-second `reports_recent` margin are separate.
Inventory readiness requires a JSON boolean, and the stored endpoint is checked
with the shared protocol validator internally, never emitted. Bounded sixty-second
polling occurs within the running fixture process instead of repeatedly starting
the release. Queries are read-only with five-second timeouts; missing rows,
invalid output and timeouts grant no admission proof. This changes no production
freshness, report, reservation, receipt or execution state. The full native
atomic-source rerun remains pending.

The atomic-source run executed the query and protocol validation successfully.
Its timeout returned **host_fresh=true, pool_fresh=true, reports_recent=false**,
with every other predicate true. Log:
`/tmp/kittens-workflow-native-atomic-source.log`. Configured freshness therefore
passed at the observed snapshot; the extra one-second margin did not. The fixture
now derives its margin from the configured window, reserving two seconds for the
following RPC (a three-second sample-age allowance under a five-second window).
The normal freshness checks remain independent and mandatory, and public
admission still revalidates its own source. No report timestamp is updated.
The budgeted native rerun remains pending.

### Final full native acceptance

The budgeted-source `cloning-fleet` run passed **the complete test script in
1539.61 seconds**, terminal exit **0**. The full native Porsche guest lifecycle
subtest passed in **1380.65 seconds**; clone audit after source deletion passed
in **0.13 seconds**. Native retry measurement with exact receipt replay passed
in **15.46 seconds**, and native cancellation measurement with exact receipt
replay passed in **8.40 seconds**. Log:
`/tmp/kittens-workflow-native-source-rpc-budget.log`.

This captured candidate includes the production continuing-boot repair and the
final atomic sixteen-boolean source observer with configured-window RPC budget.
The unchanged-process repeated public Start, inherited and divergent guest
markers, real occupied-stream cancellation, original source restoration/GUID,
destination archival/dataset removal, transfer-slot release, stopped-source
browser copy, both independent cloned-guest relocations, surviving copies after
source deletion, and retained physical audit assertions all passed. Source
preflight reads neither supplied authority nor altered telemetry. All original
OSS and physical recovery assertions remained enabled.

Architecture review: correction within ADR-0004, ADR-0017, ADR-0113 and ADR-0133;
physical nonce/epoch, confinement preconditions, current-generation readiness,
original accounting deadlines and immutable terminal outcomes remain intact.
No new domain, protocol, deployment role or dependency is introduced. The full
Lilly gate and scoped native acceptance support publication. Native foreign or
corrupt boot ownership refusal, relocation destination retry/cancellation
measurement and the remaining per-adapter in-flight/overload/storage faults
remain separate gaps. Seven-day compliance and 90 days of historical data are
not claimed; optional notification delivery still needs an approved destination.

### Underclass freshness cadence correction

Post-deployment inspection found the Underclass source clock approaching the
45-second freshness refusal boundary because the probe emitted every fifteen
seconds while the central fleet scrape and recording group ran every thirty
seconds. The correction preserves the 45-second guard and changes the probe to
five seconds, the central `kittens-otel` scrape to ten seconds, and the SLO
recording group to ten seconds. Marshall's evidence projection now includes the
Underclass source age. The NixOS fleet fixture asserts a fresh source clock
after the real probe, collector and Prometheus path starts. Rust probe properties
remain green; Nix rule evaluation passed. Deployment and sustained production
acceptance remain required before claiming a long-term freshness rate.
