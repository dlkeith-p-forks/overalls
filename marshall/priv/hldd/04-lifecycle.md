# Machine lifecycle

Keep four facts separate: desired VM state, observed physical state, workflow
phase, and cleanup receipts. A successful state transition records intent; it
cannot prove that a process stopped or a disk disappeared.

```mermaid
stateDiagram-v2
  [*] --> running: initial intent
  running --> stopped: request_stop
  stopped --> running: request_start
  running --> deleted: request_delete
  stopped --> deleted: request_delete
  deleted --> deleted: repeated delete
```

These are **desired states**. The VM resource permits idempotent start/stop
requests. Deletion is terminal intent. Relocation has additional stopped-source
handoff and restoration transitions guarded by its coordinator.

A repeated Start advances logical generation even when the confined VMM remains
running. Lilly adopts the boot journal into that generation only under placement
ownership, after proving the existing native process. The same placement and
execution epoch retain their boot challenge; missing, corrupt, foreign or
regressing journals refuse adoption. Current-generation trust and readiness
remain required before acknowledgement. The
[journal properties](repo:lilly/test/vm/boot_generation_adoption_property_test.exs)
passed isolated generated histories. The repaired clone fleet passed repeated
public Start with unchanged native process identity and guest inheritance. The
complete native clone matrix also passed. Native foreign/corrupt ownership
refusal remains outside this recorded scope.

Lilly keeps volatile execution proof separate from its durable outcome journal
and native exit observer. A negative physical observation withdraws boot/live
authority immediately. Its already bound watcher remains available to report
the actual exit or error; retaining that observer cannot republish proof. One
actor owns at most one watcher, and a superseding command, replacement target
or actor shutdown closes the previous observer.

The thirty-second backstop requires an armed watcher on the exact verified VMM
that supplied the published proof. Unarmed or unavailable target bindings retain
the two-second bound, including after delayed arming messages. A verified boot
target replacing a live target withdraws old live authority before publishing
roster-only proof. A same-target boot observation does not renew running proof.
The ordered [actor/port regressions](repo:lilly/test/vm/actor_watch_test.exs)
exercise these boundaries; native exit delivery remains separately recorded in
the [cutover review](repo:docs/architecture/reviews/2026-10-09-observability-decoupling.md).

```mermaid
stateDiagram-v2
  [*] --> pending
  pending --> acknowledged: host receipt
  pending --> completed: matching outcome
  acknowledged --> completed: matching outcome
  pending --> cancelled: superseded work
  acknowledged --> cancelled: superseded work
  cancelled --> completed: late physical outcome
```

Operation cancellation does not erase a physical effect. A late outcome still
requires reconciliation against the current identity and generation. The
[generated lifecycle history](repo:marshall/test/marshall/compute/lifecycle_history_test.exs)
checks one to four delayed physical receipts after confirmed archival. Their
immutable rows append while VM state and released reservations stay fixed; a
changed replay is refused. This uses synthetic outcomes in local PostgreSQL,
not native guest or cross-host evidence.

A Lilly delete with unconfirmed physical cleanup retains its durable fence and
retries with delays growing to thirty seconds. Pool-lock contention is not a
cleanup failure: it is retried on the next actor tick without that backoff.
The dataset precondition uses an identity observation (ADR-0143). It needs the
same identity, policy, snapshot and coherent accounting as a capacity sample,
but tolerates usage-counter drift, because pool-wide `available` moves with any
write. Earlier exact-usage checks produced 5–23 minute production deletes
under pool writes. Each unconfirmed attempt reports a fixed `stage`.
Stage `destroy` with `lilly.zfs_namespace_cleanup_unconfirmed` exposed the
remaining tail: Nix build sandboxes (user namespaces) held locked copies of a
guest dataset, which ordinary unmount cannot remove, so deletion waited for the
build. Lilly hosts therefore run `nix-daemon` in a private mount namespace
without pool mounts (ADR-0144). The same lock affected services with private
user namespaces (Prometheus, VictoriaLogs, rootless containers) on Overalls, so
`lilly-pool-propagation` makes every pool mount recursively private before Lilly
starts; guest mounts then propagate into no other namespace. Namespaces created
while a guest is mounted still copy it, and no machine test yet covers this
second path. Repeated cleanup failures never
establish deletion or retire the actor; a newer generation bypasses the old
retry deadline. A generated [actor retry property](repo:lilly/test/vm/actor_test.exs)
checks this local journal and scheduling path. Its controlled executor does not
establish native ZFS cleanup or Marshall allocation release.

The audit-retention sweep removes at most 1,000 expired lifecycle and PaperTrail
rows in one transaction and schedules a maintenance-queue continuation when a
batch is full. A [generated backlog test](repo:marshall/test/marshall/compute/lifecycle_audit_test.exs)
checks empty, partial and multiple full batches against remaining expired rows
and continuation counts while preserving the live VM. It drives the action
directly; Oban execution, cron recovery after job failure and elapsed expiry
lag remain untested.

Creation admits an immutable image and shape, reserves capacity and an address,
creates durable placement intent, and dispatches provisioning. Lilly validates
native storage, builds owned drives, installs isolated networking, and starts the
jailed VMM. Readiness requires current physical evidence; job completion alone is
insufficient.

Launches and restarts also require Lilly's private services. Private Audi
(`audi-private.service`) runs in Lilly's network namespace and is both required by
and wanted by `lilly.service`: any Lilly stop stops it, and any Lilly start,
including a stop/start or an enrollment rollback, starts it again. While it is
unavailable Lilly defers new launches and restarts and logs
`vm.execution_deferred` (VM, placement and reason atom, once per reason change);
already-running guests are adopted and unaffected. Private Audi also requires
Ziggy and Galileo. A crash with automatic restart, or `systemctl restart`, of
either restarts private Audi with it, and the auto-updater stops and then
explicitly starts all three around every switch, with private Audi as a health
unit. Only a manual `systemctl stop` followed by a separate `start` of Ziggy or
Galileo leaves private Audi down; use `restart`, or start `audi-private.service`
afterwards. Marshall's ingress
control API still answers any unexpected refusal with a uniform 503, but records
a closed reason class on `audi.control_unavailable`; `reason=unavailable` on
`fleet-certificate` before issuance is expected while ACME is pending.

Generated Marshall admission checks inject insert failures at twelve VM,
audit, agent, ingress, placement, reservation, address, operation and
dispatch-job stages. Each refusal leaves the complete committed public-table
inventory unchanged; a later admission creates one linked set of the checked
rows, and exact replay or changed-shape refusal adds no rows. These local
checks do not exercise optional source or Inception environment writes,
process death at commit ambiguity or native job execution.
Generated [archived replay histories](repo:marshall/test/marshall/compute/admission_test.exs)
return the original VM after one to four same-key retries, reject changed shape,
and preserve the local VM, placement, reservation, address, operation, audit
version and dispatch-job inventory after each prefix. Lost HTTP replies,
simultaneous callers and cross-node replay at an uncertain commit remain open.

Generated three-node capacity histories reject retained structured SQL deadlocks
and accept clone activation only as success or a documented atom refusal. A
rolled-back opaque activation error cannot count as a safe capacity refusal.
The focused race and wrapper properties passed seed202304 in60.2seconds. Full Marshall
precommit passed 1,423 checks (222 properties, 1,201 tests), two exclusions,
seed59328,1465.7seconds; forced Dialyzer44.48seconds, zero errors/skips/unnecessary
skips, exit0. Opaque errors in other step families and ungenerated lock
schedules remain gaps. Fixture cleanup retries provide no mutation evidence.

An additional controlled schedule runs opposite-source relocations and clone
activation on three independent peers. Before release, every tagged backend
blocking chain reaches a separate holder, with a direct transaction-ID wait.
Exact committed endpoints, durable activation, accounting and fixture restoration
passed the focused property (seed219491,51.6seconds,exit0). This does not establish
native transfer, hosted fault search or untested cross-resource lock cycles.

Every Lilly host keeps a separate host-local provisioning journal; the former
`provisioningReadiness` switch was removed (ADR-0159). Provision/start completion
requires an exact-boot guest readiness receipt after trust, network,
writable-root and configured SSH service readiness. A running boot without a
durable boot identity is refused rather than adopted. This does not prove that
an arbitrary external client can authenticate or reach the guest.

```mermaid
stateDiagram-v2
  [*] --> pending
  pending --> materializing
  materializing --> launching
  launching --> awaiting_trust
  awaiting_trust --> awaiting_ssh
  awaiting_trust --> unattested: no guest agents
  awaiting_ssh --> ready
  awaiting_ssh --> failed
  unattested --> failed
  unattested --> superseded
  ready --> superseded
  failed --> superseded
  superseded --> pending: newer execution
```

A guest whose boot bundle declares no agents (a firmware-booted image,
[ADR-0170](repo:docs/architecture/decisions/0170-lilly-firmware-guest-launch.md)) never exchanges
readiness: Lilly records trust as `skipped` for the exact boot instead of
delivering it, advances provisioning to the terminal `unattested` phase (a boot
challenge, never a boot UUID, no path to `ready`) and reports the VM running
without a `guest_ready` fact. Marshall admits only the physical service level
for such an operation. Whether a boot exchanges readiness and trust, and how
long readiness may take, is decided per agent set by the protocol's capability
table ([ADR-0171](repo:docs/architecture/decisions/0171-windows-guest-agents.md)):
Linux guests keep the 120 s budget (2400 s for Inception), `windows-v1` guests
get 600 s (matching Marshall's provision service level), and the budget is
recorded once at the first launch of a boot and never extended by a relaunch.
The two completions are exclusive: the ready commit refuses an agent set
without readiness, and the `unattested` commit refuses an agent set that
proves readiness, so an agent guest is never reported running without its
ready line.

Failure and supersession can also terminate earlier phases. The execution and
dataset journals retain launch and cleanup authority. The deadline starts at
launch, allowing materialization its separate utility bounds. The original deadline
survives retries; a cached receipt is reusable only for the same execution and
boot challenge after physical confinement is rechecked. State and revision
publish atomically in lifecycle envelope version 2; duplicate polling changes
neither. After fsync, at most 128 reviewed UUID/state/time diagnostics per caller defer
until the exact native writer releases. Confirmed release admits them to the
bounded SDK queue and structured logs; spool handoff runs independently. Queue
refusal or uncertain lock release may drop diagnostics without undoing state.
Template diagnostics retain closed host/pool identity; these
observations never authorize a copy, physical seal or execution.

The matching provision/start physical outcome carries `guest_ready: true` only
following successful current-boot guest readiness. Marshall's immutable service
level measurements read that exact VM/placement/host/epoch/generation receipt at
its database arrival time. Old retained outcomes without the flag remain unknown
for readiness; historical remote transition events cannot fill the gap. Missing
readiness by the original deadline remains a finished measurement failure.

The browser and Porsche SSH creation entries select OSS when no profile is
chosen. Explicit Customer selection remains owner-only and blocks sharing,
agent registration and guest-initiated egress. Browser drafts retain the selected
profile and request identity across refresh and reload. SSH retries compare the
original explicit inputs before resolving defaults: changing an omitted profile
to an explicit profile conflicts, including explicit OSS. The
[default-profile verification review](repo:docs/architecture/reviews/2026-09-25-default-oss-verification.md)
records passing generated histories and the bounded native creation journey.
Both OSS guests reached the local DNS/HTTP origin; the explicitly selected
Customer refused sharing, foreign reads, agent admission and outbound HTTP.
The wider packet, tool-execution and guest-user SSH matrices remain separate.

Porsche reports Customer sharing as `forbidden`; the profile restriction cannot
be repaired by retrying a temporary outage. Rejected sharing records no grant,
change receipt or SSH request result. Owner Customer start, stop and deletion
enter only through the browser power controls or Porsche `stop`/`start`/`rm`:
a used request key replays the same operation and a changed kind conflicts
without new durable work. Member, stranger and administrator lifecycle commands
are refused at both entries and persist nothing; a persisted administrator flag
does not create CLI authority because SSH sessions carry no passkey elevation.
Deletion receipts remain readable to their issuing owner after archival and a
name-reused machine never inherits them. The
[customer controls review](repo:docs/architecture/reviews/2026-09-26-customer-controls.md)
records the generated profile/actor histories, the browser key-reuse pins, and
the native journey where the owner's CLI restart kills and recreates the real
guest process tree around its retained ZFS identity while the egress fence
remains closed.

Stopping preserves drives and machine identity. A later start requires admission
against current host capacity. Lilly's per-VM actors and independent launchers
allow guests to survive the main Lilly process restarting. Crash recovery is
bounded and suppressed during maintenance. A crash or resize restart that finds
the host's capacity report merely late keeps its compute hold, and the next
accepted report decides the restart. A late report is not a capacity shortfall
(ADR-0140). Repeated crashes should be diagnosed,
not hidden by unlimited restart loops.

A launch runs as six steps: begin (claim and running intent), disk, boot
records, jail, logging and network, and commit
([ADR-0176](repo:docs/architecture/decisions/0176-host-concurrency-single-writers-and-effects.md)
decision 2). Each step holds the placement lease only for its own duration and
waits for it in lilly-hostd's queue for at most two seconds, so a boot probe or
observation between steps no longer waits behind a whole create. Before acting,
every step after begin re-reads its fence: the exact intent begin set, no
deletion tombstone, a stopped unit and no launch attempt at or beyond that
revision. A changed fence stops the launch as preempted before that step's
effects. Commit checks the actor's commit grant, persists `launch-attempt.bin`
and starts the unit in one section, so a launch is attempted at most once per
revision. A launch that stops between steps starts again from begin; each step
is idempotent (an existing correctly bound disk is reused).

A source-bearing restart also requires its durable image's matching manifest4
identity and source2 capability, including when resize supplies its own command
snapshot. The stored VM source and retained immutable image determine the new
snapshot; a caller cannot select another image for a sourced start. A disabled current
capable image remains eligible; staged image availability is independent of
retained boot custody.

Unavailable source capability refuses automatic restart while committing the
confirmed crash or resize outcome and any valid host report. Confirmed stopped
compute is released; disk and network address remain retained. A confirmed resize
keeps its target sizes and completes with `workspace_source_unavailable`, allowing
ordinary deletion and recreation on a current image. Unconfirmed effects retain
their existing holds and fencing requirements. The final focused SQL-backed set
passed 39 checks (3 properties, 36 tests), including six new source/snapshot
regressions and editor publication; native recovery acceptance remains separately
scoped in the [review](repo:docs/architecture/reviews/2026-10-10-browser-launcher.md).

The [ordinary durable fake executor](repo:lilly/test/support/durable_fake_executor.ex)
accepts stop or delete evidence only for an incarnation with a persisted launch
marker. A
[generated fake command history](repo:lilly/test/vm/fake_executor_property_test.exs)
checks this causality through replay, generation advance and unseen commands.
It validates controlled-executor histories and cannot establish native Firecracker
or ZFS effects.

The [state journal properties](repo:lilly/test/lifecycle/journal_test.exs)
exercise histories beyond the former 64-event bound while diagnostics are
unavailable, replay identity, and refusal of corrupt or non-v2 primary envelopes
without rewriting.
These are local fsync/journal tests, not native VM lifetime or distributed
collector durability evidence.

Deletion retains the VM's identity and idempotency history while physical cleanup
runs. Busy mounts, foreign GUIDs, or uncertain execution retain holds. The native
cleanup path handles owned mount copies across Linux namespaces; it does not force
an unverified dataset into a free state.

Lilly journals also model execution, claims, receives, exports, snapshots, and
resize effects. Updates occur under native locks and publish state plus revision
atomically. Preserve these journals across daemon upgrades and recovery.

The [historical Antithesis actor harness](https://github.com/antithesishq/kittens/blob/9fe1e493b2090d44bacd16089049cd12b316d58a/antithesis/README.md)
exercised duplicate-generation launch histories through Lilly's real command
Store, VM actor and journal with a persistent fake executor. Its named-volume
workload observed replay across actor process lifetimes; it did not run Marshall
exchange, a full Lilly runtime, or native KVM, systemd and ZFS execution. Its
[architecture review](repo:docs/architecture/reviews/2026-09-28-antithesis-local-harness.md)
retains the recorded local validation and untested hosted/native boundaries.
The old `antithesis/` tree is retired before a fresh whole-repository rebuild;
the [reset review](repo:docs/architecture/reviews/2026-10-13-antithesis-reset.md)
records the removal and retained evidence. No fresh hosted run or mutation
sweep is established by this removal. The ordinary test fixture remains local
to Lilly, independently of the retired Compose workload.
Local [generated actor properties](repo:lilly/test/vm/antithesis_actor_property_test.exs)
passed replay/advance histories across actor lifetimes and a simulated
interruption after a durable fake launch marker. A further property kills the
real actor after the fake executor writes that marker and before it publishes
running. The replacement fences the same generation without another fake
launch. These local checks do not establish full Lilly process restart or native
launch fencing.
The [native completed-effect scenario](repo:docs/architecture/reviews/2026-10-03-lilly-native-actor-recovery.md)
adds the real Executor and Firecracker/systemd/ZFS fixture to this recording
window. It requires byte-identical attempt-only journals through actor death,
unchanged native process identity and launch marker across recovery, and stable
outcome replay. The combined native check passed in 671 seconds. Actual
placement-lock contention returned Executor retry with a persisted attempt,
stopped unit and absent launch marker before confirmed native lock release.
The [worker BEAM extension](repo:docs/architecture/reviews/2026-10-03-lilly-native-beam-recovery.md)
adds abrupt whole-worker loss and independent source-built worker Store/lock
reopens at the same recording boundary. It checks stable outcomes, native
process/launch-marker identity and guest data access. Three new histories passed
within the 1,040-second native check; the worker histories took 506.95 seconds.
The storage fixture disables
the production systemd daemon; it cannot establish that daemon's restart path.
This does not independently prove actor-deferred result consumption. Marshall
exchange, authenticated activation and full daemon death at this boundary remain
separate.
Generated [actor ordering and supersession properties](repo:lilly/test/vm/actor_test.exs)
also inspect the persisted attempt before a blocked executor returns, then
check that an older result cannot publish after a newer generation or epoch
replaces it. They exercise controlled executor tasks and durable journals,
not a native launcher or an actual process kill in that window.

Evidence: [VM resource](repo:marshall/lib/marshall/compute/virtual_machine.ex),
[operation resource](repo:marshall/lib/marshall/compute/operation.ex),
[host lifecycle resources](repo:lilly/lib/lilly/lifecycle/resource.ex),
[lifecycle decision](repo:docs/architecture/decisions/0074-durable-lifecycle-state-machines.md).


### Diagnostic custody and restored actors

Restored Lilly actors resume physical reconciliation when the current
authenticated control session connects. Collector acceptance and Tempo
availability do not gate actor startup, command dispatch, state transitions or
physical outcome acknowledgements.
The [recovery property](repo:lilly/test/lifecycle/recovery_history_test.exs)
reopens persisted execution histories and observes restored actor dispatch
without a diagnostic sender. Its control result and executor are synthetic;
authenticated transport, full Runtime bootstrap and native VMM lifetime remain
outside this scoped evidence.

Lifecycle journals accept only the state-only v2 envelope. Any other envelope
version, including the retired v1 shape with embedded events, fails closed
without rewriting or archiving; ADR-0159 removed the v1 migration, the
`.lifecycle-v1` archive importer and its legacy event vocabulary after the
fleet's old-format state was exported and purged. The
[journal tests](repo:lilly/test/lifecycle/journal_test.exs) check that refusal.
Committed transitions enter the shared library's bounded volatile queue only
after the native writer releases.
The former audit-drain, cursor and reoffer evidence describes the retired
application protocol and is preserved at the
[baseline lifecycle chapter](https://github.com/antithesishq/kittens/blob/a99f74f0/marshall/priv/hldd/04-lifecycle.md).
Marshall's local transactional audit and PaperTrail retention tests remain active.

## Native submission and daemon-loss verification

Launch authority is persisted before native unit submission. A daemon lost before
submission must refuse that generation; a new public start can issue a distinct
authority. Loss after successful submission must adopt the original independent
VMM and report the original operation through authenticated exchange. The
[submission recovery scenario](repo:nix/tests/machines/fleet/scenarios/submission-recovery.py)
contains generated histories for both boundaries and repeated daemon reopens.
Recorded native execution passed: the submission history took337.69seconds
within a1036.30-second machine script, with composed driver static checks passed.
A timeout or disconnection alone is insufficient evidence of the
intended daemon loss; the scenario observes actual process retirement.
Initial provisioning, guest data continuity, power loss and hosted
faults remain separate gaps.

### Native submission mutation sensitivity

The retained-start daemon-loss fixture also caught one deliberately weakened
launch-marker comparison: a same-authority relaunch contradicted the required
failed settlement after the before-submission fault. This is bounded native
sensitivity, not a hosted mutation sweep. The integrated Marshall gate passed
1452checks including238properties; forced Dialyzer reported zero errors.
Initial provision, guest data usability and power loss remain separate gaps.
See the [submission review](repo:docs/architecture/reviews/2026-10-05-lilly-submission-recovery.md).

## Waiting launch authority

A guard blocked behind exclusive intent custody must acquire its shared lock
before reading the current intent. Stopped, foreign, superseded or unsafe intent
must refuse exec; unchanged intent must execute. The generated kernel-witnessed
waiter property and exec-marker control passed in a fresh127-second native package
with three library properties and six integration checks, rustfmt and Clippy.
This verifies local lock/intent ordering, not journal/systemd/Firecracker recovery.
See the [waiting-intent review](repo:docs/architecture/reviews/2026-10-05-launch-guard-waiting-intent.md).
