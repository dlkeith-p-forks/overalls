# ADR-0133: Durable physical service level accounting

- ID: ADR-0133
- Date: 2026-10-02
- Status: superseded
- Implementation: partial
- Components: Marshall Compute, Marshall SSH, Lilly, NixOS, OpenTelemetry
- Supersedes: none
- Superseded by: ADR-0149

## Context

[ADR-0149](0149-independent-observability.md) replaces application diagnostic
transport, persistence and presentation, with Lilly v4 and Ziggy v2 documents.
It carries forward unrelated authority, isolation, transactional audit/accounting
and recovery requirements. The original rationale and historical evidence follow.

The user authorized completion of the remaining SLOs, Marshall presentation,
deployment and seven-day targets and burn alerts. Browser response and SSH
dispatch counts do not measure creation readiness or physical completion.
Marshall retains immutable authenticated physical outcomes, canonical SSH
request-to-operation links and authenticated historical Provisioning transitions.
Lilly's independent VMM processes can survive a daemon restart. Restarting an
accounting sidecar cannot establish that their work failed.

## Decision

Add Ash-owned measurement attempts and permanent numeric totals to Compute.
An operation admits its physical-lifecycle measurement in the enqueue transaction;
initial provisioning also admits creation-to-ready. An accepted SSH receipt
linked to an operation admits a separate physical-command measurement in its
receipt transaction, retaining the measured operation's original admission and
deadline. Operations predating durable admission stay outside this rollout's
denominator; linking to them cannot fabricate historical measurements.
Idempotent replay creates neither extra admissions nor
extra totals. The retained admission has a fixed deadline: ten minutes for
ordinary provision/start, fifty minutes for Inception provision/start, and two
minutes for stop/delete/resize. These measure committed admission to received
evidence and include materialization and report transport.

Physical success requires the operation's matching running/stopped/deleted
outcome; resize requires the existing validated stopped result. Creation readiness
and SSH provision/start additionally require a Provisioning ready transition
matching host, placement, execution epoch and generation. Both observations must
have reached Marshall by the original deadline. Historical audit is additional
reliability evidence only: it never authorizes execution, changes receipt status,
or releases reservations. Producer readiness still requires its exact verified
boot under ADR-0130. Unknown physical observations remain pending. Missing
evidence at the deadline creates an immutable measurement failure, without
cancelling or replaying work. A later outcome does not rewrite that result.

The migration initializes three permanent source rows before admission code
starts. Admission reads them without a global lock; missing source rows refuse
admission. Received physical and audit timestamps use the database clock shared
with admissions and deadlines, keeping producer occurrence times separate.
Each reconciled attempt locks its measurement row and updates its fixed service
total in the same transaction. Each attempt uses a separate transaction; a
bounded, least-recently-checked scan prevents old pending attempts from starving
later work and avoids acquiring several service-total locks in differing orders.
Counters, duration buckets and source lifetime survive BEAM restart. Exported
snapshots contain fixed numeric fields only and are reconstructible from the
database; their files are not durable authority. Pending-only indexes support
the checked-at/ID scan and overdue-deadline guard without including completed
measurements; the existing historical index remains available.

Attempts belong to their operation through a cascading foreign key. Production
exposes no operation deletion action. Run-owned fixture cleanup can remove its
operations and attempts without deleting permanent aggregate rows or resetting
their source lifetimes and totals.

One Overalls Marshall instance publishes these shared-database totals. Three
independent Rust exporter users read mode-0640 source snapshots and send through
three group-restricted collector intakes. Each intake fixes its service, host and
outer-source provenance. This adds three provisional 99% seven-day objectives
to ADR-0132's roster, with the same coverage, freshness and burn policy. Lifecycle
histograms have seven fixed bounds from one second to fifty minutes. The existing
short application histogram remains separate. Marshall exposes all three names,
readings, targets and actual burn states through its existing authenticated page.

### Workflow completion extension

Four additional permanent sources measure clone, relocation, destination retry
and cancellation commands independently: `porsche_clone`, `porsche_relocate`,
`porsche_retry` and `porsche_cancel`. Accepted canonical SSH receipts admit a
Compute-owned workflow attempt in their mutation transaction using a database
clock captured before mutation. Each attempt retains a ten-minute deadline and
the clone sequence where applicable. Replays cannot reset these fields.
Synchronous terminal cancellations may finish in admission; later reconciliation
reads immutable terminal audit evidence without refreshing receipts.

Explicit cancellation or supersession of an original completion intent creates
a retained exclusion, omitted from both numeric success and failure counters.
Cancellation commands have their own denominator and require confirmed
cancellation. Other terminal failures and expired missing evidence count as
failure. Retry activation alone cannot succeed: the immutable start operation
must match VM, relocation and generation, with exact physical running evidence
and committed readiness received within the admission window.

An additive migration initializes only these four new lifetimes. All seven
sources have independent Rust exporter identities and collector intakes on
Overalls, provisional 99% seven-day targets, and authenticated Marshall cards.
Both pending queues must have no overdue work before fresh publication.
Native clone/relocation receipt-bound measurement and seven-source restart
conservation passed the final SSH journey in 1191 seconds. Native clone
source-restoration retry measurement passed a scoped 7.97-second subtest with
exact receipt replay and aggregate conservation in the
[retention review](../reviews/2026-10-03-telemetry-retention-and-diagnostics.md).
The overall run later failed copied-guest readiness before cancellation.
The corrected copying-window run passed native clone retry measurement in 8.87
seconds and native clone cancellation measurement in 8.48 seconds, each with
exact replay and conservation. Source restoration and destination cleanup passed;
the full matrix later failed ordinary clone relocation with source_unavailable.
Relocation destination retry and cancellation acceptance remain pending.
Both hosts activated `6a0b3c32` healthy;
live verification preserved the original source identities/lifetimes and monotone
counters while adding all four exporters, twenty objectives and forty evaluators.
Seven-day compliance remains unmeasured.

The [continuing boot correction](../reviews/2026-10-03-telemetry-retention-and-diagnostics.md)
aligns an already-running VM's durable boot journal with a newer logical intent
after proven confinement, preserving its physical epoch/challenge. It retains
current-generation readiness, original measurement deadlines and immutable
outcomes. Scoped metadata properties, native repeated-start process continuity,
clone cancellation accounting and the full Lilly component gate passed. The
complete native clone matrix passed in 1539.61 seconds, including retry/cancellation
replay, physical cleanup and independent clone relocation. Native foreign/corrupt
boot refusal and relocation destination retry/cancellation accounting remain open.

## Alternatives

Receipt polling would omit requests whose client disconnected and entangle
accounting with UI reads. In-memory counters could lose admitted work on crash.
Restart-based failure finalization could incorrectly classify surviving guests.
Treating a running VMM as boot readiness would omit trust, certified SSH and
writable-root checks. Reusing both hosts as publishers would count the same
shared-database outcomes twice.

## Consequences

Admission now requires measurement persistence in the same database transaction.
An unavailable database cannot admit unmeasured physical work through this path.
Measurement rows and three aggregate rows add persistent storage; attempts are
not pruned in this change. A bounded reconciliation backlog delays publication
of terminal counts, while deadlines retain their original timestamps. Publication
withholds fresh snapshots while any overdue pending attempt remains after a scan;
the scheduled publisher removes snapshots on this refusal and retries normally.
Numeric
overflow or publication failure must leave the source unavailable, not fabricate
fresh measurements. PostgreSQL and the single publication instance remain
measurement failure boundaries. No migration runs implicitly during app startup.

## Invariants and verification

The native fleet's private sentinel-fenced helper invokes the production
reconciler without receipt refresh, forged outcomes or altered deadlines.
[Agent assertions](../../../nix/tests/machines/fleet/scenarios/agent.py) and
[NixOS/Ubuntu Porsche assertions](../../../nix/tests/machines/fleet/scenarios/user-ssh-journey.py)
require actual successful guest measurements and identical permanent source
identities/counters/buckets after Marshall restart and repeated scans. These
agent assertions passed the serial native NixOS check in 900 seconds, as recorded
in the review. The full serial NixOS Porsche journey passed in 1206.15 seconds; a subsequent
full merged Ubuntu journey passed in 997.02 seconds. Both establish real creation,
SSH completion and restart conservation for their captured snapshots. Earlier
failures retain their separate scope. The production activation evidence below
records verified retained readiness journals; fresh creation and live provider
acceptance remain open.

- Admission rollback leaves neither a new operation nor measurement rows and
  leaves the existing migrated source lifetimes and totals unchanged.
- Replays, retries and repeated scans do not double-count terminal measurements.
- Foreign-generation readiness, late evidence and absent physical observations
  cannot manufacture success. A timer changes measurement state only.
- Process restart preserves database source identity and counters. Exporter
  users cannot write snapshots or access application credentials.
- Property tests cover deadline histories. Database tests inspect actual Ash
  admissions, readiness binding, totals and immutable results. NixOS tests must
  cover packaged publication, collector provenance and authenticated cards.
- Native NixOS/Ubuntu guest journeys and producer activation are required before
  claiming complete physical readiness acceptance or measured fleet compliance.

## Implementation evidence

The [workflow resource](../../../marshall/lib/marshall/compute/workflow_service_level_attempt.ex),
[workflow reconciler](../../../marshall/lib/marshall/compute/workflow_service_levels.ex)
and [workflow properties](../../../marshall/test/marshall/compute/workflow_service_levels_test.exs)
implement receipt-bound accounting and retained exclusions. Their test scope and
native clone/relocation acceptance and remaining retry/cancellation gaps are
recorded separately in the review.

The [mixed backlog property](../../../marshall/test/marshall/compute/service_level_backlog_history_test.exs)
now exercises both operation and workflow measurement queues through actual
admission actions, fixed 100-row boundary witnesses and complete immutable
execution/receipt and terminal-row inventories. The reviewed combined focused
run passed two properties (seed281508,49.7seconds); full batch precommit passed1,418checks (217properties,1,201tests),
seed981745,1055.5seconds with forced Dialyzer36.71seconds and zero errors.
The subsequent exact-bucket assertion passed its focused two-property follow-up
(seed437252,48.7seconds, warnings-as-errors and terminal exit0). The [history review](../reviews/2026-10-02-relocation-and-workflow-backlog-histories.md)
keeps sandbox clock controls separate from native publisher and hosted evidence.

[Admission hook](../../../marshall/lib/marshall/compute/service_level_admission.ex),
[attempt resource](../../../marshall/lib/marshall/compute/service_level_attempt.ex),
[reconciler](../../../marshall/lib/marshall/compute/service_levels.ex),
[permanent total](../../../marshall/lib/marshall/compute/service_level_total.ex) and
[publisher](../../../marshall/lib/marshall/compute/service_level_publisher.ex)
implement retained measurement accounting. The
[properties and database tests](../../../marshall/test/marshall/compute/service_levels_test.exs)
have recorded passing focused execution in the
[review](../reviews/2026-10-02-durable-physical-slos.md).
[Nix custody](../../../nix/modules/otel-fleet/service-levels.nix) and
[Rust exporter](../../../nix/modules/otel-guest/receiver/src/slo.rs) define the
collection boundary. Native publication/browser checks and full Marshall and
protocol gates have recorded passing execution in the review. Both production
hosts activated `3f7ebc11`; live checks verified three isolated exporters,
16 objectives, 32 burn evaluators and 45 dashboard panels. Producer readiness
activation deployed healthy on both hosts at `c98a375c`. Passive post-switch
verification found ready journals for all 22 current retained boots; three
deletions preceded activation. Terminal measurement digests and live snapshot
totals are unchanged. Fresh production creation, live provider acceptance and
seven-day compliance remain separate evidence requirements.

## Open questions

Notification destination remains requested from the user. Complete seven-day
observation, final measured targets, physical guest/provider acceptance and
durability of other application sources remain outstanding.

## Related decisions

[ADR-0132](0132-seven-day-provisional-fleet-objectives.md),
[ADR-0130](0130-verified-provisioning-fastpath.md),
[ADR-0074](0074-durable-lifecycle-state-machines.md),
[ADR-0046](0046-porsche-ssh-management.md).


## Mixed service level backlog histories (focused execution recorded)

The local draft property `mixed deadline backlogs preserve totals and refuse
premature freshness` extends ADR0133 evidence without changing its accepted
architecture or partial implementation status. It uses real Ash admissions and
bounded production reconciliation, with sandbox-only synthetic measurement clocks.
Every history owns a fresh sandbox so an expected publisher rollback cannot
abort an enclosing workload transaction. Exact first-scan counts enforce the
100-attempt bound; second-scan completion checks progress past future attempts.
Future attempts remain pending, operations remain unchanged and terminal totals,
buckets, durations and source lifetimes remain exact. Refusals retain prior file
bytes; success must advance a shared sample clock and publish the same lifetimes
and numeric totals. The value menu covers0/1/99/100/101/102 overdue attempts,
with fixed zero/below/at/above/all-overdue witnesses and both ordering families.

Fresh source review caught and repaired nested rollback isolation and the missing
bounded-scan oracle; success freshness checks were then strengthened. Formatting and compilation passed. The ID-map version passed one focused
property (seed `572736`, 49.8 seconds); the stronger successive-sample oracle also passed (seed `614922`, 44.3 seconds).
Full gates and HLDD verification remain pending. No external
commit, process restart, independent publisher contention, native guest outcome,
collector/exporter or hosted fault claim follows from this draft. Existing
native execution records retain their original revision and scope.


The pinned full Marshall test stage passed 1,413 checks (214 properties and
1,199 tests), with two exclusions, seed `252201`, in 1,289.0 seconds. This
includes the successive-sample backlog oracle. Log:
`/tmp/overalls-slo-backlog-marshall-full.log`. Forced Dialyzer passed in 49.65
seconds with zero errors, skips or unnecessary skips; the full precommit command
exited successfully. Final handbook/evaluated gates remain pending.

The [retry window history review](../reviews/2026-10-02-retry-measurement-window-histories.md)
records actual authenticated retry actions followed by synthetic received-time
controls for both proofs. The focused property passed seed405587 in38.6seconds;
Full Marshall precommit passed 1,419 checks (218 properties, 1,201 tests), two exclusions, seed404257,1135.7seconds; forced Dialyzer42.61seconds with zero errors, skips or unnecessary skips; terminal exit0. It establishes measurement conservation and inclusive
proof windows without claiming native retry, delivery timing or process recovery.

The retry property additionally passed reviewed late-proof histories (seed768114,
44.3seconds): actual ready state and matching success audit arrive after failure
without rewriting exact terminal measurement/totals. Full Marshall precommit passed 1,419 checks (218 properties, 1,201 tests), two exclusions, seed404257,1135.7seconds; forced Dialyzer42.61seconds with zero errors, skips or unnecessary skips; terminal exit0.

The [retry proof binding review](../reviews/2026-10-02-retry-proof-binding-histories.md)
adds authenticated refusal/retained historical receipts and an unchanged-window
database-clock crossing after sandbox backdating. The reviewed four-property run
passed seed158289 in91.9seconds. Full Marshall precommit passed 1,422 checks (221 properties, 1,201 tests), two exclusions, seed930025,1133.1seconds; forced Dialyzer42.96seconds with zero errors, skips or unnecessary skips; terminal exit0.
No native timing, restart or publisher concurrency claim is added.
