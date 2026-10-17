# ADR-0136: Durable application request accounting

- ID: ADR-0136
- Date: 2026-10-02
- Status: superseded
- Implementation: partial
- Components: Rust, Elixir request-accounting library, Marshall, Audi, Brady, Galileo, Enrico, Porsche, Ziggy, NixOS
- Supersedes: none
- Superseded by: ADR-0159

> Superseded by [ADR-0159](0159-remove-legacy-compatibility.md) only for version-one/two checkpoint upgrades and application-owned SLO exporters. ADR-0159 carries every other requirement of this record forward unchanged.

## Context

Eight trusted request sources currently retain completed outcomes in memory:
Marshall browser requests, Galileo integration forwarding, Enrico refresh,
Brady egress, Porsche dispatch and Audi private forwarding, DNS and SSH.
Deployments restart their source lifetimes and crashes can lose unexported
completions and admitted work. The user requires remaining SLOs implemented,
seven-day targets and burn alerts, Rust receivers and meaningful property/native
tests. Saving only completed counters cannot account for lost admissions.

## Decision

Implement a host-local Rust durable recorder for these eight request sources.
The existing authorization/admission boundary remains authoritative. Admit an
opaque numeric measurement before the eligible work begins; no request identity,
path, arguments, credentials or payload enters the recorder. Persist admissions
and terminal transitions before acknowledgment, using private fsynced staged
checkpoints, atomic replacement and directory fsync. Keep a permanent source
identity/lifetime, a never-reused admission sequence and bounded pending work.
The user's instruction to finish all SLOs authorizes this accounting extension.

Each source gets an independent recorder socket and checkpoint. Authenticate
local producers using kernel peer credentials and the configured systemd unit;
UID alone cannot distinguish Audi's three roles. Retain PID, process start ticks
and host boot identity for producer fencing. Only a matching producer may finish
an admission once. Kernel-confirmed producer death or an immutable configured
measurement deadline settles an unresolved admission as failure. A recorder
restart alone must not declare a surviving producer dead. Missing completion
duration stays missing; do not manufacture a latency sample from downtime.
Exclusions remain outside the completion denominator but retain admission
conservation. Producers must distinguish admission refusals from admitted work.

Storage failure withholds fresh source snapshots and poisons the writer until
reopen. Corrupt or missing previously initialized checkpoints refuse startup;
they never silently reset seven-day history. Private checkpoints and bounded
socket frames contain only closed typed accounting data. The exporter retains
its separate read-only custody and existing collector provenance boundary.
Separate groups and directories govern producer RPC and exporter publication;
neither reader access to snapshots nor producer access to RPC grants checkpoint
access. Recorder export selection is explicit and must not fall back to legacy
application sockets or files.

This decision adds no VM execution or provider authority. ADR-0133's database
measurements remain separate; surviving guests must never become failures merely
because a request producer restarts. Keep the current Grafana/Marshall objective
meaning and provisional policy under ADR-0132.

Ziggy is a ninth consumer of the shared pure aggregate model. Its private
completion checkpoint and replay identity protocol remain separate from the
eight host-local producer and Rust-recorder sources covered by this decision.

Retain a durable coverage clock independently of source identity and lifetime.
Authenticated gap reports, recorder restart and admission saturation advance
coverage and mark existing admissions as crossing unknown recording evidence.
Their countable settlements advance coverage through settlement, without marking
later unaffected work uncertain. Exclusions remain outside the budget. Version-one
and version-two checkpoints upgrade conservatively to version three at load time;
missing current admission quality metadata refuses startup. Export
the clock with source snapshots and require matching fresh coverage older than
each objective window, including retained readings and burn alerts. Producer
communication failures must persist and report gaps before fresh evidence resumes;
current heartbeat alone cannot prove that prior admissions were complete.

Keep producer runtime I/O and the pure request-accounting model in a separate
local `overalls_request_accounting` library; the shared protocol library remains
pure. `Overalls.RequestAccounting.Producer` owns admission, terminal custody,
bounded Unix RPC and private clean/running/gap markers. The immutable
`Overalls.RequestAccounting.Aggregate` model owns fixed histogram bounds,
success/failure/exclusion conservation and the validated snapshot shape. It
does not own application eligibility, classification, storage or publication;
those policies remain in each source adapter. Persist private markers with file
and directory fsync. Report a durable recorder gap after an unclean producer
restart or any ambiguous RPC, queue or storage failure. A clean application
deployment preserves coverage only after source shutdown quiesces eligible work
and no admitted work or gap remains. Monitor actual request workers, including
tasks admitted by a coordinator; only the issuer or worker may complete its
ticket. Before an old admission completes during a recording gap, report the
gap durably so completion cannot mask lost coverage. Measurement unavailability
does not grant or revoke application authority. Diagnostics remains a separate
best-effort telemetry library.

## Alternatives

Completion-only checkpoints preserve some counters but omit lost admitted work.
In-memory counters cannot preserve seven-day eligibility across deployment.
Putting every request admission in Marshall's PostgreSQL couples host-local
forwarding and DNS to control-plane database availability. Guest telemetry lacks
the trusted source authority required for outer-fleet reliability arithmetic.

## Consequences

Admission acknowledgment adds local durability latency and bounded queue pressure.
Checkpoint size is bounded by 4096 pending admissions and one MiB. Group commit
may amortize fsync only if every acknowledged transition is included in the
durable state. Recorder saturation and unavailable storage remain explicitly
unavailable measurement evidence; they must not appear as healthy zero traffic.
The recorder is another host-local failure boundary and requires independent
lifecycle supervision, secure producer attribution and native crash tests.

## Invariants and verification

- Every allocated sequence is terminal, excluded or pending; counters conserve
  requests and histogram samples independently.
- Foreign, repeated and late completions cannot change totals.
- Producer and recorder restarts preserve source identity and acknowledged work.
- Dead-producer recovery counts unresolved work exactly once without creating
  duration samples or changing application execution.
- Partial writes, corruption, missing initialized state, symlinks, hardlinks and
  concurrent writers cannot reset or replace committed history.
- Property tests exercise histories and checkpoint reopen. NixOS tests must
  exercise real producer/recorder SIGKILL, surviving producers, socket custody,
  wrong-unit refusal, publication loss, restart continuity and application hooks.

## Implementation evidence

The [native commit/reply-loss design](../reviews/2026-10-05-recorder-commit-reply-loss.md)
records a passing native baseline with a test-only production recorder checkpoint
and generated Client uncertainty histories. Lost/delayed replies after actual
accepted admission, finish and gap commits preserve accounting, identity and
acknowledged recovery across reopens. The native check passed189seconds;
instrumented Rust and composed verification passed. Both scoped properties
detected realistic local native mutants with recorded branch witnesses;
full batch gates remain pending. This does not establish real application,
collector or hosted acceptance or change partial status.

The [generated native producer/recorder review](../reviews/2026-10-05-producer-recorder-histories.md)
describes a present property using the production Elixir client and Rust recorder
in the disposable machine fixture. It checks retained pending authority across
recorder reopens and mixed success/observed-worker-death accounting. Refined native
subtest passed10.77seconds within the74.87-second machine script; composed driver
lint and type checks passed. Full application/collector and hosted gaps remain;
this does not change the partial implementation status.

The [producer worker history review](../reviews/2026-10-03-producer-worker-completion-histories.md)
records a repaired local BEAM death-proof boundary and three generated client
histories: foreign/live-worker messages preserve pending tickets, actual death
settles once, and racing authorized completion/death records one terminal outcome.
The source client project passed nine checks (six properties, three tests),
seed751543. A controlled Unix acknowledgment peer does not extend native Rust
identity, durable storage or production coverage evidence.

The [Rust accounting core](../../../nix/domains/system/otel-guest/receiver/src/durable_slo.rs)
implements bounded admissions, fenced terminal outcomes, conservation validation,
deadline/death reconciliation and private exclusive fsynced checkpoint custody.
Its tests exercise generated histories, real checkpoint reopen, interrupted stage
refusal, missing/corrupt state and poisoned writers. Execution results are recorded
in the [review](../reviews/2026-10-02-durable-request-slos.md).
The [Rust runtime](../../../nix/domains/system/otel-guest/receiver/src/request_recorder.rs)
implements versioned bounded frames, kernel peer UID and cgroup-unit attribution,
PID/start/boot death proof, live-producer heartbeat gating and exporter-compatible
snapshots. The [Nix module](../../../nix/domains/system/otel-fleet/request-recorder.nix)
declares independent unprivileged units and private source custody; its standalone
instance set defaults to empty. The [fleet bindings](../../../nix/domains/system/otel-fleet/request-sources.nix)
now select eight sources on Overalls and five on Dungarees, with independent
exporter accounts and explicit measurement horizons. Legacy request exporters
are disabled while application handlers and database sources remain independent.
The [native test](../../../nix/verification/tests/machines/otel-request-recorder/default.nix)
and [driver](../../../nix/verification/tests/machines/otel-request-recorder/driver.py) exercise
real recorder/producer SIGKILL and wrong-unit/refusal boundaries. Passing execution
is recorded separately in the review. The [producer](../../../elixir/request_accounting/lib/overalls/request_accounting/producer.ex)
uses bounded Unix RPC and [private quality markers](../../../elixir/request_accounting/lib/overalls/request_accounting/quality_marker.ex).
The pure [aggregate model](../../../elixir/request_accounting/lib/overalls/request_accounting/aggregate.ex)
centralizes value-model arithmetic and snapshot construction without taking
ownership of source policy, concurrent storage or persistence.
Hooks now exist for all eight sources; they preserve source-specific admission
and exclusion boundaries. The native fixture exercises the actual BEAM client
against the Rust recorder, separately from real application acceptance.
The measurement horizons account for bounded dispatch/fetch/setup overhead and
use an explicit 24-hour horizon for renewable transports; they do not cancel
work or create a business execution timeout. Actual Marshall HTTP/collector
recovery and Galileo/private-Audi source/collector acceptance now have recorded
native execution in the review. Production activation is recorded in the
[retention and diagnostics review](../reviews/2026-10-03-telemetry-retention-and-diagnostics.md):
both hosts reached healthy updater state on `b7e29b8f`, with zero failures.
Full per-source fault acceptance remains open; deployment health does not prove
every application's crash and storage-failure accounting.
The same review records expanded packaged Enrico native acceptance for recorder
SIGKILL with the producer alive, clean application restart, source outage and
producer SIGKILL during a blocked admitted refresh. Identity and completed
history remain durable; dead-producer settlement adds one failure without an
invented duration. Complete per-source overload/storage-fault acceptance remains
open.

The [DNS native fault extension](../../../nix/verification/tests/machines/audi-dns/slo-faults.py)
has recorded passing execution in that review. It verifies recorder loss with
the real DNS producer alive, clean restart coverage preservation and unclean
idle restart coverage advancement without resetting completed outcomes. Its
publication fixture is isolated and does not confer Marshall domain authority;
The admitted DNS producer-loss extension passed in 11.80 seconds within an
89.06-second full native script. It observes an acknowledged ticket from a real
TCP question before killing the producer, settles one unknown-duration failure
before the unchanged deadline, preserves completed history and recorder identity,
and verifies client failure before timeout followed by fresh DNS recovery.
Complete per-source overload/storage faults remain separate.

The [Porsche native fault extension](../../../nix/verification/tests/machines/fleet/porsche-slo-faults.py)
has recorded passing execution in the same review. Actual approved-key SSH
dispatch and collector acceptance precede recorder loss, clean restart and
unclean idle producer restart checks. Settled history and coverage preserve
their specified transitions, and a fresh SSH command adds one success/duration.
In-flight loss and physical lifecycle fault acceptance remain separate.

The [Brady native fault extension](../../../nix/verification/tests/machines/fleet/brady-slo-faults.py)
has recorded passing execution in the same review. Real guest requests and
collector acceptance precede recorder loss, clean restart and idle producer
SIGKILL. Settled history, coverage transitions and unchanged guest process
identity are checked; a fresh guest HTTP request adds one success/duration.
In-flight loss, overload/storage faults and power loss remain separate.

The [transport native fault helper](../../../nix/verification/tests/machines/fleet/request-slo-faults.py)
has recorded Audi SSH execution in the same review. Registered-key guest SSH
and independent collector acceptance precede recorder SIGKILL, clean restart
and idle producer SIGKILL. Settled checkpoint/publication identity, coverage,
terminal totals and duration buckets match; fresh SSH adds one success/duration
after each recovery, and guest process identity stays unchanged. The expanded
native run passed in 420.26 seconds, including admitted establishment loss:
pausing the real Lilly connector exposes one persisted admission before producer
SIGKILL. Exactly one failure settles without an invented duration, recorder PID
and completed history survive, coverage advances, and a fresh guest SSH succeeds.
The full sequence leaves guest process identity unchanged. Overload/storage
faults and power loss remain separate; this does not verify other sources'
in-flight loss or production history.

The same helper has recorded full `otel-galileo-native` execution for Galileo
and Audi private. Real guest forwarding and independent collector acceptance
precede each source's recorder loss, clean restart and idle producer SIGKILL.
Settled identity, terminal totals and histogram buckets remain durable; coverage
transitions and exactly one new success/duration after recovery pass. The fixture
temporarily pauses SSH refresh and agent polling and restores both afterward.
Guest process identity remains unchanged; the existing load, execution fencing,
peer ingress, relocation and control-plane outage/recovery assertions also pass.
In-flight loss, overload/storage faults and power loss remain separate.

The [recorder machine fixture](../../../nix/verification/tests/machines/otel-request-recorder/driver.py)
has recorded whole-VM hard-stop execution in the same review: 66.87 seconds,
including a 12.13-second restart subtest. An acknowledged pending admission
survives a changed kernel boot and settles once, before its unchanged deadline,
as an unknown-duration failure. Completed history, identity and admission sequence
survive; late completion refuses and fresh admission succeeds. This proves virtual
host recovery of the core, not hardware power loss or application adapter recovery.
Implementation remains partial with source-specific fault acceptance still open.

The [producer uncertainty histories](../../../elixir/request_accounting/test/uncertain_ack_history_test.exs)
exercise real Producer/QualityMarker/RecorderRPC acknowledgment-loss and
gap-recovery properties,
including preserved work return/error/throw/exit semantics. Two properties passed
seed211549 in1.1seconds; [review](../reviews/2026-10-05-producer-uncertain-ack.md).
Controlled acknowledgments do not establish native Rust durable commit/reply
ambiguity, authenticated identity or application acceptance. Component and
dedicated typing, reviewed hooks and evaluated HLDD passed; scope remains partial.

## Open questions

Source-specific measurement horizons and overload behavior require actual
application acceptance before production activation. Recorder coverage
markers, retrospective objective guards and producer-side persistent gap
reporting exist. Full real-source acceptance remains required: cached series
and current freshness cannot prove complete admissions across an outage.
Preserve permanent counters/lifetimes when withholding affected windows.
External notification
delivery still needs a destination; evaluator provisioning is already deployed.

## Related decisions

- [ADR-0132](0132-seven-day-provisional-fleet-objectives.md)
- [ADR-0133](0133-durable-physical-service-level-accounting.md)
- [ADR-0012](0012-provisioner-control-transport.md)
