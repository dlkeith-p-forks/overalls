# Elixir and Rust observability source review

Baseline: `a99f74f06542798dc9ef288e77c99d480433fc57`. The baseline inventory contains 1865 Elixir sources and 103 Rust sources. The current inventory below includes tracked and untracked source files, excludes removed paths and respects Git ignore rules.

| Area | Elixir source files | Rust source files |
| --- | ---: | ---: |
| `.formatter.exs` | 1 | 0 |
| `antithesis` | 4 | 0 |
| `audi` | 109 | 0 |
| `brady` | 60 | 0 |
| `enrico` | 20 | 2 |
| `galileo` | 28 | 0 |
| `lilly` | 287 | 43 |
| `lyra` | 0 | 27 |
| `marshall` | 980 | 0 |
| `nix` | 75 | 31 |
| `elixir/diagnostics` | 15 | 2 |
| `porsche` | 42 | 0 |
| `protocol` | 134 | 0 |
| `scripts` | 17 | 0 |
| `elixir/request_accounting` | 15 | 0 |
| `ziggy` | 47 | 0 |

## Review method and scope

Every inventoried source path entered searches for diagnostic emitters, raw Logger/IO output, Rust stdout/stderr/log calls, telemetry hooks, protocol diagnostic fields, persistence/outbox and SLO consumers. Source inspection followed the production emission boundaries, their callers and governing contracts. This inventory establishes search coverage; it does not claim line-by-line semantic verification of every test or helper. Native wire stdout and private terminal streams remain exact. Existing CLI output remains user-facing output, not fleet diagnostics.

## Findings and changes

The final source inventory after incoming Starship/profile integration contains
1829 Elixir sources and 105 Rust sources. The earlier captured inventory contained
1825 Elixir sources and 105 Rust sources. The combined tree adds one fresh-VM
schema regression after integrating origin/main
`1cd8be40`: Standard replaces the previous product profile atom, safe email
eligibility retains its incoming authority, and owner-validated standby remount,
claim-first recovery and independent archive custody coexist. The regenerated
captured finite trace schema changed only `antithesis` to `standard`; resource identity,
UUID keys, numeric keys and privacy boundaries are unchanged.
Explicit JSON object ordering fixes the observed cross-VM atom-order difference;
the regression checks production vocabulary in both loading orders without
starting services or rewriting the artifact.

Incoming `70e2aaf6`/`76c6ce42` subsequently add the ProfileRename module/property,
and the merged correction adds the actual Marshall migration regression. The
incoming database migration itself adds a fourth Elixir source. The
[profile custody review](2026-10-10-profile-migration-custody.md) records emitter,
privacy, native-lock, archive/publication, host/version and caller-contract review
of those additions. The final inventory is search/review scope, not evidence that
the previously captured native derivations executed the new startup migration.

The current regenerated trace schema adds the catalogued `lilly.profile_renamed`
event and finite atoms `migrate`, `plain`, `profile_migration_failed` and
`proof_target`. Its SHA-256 is
`107f7b0872c0f916419a8b56be4e258e2688d6a5230cf3523a8cbf139ad38484`.
UUID/numeric keys, resource identity and privacy filters remain unchanged.
The current complete SDK precommit passes eleven tests in 3.5 seconds, nineteen
contract regressions and forced Dialyzer with zero errors, skips and unnecessary
skips in 6.25 seconds, recorded at
`/tmp/overalls-observability-profile-sdk-final.log`. The current Rust spool checks
also pass thirteen tests, rustfmt, all-target Clippy with warnings denied and the
locked release build in 50.72 seconds. These source/schema/type checks do not
establish native execution of the incoming retained-state profile migration.

The frozen merged Lilly precommit subsequently passes 541 checks (104 properties
and 437 tests) in 75.3 seconds, seed 95084, with zero-error/skip/unnecessary-skip
forced Dialyzer in 14.82 seconds. Its whole shell is 149.526942544 seconds, recorded
at `/tmp/overalls-lilly-profile-custody-final-precommit.log`; runtime, 149-ADR,
contracts, logging, compiler and formatting gates pass without source/assertion
changes during execution. This current component result is separate from the
captured 530-check watcher gate and frozen native derivations below. The frozen
current Marshall precommit exits 0 with 1387 passing checks (235 properties and
1152 tests), two excluded, seed 922173, in 1510.0 seconds (40.1 asynchronous and
1469.9 synchronous). Its 32 terminal/accessibility and four dashboard checks and
workspace TypeScript gate pass. Forced Dialyzer has zero errors, skips and
unnecessary skips in 61.94 seconds, after PLT preparation of 13.38 and 324.95
seconds, recorded at
`/tmp/overalls-observability-profile-marshall-final-precommit.log`.
The corrected current-source native relocation gate now passes all 19 subtests,
as recorded below. Retained-state native upgrade and physical power-loss
acceptance remain unverified.

Incoming `e3300040` adds no Elixir/Rust sources and changes only the standby
fixture and documentation. The fixture refills one real standby before its
interrupted-unmount fault and includes that standby's GUID in the existing cleanup
oracle. The [latency review](2026-10-05-create-clone-delete-latency.md) preserves
the author's reported production rollout, samples and incidents separately from
captured observability tests. Its reported native pass has no exact wrapper,
duration or output artifact; the modified standalone standby fixture has not been
run by this review. The overview and ADR-0145/0146 now distinguish enabled fleet
declarations from historical diagnostic-wire reader releases retired by ADR-0149,
while retaining native journals, ownership and capacity accounting.

Incoming `e7e2f2e3` subsequently records the user's ADR-0146 acceptance on
2026-10-09 and reconfirmation on 2026-10-10. The earlier `e3300040` review recorded
proposed metadata; the current decision and index are accepted/partial. This
documentation-only status correction changes no runtime, captured native result
or author-attribution gap. ADR-0151 remains proposed/partial, with retained-state
native upgrade acceptance separate.

The review also found and repaired three concrete trace-boundary defects: SDK status
setter failures could replace a business return; orphan pending indexes could
open without their immutable custody row; and a basename-only producer-unit check
did not establish the evaluated canonical systemd cgroup. Fault injection and
native corruption/identity fixtures now cover those paths. Galileo's401 upgrade
refusal is mapped from the shared client's closed `:refused` class to
`:unauthorized`, preserving its existing permanent-refusal contract.

Final review also corrected the real LoggerJSON metadata shape and production
routing so health remains in application logs while bounded numeric values reach
Grafana independently. Terminal standby pruning retains legacy archives outside
the active catalog, with same-filesystem rename and parent-directory fsync.
Marshall's committed lifecycle notifier now maps dependency-created unknown atoms
to its reviewed fallback instead of raising after commit. These repairs preserve
the authority boundary rather than expanding diagnostics into it.

The final generated-schema check detected a stale finite enum after a native
archive-device guard changed. The reviewed regeneration preserves UUID and enum
key boundaries and includes the eight reviewed health events and numeric runtime
fields. The SDK precommit now enforces source/schema correspondence without
rewriting files or starting services. This enforcement has no additional
architecture impact; the final SDK suite and forced type check pass.

Antithesis research now marks the four removed diagnostic API/outbox candidates
historical and superseded by ADR-0149. Their captured evidence is preserved.
A replacement independent-custody candidate records current local/native scope
and explicit hosted gaps; no hosted workload or launch was performed.

The combined native Lilly recovery run exposed another transport defect after
physical control had continued through observer loss: the spool rejected the
pinned Collector 0.151.0's valid HTTP200 protobuf body `0a00`. Recovery timed out
at its original pending-drain assertion; subsequent exact transition delivery to
Tempo and submission histories were not reached. The forwarder now uses the
official `ExportTraceServiceResponse` decoder. Absent or zero rejected counts,
including private warning text, confirm delivery; nonzero/negative counts,
malformed/truncated protobuf and ambiguous HTTP framing retain pending custody.
The complete reply stays within 4,096 bytes and a two-second read deadline. The
exporter calls `Store.delivered` only after validated success, removing
the pending row while preserving the immutable archive until retention expiry.

The locked Rust suite passes thirteen tests, including the actual Unix forwarding
regression; rustfmt and all-target Clippy with warnings denied pass. The native
sink fixture now returns the exact pinned Collector success body, and its targeted
Ruff formatting/lint and ty checks pass. This corrects ADR-0149's existing delivery
contract without changing its accepted decision or partial implementation status.
Post-fix native spool checks passed in 34.90 seconds with a synthetic sink returning
the exact pinned Collector `0a00` success. Canonical UID/cgroup refusal, SIGKILL,
reboot, pending drain, retained upstream-ACK archive/replay, quota, corrupt-archive
startup refusal and producer independence passed. The production parser and sink
are identical; that native snapshot precedes the subsequent eager drain-loop
change. That snapshot did not establish combined real Lilly-to-Tempo delivery.
A second combined run with the corrected response parser again
passed physical control and timed out at pending drain. Both failed combined
runs supply physical-control evidence only, not successful backfill or
source-to-Tempo delivery. The
[implementation review](2026-10-09-observability-decoupling.md) records their actual
execution results separately.

The initial failure-only native recovery helper restricted its printed report to
allowlisted bounded integers, validated socket modes/UIDs/GIDs and fixed service
availability fields, without trace or credential reads or observer mutation.
However, Nix driver's `check_output=False` skips reading the command reply/status;
the resulting empty counters and false availability fields are invalid diagnostic
evidence. The earlier review covered privacy and typing but missed this acquisition
semantics. The corrected helper uses the driver's normal capture defaults, which
privately return both status and output without logging raw response text. It
retains five-second read timeouts, finite validation and the original failure on
diagnostic error; its source was checked against the actual pinned driver API.
Neither the earlier invalid fields nor the helper's failure establish the
backlog's cause. The original pending-drain assertion remains the failed
observation, and diagnostic output supplies no recovery or application authority.

An independent rate reproduction used the actual spool, pinned Collector and
exact producer UID/cgroup. All 64 requests at eight per second were accepted in
8.226 seconds, but SQL still counted 32 pending at producer completion. The
sampled health snapshot reported 63 accepted, 31 exported, 32 pending and zero
export failures; the one-event difference is a publication tick lag. This confirms
a healthy delivery-rate mismatch in that reproduction: the unconditional
250-millisecond sleep limited successful drain to at most four batches per
second, while routine SDK flushes can submit up to ten batches per second plus
committed handoffs. It does not by itself identify the cause of the combined
native run's backlog. The corrected-loop native result remains separate.

The final drain-loop source review confirms that successful exports continue
without that fixed sleep; an empty queue or forwarding/storage failure returns
to the 250-millisecond backoff. Indexed FIFO selection still loads one bounded
batch, releases the custody mutex for all network I/O, and requires successful
durable `Store.delivered` completion before continuing. A scheduler yield after
success gives admission a scheduling opportunity. Immutable archive retirement
still occurs only at expiry; quotas and the evaluated 128 MiB memory, 25 percent
CPU and 16-task process limits are unchanged. Maintenance/health publication is
paced to at most four attempts per second during a drain. Saving the expiry result,
publishing numeric health, then propagating the result preserves poison visibility
on expiry failure; an earlier draft suppressed this health update and was repaired.
This review does not claim strict starvation freedom: mutex scheduling has no such
guarantee, and the existing expiry operation still completes its expired-row work
under the custody mutex. No application authority, payload logging or new storage
boundary was introduced; ADR-0149's accepted decision remains unchanged.

The locked Rust suite now passes seven library and six binary tests; rustfmt,
all-target Clippy with warnings denied and the locked build pass. The new actual
Unix/Store regression drains 32 unique accepted batches in 10,870 microseconds
against its two-second deadline, which rejects the former approximately
eight-second delay. The fixture bounds idle accept, request read and response write
and joins its upstream before result assertions. Collector-side
`try_lock` checks that forwarding releases the custody mutex. Reopen/replay
compares stable IDs, acceptance/expiry timestamps and exact body bytes. Missing
socket forwarding and SQLite-triggered delivery/expiry failures stop draining,
preserve accepted pending custody across reopen and publish bounded poison health;
the expiry case checks health on its first failure, not just on a poisoned retry.
These regressions establish their local boundaries, not native isolation or
production throughput. An isolated source-copy mutant restored the former
250-millisecond success delay; the same regression rejected it with exit 101
after a 2.03-second test run. Its idle deadline terminated the fake upstream,
which was joined before the assertion failed. The original source was unchanged,
then force-rebuilt to avoid a shared Cargo target fingerprint collision; all
thirteen tests, Clippy and the locked build passed again.

Repeating the independent actual-spool/pinned-Collector rate fixture after the
loop correction accepted all 64 batches at eight per second in 8.224 seconds,
with SQL counting zero pending at producer completion versus the earlier 32.
The last sampled health snapshot reported 64 accepted, 62 exported, two pending
and zero export failures; SQL observed after completion avoids that publication
lag. This confirms the isolated rate correction without establishing combined
native recovery or durable Collector/Tempo storage.

The corrected-loop native spool gate passed in 32.28 seconds, with the Nix
build/run completing in 100 seconds. Canonical UID/cgroup refusal, reboot,
SIGKILL, pending drain, retained archive/replay, quotas, privacy and corrupt-startup
refusal passed. Its production source is identical to the current exporter;
subsequent changes only bound unit-test response writing and upstream cleanup.
This focused spool result remains separate from the earlier parser-only native
pass and from the combined real Lilly-to-Tempo recovery gate described below.

Final fixture review found that the parser-only `collector_reply` helper still
used a blocking accept and join: an early-return forwarding regression could
leave the test waiting indefinitely. It now uses nonblocking acceptance with a
two-second deadline and one-millisecond idle sleeps, the existing absolute
250-millisecond request deadline and a response loop that applies the remaining
250-millisecond write deadline to every write. The upstream result is joined
before socket/directory cleanup and result assertions. This closes the fixture
termination gap without changing production code. Final locked Rust checks pass
all seven library and six binary tests; rustfmt, all-target Clippy with warnings
denied, the locked build and contract format/diff checks pass. This final run's
32-batch eager witness is 14,115 microseconds; the earlier 10,870-microsecond
witness remains a separate recorded run. The production prefix before
`#[cfg(test)]` retains SHA256
`b71297ea8c79d26f4be19dd82473babd655e66802420d6833210463ea3074a9e`,
so these fixture changes do not invalidate the focused or combined native
runtime snapshots.

The corrected combined native execution passed with exit 0, output
`/nix/store/84zd12k7zm71fiqynsg0wgq81dyskqxy-vm-test-run-overalls-lilly-observability-recovery`
and the final driver footer `test script finished in 686.22s`. Its observer-outage
subtest passed in 113.04 seconds. It conserves exact native VMM and surviving guest
identity across Lilly restarts, retains old physical receipt identity, settles
fresh public stop/start readiness and durable SLO identity, and then satisfies
the original 180-second pending-drain assertion while preserving retained archive
counts. Its strict real Tempo query passed in 12.29 seconds within that subtest:
the result must match the actual native running Execution transition's UUID,
revision 16, enrolled host and exact placement, as well as Lilly service/host,
resource type and event name. This establishes the queried fresh transition's
delivery rather than only producer/Collector acceptance. Subsequent whole-daemon
submission recovery histories passed in 291.72 seconds: fixed l1/one-reopen,
fixed l2/two-reopen and generated l1/one-reopen histories each execute real before
and after launch checkpoints. Those six checkpoints and eight post-settlement
reopens preserve exact authenticated physical outcomes, native launch markers,
VMM ownership and unrelated guests. Original assertions, deadlines and fault
schedules are intact. The nested VM-script timing is 685.66 seconds; the 686.22
seconds above is the recorded final driver footer. No exact whole-Nix call timer
was recorded, and the log file's creation time predates a rejected invocation, so
it cannot supply that timer. The complete execution log is
`/tmp/overalls-lilly-observability-native-eager-final.log`. The two prior failed
combined executions remain failed historical evidence. These passing disposable
native-machine checks do not establish production sizing, independent physical
host failure or notification receipt; ADR-0149 remains partially implemented.

Completion review independently compared the current Nix dashboards with native
fixtures: baseline has fifty-nine panels, operations fifteen and logs two. The
log-store fixture still asserted nine operations panels, so its earlier
58.45-second passing execution predates the current inventory. The corrected
helper uses an explicit `list[tuple[int, str, str]]` expectation for all fifteen
panel IDs, titles and visualization types, then checks Grafana's actual response
with `jq`: every panel has the `overalls-prometheus` datasource/type and at least
one nonempty string query expression. The `grafana-operations-provisioned-inventory`
contract describes this verification obligation. It does not expose credentials
or add application authority; architecture impact is evidence correction for
ADR-0149's existing provisioning decision.

The complete current log-store native execution passed with exit 0, driver footer
`test script finished in 50.56s` and a recorded 68-second Nix invocation, at
`/nix/store/hl7q3blr08cixnvfsjdygy4hnq0dwxdp-vm-test-run-overalls-log-store`.
The actual fifteen-panel inventory, pinned VictoriaLogs plugin, verified TLS,
reader credential custody/API redaction, real log/trace correlation, read-only
proxy refusal and queued outage backfill all passed. Explicit type checking of
the Nix-composed driver, Ruff formatting/lint and contract format/discovery also
passed. The wrapper log is
`/tmp/overalls-log-store-dashboard-inventory-final.log`; the complete Nix build log
is `/home/ghuntley/.local/state/nix/build-logs/1791596009969-742376-0.jsonl`.
This supersedes the earlier log-store result for current fixture acceptance;
production workload sizing, physical-host failure and notification receipt remain
outside this disposable machine gate.

The control-room completion audit removed only the retired `fleet` navigation
entry, preserving the nine current admin pages. Initial native execution reached
the retained roles, elevation/refusal/audit/demotion and mounted login-expiry
checks, then failed final fresh navigation: a valid independent remembered
credential resumed into the fresh-MFA security page under ADR-0123. A second
fixture expired both stored login and remembered timestamps and checked that no
stored live records remained, but also failed final navigation. The remembered
JWT's signed expiry was unchanged; runtime JWT verification and revocation are
the accepted boundary. These are failed fixture assumptions, not evidence for
an authentication defect or passing final refusal.

The final fixture preserves the original user-only login expiry and mounted
refusal deadline, then uses the actual sign-out confirmation. It establishes one
remembered credential beforehand, zero afterward and an increase in nonexpired
revocation rows. The original fresh admin refusal remains, with an additional
export refusal. Production authentication code, ADR-0123 rationale and all
earlier authority assertions are unchanged. Contract discovery/semantic review,
Ruff and packaged Playwright/composed-driver typing pass. The packaged browser
helper at
`/nix/store/2qdf38xg1x2gdn9bnirjypp0ky94k8xk-control-room-browser-typed/browser.py`
is byte-identical to the reviewed current fixture.

The complete corrected native gate passed with exit 0 and driver footer
`test script finished in 63.59s` (nested script 63.55 seconds), at
`/nix/store/71j99s7x7hdacy7dgvkqnybnddb5csw2-vm-test-run-overalls-control-room-browser`.
The actual browser authority subtest passed in 33.60 seconds; the Nix invocation
took 367 seconds including source-built Marshall. The wrapper log is
`/tmp/overalls-control-room-retirement-signout-final.log`, and the full build log
is `/home/ghuntley/.local/state/nix/build-logs/1791597135963-924633-0.jsonl`.
Earlier failed wrappers remain
`/tmp/overalls-control-room-retirement-final.log` and
`/tmp/overalls-control-room-retirement-expiry-final.log`; neither establishes final
fresh-request refusal. Architecture impact is fixture/evidence correction for
ADR-0149's retired UI and ADR-0123's retained authentication boundary.

The current Marshall observability gate's browser request client initially
failed disposable TLS trust before it could evaluate the retired page's 404.
The fixture now adds `NODE_EXTRA_CA_CERTS=/run/overalls-test/ca.crt`, retaining
Chromium NSS trust and verified TLS. Its reviewed contract names the forty
Prometheus rules and strict retired-page refusals. The complete current native
execution passed with exit 0, driver footer `test script finished in 113.32s`
(nested script 113.26 seconds), at
`/nix/store/q4qgzxakvmrc90kjg5n3vxh9kddsbvx2-vm-test-run-overalls-otel-marshall`.
Recorder loss passed in 4.48 seconds, clean deployment in 14.71 seconds, producer
loss in 16.95 seconds and the actual browser journey in 12.10 seconds. The
browser reaches strict removed-page 404 before and after ordinary login, no
overview navigation links, and current/remembered revoked-authority refusals.
The wrapper is
`/tmp/overalls-otel-marshall-retirement-native-trust-fixed.log`. The preceding trust
failure remains historical; no production authentication or transport behavior
changed, and notification receipt remains deployment acceptance.

The remaining lifecycle and Porsche clone fixtures still expected Lilly
`Dataset`/`Execution` diagnostics in Marshall. Their corrected audit helpers
require zero provisioner rows for fresh fixture VMs. Lifecycle now checks both
deleted host victims against their exact initiating owner/VM deletion intent
and system accepted deleted observation. The clone helper preserves the previous
exact count of two completed request IDs and additionally binds both destination
VMs to their human enqueue and system successful completion, exact source,
resource/workflow ID and requester. Canonical UUID validation precedes SQL.
Source tracing through `LifecycleAudit`, `Ledger`, `Outcomes` and `Cloning`
establishes the expected transactional action/actor/state fields; independent
contract review found no scoped violation. Native GUID, service/process, storage,
capacity/reservation, guest-data, clone independence and cleanup oracles are
unchanged. These fixture corrections preserve ADR-0149's distinction between
retained application authority/audit and independent diagnostics. Both existing
full base and Porsche lifecycle driver derivations pass their explicit composed
`ty` and Ruff lint gates, recorded in
`/tmp/overalls-fleet-audit-composed-typing-final.log`. Their packaged driver outputs
are `/nix/store/6qz4c2w63348s3b0h6krycabvfbzm7kf-nixos-test-driver-overalls-fleet`
and
`/nix/store/q445626k7y62wpbgnkz9xw77jvi9bsnv-nixos-test-driver-overalls-porsche-lifecycle-fleet`.
The complete captured base runtime passes with exit 0 in 2,324.23 seconds
(nested script 2,323.94 seconds; whole shell 2,785.364 seconds), at
`/nix/store/r6n7bdg75gngrblwrpdv63r9r4795p95-vm-test-run-overalls-fleet`.
The wrapper is `/tmp/overalls-fleet-observability-retirement-final.log`.
Physical lifecycle cleanup passes in 59.97 seconds and exact application-audit
checks for both deleted host victims in 0.46 seconds. The full run also preserves
capacity-race, network isolation, terminal sharing/reconnect, machine/database
loss, daemon-death and authority-refusal oracles. This runtime predates the
subsequent watcher correction and cannot establish that correction's acceptance.
The complete corrected Porsche lifecycle gate also passes with exit 0 in
869.30 seconds (nested script 868.92 seconds; whole shell 1,057.869 seconds), at
`/nix/store/vhq2w5qkr8448q90y240y8vyv5bzmafd-vm-test-run-overalls-porsche-lifecycle-fleet`.
Its wrapper is `/tmp/overalls-porsche-lifecycle-watcher-native-final.log`; the
realized output is independently confirmed by `nix path-info`.
The real browser/native SSH lifecycle passes in 703.71 seconds, including exact
independent disk/data, relocation and source/copy deletion oracles. The final
clone audit passes in 0.49 seconds, binding both destinations to their exact
source, request/workflow, initiating user enqueue and successful system
completion, with zero provisioner diagnostic rows for source and copies.
It executes the frozen corrected typed watcher before the incoming Starship
guest runtime/fixture changes; no merged guest execution is claimed. Ubuntu and
additional cloning matrices have not been rerun for this correction.

Overview/index review found present-tense ADR-0132 claims for the removed
`/admin/slos` reader despite the overview's historical-evidence warning and the
index's correct superseded status row. The narrow prose correction explicitly
marks that reader and its captured review as historical, points current views to
ADR-0149's Grafana provisioning and preserves the Prometheus objective/unknown
history boundaries. No accepted rationale, implementation status or historical
execution claim is upgraded.

Actual formatter review found that seven services use nested
`LoggerJSON.Basic` metadata, while `Brady.Log` emits its reviewed health values
at the top level. The previous synthetic transport fixture modeled all eight
as nested and therefore missed a production bridge compatibility gap. The
correction admits flat health only when trusted journal classification selects
Brady, the exact event is `brady.observability_health` and nested metadata is
absent. Existing finite numeric validation and source-derived labels remain.
The new source-built Elixir fixture calls the actual packaged `Brady.Events`
declaration and `Brady.Log.format`, checks the exact four reviewed numeric
fields/types and verifies removal of undeclared metadata. Foreign units/service
claims, conflicting nested metadata, invalid numeric values, normal application
records and metrics-only payload refusal are covered separately; the other seven
services' nested health fixtures remain synthetic.

The complete current Fluent Bit process/transport gate passed with exit 0 at
`/nix/store/h8qj1h046ayniqc1hc36dxv1c6k98ria-overalls-logging-transports`, with a
431.15-second whole Nix timer in
`/tmp/overalls-logging-brady-flat-health-native-final.log`. Actual Brady shape,
refusals, privacy, trusted source/correlation routing and independent cursor
custody passed. Actual fixture compilation with warnings denied and pinned
scoped Dialyzer against the fixture plus unchanged Brady beams pass with zero
warnings, recorded in `/tmp/overalls-brady-health-fixture-dialyzer-final.log`.
This is unit/process evidence; it does not establish NixOS machine acceptance,
live SDK supervision or fleet throughput. Architecture impact is compatibility
repair within ADR-0149's accepted finite source/field boundary, with no additional
application authority or observability destination.

Final independent Collector custody review identified a production discrepancy:
both persistent queue extensions omitted `fsync`, whose pinned default is false,
despite ADR-0149's explicit fsynced delivery requirement. Guest trace intake also
acknowledged through an asynchronous prequeue batch and expired elapsed retries
after 300 seconds. The current correction explicitly enables fsync in the
separate application/guest queues, removes the guest trace batch and sets its
retry limit to `0s` (unlimited), matching the existing application trace setting.
Each queue retains its 64-entry bound and source separation. The new
`collector-trace-custody-configuration` evaluated-module contract/regression
checks exact storage/exporter/pipeline binding, fsync, enabled/bounded queues,
unlimited retry and absence of prequeue batching for both trace paths. Metrics
batching and control/accounting authority are unchanged. This fixes code to meet
the accepted decision without changing its rationale or silently claiming the
prior settings were durable. The evaluated `collectorTraceCustody` case passes
with `true`; the first corrected native Collector gate passes with exit 0 and
footer `test script finished in 432.85s` (nested script 432.74 seconds), at
`/nix/store/hh20hzz0n8cqa4s87bamwvm9r0nlfyh9-vm-test-run-overalls-otel-fleet`.
The combined Nix invocation took 597.34 seconds; its wrapper is
`/tmp/overalls-collector-fsync-native-final.log`.

That passing fixture predates stronger crash synchronization: both worker
twelve-second waits are removed and all three original queue journeys now
SIGKILL the Collector immediately after its HTTP acceptance. Guest backend
outage, authenticated-tunnel outage and the private application queue retain
their exact trace IDs, source separation, refusal/recovery checks and deadlines.
The strengthened native crash gate passes with exit 0 and footer
`test script finished in 500.09s` (nested script 500.02 seconds; whole shell
527.36 seconds), at
`/nix/store/lc896lmvjjzs72pg8hf88p73ay0yyanr-vm-test-run-overalls-otel-fleet`.
Its wrapper is `/tmp/overalls-collector-fsync-sigkill-native-final.log`. All three
exact trace journeys recover after HTTP acceptance, immediate SIGKILL and
restart, without relaxing the original deadlines. This establishes the tested
process-crash boundary, not physical power-loss durability. Earlier captured
physical base/Porsche journeys remain applicable to their unchanged execution
paths, but cannot prove the corrected Collector settings.

The final complete real Lilly-to-Tempo recovery gate passes with exit 0 against
the corrected typed watcher and fsynced Collector configuration in 707.93 seconds
(nested script 707.60 seconds; whole shell 796.360 seconds), at
`/nix/store/n30gqwncgn0w9r0j8lahs370x8mb75rp-vm-test-run-overalls-lilly-observability-recovery`.
The wrapper is
`/tmp/overalls-lilly-observability-watcher-typed-fsync-native-final.log`, with raw
JSONL `/home/ghuntley/.local/state/nix/build-logs/1791601944894-1388639-0.jsonl`;
the realized output is independently confirmed by `nix path-info`.
The collector/spool outage group passes in 113.51 seconds, preserving exact
physical guest/VMM/receipt and readiness oracles, the original 180-second pending
drain, retained archives and the exact fresh native transition queried from
Tempo. Whole-daemon authenticated launch recovery passes in 299.61 seconds across
three histories, six before/after submission checkpoints and eight settled
reopens. The intentionally interrupted pre-correction run remains non-passing
evidence. The final native capture predates incoming Starship guest runtime and
fixture changes; it does not claim their merged execution or physical-host
power-loss durability.

The final Lilly source-contract audit reconciles five files (twelve comment
additions and eleven removals): provisioning lock/readiness contracts, journal
writer contention, the actor's physical-ACK retry note/test contract, and backup
history's state-only v2/validated legacy v1 envelopes. Direct diff review confirms
no executable code, assertion, deadline or lock change. Contention remains a
bounded retry with nothing written, never host fencing; diagnostics cannot gate
the retained readiness observation. This removes the retired audit-sender/outbox
assumption without weakening authority or rewriting accepted rationale. The
captured full pinned Lilly precommit gate passes 524 checks (103 properties and
421 tests), seed 232788, in 98.3 seconds; forced Dialyzer has zero errors and zero
skips in 16.1 seconds. The whole shell timer is 160.09 seconds, separate from the
log at `/tmp/overalls-lilly-retirement-comments-precommit-final.log`.
Captured native execution paths remain unchanged; these component checks do not
prove physical isolation or the new Collector custody configuration.

An earlier complete relocation rerun remained failed at its first midstream fault
predicate after six preceding physical journeys. Source/package review ruled out
a ZFS wrapper or changed native journal shape. The disposable `/proc` helper
instead treated every missing executable as incomplete before selecting eligible
userspace transfer processes; native kernel threads have no executable. Its new
typed parser reads at most 4,096 bytes and excludes only validated
`PF_KTHREAD` flags. Malformed, oversized, unknown or racing userspace observations
still make the scan incomplete. Exact unique helper/ZFS-parent identity, more
than 1 MiB streamed, physical authority and original deadlines are preserved.
Six isolated procfs regressions pass; the original helper fails the exact
kernel-thread/native-witness regression with exit 1. Pinned all-files Python
format/lint/type and standalone helper/test typing pass. Logs are
`/tmp/overalls-relocation-diagnostic-python-final.log`,
`/tmp/overalls-relocation-diagnostic-original-failure.log` and
`/tmp/overalls-relocation-diagnostic-standalone-ty-final.log`.
The pinned Nix regression gate also passes all six cases in 0.016 seconds, at
`/nix/store/ndmz5615ld3ib2xa4z9hd5nyplag4sns-overalls-relocation-diagnostics-tests`,
recorded in `/tmp/overalls-relocation-diagnostic-nix-final.log`.
This repairs verification within ADR-0149's independent fault synchronization;
it changes no production execution path and does not turn the failed full run
or isolated parser tests into native relocation acceptance.

The subsequent corrected typed-procfs full relocation capture exits 1 after
1,958.249 seconds for the whole shell, without a complete output artifact. Its
exact derivation is
`/nix/store/pbdc9djqlng5ld8hk4akpkgzdkg16www-vm-test-run-overalls-relocation-fleet.drv`,
with wrapper `/tmp/overalls-relocation-kernel-thread-native-final.log`.
The live move passes in 262.70 seconds, return in 181.98 seconds, stopped move in
155.72 seconds, pre-handoff cancellation in 41.21 seconds and Delete in
7.55 seconds. Actual nonempty midstream cancellation now passes in 90.33 seconds
under the original complete procfs scan, unique helper/ZFS child and more-than-1-MiB
witness, independently establishing that repaired synchronization boundary in this
native capture. Both-endpoint restart recovery also passes in 368.53 seconds.
The next fresh guest setup fails at `seed_relocation_guest`/`await_running` before
the completed-final-receive fault is injected. `private_services_unavailable`
corresponds to the previous reboot deleting the fixture's public
`/run/galileo-audi-root.pem`; Galileo startup and required Audi-private dependency
then fail. The correction retains that exact public root across reboot and checks
actual private-service readiness before continuing, preserving fault schedules and
original bounds. The failed full run stays failed; its passing prefix does not
establish later receive faults, incoming Starship/profile migration or
physical-host power-loss acceptance.

The complete corrected relocation gate exits 0 with all 19 subtest footers,
using frozen derivation
`/nix/store/vqmp9ypkb52nnq7w93nl3410wb8vjxkn-vm-test-run-overalls-relocation-fleet.drv`
and driver
`/nix/store/hp58jifzd3dzlrwjkc9viif6l22sydcx-nixos-test-driver-overalls-relocation-fleet`.
The actual output is
`/nix/store/11ibfwp2xv1jdf53vn3gr3q22mhdc3hg-vm-test-run-overalls-relocation-fleet`,
recorded at `/tmp/overalls-relocation-trust-native-final.log`. The VM-run footer is
3,643.75 seconds, the following script footer 3,643.99 seconds and the Bash wrapper
3,654.445 seconds. Independent inspection confirms the realized output and every
subtest footer:

| Captured relocation subtest | Passing duration (seconds) |
| --- | ---: |
| Runtime credentials and explicit schema migration | 20.24 |
| Public browser/private fleet separation | 0.25 |
| Authenticated observations enable disabled fixtures | 71.16 |
| Guest trust precedes legacy feature admission | 25.07 |
| Live move with post-baseline guest writes | 202.93 |
| Return placement retains final data | 172.11 |
| Initially stopped guest moves without destination boot | 158.23 |
| Pre-handoff cancellation with unavailable destination cleanup | 40.43 |
| Logical Delete releases the final retained copy | 8.19 |
| Actual nonempty stream cancellation restores source | 84.28 |
| Durable phases recover across both endpoint daemon restarts | 381.13 |
| Completed final receive survives endpoint loss before control receipt | 232.39 |
| Cancellation after physical source stop restores data/fresh authority | 207.57 |
| Readiness timeout retains source; Delete reclaims both copies | 328.38 |
| Delete during unavailable destination cleanup retains disk/address | 206.12 |
| Actual endpoint updates resume interrupted native transfer | 336.29 |
| Failed readiness retries under new boot without source rollback | 389.19 |
| Actual source pressure selects stopped-copy without changing identity | 484.63 |
| Destination ENOSPC preserves holds and resumes after physical recovery | 269.67 |

The two trust-custody source checksums remain unchanged during execution; no
physical/audit oracle, actual fault or deadline is weakened. This capture includes
the incoming profile implementation and Starship guest source. Later option
descriptions, fleet comments, the separate `e3300040` image-template fixture and
decision-status edits change no relevant tested runtime values. This does not
establish the packaged retained-state upgrade, native Starship prompt rendering,
the full clone/Ubuntu matrix, physical-host failure, independent live deployment,
retention sizing or notification receipt. Earlier native failures and their
archives retain their own scope.

A subsequent real Brady fault run exposed a production execution-watcher race.
The target had one VMM, one watcher and one pidfd with a valid starting cursor;
the target's `outcome_unknown` report then revoked routing, and
`Actor.follow(_none)` can close the native watcher before it reports the genuine
process exit. The actor now retains the exact bound watcher after withdrawal
without retaining any proof row or authority. Actual terminal reports, verified
target replacement, superseding commands and shutdown retire the old watcher;
there is still at most one per actor. Internal `proof_target` restricts the long
backstop and late `armed` renewals to the exact currently proven VMM. Unknown or
unarmed targets keep two seconds; different boot evidence revokes old live
authority before publishing roster-only proof, and same-target boot evidence
cannot renew the running deadline. Journal contention cannot relabel held proof.
This repairs the accepted liveness decision, as recorded in
[ADR-0140](../decisions/0140-event-driven-liveness-and-single-writer-views.md).

The shell fixture's timeout/EOF distinction is corrected before comparing the
true original actor, which fails the exact port-retention regression. The
corrected actor watcher suite passes 13 checks (one property and twelve tests)
in 1.4 seconds, recorded in `/tmp/overalls-brady-watcher-race-fixed.log`.
The corrected-fixture baseline exits 2 with zero of one passing and seven
excluded checks, at `/tmp/overalls-brady-watcher-race-baseline.log`; the original
watcher port is already absent at the exact retention assertion.
Source/contract review covers actual exit/error retention, stale/ambiguous target
and delayed armed refusal, different boot target, command supersession and
shutdown. This is deterministic actor/port evidence, not native pidfd proof.
Root held queued Porsche and renewed real Lilly recovery to recapture the
corrected runtime. The completed base gate remains scoped to its captured
pre-correction actor.

The first full watcher gate passed 530 application checks but failed Dialyzer
with five warnings after 18.5 seconds. Its closed-map private predicate spec
excluded the other actor state fields. The equivalent correction accepts
precisely typed `Watch.t()` and `Watch.target() | nil` inputs, passing only those
two fields. Independent source review found no semantic change. The first raw
wrapper was overwritten; the actual tool transcript and explicitly transcribed
`/tmp/overalls-lilly-watcher-first-gate-failure-summary.txt` preserve the failure.
That summary is not an original raw execution log.
The final complete pinned Lilly gate passes with exit 0: 530 checks
(103 properties and 427 tests) in 66.8 seconds and forced Dialyzer zero errors,
skips and unnecessary skips in 11.46 seconds, recorded in
`/tmp/overalls-lilly-watcher-final-precommit.log`.
The current complete typed native Brady gate passes with exit 0 in 359.64 seconds
(nested script 359.33 seconds; whole Nix 625 seconds), at
`/nix/store/xy3r24b2qadnwj7w00lsfgpr5j57vc9x-vm-test-run-overalls-brady-fleet`.
The wrapper is `/tmp/overalls-brady-fleet-watcher-typed-final.log`, with raw JSONL
`/home/ghuntley/.local/state/nix/build-logs/1791601298741-1323264-0.jsonl`.
The pre-kill count-only witness shows one VMM, one target watcher, one pidfd and
a valid cursor. Real VMM death produces the actual `exited` event for the exact
placement and revokes attribution in 99 ms, within the unchanged 1,000-ms bound;
post-kill attribution is unresolved. That fault subtest passes in 0.64 seconds,
address-reuse refusal in 69.79 seconds, actual independent infrastructure export
without Marshall ingestion in 0.56 seconds and legacy live-owner attribution in
15.99 seconds. Full restart/history and guest-lifetime checks also pass. Earlier
failed Brady runs remain failed. The current native capture predates incoming
Starship guest runtime and fixture changes, and does not establish merged guest
execution. The complete Porsche lifecycle gate also passes against the exact
recaptured frozen typed derivation as recorded above; the prior captured
pre-helper artifact was not launched. Current real Lilly recovery now has
separate complete native acceptance above. The corrected full relocation gate
also passes separately as recorded above after the fresh-guest trust fixture
failure; deterministic ordering/component checks, Porsche lifecycle and the
Collector crash gate retain their distinct captured scope.

| Area | Observability boundary reviewed | Result |
| --- | --- | --- |
| Marshall | Application transactions, host report locks, inference accounting, diagnostic domain readers, HTTP entry and privilege filters | Retired diagnostic API/resources/views; retained current control/security/audit/accounting. Added catalogued numeric runtime metrics and a payload-free router request scope. |
| Lilly | Native journal publication, archive import, writer lock release, readiness outcomes, host resource collection, native command/transfer wrappers | State-only journal migration preserves exact historical bytes; diagnostics hand off after lock release. Reports retain authority measurements; exporter carries utilization. |
| Ziggy | Private completion spool, reporter replay, inference HTTP outcomes and guest SSH final check | Accounting v2 removes diagnostic fields on wire, keeps private completion and existing SLO totals. |
| Audi, Brady, Galileo, Porsche, Enrico | HTTP/DNS/SSH/utility scopes, Events facades, credential/privacy filters and numeric SLO recorders | Shared reviewed catalog + official SDK; bounded typed spans. Brady requests and Porsche metrics no longer bypass Events. |
| Protocol and request-accounting library | Wire schemas versus independent request measurement | Protocol contains pure closed schemas and authenticated control transport. No diagnostic-export dependency was added to it. Durable request accounting remains separate from trace sampling; its producer and aggregate now live in `elixir/request_accounting`. |
| Rust native helpers | Host lock, launch guard, boot log, image copy, transfer/export channels, resume token, VM watch, flow labels, KVM probe, namespace unmount, Git owner | Helper output/custody protocols retain their existing authority; wrapper instrumentation avoids payload capture and double counting. Native fault coverage is recorded separately in the implementation review. |
| Rust outer observability | Guest receiver, exporter/recorder binaries, independent spool, terminald, Lyra | Independent spool authenticates Unix peer UID and exact cgroup, sanitizes OTLP, retains durable archive and replay state. Guest diagnostics never become outer fleet authority. Terminal and guest local event boundaries remain restricted. |

Lyra's reviewed guest tool telemetry used two synchronous uploads after the
terminal ACK. One fixed-capacity observer queue now owns all TLS/HTTP work;
nonblocking admission and a single worker keep collector loss or saturation out
of executor progress. Cumulative numeric snapshots remain separate from sampled,
best-effort fixed-name spans. The existing Rust protobuf encoder and guest
provenance receiver remain the boundary; native helper protocols remain exact.

## Contract and evidence limits

Contract discovery includes root/component/native directory CONTRACTS and local publication, accounting, privacy and source-custody notes. The final implementation review records syntax/type/native/gate execution at the tested revision. Generated catalog registration and passing syntax gates alone do not establish semantic sufficiency, physical isolation or production throughput. Historical deleted-source evidence remains scoped to the captured baseline. Production retention sizing, actual notification receipt and physical-host failure acceptance remain deployment work.
