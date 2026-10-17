# Durable application request SLO review

## Scope and architecture impact

ADR-0136 extends eight request sources with host-local durable admission and
completion accounting. ADR-0132's provisional policy and ADR-0133's database
physical/workflow authority remain separate. This is partial implementation;
there is no source cutover or new deployed service yet.

## Declared fleet rollout and actual Marshall acceptance

The current module imports production request bindings: eight recorder/exporter
pairs on Overalls and five on Dungarees. Each pair uses bounded independent Unix
accounts, separate RPC and publication groups, and private permanent checkpoint
state. An assertion refuses duplicate recorder account hashes. This is declared
placement; production activation remains pending. Database sources stay separate.

The actual Marshall integration check passed in **371 seconds**, with **101.76
seconds** of test-script execution. Archive: `1790985929916-1268329-0.jsonl`;
log: `/tmp/overalls-request-marshall-durable-native-catalog-fixed.log`.
It exercises real HTTPS admission and collector export, independent reader
custody, recorder SIGKILL without restarting Marshall, clean Marshall restart
preserving lifetime/totals/coverage, and an admitted incomplete browser request
whose producer SIGKILL settles exactly one failure without inventing duration.
The ordinary-reader browser verifies cards and evaluator presentation; forty
burn evaluators remain healthy and inactive in the isolated fixture.

The preceding expanded run failed overall after its three new crash/restart
subtests passed: the evaluated catalog was 164,691 bytes, above the old 128 KiB
Marshall bound. The reader now bounds input to 256 KiB plus one byte, retaining
the 8 KiB query-field bound and unknown fallback. The isolated regression passed
seven checks (four properties, three tests); oversized data still yields unknown.
This acceptance proves Marshall's packaged local paths, not seven days of
production compliance or complete native acceptance for the other sources.

Audi SSH now waits for production durable units and snapshot publication.
Galileo/private Audi and Brady fixtures use the production recorder module and
explicit Rust export selection with distinct reader accounts. Their local
collectors remain disposable; passing execution must be recorded separately.

The final Nix HLDD gate passed in 16 seconds, archive
`1790986659969-1772669-0.jsonl`. The updated topology's handbook browser check
passed in 452 seconds, archive `1790986382723-1583961-0.jsonl`. Repository hooks
passed contracts, logging, HLDD, Ruff lint/format and ty. This does not establish
production placement or source history.

The combined remaining-native invocation failed overall in 463 seconds:
Brady's enrollment assertion reported `Idle capacity expires between reports`,
before its new accounting assertions. Enrico, DNS and Porsche service scripts
finished in 38.36, 51.33 and 153.01 seconds respectively. Enrico verifies an actual
authorized refresh through the durable snapshot and collector; DNS verifies
counted SERVFAIL outcomes through the durable snapshot and collector. Porsche's
service fixture establishes idle publication/custody and startup refusal, not
an authorized native SSH command. Archive: `1790986479648-1664295-0.jsonl`.

Audi SSH failed overall in 751 seconds before native SSH acceptance, at the
private browser's `owner:primary-http` assertion. Archive:
`1790986237405-1463914-0.jsonl`. Its original stage-only diagnostic cannot identify
the response status. The fixture now records only the numeric HTTP status and
fixed stage, preserving the private URL/cookie/exception boundary. These runs
overlapped other fleet checks and the full Marshall suite; contention remains
a hypothesis, not an established cause. Serial acceptance remains required.

Both production updaters were observed healthy at `1470ab5d8a80fa78289da37b84aa1af16b15b112`,
with zero failures. That moving-main deployment does not include this branch's
durable request cutover.

The new focused `otel-porsche-native` fixture retains real browser key approval
and authorized OpenSSH dispatch, then requires durable successful totals and
collector export. A unique split marker is asserted during Nix evaluation;
the scenario stops before separate physical VM creation and recovery workflows.
This closes the service fixture's idle-only measurement gap when native execution
passes; fixture presence alone does not establish it.

The expanded `otel-galileo-native` run passed overall in **1,319 seconds**, with
**857.90 seconds** of script execution, archive `1790986317077-1520194-0.jsonl`.
Actual guest outcomes reach durable Galileo and private Audi snapshots and their
isolated collectors, with independent application-UID collector refusal. The
unchanged broader journey verifies body preservation, execution fencing, peer
provenance and cross-host physical relocation. Its source assertion took 9.31
seconds. This establishes actual source/collector transport; counter continuity
through every later fault and seven days of production observation remain
separate. Log: `/tmp/overalls-request-galileo-durable-native.log`.

The implemented Rust core holds permanent source identity, bounded numeric
admissions, immutable per-admission deadlines and exact producer identity.
Private checkpoints preserve admission conservation across reopen, use exclusive
writer locking, reject corruption and loss of initialized state, and acknowledge
only after file and directory fsync. A write failure poisons fresh publication.
Unresolved producer death is failure with unknown duration. Recovery never
changes request execution or physical guest authority.

## Verification and remaining gates

The final full pinned Rust run passed 27 library tests and three receiver tests
in 0.67 and 0.13 seconds respectively. This includes nine core tests: three
properties and six filesystem/refusal tests. The generated real-checkpoint
history property runs 32 cases, preserving each committed state across reopen
and counting unresolved dead-producer work once without duration fabrication.
Library Clippy with warnings denied passed in 0.81 seconds. Rustfmt formatted
the new module. Logs: `/tmp/overalls-durable-request-core-final.log` and
`/tmp/overalls-durable-request-core-clippy.log`.
These are process-local properties and filesystem tests, not native SIGKILL or
power-loss acceptance. No socket credential/cgroup validation, application hooks,
freshness publication or NixOS runtime exists yet. Those are required before
enabling any source and claiming seven-day restart continuity.

## Contract review

Repository evidence and secret-diagnostic contracts remain applicable. The core
retains only closed source names, numeric counters, local process identity and
opaque sequence numbers. Neither guest nor arbitrary caller attributes become
metric labels. Store failures remain closed typed errors. All transitions retain
counter/sequence conservation and refusal leaves authoritative state unchanged.
The ancestor guest telemetry contracts apply to the receiver's existing intake;
this host-only module cannot grant guests access to trusted request accounting.

## Required continuation

Implement kernel peer/unit validation, PID incarnation/death detection, bounded
socket admission/completion protocol, independently supervised Nix recorders,
exporter-compatible snapshots and real source admission hooks. Preserve existing
source denominators and health/OTLP exclusions. Add native producer/recorder
crash and wrong-source tests, full component gates, then deploy and verify lifetime
and counter continuity. Native retry/cancellation workflow measurements and
external alert delivery remain separate open work.

## Authenticated runtime extension

The Rust runtime and production Nix module now exist. The module defaults to no
instances; the native test alone enables recorders. One configured source and
exact systemd unit bind every connection through kernel peer UID and cgroup v2.
PID/start/boot identity plus pidfd checks distinguish dead, alive and unknown.
Recorder restart does not classify a surviving producer as failed. Version-one
frames are limited to 512 JSON bytes; no frame contents enter logs. Producer
heartbeats gate fresh snapshots independently of recorder uptime. Deadline/death
reconciliation runs without request traffic. Exclusive checkpoint ownership is
acquired before clearing interrupted snapshot stages.

The final runtime Rust run passed **32 library tests and three receiver tests**
in **0.55 seconds** and **0.11 seconds** respectively. Three new properties cover
process names with parentheses/spaces, oversized frame lengths and exact unit
components; deterministic tests cover unknown fields/versions/truncation and
actual current Linux process incarnation. All-target Clippy with warnings denied
passed in **0.92 seconds**. The schema test caught extra fields accepted by Serde
unit variants; empty struct variants now enforce refusal. The first Nix invocation
failed at compilation due to a property diagnostic-format macro, before native
execution. The corrected native run passed in **74 seconds**, including **22.71
seconds** of script execution. Archive: `1790979247319-1607401-0.jsonl`.
This records its original crash/custody scope; application hooks remain absent.

Final review found that invisible procfs can return ENOENT for a live producer.
ENOENT now requires pidfd exit/ESRCH proof before classifying death. The native
fixture adds `ProtectProc=invisible`, verifies the pending admission is preserved
while producer authentication is unavailable, restores visibility and explicitly
excludes that fixture admission. The final expanded native run passed in
**89 seconds**, including **26.12 seconds** of test script execution.
Archive: `1790979402612-1701985-0.jsonl`. This proves the listed recorder fixture
boundaries, not integration with any real application or external collector.
The final Rust run after this change passed 32 library and three receiver tests
in 0.56/0.11 seconds; all-target Clippy passed in 0.89 seconds.

The native fixture uses the production module and Rust recorder, a separate
systemd producer and real local peer/cgroup attribution. It tests acknowledged
admission surviving recorder SIGKILL, producer SIGKILL settling unresolved work
once without fabricated duration, unchanged lifetimes, wrong-unit/same-UID and
foreign-UID refusal, live-producer deadline expiry and missing initialized state
refusal. Source hooks, final deadline/overload contracts, exporter/collector
integration, full application gates and production source activation remain open.

Before source cutover, admission failures need explicit measurement-quality
handling. The current seven-day guards check current freshness and retained
series coverage; a cached series cannot prove that every eligible request was
recorded during a producer/recorder communication outage. Hooks must report
recording gaps durably, and readers must withhold objective windows containing
such gaps without resetting permanent counters or fabricating success.
The quality extension implements a durable coverage clock, authenticated gap
command, startup/saturation marking and conservative version-one checkpoint
upgrade. The exporter rejects coverage regression and emits a fixed coverage
gauge. Five-minute candidates, seven-day recordings, retained readings and burn
alerts require complete matching coverage for their requested windows. Producer
persistent gap reporting remains absent; production instances remain disabled.

The pinned quality Rust run passed 35 library and three receiver tests in
0.57/0.11 seconds. All-target Clippy with warnings denied passed in 1.00 seconds.
New properties preserve all state except coverage across generated gaps and
reject regressing or future export clocks. A filesystem test upgrades a synthetic
legacy checkpoint while preserving counters, admissions and permanent lifetime.
Logs: `/tmp/overalls-request-quality-rust.log` and
`/tmp/overalls-request-quality-clippy.log`.

The Prometheus rule check passed in **142 seconds**; archive
`1790980540704-2337192-0.jsonl`. Synthetic rule histories prove missing/gapped
coverage suppresses retained objective readings, burns remain suppressed after
five-minute warmup, and seven-day recordings recover only after seven complete
days following the gap. They do not establish real producer reporting or actual
seven-day production history.

The expanded native gap fixture passed in **94 seconds**, with **26.44 seconds**
of script execution; archive `1790980654263-2402897-0.jsonl`. Its authenticated
gap report advances coverage while preserving sequence/counters; the published
snapshot reflects that clock. Recorder restart advances coverage again while
preserving permanent lifetime/identity. Earlier crash, custody and deadline
assertions remain in the same script. This is an isolated producer fixture,
not actual application gap persistence or collector transport acceptance.
After formatting the typed driver, the final native invocation passed in
**35 seconds**, archive `1790980758853-2466965-0.jsonl`, with the same assertions.
Rust, contract syntax/coverage, ADR structure, generated options/coverage/views
and the Nix HLDD gate passed. The UTF-8 locale remains explicit in the Elixir
Nix checks; no encoding failure occurred in these validations.

## Producer library and source hooks

The separate producer library performs private marker and bounded Unix RPC I/O
without adding I/O to protocol. In the captured revision it was named
`slo_client/`; the current breaking rename is
`elixir/request_accounting/` (`Overalls.RequestAccounting`). Its staged quality
writes fsync both file and directory. Clean/running/gap markers distinguish
clean deployment from unclean SDK/application restart. Dirty storage stays
dirty; only durable recorder gap acknowledgment permits completion of older
admitted work during a gap. Local worker monitors settle unresolved work; a
coordinator may admit a suspended local task before effects and the task
completes before reporting its business result.

All eight hooks now exist. Marshall admits at endpoint start; Galileo after
authorization; Enrico before accepted task effects; Brady after resolved identity
and validated request authority/method; Porsche at dispatch with terminal 2/3
exclusions; Audi private after current binding excluding OTLP; public DNS after
ordinary-question validation and before resolution; Audi SSH after valid grant.
Existing application authority, request effects and legacy status counters remain
separate. Runtime configuration is still absent on production hosts.

The initial producer library gate passed six tests (three properties), compiler,
contract checks and forced Dialyzer with zero findings. The new DNS admission
properties passed separately (two properties, 0.1 seconds), proving classified
public outcomes require pre-resolution eligibility and invalid packets cannot
enter it. These are property/code evidence, not actual application transport
acceptance. Logs: `/tmp/overalls-slo-producers-slo_client-precommit.log` and
`/tmp/overalls-dns-admission-properties.log`.

The first correct BEAM/Rust native fixture passed in **58 seconds**, script
**45.54 seconds**, archive `1790981297097-2765909-0.jsonl`. It proves worker death
within a surviving BEAM, clean application shutdown preserving coverage, unclean
BEAM restart reporting a gap, RPC-gap persistence across restart and corrupt
marker refusal. A delegated-task version passed in **66 seconds**, archive
`1790981649411-2961504-0.jsonl`. These runs precede the later dirty-storage/old
completion guard and do not establish that new assertion. An earlier attempt
failed before execution at a test-package toolchain mismatch; the next attempt
was stopped after the fixture called Elixir `Application.load` with an Erlang
resource tuple. The corrected fixture calls `:application.load`.

Review found two disabled-mode startup projections included ignored client child
specifications. Clients now enter the supervision tree only when configured;
tests retain their startup requirements. Review also found that an old completion
could refresh recorder evidence while producer storage was dirty. Gap reporting
now precedes that completion, and a dedicated native assertion is required.
Full consumer gates, that native guard, exporter custody, source deadlines and
real-source deployment acceptance remain required before production activation.

The final strengthened native guard passed in **57 seconds**, script
**47.53 seconds**, archive `1790982140006-3241174-0.jsonl`. It admits a real
worker, corrupts producer quality storage, completes the old admission and checks
that durable coverage advanced before the completed totals appeared. A new BEAM
still cannot clear corrupt storage and reports another gap. The clean-deployment
assertion now requires a source sample newer than post-restart control readiness,
so retained snapshots cannot satisfy it. The RPC outage also requires the recorder
to remain inactive after producer restart. Two preceding attempts exposed those
fixture weaknesses: retained control/socket readiness raced startup, and a runtime
mask did not override the persistent Nix unit. The final test uses an explicit
missing start condition, proves inactivity and restores it before recovery.
These are kernel/SDK/Rust fixture assertions; real application transport and
exporter custody remain unverified.

Review of delayed recovery found that a pre-gap admission could settle after
coverage resumed, admitting an uncertain terminal sample into a later window.
Version-three checkpoints retain a gap-crossing marker on existing pending work.
Countable settlement advances coverage through settlement; later unaffected
admissions retain their own marker, avoiding an endless cascade under traffic.
Excluded work does not burn the budget or advance this clock. Version-one/two
upgrade preserves identity/counters/admissions and conservatively marks pending
work; missing current quality metadata refuses startup.

The final pinned Rust run passed **38 library tests and three receiver tests**
in **0.58/0.13 seconds**, with all-target Clippy passing in **1.00 seconds**.
The new property covers successful, failed, dead-producer, deadline and excluded
gap-crossing settlements while later work cannot extend coverage. Filesystem
tests verify version-two pending upgrade and current missing-metadata refusal.
Log: `/tmp/overalls-slo-producers-rust-gap-settlement-final.log`.

The final non-Marshall consumer gates passed, including forced Dialyzer with zero
findings: Galileo 27 tests (9 properties), Enrico 6 (3 properties), Brady 80 (29
properties), Porsche 91 (15 properties), Audi 167 (43 properties), and producer
library 6 (3 properties). Logs are `/tmp/overalls-slo-producers-APP-precommit-final.log`.
The NixOS HLDD browser check passed in **322 seconds**, script **60.48 seconds**,
archive `1790982350878-3379079-0.jsonl`, exercising the maintained diagram and
section-delivery renderer. It does not establish SLO producer transport acceptance.
The extended version-three native check passed in **56 seconds**, script
**46.30 seconds**, archive `1790982841922-3678527-0.jsonl`. In addition to the
preceding assertions, a gap with pending work followed by deadline expiry advances
coverage through settlement. This proves the real recorder's delayed-settlement
guard in the isolated fixture; it does not establish application or exporter
transport acceptance. Log: `/tmp/overalls-slo-client-native-late-gap-final.log`.
Marshall's isolated test phase passed **1,417 checks**: **216 properties** and
**1,201 tests**, with two exclusions, in **1,054.2 seconds**. A fresh partition
isolated the run from unrelated/default-database test activity; no shared
database was deleted. Log: `/tmp/overalls-slo-producers-marshall-precommit-isolated.log`.
Forced Dialyzer passed with **zero errors and zero skips**, completing the full
consumer gate. Passing native execution precedes production activation.

## Exporter custody continuation

The explicit Rust `--recorder-group-source` mode accepts only the eight request
sources and enforces existing read-only group-file custody without a legacy
fallback. Its pinned run passed **39 library tests and three receiver tests**
in **0.60/0.11 seconds**, with all-target Clippy passing in **0.77 seconds**.
Log: `/tmp/overalls-slo-exporter-custody-rust-final.log`.

The Nix module separates RPC and publication groups/directories and configures
the producer's private quality directory. Its inner marker directory avoids
DynamicUser's state-entry symlink. The native fixture now requires readers to
read snapshots while refusing snapshot/directory writes, producer RPC and
checkpoints; producer accounts must also be unable to read publication.
The repaired native check passed in **64 seconds**, script **49.50 seconds**,
archive `1790983608060-4126836-0.jsonl`, including these permissions assertions
and the preceding BEAM/crash/gap/deadline assertions. Log:
`/tmp/overalls-slo-exporter-custody-native-repaired.log`. Two diagnostic attempts
proved systemd resets RuntimeDirectory ownership/mode before later commands,
undoing the attempted RPC group setup. RPC directory custody now uses explicit
tmpfiles while publication retains systemd's separate primary reader group.
Production exporter wiring, reviewed deadlines and actual source acceptance
remain pending.

The Grafana configuration now defaults to `now-7d` through `now`, matching the
requested observation range. This display default does not override history
eligibility or imply that production has seven complete days of evidence.

The extended native check also passed in **78 seconds**, script **52.91 seconds**,
archive `1790984127134-231543-0.jsonl`. An actual DynamicUser BEAM application
uses the recorder module's environment and private marker directory, completes
an admission and cleanly restarts while preserving lifetime, totals and coverage.
The other permission/crash/gap assertions remain in the same run. This establishes
the configured SDK storage/startup path, not actual Marshall HTTP or collector
transport. Log: `/tmp/overalls-request-dynamic-native.log`.

Full deployment evaluation found that readable generated account/group names
exceeded NixOS's 31-character limit for several real instances. The recorder,
RPC, reader and exporter roles now use bounded deterministic hashes of the
configured instance; unit and storage names remain readable. No production
recorder had been enabled under the invalid names. The final corrected native
check passed in **75 seconds**, script **53.38 seconds**, archive
`1790984471768-433796-0.jsonl`. It exercises the real `marshall-overalls`
instance name with a DynamicUser producer and retains all custody/crash assertions.
A preceding attempt reached checkpoint-loss recovery but failed because the
fixture restore hardcoded an obsolete account; the fixture now preserves the
actual checkpoint owner and mode on its private backup and restore.
Log: `/tmp/overalls-request-bounded-identities-native-final.log`.

Complete Overalls system-derivation evaluation of the draft source bindings
passed at `/tmp/overalls-request-bindings-overalls-toplevel-fixed.log`. The
allowlisted configuration projections contain eight Overalls sources and five
Dungarees sources, with distinct exporter accounts, reader/collector groups and
producer marker configuration. This establishes declared configuration, not
application transport, collector provenance or production activation. The draft
bindings remain outside the fleet module imports until the producer milestone
is committed and source acceptance is prepared.

## Latest serial verification before public Grafana rollout

The Audi SSH serial rerun passed overall in **777 seconds**, archive
`1790987742609-2398126-0.jsonl`, log
`/tmp/overalls-request-audi-ssh-durable-native-serial.log`. Its registered-key native
OpenSSH and durable collector source assertion passed in 17.14 seconds; enrollment,
separate DNS/gateway authority, guest HTTP readiness and private owner/browser
HTTP/WebSocket assertions also passed. Earlier failed runs remain separate;
this success does not establish contention as their cause.

The full Marshall test stage passed **1,417 checks: 216 properties and 1,201
tests**, with two excluded, in **1,371.7 seconds**. The precommit invocation itself
failed later in Dialyzer on a missing consolidated Collectable BEAM artifact while
another Mix command shared `_build/test`. The merged-main focused suite separately
passed **20 checks: eight properties and twelve tests** in 168 seconds. Final
serial toolchain, architecture, HLDD, contracts, logging, forced warning-free
compile and forced Dialyzer passed; Dialyzer took **49.56 seconds** with zero
errors or skips. Logs: `/tmp/overalls-request-rollout-marshall-precommit.log`,
`/tmp/overalls-request-main-merged-properties.log`, and
`/tmp/overalls-request-merged-final-static-dialyzer.log`. The original full
precommit invocation remains failed; the repaired final gates are separate evidence.

The next serial Brady rerun failed overall in **611 seconds**, archive
`1790989053338-3207505-0.jsonl`, log `/tmp/overalls-brady-grafana-rollout.log`.
The actual guest HTTP/TLS requests succeeded, but the fresh authoritative
attribution retry timed out before the new durable source assertions. The
allowlisted event summary contains nine HTTP 200 requests, all explicitly
unresolved, with no VM or owner identity. Those requests remain outside the SLO
denominator; weakening the kernel/route/actor proof or its deadlines would be
incorrect. This establishes the failed stage, not its root cause. A new run after
the full Marshall test stage is planned to reduce concurrent local load.

The first focused Porsche invocation failed before native execution in **374
seconds**, archive `1790989872881-3670363-0.jsonl`. The composed driver's mandatory
type/syntax gate found two statements joined across the split-marker boundary.
The fixture now inserts an explicit newline; production SSH, eligibility and
accounting behavior are unchanged. The gate remains enabled and native rerun is
required. Log: `/tmp/overalls-porsche-grafana-rollout.log`.
