# Durable physical SLO accounting review

## Workflow completion extension under implementation

The remaining clone, relocation, retry and cancel paths receive four separate
permanent sources. This preserves the three deployed sources' meanings, numeric
history and lifetimes. Compute owns a new receipt-bound measurement resource;
SSH captures a database admission clock before executing a mutation, then admits
its measurement in the same outer transaction as its canonical receipt.
Terminal audit evidence retains clone sequence and a closed outcome separately
from phase. Source-restoration failure remains failed evidence even without a
phase transition. A same-sequence restoration retry has a later admission clock.
Synchronous/no-op terminal cancellation may finish inside admission; subsequent
scans never refresh receipts or change execution. Relocation retry activation
alone cannot succeed: its exact immutable start operation needs physical running
and committed readiness. Missing evidence fails the measurement at its immutable
ten-minute deadline without cancelling work or releasing reservations.

Explicit cancellation and supersession retain terminal exclusion rows for the
original completion objective. They never add numeric successes or failures.
The cancellation command has its own completion denominator and succeeds only
on confirmed cancellation. Retry readiness, including failure, must match the
retained start operation's VM, relocation and generation.

Bounded scans lock only measurement rows, then serialize numeric addition in
their terminal transaction. Both measurement queues must drain overdue work
before publishing fresh sampling clocks. Each new source has one Overalls
exporter, isolated collector intake, a signed-in Marshall card, Grafana panels
and provisional 99-percent seven-day targets with the existing history guards
and seven-day budget burn factors. Migration initializes only the new lifetimes.
This extends ADR0133's existing measurement authority; it changes neither
workflow authorization nor boot/storage execution authority. Full application
gates passed; native clone/relocation measurement acceptance passed, while
native retry/cancellation acceptance and deployment remain pending.
Preceding records retain their scope.

The logging mutation heuristic has one reviewed exemption for the nested
workflow measurement admission. It adds no execution or authorization outcome;
SSH command outcomes remain catalogued after the outer commit, and publication
failure remains catalogued by the publisher. Emitting an admission diagnostic
inside the accounting callback would incorrectly report rolled-back work.

Extension verification on the current worktree passed nine focused checks
(two properties and seven tests) in 45.2 seconds, including real retry resource
transitions with physical running and readiness fences. A separate roster,
backlog and reader run passed 22 checks (12 properties and ten tests) in 44.6
seconds. The backlog fixture now checks all seven snapshot files and retains
conservation, immutable deadlines and withheld freshness assertions. One earlier
run encountered unavailable generated Ash worker modules during recompilation;
fresh compilation passed without changing the outcome assertions.
The pinned Rust package passed 18 library and three exporter tests. These results
do not establish native workflow completion or deployed seven-day history.

The extended packaged `otel-marshall` check passed in **458 seconds**, with
**115.09 seconds** of test script execution. It exercises all seven migrated
snapshot sources, distinct Rust exporter users, snapshot write refusal, real
collector provenance, all forty healthy inactive burn evaluators and the four
new authenticated workflow cards with provisional 99% targets and unknown
seven-day readings. Session revocation still refuses the browser. This proves
packaged custody and presentation, not real guest workflow outcomes or seven-day
history. Archive: `1790974530615-2901497-0.jsonl` in the local Nix build log store.

The extended two-node `otel-fleet` check passed in **655 seconds**, including
**605.78 seconds** of script execution. It verifies the real Nix-provisioned
Grafana dashboard has fifty-seven panels and retains guarded seven-day and
duration queries, authenticated fleet transport and restricted telemetry paths.
Archive: `1790974499854-2876630-0.jsonl`. The Rust source was subsequently
formatted without semantic changes; the native guest build includes that layout.

Review found that the native m1/m2/m3 fleet has no enrolled Overalls publisher.
Its private sentinel-fenced helper now invokes both production reconcilers and
includes all seven permanent source identities, counters and buckets in its
digest. The clone/relocation assertion invokes this helper before inspecting
measurement results. The earlier captured native build lacks this fixture fix;
its terminal result must retain that scope rather than establish extension
acceptance. That confirmed live build was interrupted with SIGINT after the
fixture defect was identified; its session returned exit 1. It was not restarted
because of an observation timeout. A corrected native run is now under way and
must pass before claiming native workflow acceptance.

The next captured run was also interrupted after review found that a global
successful workflow count could be supplied by earlier fixture work. The final
oracle joins the measurement to its exact canonical SSH request key and VM,
requiring exactly one successful clone and relocation measurement from this
journey. These interruptions reflect deliberate fixture corrections, not passing
execution. The final receipt-bound `user-ssh-journey-fleet` run passed in
**1191 seconds**, including **1129.22 seconds** of test script execution.
It requires exactly one successful measurement linked to each journey's
canonical clone/relocation receipt and VM. Both production reconcilers run,
and all seven source UUIDs, lifetimes, counters and buckets survive Marshall
restart unchanged. This establishes native clone/relocation accounting and
seven-source restart conservation; it does not establish native retry or
cancellation outcomes. Archive: `1790975911518-3803266-0.jsonl`.

The extended full Marshall suite passed **1,417 checks (216 properties and
1,201 tests)** in **1463.5 seconds**, with two excluded tests. This includes
the distributed tests requested by precommit. The full precommit gate returned
exit 0, including compiler, formatting and frontend checks. Forced Dialyzer
reported **zero errors, zero skips and zero unnecessary skips** in **107.11
seconds**, after a 28.45-second PLT check. Log:
`/tmp/kittens-slo-workflow-precommit.log`.

## Workflow production activation

Both hosts activated **6a0b3c328e337a34a5305b9e4fc9b4c2114a05e7** healthy
with zero updater failures. Seven permanent source rows are present. Comparing
the private pre-deployment projection with the post-deployment projection verified
the original three UUIDs and lifetimes are identical, all counters and buckets
are monotone, and numeric conservation holds for all seven sources. The retained
original totals remain 20/17/3 (`lilly_physical`), 8/0/8 (`marshall_ready`) and
17/6/11 (`porsche_physical`); new sources begin at zero without altering history.
All four workflow exporter units are active and Prometheus sees four authenticated
application-origin request series. Live Prometheus contains twenty objective
definitions and forty healthy inactive burn evaluators after their first execution;
authenticated Grafana contains fifty-seven
panels. Seven-day objective series are absent because history is insufficient.
These are provisioning and custody observations, not seven-day compliance or
production workflow completion evidence. Native retry/cancellation accounting,
other application crash accounting and external notification delivery remain open.

After merging upstream main, all-file static hooks passed (including typed driver
checks), ADR structure passed for 133 records, generated handbook coverage/options/
views checks passed, and the final Nix handbook and conflict-marker checks passed.
One initial command used nonexistent `checks.x86_64-linux.conflicts`; the corrected
`conflict-markers` check passed. The merge preserved upstream recovery and namespace
property evidence. The pre-merge full Marshall gate remains applicable because
the merged production Marshall source was unchanged.

## Initial physical scope and architecture impact

ADR-0133 adds two Compute resources, transactional operation/SSH measurement
admission, deadline classification, retained numeric totals and three isolated
Rust exporter intakes. ADR-0132 supplies their provisional seven-day policy;
ADR-0130 retains boot readiness authority. Measurement never replaces execution,
capacity, cleanup or receipt authority. This is substantive persistence and
telemetry work, authorized by the user's remaining-SLO implementation request.

## Reviewed boundaries

Canonical operation admission and accepted SSH receipt creation commit their
measurement together with the domain mutation. Failed outer transactions also
roll back the admitted attempts and leave migrated source totals unchanged.
The migration initializes the three fixed sources; admission only reads them.
Received evidence uses the database clock shared with admission and deadlines.
Provisioning readiness must match all retained
operation execution fields. Physical observations come from the immutable ledger;
receipt refresh is not called. Deadline failures do not change physical state or
release capacity. A Lilly restart alone supplies no failure evidence.

Each attempt finishes under its row lock and adds its fixed aggregate in that
transaction. Separate transactions avoid inversion across fixed aggregate locks;
least-recently-checked pending selection prevents starvation by early long work.
The publication instance is Overalls only, avoiding duplicate shared-database
series. Each exporter has a distinct static UID, numeric source-group read access
and one collector intake group, with no database or provider credentials.

## Recorded verification

Focused execution in the dedicated test partition `otel_slos_20261002` passed
16 checks: nine properties and seven tests, in 0.8 seconds (seed 11196).
This includes the expanded reader/burn roster and actual Ash admission/replay,
outer rollback, physical-only refusal of readiness, wrong-generation readiness,
matching readiness, permanent aggregate arithmetic and immutable-result refusal.
The control-plane observations are synthetic; this is not native guest evidence.

The pinned Rust package built and checked successfully in 33 seconds. Its new
generated lifecycle histogram check validates all three fixed service names,
the extended bounds in encoded OTLP, and refusal of short application bounds.
Archive: `/home/ghuntley/.local/state/nix/build-logs/1790952513207-1636298-0.jsonl`.
Evaluated Overalls configuration selects the source-built Rust exporter and the
fixed private snapshot and collector paths. This is configuration evidence only.

The initial expanded native browser/collector check passed in 405 seconds,
including the three source identities, signed-in cards and 32 inactive evaluators.
Archive: `/home/ghuntley/.local/state/nix/build-logs/1790953175907-2075629-0.jsonl`.
That build predates migration initialization and database-clock changes; final
native acceptance remains pending. The earlier full suite was stopped after
admission-time source initialization caused lock contention. It is not passing
evidence. The latest focused SSH checks passed five checks (two properties and
three tests), including original deadline reuse and unchanged receipt status.
The repaired fleet gate and merged native validation passed; deployed physical
guest measurement acceptance remains under verification.
No production activation of these three sources is claimed here.

The final migration-initialized native Marshall/collector/browser check passed
in 360 seconds. It verifies the three real Rust exporter units, mode-0640
snapshots, read-only exporter access, independent identities, fixed Prometheus
provenance, 32 healthy inactive evaluators and ordinary signed-in SLO cards.
Archive: `/home/ghuntley/.local/state/nix/build-logs/1790955043582-3383937-0.jsonl`.
The extended rules check passed in 57 seconds, including positive seven-day
readings for all three lifecycle sources and short-window refusal of wrong-host,
missing, frozen and future sampling clocks.
Archive: `/home/ghuntley/.local/state/nix/build-logs/1790954971082-3325755-0.jsonl`.
Generated handbook views, options and coverage checks and all-file precommit
hooks passed, including ruff, ruff-format and ty for the machine drivers.

The final Marshall suite in `otel_slos_20261002_physical` passed 1399 checks:
203 properties and 1196 tests, with two excluded, in 1080.7 seconds. The source
initialization change removes the earlier admission-time aggregate contention.
Compiler, contracts, reviewed logging and terminal/dashboard/workspace checks
also passed. Forced Dialyzer passed in 48.9 seconds with zero errors, skipped
warnings or unnecessary skips. The complete Marshall precommit command exited
successfully. The two fleet fixture attempts
failed on stale objective array positions. The repaired assertion selects actual
recording queries and additionally requires all three lifecycle objectives.

After merging upstream Galileo and fleet API repairs through `95b54709`, the
combined affected-path suite passed 81 checks (21 properties, 60 tests).
Forced Marshall Dialyzer passed with zero errors or skips in 55.32 seconds.
Protocol's complete precommit and Dialyzer gates passed on the merged tree.
These checks preserve the upstream closed-refusal, exclusive-cursor and SSH
object-response repairs alongside the new transactional measurement admission.

The repaired native fleet check passed in 634 seconds, including all 45 Grafana
panels and query-based assertions for the three new seven-day objectives, real
host collection, guest Unix receiver permissions and source/recovery windows.
Archive: `/home/ghuntley/.local/state/nix/build-logs/1790956191915-27552-0.jsonl`.
The combined invocation also passed the Nix handbook gate and browser check.
The subsequent HTTPS acceptance merge changes documentation and test helpers
only; all-file static hooks passed on that combined tree. No SLO production
receiver or application measurement implementation changed in that merge.

Merged native Marshall/collector/browser and handbook/browser checks passed
in 396 seconds. Archive:
`/home/ghuntley/.local/state/nix/build-logs/1790956683395-390788-0.jsonl`.
Final Nix handbook and conflict-marker gates passed under `C.UTF-8` in 14
seconds with no diagnostics. After the last browser-only upstream repair,
18 focused checks passed (10 properties, eight tests), followed by forced
Dialyzer with zero errors or skips in 49.03 seconds, all-file static hooks and
the Nix handbook/conflict gates. This preserves upstream input replacement
without changing SLO publication or execution authority.

## Deployment and remaining native evidence

Both Overalls and Dungarees activated `f8dd5632a71b06e9424c7fedf25a7eb5f88f4d99`
from origin/main and reported healthy with zero updater failures. Overalls runs
all three isolated Rust exporters. Each source has exactly one Prometheus
request series with fixed application provenance, Overalls host and instance.
All 32 burn evaluators are healthy and inactive; the authenticated Grafana API
reports 45 panels. Live snapshots are mode 0640, exporter-readable and not
exporter-writable, with database sampling clocks less than ten seconds old.
Their initial counters are zero; this does not establish physical journey
success or seven-day compliance. Readiness producers remain disabled pending
compatible native acceptance, and no notification destination has been supplied.

The three-check real-guest invocation failed after 689 seconds in the Audi SSH
fixture's enrollment precondition: `Idle capacity expires between reports`.
That precedes guest telemetry and physical SLO assertions. None of those three
checks is recorded as passing. The freshness assertion is preserved; rerun
native checks serially to investigate contention without weakening the gate.
Archive: `/home/ghuntley/.local/state/nix/build-logs/1790957483341-961055-0.jsonl`.

The fleet helper now invokes the real production reconciler under the private
database sentinel and hashes fixed source identities, counters and buckets.
New assertions require successful measurements from actual retained guest
physical/readiness evidence and unchanged nonzero totals after Marshall restart
and repeated scans. The agent fixture covers creation/readiness; the native
Porsche SSH journey requires all three sources for NixOS and Ubuntu. These
Porsche assertions remain under validation. They introduce no new
production authority, dependency, configuration or protocol.

The strengthened `otel-guest-native` check passed serially in **900 seconds**
with `--max-jobs 1`. The real guest/tool round trip passed, including successful
physical/readiness measurement, Marshall restart, identical permanent source
identities/counters/buckets and repeated reconciliation without double counting.
All six capacity samples were fresh. This proves the NixOS agent variant only;
it does not establish Ubuntu, Porsche, live-provider or seven-day acceptance.
Log: `/tmp/kittens-service-level-guest-serial.log`.
Archive: `/home/ghuntley/.local/state/nix/build-logs/1790960797383-2930550-0.jsonl`.
The subsequently moved helper contract is documentation only; runtime assertions
and production implementation are unchanged.

## Remaining requirements

The NixOS Porsche run passed the real creation subtest in 107.24 seconds,
including all three successful durable measurements, Marshall restart and
identical totals after repeated scans. The full journey subsequently failed
zero-key onboarding with unexpected direct SSH exit status 255. This is scoped
SLO subtest evidence, not a passing native journey. Archive:
`/home/ghuntley/.local/state/nix/build-logs/1790962523318-4063026-0.jsonl`.
The fixture now classifies unexpected stderr into fixed diagnostic categories
without printing raw identity/onboarding data. The strict exit assertion remains.

The serial Ubuntu Porsche attempt failed before SSH/SLO assertions at the
unchanged idle capacity freshness gate: one sample was 5.273019 seconds old.
Database checkout timeouts were also reported. Serial execution alone did not
resolve this precondition; contention remains a hypothesis. The NixOS Porsche
variant is being checked independently. Archive:
`/home/ghuntley/.local/state/nix/build-logs/1790961749930-3549702-0.jsonl`.

Source review found that a bounded scan could leave overdue measurements behind
and still refresh publication. The publisher now refuses fresh snapshots while
any pending deadline is overdue at its database sampling time. A sandbox-owned
102-admission regression passed: the first 100-attempt scan withheld freshness,
the next drained the backlog, totals and buckets conserved all 102 failures,
and execution operations remained pending. Focused execution passed **six checks
(two properties, four tests)** in `/tmp/kittens-service-level-backlog-tests.log`.
This preserves ADR-0133 measurement authority and deadline semantics; it changes
publication availability during backlog. The full Marshall precommit passed
**1,409 checks: 210 properties and 1,199 tests, with two exclusions**, in 1385.6
seconds. Forced Dialyzer passed with zero errors/skips in 62.16 seconds.
Compiler, contracts, logging, terminal, workspace and dashboard gates passed.
Log: `/tmp/kittens-service-level-backlog-precommit.log`.

The merge preserves current main's Galileo ownership, namespace cleanup and
terminal history changes. Focused merged execution passed **10 checks (six
properties, four tests)** covering SLO backlog, Galileo archival and terminal
takeover. Forced test-environment Dialyzer passed with zero errors/skips in
52.25 seconds. Nix handbook/conflict gates passed in 24 seconds; all-file static
hooks and generated views/options passed. Logs:
`/tmp/kittens-service-level-merged-focused.log`,
`/tmp/kittens-service-level-merged-dialyzer.log` and
`/tmp/kittens-service-level-merged-nix-governance.log`.

Enable verified provisioning readiness only after its reader and native acceptance
requirements are met. Complete native NixOS/Ubuntu Porsche measurements and
SSH completion with no receipt polling. Finish durable accounting in other application sources, native guest
provider paths, seven-day observation and notification delivery. SSH workflows
without a direct operation link remain outside this initial physical-command
denominator and must acquire their own retained workflow measurement.

## Subsequent serial acceptance and retained-boot activation review

The serial paired Porsche checks captured the backlog fix and redacted SSH
onboarding diagnostics before merge revision `3f7ebc11`. The **full NixOS
Porsche journey passed in 1206.15 seconds**: unchanged capacity freshness,
creation with all three durable SLO measurements, Marshall restart and repeated
reconciliation, zero-key onboarding, guest SSH/agent, certificate renewal,
relocation and reboot/cloning. The Ubuntu variant passed capacity freshness,
creation with all three durable SLO measurements and restart conservation,
onboarding, guest SSH/agent, certificate renewal and relocation. Its final
reboot/cloning stage failed with `Porsche command rejected`; this is partial
Ubuntu evidence, not a passing full Ubuntu journey. The rejection did not report
a status or workflow phase, so its cause remains unknown. The fixture now adds
only allowlisted status/error/phase categories and preserves its strict success
and timeout requirements. No response payload or stderr is printed on rejection.
Log: `/tmp/kittens-service-level-ssh-diagnostic-rerun.log`.
Archive: `/home/ghuntley/.local/state/nix/build-logs/1790963669485-536344-0.jsonl`.
The subsequent serial Ubuntu check with the earlier merged descriptor cleanup
failed in 283 seconds at the unchanged idle capacity freshness precondition,
before SSH/SLO or clone assertions. Twelve capacity-age observations ranged
from 1.632844 to 5.606897 seconds, including two above the five-second limit.
The archive contains DBConnection error reports, but no causal connection to
this freshness failure has been established. This run does not diagnose the
prior clone rejection. Log: `/tmp/kittens-service-level-ubuntu-merged.log`.
Archive: `/home/ghuntley/.local/state/nix/build-logs/1790967332238-2649422-0.jsonl`.
Later main changes, merged as `456e76a3`, include proc-less namespace inspection
and complete-pass audit recovery gating; they were not in this native snapshot.

Both hosts subsequently activated `3f7ebc11` with healthy updater state and
zero failures. Overalls had three active isolated Rust exporters, source-owned
0640 snapshots readable but not writable by each exporter, one correctly
labelled request series per new source, **32 healthy inactive burn evaluators**
and **45 Grafana panels**. Counters at that observation were readiness 8 requests,
0 successes and 8 failures; physical lifecycle 14 requests, 12 successes and
2 failures; physical SSH 14 requests, 4 successes and 10 failures. Readiness
producers remained disabled: missing readiness evidence does not prove guest
boot failure. Immutable measurement results must not be rewritten. These are
point-in-time publication observations, not seven-day compliance or alert delivery.

Retained-boot activation review found 25 running VM records at that observation.
`Lilly.VM.Executor.after_trust/5` with readiness enabled invokes
`Driver.provisioned` for adopted running executions; failed proof reaches
`readiness_failure` and the existing fencing path. A fresh-guest acceptance
result alone does not prove older retained boots compatible. A passive probe
was prepared to recheck confined current boot records without changing journals
or power state. Production Lilly uses `RELEASE_DISTRIBUTION=none`, and release
RPC returned `:noconnection`; **no guest probe ran**. Readiness remains disabled
until a supported passive verification path and retained-boot evidence establish
compatibility. This is an ADR-0130 activation gap, not a change to recovery
semantics. Notification destination and delivery remain unresolved.

## Pending measurement indexes

Source review found that the existing completed/admitted/ID index did not match
the production least-recently-checked pending scan or the overdue guard. Two
Ash-declared partial indexes now cover pending checked-at/ID ordering and pending
deadline lookup. The generated migration adds these indexes and its down path
removes only them; the matching resource snapshot is generated. The historical
index, immutable measurements, deadlines and transaction boundaries are preserved.
This implements ADR-0133's existing bounded accounting design without changing
measurement or execution semantics. It does not establish fleet throughput.

With the new migration, focused execution passed **six checks (two properties,
four tests)** in 4.8 seconds, including the 102-admission backlog conservation
regression. Log: `/tmp/kittens-service-level-pending-index-tests.log`.
Full Marshall precommit and packaged migration acceptance subsequently passed
for this follow-up candidate, as recorded below.

The follow-up diagnostics also recognize Porsche's fixed `timed_out` wait marker.
An accepted receipt whose wait expired remains distinguishable from a terminal
workflow failure; neither result weakens the fixture's required success assertion.

## Reader and retained-boot readiness activation candidate

The unsupported RPC attempt above was followed by a standalone release-eval
probe. It loads validated private local configuration, decodes at most 512
bounded v3 intent copies directly, and never opens or mutates the command store.
Existing private boot and lock files are required. Each probe uses the production
executor confinement guard and checks exact boot identity under the placement
lock on both sides of a bounded passive vsock readiness poll. It rechecks the
same durable intent and unchanged configuration, emits aggregate categories
only and invokes no provisioning, credential delivery or lifecycle effects.
A further read-only journal check permits only absent legacy journals or matching
unexpired/current ready records; incompatible or expired progress is unconfirmed.

On 2026-10-02, Overalls returned **20 ready legacy boots** and Dungarees returned
**5 ready legacy boots**, with no not-ready or unconfirmed results. All 25 had
absent readiness journals and fit the existing confined legacy adoption path.
This is point-in-time retained-boot evidence, not universal future-boot coverage.
The temporary script is `/tmp/kittens-retained-ready-probe.exs`; it never prints
commands, configuration, nonce, guest reply or identifiers. It is not a new
production API or receiver.

Both hosts' compatible reader release `beb43239` was healthy with zero updater
failures; last-healthy and activated revisions agreed and the recorded system
matched `/run/current-system`. Overalls Marshall, Porsche and Lilly were active;
Dungarees Lilly was active. The installed production lifecycle-event schema has
`pool_id`. Prior native NixOS agent/full Porsche and Ubuntu creation/SLO restart
results exercise fresh exact-boot readiness and authenticated v3 audit; the
current merged Ubuntu run also passed its unchanged capacity cadence gate with
all twelve ages below five seconds, maximum 3.162214 seconds. Its final journey
result remains pending.

The reviewed candidate now sets `services.lilly.provisioningReadiness = true`
for both enrolled hosts. Default module behavior and the independent template
producer remain disabled. No deadline, progress journal or immutable SLO result
is reset. Activation and post-switch journal/current-guest verification remain
pending until the candidate is published and healthy on both hosts.

## Full merged Ubuntu acceptance

The **full Ubuntu Porsche journey passed in 997.02 seconds** on the captured
`456e76a3` merged source with strict capacity freshness and success assertions.
The total Nix build took 1531 seconds including release construction. Creation
measured all three durable sources, retained nonzero source identities and
counters/buckets across Marshall restart and repeated scans, and completed
onboarding, guest SSH/agent, certificate renewal, relocation and final
reboot/cloning. This closes the full Ubuntu journey gap for that snapshot.
It does not establish production readiness activation, live provider behavior,
seven-day compliance or causal attribution for earlier unexplained failures.
This native snapshot predates the pending-index migration and production
readiness declarations; the fixture already enables readiness.
Log: `/tmp/kittens-service-level-ubuntu-current-main.log`.
Archive: `/home/ghuntley/.local/state/nix/build-logs/1790967824111-2970483-0.jsonl`.

## Follow-up schema and publication gates

Both pending indexes were inspected as installed in the existing private test
partition, without resetting its database. Forced test-environment Dialyzer
passed with **zero errors, skips and unnecessary skips in 47.39 seconds**.
All-file Ruff, Ruff format, ty, logging and handbook hooks passed for the index
follow-up. The subsequent fixed wait-category and readiness declaration changes
retain separate final gate requirements.

The packaged **Marshall SLO publication check passed in 384 seconds**, including
the pending-index migration, three real Rust exporters and collector custody,
and the signed-in browser projection. Its scope is packaged database/publication
and UI behavior; guest creation/restart proof is the separate native evidence
above. Log: `/tmp/kittens-service-level-readiness-final-native-publication.log`.
Archive: `/home/ghuntley/.local/state/nix/build-logs/1790969438071-4038544-0.jsonl`.
The seven-day burn factors remain derived from two percent of budget in one hour
(3.36 times) and five percent in six hours (1.4 times), with source history guards.
The full Marshall precommit exited successfully: **212 properties and 1,199 tests
passed (1,411 total), with two exclusions**, in 1,327.1 seconds. Forced
test-environment Dialyzer then passed in **117.12 seconds with zero errors,
skips or unnecessary skips**. Runtime, ADR, handbook, contracts, logging,
compiler and browser-state gates passed within that command.
Log: `/tmp/kittens-service-level-readiness-final-precommit.log`.
All-file static hooks and generated handbook checks passed; the Nix handbook
and conflict checks passed in 29 seconds. These results cover the uncommitted
readiness/index candidate based on `456e76a3`, before the later main merge.
Native Audi SSH/Galileo source checks are still running; no result or
notification delivery is inferred from their presence.

## Integrated main follow-up

Merge `bc912cb4` preserves main's audit expiry/unobserved-reply and mixed
deadline backlog properties alongside the readiness/index candidate. Focused
execution passed **four properties and eleven tests (15 total)** in 43.6 seconds,
seed `535697`. Log: `/tmp/kittens-slo-merged-focused.log`.
ADR and handbook receipt, generated views/options/coverage checks passed.
Evaluated Nix handbook and conflict checks passed in 21 seconds; archive:
`/home/ghuntley/.local/state/nix/build-logs/1790971242216-865845-0.jsonl`.
These checks do not extend the independently recorded native guest scope.

Forced test-environment Dialyzer on the merged candidate passed in **105.13
seconds**, with zero errors, skips or unnecessary skips. Log:
`/tmp/kittens-slo-merged-dialyzer.log`. Candidate `c98a375c` was pushed atomically
to main and the feature branch, preserving `f3b811e2`, and deployment started on
both hosts. Dungarees activated it healthy with zero updater failures; the
installed execution configuration has readiness enabled. The passive exact-boot
probe returned **five ready recorded boots**, compared with five legacy boots
before activation. Overalls activation remains pending.

## Remaining native sources

The serial combined native invocation based on the readiness/index candidate
finished after 1,790 seconds. **Galileo's native script passed in 802.72 seconds**.
Audi SSH failed before SSH assertions: public guest HTTP returned a curl exit22
after successful DNS checks. The source/collector SSH outcome remains unverified
by that invocation. DB connection timeout reports are present, without established
causal attribution. Log: `/tmp/kittens-service-level-remaining-native-sources.log`.
Archive: `/home/ghuntley/.local/state/nix/build-logs/1790969884442-99330-0.jsonl`.

The fixture now bounds public HTTP convergence at 60 seconds, requiring the exact
guest body and verified TLS within the same successful attempt. DNS and HTTP
resolve independently expiring routes; prior DNS success cannot guarantee a
current route at the subsequent request. No route is injected, freshness threshold
relaxed or SSH outcome assumed. A fresh native execution remains required.

## Readiness activation verified

Both hosts activated `c98a375c` and reached healthy updater state with **zero
failures**. Their installed execution configuration enables readiness. Overalls
Marshall instance, Lilly, Porsche and the three durable-source exporters are
active; both pending indexes are installed in the production database.

The passive confined exact-boot probe returned **17 ready recorded boots on
Overalls and five on Dungarees**, without unconfirmed or not-ready results.
Three delete operations completed with retained physical deleted outcomes
between 19:29:29 and 19:30:18 UTC, before this deployment; the earlier 25-boot
sample is not the current inventory. This verification covers the current
22 retained boots, not a universal future-boot guarantee.

A database aggregate digest over all finished measurements admitted before
20:00 UTC matched before/after activation. It includes admission/deadline,
terminal timestamp, outcome and duration; no identifier is emitted. Live source
snapshots match database totals: creation-ready **8/0/8**, physical **20/17/3**,
and SSH physical **17/6/11** requests/successes/failures. Historical readiness
failures remain immutable. Template producers remain disabled; fresh production
creation success, seven-day compliance and notification delivery are separate
remaining evidence.

After main advanced to `ad999a42`, Overalls was healthy with zero updater
failures. Prometheus returned exactly one application-labelled Overalls request
series for each durable source, with values **8, 20 and 17**, matching the
database and private snapshots. All **32 burn evaluators were healthy/inactive**.
The eligible seven-day objective count was **zero**: history guards refuse a
compliance result until actual coverage, lifetime and volume requirements pass.
Inactive evaluators do not establish compliance or delivered notifications.

## Audi SSH convergence rerun passed

The focused native Audi SSH rerun **passed in 908 seconds overall**, with the VM
script completing in **520.91 seconds**. The real guest public HTTP body and
verified TLS succeeded, the browser grant journey passed, and the registered-key
OpenSSH guest session passed together with collector-visible nonzero request and
success counters under the fixed application/source identity. The SSH subtest
completed in 22.03 seconds; this is fixture execution time, not a measured latency
objective. The snapshot uses `c98a375c` application code plus the bounded Audi
fixture and then-current handbook edits, before the Brady-only merge.
Log: `/tmp/kittens-slo-audi-ssh-convergence-native.log`.
Archive: `/home/ghuntley/.local/state/nix/build-logs/1790971800587-1157504-0.jsonl`.

The earlier pre-SSH HTTP failure remains a separate execution record. This result
does not establish source crash recovery, live provider behavior or seven-day
compliance. The final Brady merge's all-file static hooks passed and evaluated
Nix handbook/conflict gates passed in 27 seconds (archive
`/home/ghuntley/.local/state/nix/build-logs/1790972332461-1522732-0.jsonl`).
