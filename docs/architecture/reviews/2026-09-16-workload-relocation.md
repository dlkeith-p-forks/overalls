# Workload relocation: feasibility and implementation review

## Security correction — 2026-09-18

The destination receive state machine now accepts the already-approved stopped/full
fallback for an originally running workload, but only after the existing physical
stop confirmation fence. Previously, source permit generation supported this case
while destination command selection rejected it, leaving both transfer slots held
until cancellation. The focused relocation suite covers the source full request,
destination receive offer and stop-fence sequencing (34 tests pass). This is an
implementation correction within ADR-0037 and ADR-0050/0051; it adds no authority,
capacity, protocol-version or recovery decision. Full multi-host/native acceptance
remains a separate gap recorded below.

Date: 2026-09-16. Decision: [ADR-0037](../decisions/0037-workload-placement-and-relocation.md).
Status: accepted design, partial implementation; not ready for end-to-end use.

## Current checkpoint (2026-09-18)

This is a chronological implementation journal. Earlier pending-work statements
record their checkpoint, not the current state; later evidence below supersedes them.
ADR-0050/0051 supersede capacity/resource-budget portions of ADR-0037 while carrying
forward its unrelated relocation requirements. Full relocation acceptance remains
unproven.

- Placement fencing, authenticated source snapshots/export, destination receive and
  adoption, atomic handoff, readiness, source cleanup, cancellation restoration,
  independent cleanup and all-copy Delete have application and scoped native evidence.
  Archived receipt locking and distributed cancellation/Delete races are covered.
- Automatic admission, manager move/cancel controls, phase/mode/readiness/cleanup
  status, attempt byte counters and control-plane observed downtime are implemented.
  Focused UI/source/transport tests pass. The latest full Marshall run has passed
  551 cases, browser-state checks and forced Dialyzer (one documented upstream
  exclusion, no unsuppressed findings). Source-rendered desktop/mobile browser
  review also passed; this is layout evidence, not a browser-driven native move.
- Rate-limited native SSH full/baseline and incremental resume with validated tokens
  and receiver progress forwarding pass the two-machine endpoint suite. Protocol
  progress validation, authenticated Marshall persistence, attempt/session ordering
  and bounded observation storage are implemented with passing focused tests.
- The first integrated native relocation stalled before destination receipt. Its
  diagnostic rerun shows recurring source-applied baseline permits without receipt.
  A concrete initial retry-clock bug prevented fresh receive/import/readiness/cleanup
  workers from starting on negative monotonic time. That is fixed and all 268 Lilly
  cases plus forced Dialyzer pass. The corrected-clock native run completed the
  first full move and guest-data verification (695.52 seconds), then failed at
  public admission for the return move. The old fixture suppressed its refusal
  reason. The current fixture now exposes only finite public refusal enums.
- The local `zfs-guest` suite passed in full, including restored-source Delete.
  The latest `z9ztiy_b` fleet snapshot also passes the complete first running move
  and guest-data verification in 1035.58 seconds, including final import, handoff,
  readiness and physical source cleanup. The return move also passes in 1209.29
  seconds, including a fresh placement/epoch and retained guest data. Initially
  stopped transfer, phase-by-phase failures, cancellation after source stop, readiness
  failure, Delete during pending cleanup and updater interruption/resumption still
  need integrated acceptance. No isolated storage/guest test substitutes for these.
- The native fleet fixture now includes mid-stream cancellation, daemon restarts
  across durable phases, source reboot after physical stop, post-stop cancellation,
  readiness timeout, Delete during pending cleanup, actual updater interruption,
  stopped fallback under physical source pressure and destination ENOSPC recovery.
  These new scenarios are implemented but not yet accepted by a completed run.
- Re-reading the recovered plan identified a missing explicit retry after failed
  destination readiness. It is now implemented with retained request identity,
  destination-only physical stop, fresh startup admission and a new activation/
  readiness request. The 48 focused source/UI cases pass. Full gates and native
  retry acceptance remain pending. The complete Marshall gate now passes 547
  cases, six browser checks and forced Dialyzer with its one documented upstream
  exclusion (`/tmp/kittens-relocation-retry-race-precommit.log`).
- Storage-pressure acceptance remains open. Current usage-based admission preserves
  conservative temporary holds (`Budget.physical_disk_available/3`). ADR-0050/0051
  and its explicit current contract govern this implementation: the historical
  temporary-credit optimization is not part of the current implementation target.
  Retain holds through physical cleanup; do not add credit from progress, settled
  logical promises or compression. Native pressure recovery still needs evidence.

### Recovery-matrix increment (2026-09-18)

The first full rerun completed successfully: 539 cases and forced Dialyzer passed
(`/tmp/kittens-relocation-matrix-marshall-final.log`). That result precedes the
destination-retry implementation below.

The recovered plan explicitly requires retryable readiness failure. The prior
implementation retained the source safely but blocked every retry. The new
`RelocationRetry` resource records actor/key and stop/start references; PostgreSQL
enforces request identity, one pending retry and operation/relocation bindings.
The coordinator uses sorted host locks before the VM, confirms exact physical
destination stop, rechecks fresh startup headroom and atomically records a new
activation. Old failed requests remain immutable and late receipts can be
acknowledged without completing the new request. Delete supersedes pending retries.
This implements existing ADR-0037/plan recovery intent while preserving ADR-0050/0051
admission and retained source fencing. Focused validation passed 48 cases
(`/tmp/kittens-relocation-destination-retry-tests.log`); full/new native acceptance
remains required. The additive migration is
`20260918012745_relocation_destination_retry.exs`.

Architecture impact of the failure fixtures: acceptance instrumentation only, carrying forward ADR-0037
relocation requirements and ADR-0050/0051 capacity policy. No new authority,
protocol, reservation-credit or automatic recovery decision. The production
receive clock correction remains the preceding implementation fix.

The destination retry additionally changes recovery persistence and coordinator
behavior as described above; it implements the already accepted explicit retry
requirement. The latest merged native fleet run terminated at the first move's
900-second deadline (`/tmp/kittens-relocation-matrix-final-native.log`). Its final
phase had a received incremental disk and import intent, but no import receipt or
placement commit. This contradicts full integrated acceptance despite the earlier
snapshot's successful first move. A read-only fixture diagnostic now reports local
import/claim phase enums and execution/ownership file existence on timeout, without
printing journal contents, resume tokens or guest data. The cause remains under
investigation; no safety or ownership check has been relaxed.

The diagnostic rerun uses `/tmp/kittens-import-native-11pdvdb2` and
`/tmp/kittens-relocation-import-diagnostics-native.log`; its build remains live.
Subsequent fixture work adds a real PostgreSQL outage after the final receipt and
before import, checking retained disks and stopped units on both endpoints,
unchanged source placement and retained holds after database recovery. That
addition is not in the live snapshot. The retry source scenario now opens the real
LiveView, clicks its retry button, checks the waiting phase and hidden controls,
and then verifies the retained request and physical-stop gating. All 48 source/UI
cases pass (`/tmp/kittens-relocation-retry-ui-tests-final.log`). An initial test
compile failed for a missing Phoenix `get/2` import; the final run includes that
test-only correction. ADR and contract structural checks passed before these last
test additions; Python syntax and whitespace checks pass as well.

The destination retry now has a three-peer race fixture that reaches committed
authority through baseline/final control exchanges, physical source-stop evidence
and import acknowledgement before reporting failed destination activation. It
checks identical and competing request keys, physical-stop-gated reactivation and
Delete superseding a pending retry. The initial distributed run passed 32 of 33
cases; the new reactivation fixture incorrectly reused outcome sequence 1 after a
prior destination outcome, and the server correctly returned `outcome_conflict`.
The fixture now advances the current placement sequence. A focused rerun is in
`/tmp/kittens-relocation-retry-races-final.log`: both new race cases pass with
three independent Marshall peers (31 unrelated cases excluded).

Review also found an observability mismatch: failed activation without a readiness
request still projected `checking_destination`. The status now projects
`activation_failed` with “Destination boot failed; source copy retained”, including
after an earlier failed readiness request belongs to an older activation. This is
an ADR-0037 status correction with no new execution, capacity or recovery authority.
The preceding 541-case gate predates this correction; a new full gate is required.

The new full gate (`/tmp/kittens-relocation-retry-race-precommit.log`) has passed
547 cases (55 properties, 492 tests), browser checks and forced Dialyzer with one
documented upstream exclusion and no unsuppressed findings. The race
fixture is additionally extended so competing-key/Delete coverage begins with an
ambiguous activation (`unknown`, compute not proven empty), while identical-key
reactivation retains the explicit failed-boot case. Its focused rerun passes both
cases (`/tmp/kittens-relocation-ambiguous-retry-races.log`), after the full gate
completed to avoid concurrent compiler/PLT mutation. The native diagnostic
run remains active in its first baseline transfer; no full movement acceptance is
claimed for that snapshot yet.

Future phase diagnostics additionally expose persisted byte/attempt counters to
distinguish active transfer from repeated attempts; the active native snapshot
predates those counters and the PostgreSQL-outage scenario. No diagnostic changes
grant authority or replace physical completion evidence.

The diagnostic fleet run terminated at the shared 900-second move deadline. Its
last phase was the first pending incremental permit after confirmed source stop:
the baseline had consumed nearly the whole deadline at the fixture's 4 MiB/s
rate. Destination-local evidence was `import_phase=active`,
`stream_state=received`, no adopted claim, no VM ownership or launch intent, and
an inactive unit; the source retained its ready disk and stopped unit. This does
not reproduce or explain the preceding run's post-final-receipt import stall.
The test now uses 16 MiB/s and separate 900-second baseline/final/import/cleanup
stage limits within an 1800-second total. Only actual milestones reset a stage
limit; lease revisions and byte progress cannot prolong it. Midstream fault cases
still require observed bytes/partial receive evidence. Product readiness remains
120 seconds and the suite remains bounded by three hours. This is fixture timing,
not a production admission, fencing or timeout policy change.

A new complete snapshot (`/tmp/kittens-import-native-z9ztiy_b`) is running under
`/tmp/kittens-relocation-stage-bounds-native.log`. It includes the retry/status
changes, PostgreSQL outage scenario, persisted progress diagnostics and local
resume-token presence (boolean only). Python syntax validation passes; native
acceptance and the prior import failure remain open.

The plan audit adds two acceptance cases after that snapshot. One writes a
128 MiB final delta after baseline creation, gates the receive control path only
after incremental bytes are observed, and requires completed local staging plus
the final native snapshot while Marshall still has no receipt. Restarting the
receiver must recover that receipt and finish through the ordinary coordinator.
This complements the native adoption fixture's existing post-prune/post-mount
interruption checks; it does not fabricate an outcome or treat a sent command as
physical completion. The source-pressure case now publicly provisions three
guests across the two hosts, selects a source with a co-resident workload and
verifies unrelated process identities, placements and guest access both under
pressure and after the move. Its fixed guest `verify-live` action also requires the
existing writer service and a strictly advancing synced counter within ten seconds;
old data alone cannot pass the availability check. Both additions pass Python syntax validation but
are not included in the currently running native snapshot or claimed accepted.

The newer fixture overlay `/tmp/kittens-relocation-fixture-audit-siueaxfd` preserves
the running snapshot's production sources and adds only the latest failure script
and guest helper. Its Nix driver build, type check and lint all pass
(`/tmp/kittens-relocation-fixture-audit-driver.log`,
`/nix/store/nq1npm8bgwnzcvxfz5b390qzylxwb8wc-nixos-test-driver-kittens-relocation-fleet`).
This establishes fixture construction, not execution of the added faults. The
active `z9ztiy_b` fleet run is left running; no duplicate VM fleet was launched.

The receive/import/readiness/cleanup worker now reports returned effect failures
using only a closed mode and allowlisted reason. It suppresses consecutive equal
reasons until success or a different reason; arbitrary payloads and command data
are never inspected for logging. Focused tests cover suppression, privacy and
success resetting suppression without losing pending receipts. This preserves
ADR-0037 authority and ADR-0009/0020 diagnostic boundaries; it introduces no new
recovery, lease or cleanup authority. Task exits and exchange failures are not
covered by these new effect-result diagnostics. The first full Lilly gate stopped
at two adjacent contract directives in the shared fleet operator fixture; a blank
line repairs that syntax without changing behavior. The rerun is recorded in
`/tmp/kittens-relocation-effect-diagnostics-precommit-final.log` and passes 271
cases (30 properties, 241 tests), contracts and forced Dialyzer with zero findings
or exclusions. ADR structure/link checks also pass. The active native
snapshot predates this logging change; its current baseline has reported over
1 GB in a single attempt, but has not yet produced a receipt. Byte progress is
not evidence of completed relocation.

The current protocol gate also passes 111 cases (42 properties, 69 tests) and
forced Dialyzer with zero findings or exclusions
(`/tmp/kittens-relocation-current-protocol-precommit.log`). The still-running
`z9ztiy_b` native run subsequently completed baseline receipt, physical source
stop, final incremental receipt, destination import and atomic placement handoff.
The destination is observed running and readiness remains pending at this
checkpoint. This passes the earlier import-stall point without establishing its
cause or complete recovery acceptance. A fresh source snapshot
`/tmp/kittens-import-native-2dqfb2ni` includes the verified effect diagnostics and
latest failure scenarios. Its application/machine closure and test driver build,
type checking and lint pass (`/tmp/kittens-relocation-diagnostics-driver.log`,
`/nix/store/03j5jl1ijjp1bm86lq73ixdp8p1afz2x-nixos-test-driver-kittens-relocation-fleet`).
No second VM fleet has been launched; this is build evidence only.

That native first-move subtest has now passed in 1035.58 seconds, including
post-baseline guest writes, final import, handoff, real readiness, physical source
absence, one retained disk reservation and destination guest-data verification.
The return move was admitted and started its baseline transfer. This is scoped
success on the recorded snapshot; neither full recovery acceptance nor the newest
fixture additions are proven by it.

The return baseline remains at zero observed bytes across changing attempt
identifiers. That is not sufficient to distinguish a returned error, task exit
or lease expiry. The effect diagnostics now additionally classify expiry and
task exits using fixed reasons, never exit payloads. Stale expiry messages after
renewal remain silent and leave work running. Two added callback tests verify
these boundaries, actual local task shutdown, retained receipts and private exit
payload exclusion; all ten focused worker cases pass
(`/tmp/kittens-relocation-expiry-diagnostics-tests.log`). The full Lilly gate
passes in `/tmp/kittens-relocation-expiry-diagnostics-precommit.log`, including
forced Dialyzer with zero findings or exclusions. These are
observability changes only, preserving ADR-0037 authority and retry behavior and
ADR-0009/0020 privacy. Neither native snapshot above includes this last increment.
The gate contains 273 passing cases (30 properties, 243 tests). The prepared
`/tmp/kittens-expiry-native-43jt8hwa` snapshot preserves `2dqfb2ni` and overlays
only the worker and its tests. Its application/machine closure and driver build,
type checking and lint pass in `/tmp/kittens-relocation-expiry-driver.log`
(`/nix/store/nwi0bss12rbdgf4sx1n8wpranj4gv3ci-nixos-test-driver-kittens-relocation-fleet`).
The original fleet remains live; the return move has reached destination import,
handoff and running observation, with readiness and cleanup still pending.

The return-move subtest subsequently passed in 1209.29 seconds, including real
readiness, physical source cleanup, one retained disk reservation, new placement
identity, increasing epoch, stable address slot and guest-data verification. The
same fleet is now exercising an initially stopped guest. The current shared
Marshall gate passes in `/tmp/kittens-relocation-current-marshall-precommit.log`:
551 cases (57 properties, 494 tests), browser checks and forced Dialyzer with its
one documented upstream exclusion and no unsuppressed findings. The stopped
move has received its full disk and requested import; it is not yet accepted.

The `z9ztiy_b` run then terminated with exit 1 at the initially stopped case's
900-second import-stage deadline. The destination reported active import metadata
and a received stream, no resume token, no adopted claim or disk markers, no VM
ownership/launch intent/deletion tombstone and an inactive unit. The source
retained its ready disk, ownership and stopped intent with an inactive unit.
This locates the missing progress before published adoption but does not identify
which guard or effect failed. The first running move and return remain scoped
passes; later scenarios did not run. The diagnostic snapshot `43jt8hwa` is now
running the complete fleet in `/tmp/kittens-relocation-effect-reasons-native.log`,
after the previous job was confirmed terminal. Its fixed effect/expiry/task-exit
reasons should distinguish failure classes without dumping private state.

The `43jt8hwa` run terminated before relocation: enrollment's immediate pool
assertion `0 < free <= total` failed after host freshness had succeeded. The old
assertion did not retain the failing numeric values, so neither the exact pool
measurement nor a cause is established. Host freshness alone is not proof of a
usable separately reported pool observation. Enrollment now waits at most 300
seconds for two fresh, positive, consistent pool measurements and applies all
existing pool assertions to that same captured observation. On timeout it emits
only bounded free/total/freshness values. This changes fixture synchronization,
not production capacity policy or acceptance thresholds. Python syntax, ADR and
contract checks pass (`/tmp/kittens-relocation-enrollment-checks.log`). Snapshot
`/tmp/kittens-enrollment-native-h8rxer3j` overlays only this fixture on `43jt8hwa`;
its full native rerun is in
`/tmp/kittens-relocation-measured-enrollment-native.log`. No import failure reason
was obtained from the aborted enrollment run.

The `h8rxer3j` rerun passes schema setup and measured enrollment (47.55 and 168.84
seconds). Its first receive reports `storage_busy`, then a later attempt streams
the baseline successfully and Marshall requests source stop. This proves at least
one pool-lock acquisition failure and subsequent retry progress; it does not
establish the cause of the previous stopped-import stall. No failure-driven
authority, timeout or locking change has been made from that observation.

The same run later reports repeated `stream_failed` and `storage_busy` during
final receive, then completes that stream and reports
`import_execution_unconfirmed`. Those generic classifications conceal the
failure boundary. The native stream helper now distinguishes observed producer,
consumer, both-child and pipe failures using fixed exit codes; uncertain wait
results remain generic. All paths still reap both process groups before exit,
and no child payload or stderr becomes a diagnostic. Nineteen focused
stream/worker cases pass, including native producer/consumer failure, broken pipe,
rate/progress and cleanup (`/tmp/kittens-relocation-stream-failure-tests.log`).
The import guard now returns fixed stage reasons for claim, tombstone, intent,
unit, jail, network, adoption and publication failures; guard order and effects
are unchanged. Actual pool contention survives the adoption callback as
`storage_busy`. The native activated-import rejection fixture now expects the
specific intent rejection. This is ADR-0037/0009/0020 diagnostic refinement,
not a new execution or recovery authority and not a fix claim for the stall.
The full Lilly gate passes 278 cases (30 properties, 248 tests) and forced
Dialyzer with zero findings or exclusions in
`/tmp/kittens-relocation-failure-stages-precommit.log`; native acceptance of these
latest distinctions remains pending and the live `h8rxer3j` snapshot predates them.
Snapshot `/tmp/kittens-stage-native-4d6cfbw1` preserves that live snapshot and
overlays only the seven changed native helper, worker/import, driver and test
files. Fleet and storage driver builds are running in
`/tmp/kittens-relocation-stage-drivers.log`; no second VM fleet was launched.

The [failure scenarios](../../../nix/verification/tests/machines/fleet/scenarios/relocation-failures.py)
add transport-only proxy gates, current-authority public actions, service/machine
restarts and sibling ZFS pressure. The updater scenario requires interrupted
nonempty native receive, token presence without token disclosure, actual candidate
activation on both nodes, unchanged source guest PIDs and final checksum evidence.
The source-pressure case requires automatic stopped fallback; destination pressure
requires retained source authority/holds followed by recovery. Synthetic fixture
credentials last four hours within a three-hour maximum suite duration.

The complete local `zfs-guest` suite passed at
`/nix/store/z7795cvkcs9k4v7ybwf75fq3gzj4linx-vm-test-run-kittens-zfs-guest`
(`/tmp/kittens-restored-delete-native.log`). This older isolated snapshot verifies
local guest/storage/cancellation/Delete behavior, not the current merged fleet.
Rendered LiveView capture passed one fixture test with actual before/progress/cancel
actions; browser review checked 1280px desktop and 390px mobile layouts. Captures
used synthetic data and stripped LiveView session/static tokens, with no live
browser authentication or native movement claim.

The corrected-clock fleet snapshot completed its first native move, then failed
return admission (`/tmp/kittens-relocation-clock-native.log`). It predates merged
progress/capacity changes. The expanded merged snapshot
`/tmp/kittens-import-native-x_0ulp_u` is building/running under
`/tmp/kittens-relocation-matrix-native.log`; its result is pending and it predates
the subsequently added finite refusal diagnostics and return-admission regression.
That build aborted in Nix's internal `!awake.empty()` assertion before machine
execution. The follow-up snapshot `/tmp/kittens-relocation-matrix-final-3bnd0_pa`
preserves the same application sources and updates the fixture diagnostics. Its
driver built with passing type/lint checks at
`/nix/store/bjyjcc7mywz4vwd8zwi109iwsjk74f04-nixos-test-driver-kittens-relocation-fleet`;
the actual suite is active in `/tmp/kittens-relocation-matrix-final-native.log`.

The 32 relocation source cases pass, including the added public return-admission
assertions after completed cleanup. The merged Marshall gate passed 538 of 539
cases, with one new ingress fixture failure: its second automatic provision could
reuse the first host and mismatch the assumed machine identity. That fixture now
disables its first host only during second-host setup, preserving production
usage-based placement; the focused regression passes. The first full gate also
lost a consolidated BEAM file during overlapping compilation and is not accepted.
A sequential full rerun is active in
`/tmp/kittens-relocation-matrix-marshall-final.log`.
ADR structure and contract formatting/discovery pass for the initial increment;
they do not establish native correctness. The full plan remains incomplete.

## Record recovery

This review was accidentally overwritten with the architecture overview during a
key-custody evidence update. This replacement reconstructs its findings from the
surviving accepted ADR, implementation artifacts, test logs and recorded work
history. It is not a verbatim recovery of the original feasibility prose. The
accepted rationale remains in ADR-0037 and its superseded decisions. Historical
counts below are identified separately from current verification. The overwritten
copy was retained at `/tmp/kittens-relocation-review-overwritten-copy.md`.

## Scope and architectural impact

Marshall owns admission, authorization, placement, capacity and execution authority.
Lilly owns local physical effects and durable host state. Nix must supply identical
immutable guest boot artifacts and the restricted host tools/services. ZFS transports
guest disk data; it cannot transfer control-plane authority or recreate networking.

[ADR-0005](../decisions/0005-vm-lifecycle-and-storage.md) and
[ADR-0035](../decisions/0035-zfs-only-provisioning.md) are superseded by ADR-0037's
explicit relocation decision. Relevant continuing boundaries include
[capacity transactions](../decisions/0010-capacity-admission-transactions.md),
[host ownership](../decisions/0017-durable-vm-actors-and-host-ownership.md),
[terminal authority](../decisions/0019-terminal-session-and-writer-authority.md),
[maintenance](../decisions/0026-host-maintenance-and-retirement.md), and
[machine verification](../decisions/0033-nixos-machine-verification.md).
This review changes evidence, not the accepted relocation decision.

## Feasibility and accepted refinements

Admission checks eligible fresh provisioners and pools; exhaustion rejects the
request. Ordinary recovery does not automatically move a retained disk to another
host. Explicit relocation can use ZFS replication between independent machines,
provided destination resources and both transfer slots are reserved before source
interruption. An inaccessible sole source is not recoverable by this mechanism.

The accepted design uses a running baseline snapshot followed by a stopped final
incremental when both endpoints have conservative temporary headroom. Otherwise
it uses a full stopped transfer. It does not migrate memory or promise continuous
TCP sessions. Import authorization must never grant launch authorization.

A new immutable placement represents every physical copy, including a return to a
former host. One database transaction transfers current placement and increments
execution epoch, invalidates terminal authority and creates activation work.
Source stop requires physical evidence, including absence of waiting launchers
and network access. Precommit cancellation restores the original state under fresh
authority; postcommit failures must not restart the stale source copy.

Destination readiness precedes source destruction for an originally running VM.
An originally stopped VM remains stopped and needs verified import. Disk charges
remain until physical reclamation is confirmed. Oban retries alone are insufficient:
a durable reconciler must recover work even after individual jobs exhaust retries.

## Placement and execution authority follow-up

[Placement records](../../../marshall/lib/marshall/compute/workload_placement.ex),
[reservations](../../../marshall/lib/marshall/compute/reservation.ex) and
[operations](../../../marshall/lib/marshall/compute/operation.ex) bind immutable
copy identities to their VM, host and pool. Current placement references and
composite database constraints prevent mismatched tuples. Temporary disk headroom
uses the existing reservation ledger.

The [execution codec](../../../protocol/lib/overalls_protocol/execution.ex) requires
v3 placement/epoch authority. [Outcomes](../../../marshall/lib/marshall/compute/outcomes.ex)
retain late source evidence without applying it to the current destination.
[Lilly journals](../../../lilly/lib/lilly/vm/journal.ex) and the
[native guard](../../../lilly/native/launch-guard/src/lib.rs) bind placement, epoch and
generation. Host commands, actors, disks and units use placement identities.
Native helper tests execute the guard; simulated database handoff tests do not
establish real relocation safety.

## Portable dataset boundary follow-up

[Disk metadata](../../../lilly/lib/lilly/vm/disk.ex) resides outside the portable
child dataset, under the local `.lilly-zfs` ownership index. The portable contents
are the guest disk and a recognized interrupted-copy temporary file. Imported
bytes cannot act as a local ownership/readiness claim. Deletion retains local
metadata with the placement tombstone; corruption and replacement fail closed.

The real ZFS lifecycle machine run completed in 899 seconds, recorded in
`/tmp/kittens-portable-disk-zfs.log`, using derivation
`/nix/store/wnbh7imb1cckrnalbrjp5kxaz2hyp6h8-vm-test-run-kittens-zfs-lifecycle.drv`.
Its immutable source was
`/nix/store/zl5cpaq6zmczzwlra7skgg264dv6hq34-source`.
This establishes the tested local dataset boundary, recovery/refusal and deletion
behavior. It does not establish ZFS send/receive, guest relocation or later console
changes. Historical application verification at this stage recorded Lilly 105
cases and Marshall 248 cases plus six JavaScript tests.

## Console wire and persisted authority follow-up

Console messages require placement and execution epoch. Late controls and closes
cannot attach to or detach a different execution. Persisted session, writer and
mailbox identity includes placement/epoch/generation; composite foreign keys bind
placement to VM. [Authority](../../../marshall/lib/marshall/terminal/authority.ex)
invalidates previous sessions and resets relay state when execution changes.
Lilly fences preserve monotonic execution
and writer authority and attempted-input watermarks across reopening.

Historical wire-stage checks recorded protocol 36, Lilly 106 and Marshall 249
cases; persisted-authority checks recorded Lilly 108 and Marshall 251 cases, plus
six Marshall JavaScript tests and passing forced Dialyzer checks. The recorded
migration cycle applied, rolled back and reapplied the new migration without
schema drift. A missed distributed acknowledgment caller was corrected before
the final passing run. Atomic handoff invalidation remains unimplemented.

## Relocation identity and transfer occupancy follow-up

[Relocation](../../../marshall/lib/marshall/compute/relocation.ex) records immutable
endpoints, successor epochs, request identity and original running/stopped state.
[Transfer slots](../../../marshall/lib/marshall/compute/transfer_slot.ex) enforce
one occupied slot per host across send and receive roles, with historical records
retained. Only one unfinished relocation may exist per VM.

The [pair allocator](../../../marshall/lib/marshall/compute/transfer_slots.ex)
requires ordered host locks inside a transaction. It reuses exact occupied slots,
rejects released/finished history and rolls back if either endpoint is occupied.
A query bug using nil equality was corrected to an explicit `is_nil` filter;
database uniqueness prevented duplicate occupancy during that investigation.
There is no general release action before physical stream-termination evidence.

Ten focused ownership tests and a migration up/down/up and drift check were
recorded. `/tmp/kittens-relocation-ownership-final-precommit.log` confirms 261
Marshall cases and successful Dialyzer. This does not prove real distributed
relocation races or any physical transfer.

## Destination capacity preparation follow-up

[Capacity preparation](../../../marshall/lib/marshall/compute/relocation_capacity.ex)
is an internal helper requiring an enclosing transaction and sorted host locks
before the VM lock. It rechecks authorization, stable lifecycle state, freshness,
capacity and stream occupancy, chooses a destination, and atomically records the
new placement, commitments, relocation and both occupied slots.

Pre-copy requires an extra disk of physical headroom on both hosts; otherwise the
helper chooses stopped transfer. Physical headroom is separate from the guest
logical disk cap. Originally stopped workloads consume disk without compute.
Source execution authority and existing compute/disk commitments are preserved.

Twelve capacity tests cover selection, fallback, stopped workloads, stale data,
authorization, idempotency and rollback. The recorded final gate confirms 273
Marshall cases and successful Dialyzer in
`/tmp/kittens-relocation-capacity-precommit.log`. No schema change or physical
transfer was involved. Public admission, atomic job enqueue, immutable artifact
staging and authenticated transfer preparation still need integration.

## Relocation exclusion and retained-copy archival follow-up

[Relocation guards](../../../marshall/lib/marshall/compute/relocation_guard.ex)
exclude new ordinary lifecycle and endpoint maintenance while a move remains
unfinished, even if stream slots have been released. Exact existing request retries
remain valid. Lifecycle rereads placement/epoch under the VM lock to avoid acting
under a former host's lock after relocation.

Failure/stop outcomes during relocation retain commitments and suppress ordinary
crash recovery. VM archival and address release require every placement's compute,
disk and temporary commitments to be reclaimed. The worker that performs cleanup
of retained copies is not implemented.

The recorded migration cycle and drift check are in
`/tmp/kittens-relocation-exclusion-schema.log`; the final gate in
`/tmp/kittens-relocation-exclusion-precommit.log` confirms 280 Marshall cases,
six JavaScript tests and successful forced Dialyzer with one existing suppression.
The seven new tests exercise database outcomes and exclusions, not physical
fencing or actual multi-node handoff.

## Destination transfer key custody follow-up

[Key custody](../../../lilly/lib/lilly/transfer/key.ex) generates a local Ed25519
private key under a fixed relocation path and permanently binds it to host,
relocation and destination placement. A native per-relocation lock protects its
journal. The bounded command runner invokes pinned OpenSSH; only the public key
is returned or journaled. Success follows private-file, journal and parent-directory
syncs. No administrative or fleet-wide client key is reused.

Pending interrupted generation can recover; a complete unpublished key is reused.
A ready key is never silently regenerated after loss, corruption or replacement.
Unsafe and unbound files fail closed. Retirement writes a permanent tombstone
before removing private material, supports interrupted-removal retries and can
precede initial generation. Removing a key is not revocation of an established
SSH connection; permit revocation and process reaping remain separate obligations.

Eleven [key tests](../../../lilly/test/transfer/key_test.exs) execute real OpenSSH
and native locks. The saved current gates confirm:

- Lilly: 119 cases (23 properties, 96 tests), forced Dialyzer with zero errors,
  `/tmp/kittens-transfer-key-lilly-precommit.log`.
- Marshall: 280 cases (26 properties, 254 tests), six JavaScript tests, forced
  Dialyzer with its existing single suppression,
  `/tmp/kittens-transfer-key-marshall-precommit.log`.
- Nix host-tools build succeeded; output
  `/nix/store/w63q29yyk3s5x3bwa981r79ipv0nkx4g-lilly-host-tools`.
  Development shell and built tools resolve the same pinned `ssh-keygen`.

OpenSSH usage was checked against the [official ssh-keygen manual](https://man.openbsd.org/ssh-keygen.1).
This does not verify a full release deployment, restricted SSH service, peer
host authentication or stream transfer.

## Guest network identity clarification

[Guest networking](../../../lilly/lib/lilly/network/guest.ex) derives private IP
and MAC from profile/slot, while placement determines host-local TAP/guard names.
Preserve the logical address allocation and MAC during relocation. Recreate local
routes, TAP and anti-spoofing rules for the destination placement after fencing the
source. Stable private identity does not provide cross-host reachability by itself.
Host public/egress addresses may differ; existing connections do not survive the
planned guest reboot. Ingress routing must follow the current placement where used.

## Stream identity review before receiver implementation

The descriptor previously included an ambiguous `dataset_guid` alongside
`from_guid` and `to_guid`. Its contract required receiver verification too broadly,
which could be interpreted as requiring destination filesystem GUID equality.
The wire field is now explicitly `source_dataset_guid`; the codec rejects the old
name and attempts to supply destination ownership through this descriptor. The [OpenZFS property documentation](https://openzfs.github.io/openzfs-docs/man/master/7/zfsprops.7.html)
specifically preserves snapshot GUIDs across send/receive and describes a new
filesystem GUID when receive recreates a filesystem.

Treat the source dataset GUID as a binding checked by the exporter against its
local ownership claim. Check replicated snapshot GUIDs and incremental lineage at
the receiver, then record the destination filesystem GUID in a destination-local
claim. Do not derive that claim from the source filesystem GUID or imported user
properties. The descriptor contract now makes this distinction explicit. Real ZFS verification
is still required before receive acceptance is implemented. No current runtime
consumes the descriptor, so this correction does not establish working receive.

The codec regression test rejects legacy/ambiguous dataset fields and attempts to
inject destination ownership. Updated round-trip and malformed-GUID coverage use
`source_dataset_guid`. The protocol gate passed 37 cases (15 properties, 22 tests),
and consumer gates passed Lilly 119 and Marshall 280 cases plus six Marshall
JavaScript tests. Logs are `/tmp/kittens-relocation-guid-protocol.log`,
`/tmp/kittens-relocation-guid-lilly.log` and
`/tmp/kittens-relocation-guid-marshall.log`. All three gates completed successfully, including Dialyzer; Marshall retained
its existing single suppression. ADR and contract structural checks and
`git diff --check` passed. No physical send/receive was exercised.

## Outstanding findings and required acceptance

All following items are accepted requirements still unimplemented or unverified,
not reasons to redefine the accepted plan as complete:

- **Critical — orchestration:** no user move/cancel entry point, atomic Oban enqueue,
  durable phase machine or exhausted-job reconciliation. The internal capacity
  helper alone cannot perform a move. Implement coordination before exposing it.
- **Critical — handoff:** no physical source-stop proof integrated with atomic
  placement/epoch/terminal handoff and activation outbox. Verify cancellation
  races and never restart stale source authority after commit.
- **Critical — transport:** public-key distribution, enrolled source host-key
  binding, restricted export permits, expiry/renewal/revocation and established
  stream termination are missing. Local key generation does not prove peer trust.
- **High — storage:** snapshot ownership, baseline/final lineage, bounded-memory
  streaming and resumable unmounted receive remain missing. Existing blanket
  snapshot rejection must be replaced deliberately; do not weaken ownership checks.
- **High — boot and cleanup:** exact boot artifact staging, Nix guest readiness,
  challenge verification, confirmed source reclamation and all-copy Delete remain
  missing. Keep commitments and address allocation until the required evidence.
- **High — acceptance:** actual three-Marshall races and two-Lilly nested
  ZFS/Firecracker moves with guest-written data, source absence, failures,
  cancellation, SSH negatives and updater interruption remain outstanding.
  Independent physical-host acceptance must be recorded separately.

The diagram atlas remains available under `/tmp/kittens-relocation-diagrams-a7d6sq/`.
Structural ADR validation establishes links and record format only. ADR-0037 remains
partial; no current evidence establishes a complete workload relocation.


## Guest boot readiness follow-up — 2026-09-17

The [guest service](../../../nix/domains/artifacts/guest/readiness.py) is installed by the
[Nix guest configuration](../../../nix/domains/artifacts/guest/configuration.nix), with the
virtio-vsock guest module. It starts only with explicit placement, execution epoch,
32-byte boot challenge and guest address parameters. Duplicate, missing, noncanonical
and reserved values fail closed. Identity is read from this boot's kernel command
line rather than an imported disk marker. The kernel boot ID is included in replies.

The service listens on vsock port 1024 and answers only CID 2. It accepts no caller
commands or identity payload. Each reply requires active multi-user and guest-network
units, the expected eth0 /32 address plus gateway/default routes, and a root-filesystem
write/fsync probe. The service does not order itself after multi-user.target while
being wanted by that target, avoiding a startup cycle. Its sandbox does not remount
the root read-only and invalidate the intended probe. This is guest boot readiness,
not application health or evidence that a user-controlled guest is trustworthy.

The [shared readiness verifier](../../../protocol/lib/overalls_protocol/readiness.ex)
uses a closed v1 schema independent of execution v3. It compares the entire expected
placement/epoch/challenge; a response from an earlier boot of the same placement
cannot satisfy a new challenge. No response grants execution or deletion authority.

The [Lilly client](../../../lilly/lib/lilly/vm/readiness.ex) connects only to a
caller-selected local Unix socket and uses Firecracker's host-initiated vsock
handshake, with a 512-byte frame limit. The handshake port is the dynamically
assigned host-side port, not necessarily guest port 1024. See the
[Firecracker vsock protocol](https://github.com/firecracker-microvm/firecracker/blob/main/docs/vsock.md).
Connection, send, receive and retries share one monotonic deadline; the default is
120 seconds and callers can choose 1–600000 ms. Failed, malformed and stale responses
cannot extend that deadline. Callers must select a socket owned by the current VMM
and recheck current authority before consuming success.

Nine Python tests cover boot-parameter rejection, network prerequisites, root probe
cleanup/failure, each failed health check, non-host peers and ready/not-ready local
socket responses. Five Lilly tests cover fragmented Firecracker handshake/JSON,
stale placement/epoch/challenge, malformed handshakes, oversize frames, connected
unresponsive guests and invalid requests. The new protocol tests cover closed
schemas, arbitrary peer terms, boundary epochs and challenge round trips.

The exported `guest-readiness` Nix check evaluates the actual guest module and runs
the actual Python implementation with pinned Python; it passed with output
`/nix/store/85mjmaq7rfjk5ahx5qs39pqzda82yxjc-lilly-guest-readiness-check`.
Because new files are untracked, this run imported the working-tree check through
an explicit impure expression and used the flake's pinned Nixpkgs input. It did not
build or boot a whole guest image. Local socket tests do not establish real vsock,
KVM or Firecracker readiness. The protocol gate passed 42 cases (17 properties,
25 tests). Both consumer gates completed successfully: Lilly 124 cases (23
properties, 101 tests), Marshall 280 cases (26 properties, 254 tests) plus six
JavaScript tests. Forced consumer Dialyzer checks passed, with Marshall retaining
its existing single suppression. Logs are `/tmp/kittens-guest-readiness-protocol.log`,
`/tmp/kittens-guest-readiness-lilly.log`, `/tmp/kittens-guest-readiness-marshall.log`
and `/tmp/kittens-guest-readiness-nix.log`. ADR structural validation, contract
checks and `git diff --check` passed. No database schema changed in this step.

Remaining integration is material: the driver does not yet persist a fresh challenge
before each launch, add readiness identity to boot arguments, configure Firecracker's
vsock device, or ask the observer for boot readiness. The relocation coordinator must
recheck placement/epoch/boot authority and source fencing before readiness can unlock
source cleanup. NixOS machine testing must exercise those complete paths. These
components implement part of ADR-0037; they do not complete relocation readiness.


## Launch readiness integration follow-up — 2026-09-17

The [boot journal](../../../lilly/lib/lilly/vm/boot.ex) is host-local, outside the
portable dataset. Under the existing per-placement host lock, it verifies the
persisted running intent and publishes a random 32-byte challenge before launch.
Retries before a launch attempt reuse the same challenge; newer epoch/generation
pairs rotate it. Corrupt/unsafe state, placement rebinding, older revisions and
non-running or stale intent fail closed. The existing launch-attempt fence remains
a prerequisite: a repeated attempted authority cannot submit another physical boot.
The journal file and parent directory are synced before returning success.

The [driver](../../../lilly/lib/lilly/vm/driver.ex) prepares this journal between
disk preparation and jail preparation. [Jail configuration](../../../lilly/lib/lilly/vm/jail.ex)
now supplies placement, execution epoch and challenge alongside the stable guest
address, and adds a guest-CID-3 vsock endpoint at `/v.sock` inside the placement jail.
The existing `api.sock` length constraint also accommodates the shorter endpoint.
The generation remains in host-local state; the fresh challenge binds the physical
boot. This does not change running VMM observation into guest readiness or grant
permission to reclaim a source copy.

Five boot-journal tests exercise durable retry identity, rotation across generations
and epochs, lock requirements, stale/non-running intent, corrupted/symlink state,
placement rebinding and revision regression. The jail test checks the actual
Firecracker configuration includes the persisted boot identity and stable networking.
Focused verification passed eight cases (one property, seven tests).

The [real guest fixture](../../../nix/verification/tests/machines/zfs-guest/probe.exs) now requires
challenge-bound readiness after each physical boot and checks stale epoch/challenge
rejection against the live guest. The Nix machine run was started from an explicit
working-tree package import with the pinned flake inputs, including untracked source
files without changing the shared Git index. Its log is
`/tmp/kittens-boot-integration-nix.log`; completion and acceptance remain pending.
Application gate logs are `/tmp/kittens-boot-integration-lilly.log` and
`/tmp/kittens-boot-integration-marshall.log`. No database schema changed.


Application gates completed: Lilly 130 cases (23 properties, 107 tests), Marshall
280 cases (26 properties, 254 tests) plus six JavaScript tests. Both forced Dialyzer
gates passed; Marshall retains its existing single suppression. ADR and contract
structural checks passed. Initial machine scheduling failed because the daemon did
not advertise `nested-kvm`. The host exposes SVM, nested virtualization is enabled,
and the same immutable derivation was then started through the local store builder
with `--extra-system-features nested-kvm`, without changing persistent daemon
configuration. The live run log is `/tmp/kittens-boot-integration-machine-local.log`;
its derivation is
`/nix/store/rsnzqnvqvddk7hb9nlff8f6v3rxsgqf4-vm-test-run-kittens-zfs-guest.drv`.
Machine acceptance remains pending until that run completes.


The first real machine run completed with failure: physical VMM confinement passed,
but the boot-bound readiness wait expired after its unchanged 120-second deadline.
This contradicts any claim of working end-to-end readiness; ordinary tests remain
insufficient. The fixture now emits only fixed pass/fail/unavailable probe results
for guest units, the vsock module/listener and root write, withholding terminal bytes
and boot challenges. Its Nix driver type/lint checks passed. A diagnostic run uses
`/nix/store/azx65z8nkd7fbfg2pkxi4ghp7a32pw1y-vm-test-run-kittens-zfs-guest.drv`
and `/tmp/kittens-boot-diagnostics-machine.log`. No timeout was enlarged. Root cause
and a passing machine rerun remain outstanding.


### Connected-probe deadline correction

While the diagnostic machine run was pending, source review found a concrete client
liveness defect: each connection had a one-second deadline inside the overall
120-second wait. Guest readiness executes live subprocess and filesystem probes;
a valid response taking longer than one second could be discarded on every retry.
A regression with a 1.2-second valid response and 2.5-second overall deadline failed
before the fix (`/tmp/kittens-readiness-slow-probe-before.log`). The client now uses
the remaining overall deadline for the connected probe. An unresponsive peer is
still bounded by that same deadline; no overall timeout was increased. This fixes
the reproduced client bug, but is not yet proof of the machine run's root cause.

The first diagnostic launch failed before guest boot because build-user KVM access
was absent. The next run grants the build group temporary KVM access and restores
the pre-run ACL on exit (preserving unrelated changes). Its live log is
`/tmp/kittens-boot-diagnostics-machine-acl.log`. It deliberately runs the immutable
pre-fix derivation to gather the missing physical failure evidence. A corrected
machine run and the final consumer-gate results remain outstanding.


### Physical diagnostic result and route-query correction

The pre-fix diagnostic run finished with readiness timeout, while every bounded
guest check passed: multi-user, guest networking, readiness service, vsock module,
vsock listener and root write. The temporary KVM ACL was restored afterward.
This established that the failure was not simply an absent guest service/listener.

A local invocation of actual iproute2 exposed the deterministic guest-probe defect:
`ip -j -4 route show dev eth0` omits the `dev` property, whereas the unfiltered
route query includes it. The guest validator requires `dev == eth0`, so the filtered
query made correct routes fail validation. The guest now queries the route table
without the device filter, then verifies the interface/address/gateway itself.
A regression reproducing iproute2's field omission failed before the change and
passed afterward (`/tmp/kittens-readiness-route-before.log` and
`/tmp/kittens-readiness-route-after.log`). All ten Python tests pass. The Nix check
using the actual guest's pinned build package set also passed, output
`/nix/store/m320q603mmlhmww25fgzdg7r84dz1057-lilly-guest-readiness-check`.

The client deadline correction passed Lilly's complete 131-case gate (23 properties,
108 tests), Marshall's 280 cases (26 properties, 254 tests), six JavaScript tests,
and both forced Dialyzer checks (Marshall's existing single suppression remains).
Logs are `/tmp/kittens-readiness-deadline-lilly.log` and
`/tmp/kittens-readiness-deadline-marshall.log`. Both fixes must still pass the real
machine suite together; passing unit checks alone do not close this finding.


The corrected guest image, Lilly release and Nix test driver built successfully;
Nix driver type and lint checks passed. The combined corrected machine run uses
`/nix/store/vhlrhzc85j092j53hx51lamvmshid0ij-vm-test-run-kittens-zfs-guest.drv`
and `/tmp/kittens-readiness-final-machine.log`. It has been started with temporary
build-group KVM access restored by the runner on exit; acceptance remains pending.


## Authority checks around guest readiness — 2026-09-17

The corrected immutable `vhlrhzc85j092j53hx51lamvmshid0ij` machine run has now passed
initial guest readiness, negative epoch/challenge checks, guest data write, stop,
restart readiness and retained-data read. It has reached recovery after simulated
host loss; the full suite is still running. This is actual nested Firecracker/vsock
evidence for the corrected guest service and client, not independent-host acceptance.

The new [Driver.ready/4](../../../lilly/lib/lilly/vm/driver.ex) checks the existing
host/pool/spec claim, current running intent, boot record and VMM confinement under
the per-placement lock, releases that lock for the bounded socket wait, then takes
it again and repeats the checks. The boot record must remain exactly equal across
the wait. [Boot.current/3](../../../lilly/lib/lilly/vm/boot.ex) requires the requested
placement/epoch/generation to match both the running launch intent and stored boot.
It rejects absent boot state, another placement/revision and terminal failed intent.
It is a read helper; callers must hold the lock when using it as authority.

This adds a production observation primitive without making readiness a cleanup
permission. The real-guest fixture is updated to call it and reject wrong execution
authority before polling. The machine run already in progress uses the earlier
immutable direct-client fixture, so it cannot establish acceptance of this new
entry point or its concurrency behavior. A subsequent run is required. Lilly's
first gate caught an unreachable fallback branch; it was removed before rerunning.


The final application gates for the driver entry point passed: Lilly 132 cases
(23 properties, 109 tests), Marshall 280 cases (26 properties, 254 tests) and six
JavaScript tests, with both forced Dialyzer checks passing (Marshall's existing
suppression remains). Logs are `/tmp/kittens-readiness-authority-lilly-final.log`
and `/tmp/kittens-readiness-authority-marshall.log`. ADR validation and whitespace
checks passed. The updated source-built release and Nix driver also built with
passing type/lint checks. Its machine derivation is
`/nix/store/kvwjizjvjz7g2r8g1alfzny7kzdqyhwy-vm-test-run-kittens-zfs-guest.drv`;
that physical run has not started yet. The earlier direct-client suite has now
passed readiness and retained guest data after abrupt simulated host loss, and
has started its independent-neighbor deletion checks.


The corrected direct-client machine suite completed successfully in 697.10 seconds
(exit 0). It established real nested guest readiness, stale response rejection,
retained-data stop/start, recovery of flushed data after abrupt simulated host loss,
and deletion without disturbing a newer neighbor's VMM or disk. Both guests were
deleted and final pool allocations were empty. The framework cleaned up its outer
QEMU and the runner restored `/dev/kvm` to root/kvm 0660. This is local nested-machine
acceptance, not two-Lilly relocation or independent physical-host acceptance.

The new production-driver fixture run has now started using the `kvwjizj...`
derivation recorded above. Its log is `/tmp/kittens-readiness-authority-machine.log`.
It adds Driver.ready/4 calls and rejection of wrong execution authority; its result
remains pending. Source-copy reclamation still requires the future relocation
coordinator's separate fenced handoff and cleanup decisions.


## Native readiness completion and transfer verification — 2026-09-17

The production-driver readiness suite completed in 689.91 seconds, with output
`/nix/store/r48bnsn4d114rjgb1d87xq8hq6mdzhb3-vm-test-run-kittens-zfs-guest`.
Its immutable derivation and log are recorded above. Driver.ready/4 passed actual
vsock observations and wrong epoch/generation refusal. Flushed data survived guest
restart and simulated outer host loss; deleting the older guest preserved its
neighbor. The framework cleaned up QEMU and the runner restored the original KVM
ACL, independently inspected after completion. Async handoff/cancellation races
and two-Lilly relocation remain unverified.

The native snapshot property probe completed in 29.45 seconds, output
`/nix/store/3l7b1r8f6ns6zvw5gcj61y6xsjjkb5cr-vm-test-run-kittens-zfs-snapshot-properties`.
Its rows are retained in the Lilly regression fixture. Snapshot `used` is numeric;
capacity, mount and filesystem policy fields are native `-`, which the parser now
preserves. GUIDs remain unsigned decimal strings. Malformed absence, names and
numeric bounds are rejected. Accounting still rejects snapshots, so this change
cannot grant unowned disk credit or make transfer admission implemented.

The parser gates passed: Lilly 133 cases (23 properties, 110 tests), Marshall
280 cases (26 properties, 254 tests), six JavaScript tests and both forced Dialyzer
checks; Marshall retains its existing single suppression. Logs are
`/tmp/kittens-snapshot-parser-lilly.log` and
`/tmp/kittens-snapshot-parser-marshall.log`.

The new exported `zfs-transfer` check uses two independent virtual block devices
and pools in one outer machine, the pinned NixOS ZFS package and a real ext4 disk
image. Its intended assertions cover interrupted baseline receive/resume, preserved
snapshot GUIDs versus new destination filesystem GUID, unmounted/read-only staging,
post-baseline final writes, refusal of mismatched incremental lineage without force
rollback, retained disk bytes, source-only metadata exclusion and nonrecursive
source reclamation without disturbing a neighbor. This adds verification under
ADR-0037 without changing the accepted design. It is not an application importer,
SSH service, Oban coordinator or multi-host availability test. The driver built
with type/lint checks; the machine run is pending in
`/tmp/kittens-zfs-transfer-machine.log`.

The initial native transfer suite passed in 39.90 seconds. It was then expanded
with interrupted **incremental** receive/resume, full stopped-transfer fallback
without a destination baseline, and native abort of an incomplete full receive.
The final immutable check passed in 37.85 seconds (exit 0):

- Derivation: `/nix/store/dskd64az8fn6ajbk4d4m0jcnvdzczn07-vm-test-run-kittens-zfs-transfer.drv`.
- Output: `/nix/store/svsvfmpkplrzczcczks7h40zkxak8pq1-vm-test-run-kittens-zfs-transfer`.
- Log: `/tmp/kittens-zfs-transfer-final-machine.log`.
- Nix driver type/lint checks passed. The exported check catalog evaluates to
  eighteen entries and its `zfs-transfer` derivation matches the executed one.
- Baseline and final snapshot GUIDs were preserved; destination filesystem GUID
  differed from the source and remained stable through incremental resume.
- Both incomplete streams left the destination unmounted and resumable. Full
  receive abort removed its new staging dataset without modifying retained copies.
- Final disk SHA-256 matched the cleanly unmounted source image; ext4 file contents
  were verified and writable after source reclamation. The source-local authority
  marker stayed outside the transmitted disk and survived child destruction.
- Wrong snapshot lineage failed without `receive -F`; unrelated dataset/snapshot
  GUIDs and contents remained unchanged. Source destruction was nonrecursive.
- Framework cleanup completed; the temporary build-group KVM ACL was restored.

[OpenZFS send](https://openzfs.github.io/openzfs-docs/man/master/8/zfs-send.8.html)
and [receive](https://openzfs.github.io/openzfs-docs/man/master/8/zfs-receive.8.html)
document the native stream/resume interfaces. The passing pinned machine run,
not documentation alone, establishes the behavior above. The retained GUID
artifact is `transfer-identities.json` under the output directory.

Review outcome: no change to ADR-0037's accepted decision or partial status.
The tests do not grant production cleanup authority or relax snapshot rejection.
Required next integration remains a durable owned-snapshot/import journal,
physical accounting, authenticated stream permits and the Oban handoff/cleanup
coordinator. Unconnected helpers and a passing native fixture do not establish
end-to-end relocation.


## Snapshot-aware physical accounting — 2026-09-17

The [ZFS reader](../../../lilly/lib/lilly/host/zfs.ex) now offers explicit snapshot
expectations on `observe/2` and `accounting/3`. This implements the numerical and
native-identity boundary of ADR-0037; it does not yet establish snapshot ownership.
Each entry binds a reserved `lilly-a` or `lilly-b` snapshot name to both its exact
snapshot GUID and its containing child filesystem GUID. Missing/replaced snapshots,
extra native entries, parent snapshots, clone origins and nested descendants are
rejected. Empty expectations preserve the old strict behavior. Current production
pool/dataset callers still supply no expectations, so admission remains closed in
the presence of snapshots.

Child physical usage includes `usedbydataset + usedbysnapshots`, never individual
snapshot sizes added together. Individual snapshot-exclusive sizes must fit within
the retained aggregate, but can be smaller because snapshots share blocks. This
matches [OpenZFS property semantics](https://openzfs.github.io/openzfs-docs/man/master/7/zfsprops.7.html).
Both consecutive observations must satisfy decomposition and exact bindings;
changes limited to counters, including retained blocks, remain retryable busy
observations rather than accepted capacity. The reader still returns no allocation
map. The caller must independently verify durable ownership before applying credit.

Tree/owner row bounds now allow 4096 filesystems plus their two transfer snapshots
and the parent (12,289 rows), while preserving the 4 MiB native-response cap. A
large tree exceeding either bound remains unavailable; no data is truncated into
schedulable capacity. This is a bounded reader, not a scale acceptance claim.

Property/regression tests cover retained-block sharing, no double counting,
GUID/path rebinding, absent snapshots, unexpected snapshots, duplicate GUIDs,
invalid properties and inconsistent decomposition. Lilly's full gate passed
136 cases (24 properties, 112 tests) and forced Dialyzer with no errors in
`/tmp/kittens-snapshot-accounting-lilly.log`. Marshall's dependent gate is running.

The maintained native-ZFS suite adds a real shared-block scenario: two snapshots,
then overwriting a common region. Its test-only expectations derive from the
fixture's native GUIDs; this explicitly does not prove production ownership.
The source-built reader must match the actual aggregate, reject stale filesystem
and snapshot GUIDs, reject a deleted expected snapshot, and recover observation
after cleanup. Source release/driver build and actual machine acceptance are pending
in `/tmp/kittens-snapshot-accounting-native-build.log`.

Final integration gap: a durable snapshot/import journal must establish these
expectations outside portable data, serialize creation/deletion with observation,
and retain commitments until confirmed reclamation. Passing these numerical tests
alone must not enable pool credit or source destruction.

The complete native suite passed in 285.64 seconds (exit 0), output
`/nix/store/1wf5d3qmlshzhi9svbv85m5w1sfx1dxj-vm-test-run-kittens-native-zfs`.
The new shared-snapshot accounting case passed in 13.33 seconds. Existing
native identity, incoherent/usage-only observations, sparse/compressed/random
growth, quota pressure, unsafe policy, unexpected snapshots/bookmarks/clones,
degraded backing, 400-child observations and persistent device-alias import
checks also passed. The framework removed QEMU; the runner restored `/dev/kvm`
to root/kvm 0660, independently inspected after exit.

Final review: source-built native observation and rootless properties now support
the numerical implementation. Existing allocation callers remain strict and no
production caller yet supplies snapshot expectations. No claim of durable snapshot
ownership, importer safety, two-Lilly relocation or cleanup authority follows from
this acceptance. ADR-0037 remains partial with those integration obligations open.


## Durable transfer snapshot journal — 2026-09-17

[SnapshotJournal](../../../lilly/lib/lilly/transfer/snapshot_journal.ex) implements
local intent for the two fixed snapshot slots under ADR-0037. The closed record
binds host, pool, placement, relocation, source execution epoch, zpool GUID, parent
filesystem GUID and child filesystem GUID. Its directory is caller-derived private
host state outside portable data. Mutation requires a current host lock; as with
existing disk helpers, the caller is responsible for holding the correct pool lock.

Creation persists a random nonce before any native command is authorized. Duplicate
preparation reuses it; a GUID can bind only once and both slots cannot bind the same
GUID. Final preparation requires a ready baseline or no baseline for stopped full
transfer. Retirement atomically fences both slots before native cleanup. A cancelled
uncertain create can bind its original nonce/GUID for deletion without regaining
creation permission. Deletion confirmation matches the exact recorded GUID and
retirement cannot finish while a slot remains unconfirmed. Cancellation before the
first create also leaves a permanent fence.

The journal validates private single-link files, a closed schema, immutable binding,
canonical GUIDs/nonces and reachable phases. It tolerates an exact private
unpublished `PrivateFiles` temporary after an interrupted publication, but never
adopts that file's contents as native intent. Other unknown files are refused.
Publication uses file fsync, atomic rename under the lock-owning helper, directory
sync and parent sync before acknowledgement. No live lock inode is removed.

The new rootless suite covers retries/reloads, baseline/final ordering, wrong nonce,
GUID replacement/duplication, retirement before generation, uncertain-create cleanup,
wrong deletion identity, permanent retirement, every binding field, malformed state,
unknown files, symlinks, hard links, unsafe modes, unpublished temporaries and
arbitrary journal bytes. An initial compile caught reserved Elixir attribute/type
names; they were corrected before successful verification. Final Lilly precommit
passed 145 cases (25 properties, 120 tests) and forced Dialyzer with no errors,
log `/tmp/kittens-snapshot-journal-lilly-final.log`. Marshall's dependent gate is pending.

Review boundary: the journal records a caller's verified native observations; it
cannot prove native ownership or physical absence by itself. No runtime caller yet
performs snapshot create/destroy through it. The per-placement current-journal index,
native nonce/GUID validation, capacity integration, stop proof, stream quiescence and
Oban reconciliation remain required. These transitions therefore do not enable
production allocation credit or source cleanup. ADR-0037 remains partial.

Marshall's dependent gate also passed: 280 cases (26 properties, 254 tests),
six JavaScript tests and forced Dialyzer with its existing single suppression,
log `/tmp/kittens-snapshot-journal-marshall.log`. ADR validation, contract
structure/discovery and whitespace checks passed. This journal governs snapshots
created locally on the source. Destination receive still needs its own import
intent before the new filesystem GUID exists; received stream data must not supply
that destination ownership intent or a trusted local creation nonce.


## Source snapshot effects and ownership integration — 2026-09-17

ADR-0037 remains accepted and partially implemented. The per-placement
[SnapshotIndex](../../../lilly/lib/lilly/transfer/snapshot_index.ex) publishes an
initializing pointer before its journal, then a bound pointer. Lost bound journals
cannot be recreated. Only a retired predecessor permits a different relocation at
a strictly newer execution epoch on the same physical disk. Historical retirement
retries return their tombstone without selecting or deleting a newer generation.
Eight index tests exercise interrupted publication, immutable bindings, lost state,
unsafe metadata and no-effect rejection.

[SourceSnapshots](../../../lilly/lib/lilly/transfer/source_snapshots.ex) now executes
fixed-argv snapshot creation and nonrecursive destruction under caller-held pool
ownership. It persists a nonce before creation, verifies its native local property
and immutable filesystem/snapshot GUIDs before binding, and recovers uncertain
creation. A missing ready snapshot is never recreated. Cleanup retires first,
checks exact ownership, confirms absence and keeps permanent tombstones. The
caller must still prove current authority, reserved headroom, physical final stop
and stream quiescence. These are privileged primitives, not an implemented move.

Pool observation now uses
[SnapshotOwnership](../../../lilly/lib/lilly/transfer/snapshot_ownership.ex) to join
local claims, current journals and native nonces before ZFS policy/accounting and
disk allocation verification. Native usage includes retained snapshot blocks once.
Credit remains conservatively capped at disk bytes, without temporary-reservation
credit. Disk deletion refuses owned snapshots before entering deleting state.

A full-gate failure exposed a native lock-handshake race: expected contention could
close the pipe while the parent sent its nonce. The helper now consumes the bounded
nonce before attempting the lock and acknowledges only after acquiring it. Elixir
also handles an already-closed port. Thirty-two competing acquisitions exercise
rejection without losing the held owner, then successful successor acquisition.
This preserves ADR-0017's stable lock inode and acknowledgement requirements.

Verified application gates exited zero: Lilly 154 cases (25 properties, 129 tests),
Marshall 280 cases (26 properties, 254 tests), JavaScript checks and forced Dialyzer.
Logs are `/tmp/kittens-source-snapshots-lilly-verified.log` and
`/tmp/kittens-source-snapshots-marshall-verified.log`. The source-built Nix lifecycle
driver also built and linted successfully. The real machine run is active at
`/tmp/kittens-source-snapshots-machine.log`; its immutable derivation is
`/nix/store/bd4mphhz1l82bhxs73f95x2nsl9jvx5w-vm-test-run-kittens-zfs-lifecycle.drv`.
New cases cover interrupted creation/deletion, marker and GUID replacement,
retirement retries after name reuse, source reclamation and neighbor preservation.
No success claim is made until the machine run completes.

Remaining findings within this increment:

- ADR-0037 incomplete: `Collector.snapshots/1` currently aborts the whole report on
  one unavailable pool. Production relocation requires unavailable state per pool,
  preserving fresh independent observations without inventing capacity.
- ADR-0037 incomplete: temporary-credit integration, destination import authority,
  SSH permits/stream revocation, runtime stop proofs, Oban reconciliation and atomic
  handoff/cancel remain required. Snapshot APIs are not yet exposed to remote jobs.
- After source-disk removal, retries must use the disk tombstone/coordinator phase;
  the snapshot primitive intentionally requires an existing active ready disk claim.


## Per-pool unavailable observations — 2026-09-17

This implements the previously recorded ADR-0037 reporting gap. Lilly's
[Pool.report/1](../../../lilly/lib/lilly/host/pool.ex) turns an observation error,
including native pool-lock contention, into configured identity plus explicit
unavailable state. The collector continues inventory and independent pool/I/O
samples. Inventory, effective-limit and invalid pool-topology failures still
withhold the host report. The unavailable identity is configuration, not proof
that the native dataset was observed.

The [protocol](../../../protocol/lib/overalls_protocol.ex) accepts a closed four-field
unavailable variant without counters or allocation credit. Marshall still requires
exactly one valid entry per enrolled pool under its current ordered session.
[HostReports](../../../marshall/lib/marshall/compute/host_reports.ex) matches enrolled
GUID/name identity and transactionally clears that pool's freshness, credit and
storage observation. Retained totals remain historical; no reservation is released.
Existing admission, restart and relocation helpers already check each pool's
freshness. A later verified observation restores normal eligibility.

[Telemetry](https://github.com/antithesishq/kittens/blob/a99f74f06542798dc9ef288e77c99d480433fc57/marshall/lib/marshall/telemetry/observations.ex) records physical
capacity and allocatable bytes as unknown while freshness is absent; independent
I/O, reservation commitments and enrolled logical budgets remain distinct. The
change uses existing Ash report actions and nullable freshness, without schema
changes or a compatibility adapter.

Protocol round-trip/negative tests and focused Marshall tests passed. Tests cover
neighbor admission after one pool becomes unavailable, unchanged existing
reservations, malformed/mismatched entries, recovery and unknown telemetry.
A rootless Lilly test exercises actual native lock contention and verifies no ZFS
claim is created or held ownership lost. All three full gates exited zero: protocol 43 cases (17 properties, 26 tests),
Lilly 155 cases (25 properties, 130 tests), and Marshall 282 cases (26 properties,
256 tests) plus six JavaScript tests. Forced consumer Dialyzer passed; Marshall
retains its existing single upstream suppression. Logs are
`/tmp/kittens-unavailable-protocol.log`, `/tmp/kittens-unavailable-lilly.log`, and
`/tmp/kittens-unavailable-marshall-final.log`. The final Marshall gate includes
removing physical-capacity fields from unavailable I/O telemetry and testing the
mixed report through actual JSON/protocol decoding. ADR structure, contract gates
and whitespace checks pass. These checks do not prove a native multi-pool relocation.
The source-snapshot native suite remains independently running on its immutable
pre-reporting-change derivation.


## Destination import intent and lineage — 2026-09-17

[ImportJournal](../../../lilly/lib/lilly/transfer/import_journal.ex) adds the local
receive-intent boundary required by ADR-0037. Its private record lives outside
portable data and uses the closed v3 descriptor to bind endpoints, epochs, workload
shape/image/network identity and source filesystem GUID, plus the destination's
local parent/pool identity. A random local nonce is durable before receive. Native
filesystem GUID binding is immutable and explicitly independent of source GUID.

Only baseline or full transfer can initialize. A completed baseline allows its
exact incremental successor on the same bound filesystem; strategy changes,
late baseline completion and substituted lineage fail. Receive completion matches
the current stream and target GUID but grants no execution, handoff or cleanup
authority. The future native caller must verify staging policy, snapshot lineage,
stream termination and absent resume token. Cancellation retires before effects,
permits binding an uncertain partial receive solely for cleanup and retains a
permanent tombstone after caller-proven native absence. Missing state cannot
complete or bind; new intent still requires caller-proven native absence and
current reservation/relocation authority.

Seven rootless cases cover full and pre-copy paths, stable retries, partial binding,
wrong nonce/GUID, immutable identity changes, unknown fields and unsafe modes,
cancellation before/during receive, no-lock/missing-state refusal and arbitrary
persisted bytes. Test lock owners explicitly release before temporary cleanup.
Lilly precommit exited zero: 162 cases (26 properties, 136 tests), structural
contracts/ADRs and forced Dialyzer, log `/tmp/kittens-import-journal-lilly-final.log`.
The dependent Marshall gate also exited zero: 282 cases (26 properties, 256 tests),
six JavaScript tests and forced Dialyzer with its existing single upstream
suppression, log `/tmp/kittens-import-journal-marshall-final.log`.
The protocol is unchanged from its prior successful 43-case gate. Final contract
review replaced defensive use of the shared encoder on unvalidated inputs with a
bounded local conversion followed by shared-schema validation. Both final gates
above include that correction; no peer strings become atoms. ADR structure and
whitespace checks also pass.

Review limit: this journal does not yet run `zfs receive`, validate native staging,
join destination allocation accounting, adopt an executable disk claim or provide
an Oban phase. Those remain implementation requirements. The source-native
suite predates this journal and cannot establish destination receive integration.


### Native source snapshot verification completed

The previously running immutable source-snapshot lifecycle derivation exited zero.
The complete native machine script passed in 1107.18 seconds; the added source
snapshot subtest passed in 342.58 seconds. Output:
`/nix/store/0la1x8npcqpqjfz517wjm74yf631sbbw-vm-test-run-kittens-zfs-lifecycle`.
The log remains `/tmp/kittens-source-snapshots-machine.log`. Framework cleanup
terminated QEMU and the runner restored the original `/dev/kvm` ACL; both were
checked after successful process completion.

The source-built Lilly APIs recovered an actual interrupted native snapshot,
reused its GUID on retry, refused disk deletion before snapshot retirement,
rejected foreign markers and replaced GUIDs, recovered interrupted snapshot
removal, and preserved a newer relocation's reused snapshot name against stale
cleanup. Missing bound snapshots were not regenerated. The test retained its
synthetic disk marker, removed the source dataset with ownership history retained,
and preserved the independent neighbor's claim and allocation before final cleanup.
The earlier lifecycle rejection/crash-recovery cases also passed.

This verifies local ZFS source storage effects and ownership, not a running guest,
SSH transfer, Oban orchestration or cross-host handoff. The immutable derivation
predates the subsequent unavailable-report and destination-journal additions; those
have separate application evidence and are not claimed covered by this machine run.


## Native streaming process ownership — 2026-09-17

ADR-0037's bounded-memory stream requirement now has a
[native helper](../../../lilly/native/transfer-stream/src/lib.rs) and
[typed Lilly wrapper](../../../lilly/lib/lilly/transfer/stream.ex). The helper uses
a kernel pipe between producer and receiver, not the existing buffered command
runner. It acknowledges a separate stable private lock before spawning work.
Neither disk bytes nor diagnostics are returned to the BEAM. The diagnostic pipe
has a 64 KiB total bound, including a final drain after writer reaping.

Both private process groups retain the lock descriptor across exec. Caller EOF,
any unexpected control input, timeout, excessive diagnostics or either child
failure kills both groups and reaps descendants under Linux subreaper ownership.
Leader PIDs remain zombies until final cleanup so group numbers cannot be reused
while the other side runs. Unknown/unreapable work never returns completion.
Helper death gives its direct children a parent-death kill signal; independent
lock acquisition is still required before treating an uncertain result as quiescent.
No live lock inode is removed. The wrapper rejects a current host/pool lock to
avoid holding pool observation ownership through a bulk transfer.

The native helper is a trusted, non-setuid internal interface with bounded absolute
argv, not a remote shell or an SSH authorization endpoint. Caller authority,
immutable transfer intent, fixed SSH/ZFS command construction, key pinning and
permit expiry/revocation remain required integration. A zero process status is
not verified receive lineage or activation/source-deletion authority.

Six new rootless cases pass: 64 MiB hash-preserving transfer, timeout reaping,
caller-death revocation with both utility descendants reaped, stable-inode native
contention, producer/consumer failure, discarded excessive diagnostics and
argument/lock bounds. Lilly's full gate exited zero with 168 cases (26 properties,
142 tests) and forced Dialyzer, log `/tmp/kittens-native-stream-lilly.log`.
Marshall's dependent gate also exited zero with 282 cases (26 properties, 256
tests), six JavaScript tests and forced Dialyzer with its existing single upstream
suppression, log `/tmp/kittens-native-stream-marshall.log`.
The Nix driver built and linted successfully. The expanded native ZFS suite exited
zero in 43.34 seconds, log `/tmp/kittens-native-stream-machine.log`, immutable
derivation `/nix/store/ii8akrj8wndfsrz848mxikgldaaj2fbx-vm-test-run-kittens-zfs-transfer.drv`,
output `/nix/store/k8f9pywmswfn4j427kh8mdp0i4nzs0lw-vm-test-run-kittens-zfs-transfer`.
Actual helper-backed receive, EOF cancellation during partial native ZFS receive,
resume and raw disk hash verification passed. A bounded fixture pauses real send
output after 4 MiB; closing the helper's control pipe kills/reaps producer and
receiver, and the test resumes the retained receive token without printing it.
Both helper-backed destinations retain exact snapshot GUIDs and unmounted read-only
policy before verification. The existing lineage, full-transfer, abort and source
reclamation/ext4 checks also pass. Framework cleanup terminated QEMU and the
original `/dev/kvm` ACL was restored and checked. This is two pools in one outer
NixOS machine, not SSH or Oban-driven relocation between Lilly hosts. Structural
ADR/contracts and whitespace checks pass; ADR-0037 remains partial.


## Native destination staging verification — 2026-09-17

[ReceivedDataset](../../../lilly/lib/lilly/transfer/received_dataset.ex) joins a
pre-existing destination-local import journal to actual staging state. The
placement-derived import directory remains outside the received child dataset.
Pool ownership must already be held, endpoint IDs must match the local pool/host,
and ordinary active/deleted placement claim directories must be absent. Native
host/pool/placement/nonce properties must be local rather than inherited or supplied
by the stream. After exact native verification, the import journal binds its own
filesystem GUID and records the current stream's target snapshot receipt. A lost
journal cannot be reconstructed or replaced by native markers.

[ZFS.receive_child/4](../../../lilly/lib/lilly/host/zfs.ex) retains the normal mounted
writable policy for ordinary observation and source snapshots, adding an explicit
receive-only policy for this verifier. It reads the exact child plus expected
snapshots twice, checks stable policy/GUID identity and coherent decomposition,
requires canonical unmounted read-only/noauto state, local exec/setuid/devices=off,
no resume token, no relevant host mount or alias, and unchanged parent/backing
identity. Extra snapshots/descendants and replaced GUIDs fail. It returns no
capacity credit or executable claim. Native receipt does not verify guest rootfs
shape or immutable image compatibility, and cannot authorize activation or source
cleanup. Stream quiescence and current relocation/reservation remain caller proofs.

The Nix transfer suite now consumes the source-built Lilly package through the
existing separate build/test package inputs. Its new fixture creates local import
intent, receives a real dataset with destination-local properties, verifies repeat
receipts, and deliberately changes policy, mounts, local/inherited markers and
snapshot/filesystem GUIDs. It asserts no executable disk claim appears. Its
synthetic workload descriptor is deliberately not guest-image validation evidence.
Native execution and final application gates are pending; the initial driver built
and linted successfully. Rootless refusal coverage exercises missing local intent
and wrong endpoint identity before native effects. ADR-0037 remains partial.


Import history also fences ordinary blank-disk initialization for the same
placement, even after the received filesystem disappears. Existing import roots
must remain private directories; a symlink or unsafe root cannot bypass that
check. The native fixture exercises ordinary preparation refusal after child
removal, then parent-owner reconstruction refusal with the retained import record.
The native run is now active at `/tmp/kittens-received-dataset-machine.log`,
immutable derivation
`/nix/store/zsp4b1hvqfrn73yn6f966f4kjy3svjsh-vm-test-run-kittens-zfs-transfer.drv`.
The source-built driver passed type/lint checks. Lilly's final gate exited zero
with 169 cases (26 properties, 143 tests) and forced Dialyzer, log
`/tmp/kittens-received-dataset-guarded-lilly.log`. Marshall's dependent gate has
passed its 282 cases and is completing Dialyzer at
`/tmp/kittens-received-dataset-guarded-marshall.log`. Native success remains pending.


### Destination staging verification completed

The immutable native run above exited zero in 94.31 seconds. Its new destination
staging subtest passed in 50.26 seconds; output is
`/nix/store/0qn2r3dwgaaj35dy423wy18j14sqa363-vm-test-run-kittens-zfs-transfer`.
Source-built Lilly accepted native receipt and stable retries, then rejected
writable/automount/exec/setuid/devices policy changes, mounted staging, foreign and
inherited nonce markers, extra snapshots and replacement snapshot/filesystem GUIDs.
Rejected verification left the substituted native identities untouched. Ordinary
blank provisioning and missing-parent-owner reconstruction both failed after
native child removal because import history remained. No executable placement
claim was created; staging remained unavailable for ordinary allocation credit.
The pre-existing transfer interruption/resume, native helper cancellation, lineage,
source reclamation and ext4 checks also passed. Framework QEMU cleanup completed,
and the `/dev/kvm` ACL matches its captured original state after the runner exited.

Both final application gates exited zero: Lilly 169 cases (26 properties, 143 tests),
Marshall 282 cases (26 properties, 256 tests) plus six JavaScript tests and forced
Dialyzer. Marshall retains its single existing upstream suppression. Final logs:
`/tmp/kittens-received-dataset-guarded-lilly.log` and
`/tmp/kittens-received-dataset-guarded-marshall.log`. ADR structure, contract gates
and whitespace checks pass. These results verify staging facts and receipt
publication in one outer NixOS machine, not guest rootfs/image validation, destination
activation, SSH authorization, capacity-credit adoption or Oban handoff. Those
remain required implementation under ADR-0037.


### Review recovery on 2026-09-17

A later evidence update accidentally replaced this untracked review with the Nix
test README. The pre-repair file is retained at
`/tmp/relocation-review-before-recovery.md`. Recovery used the recorded review
replacement and subsequent review-only edits from the session history, replayed
against an in-memory document. No recorded shell commands or unrelated edits were
replayed. The erroneous final README write was excluded; its accompanying native
verification section was retained. This restores the previously reconstructed
review and subsequent evidence, not the original pre-reconstruction prose.


### Guarded destination import preparation

Architecture impact remains within ADR-0037: Lilly owns durable local effects;
Marshall authority and reservations remain caller prerequisites.
[ReceivedDataset.prepare/2](../../../lilly/lib/lilly/transfer/received_dataset.ex)
now joins validated local intent, destination identity, parent binding and ordinary
claim exclusion before preparing receipt state. New intent requires absent native
data and an absent canonical mountpoint. Retained filesystem GUIDs cannot select a
replacement child. An incremental successor rechecks the recorded baseline's
native GUID lineage and receive-only policy before advancing its journal.
Private import-root creation is synchronized before the journal is published.

The native fixture now calls this production entry point instead of constructing
its journal directly. New cases cover stable full-transfer preparation retries,
missing-journal refusal with existing native data, missing/replaced received data,
and baseline-to-incremental advancement with foreign-snapshot refusal. The
immutable machine run passed in 115.45 seconds at
`/tmp/kittens-import-preflight-machine.log`, derivation
`/nix/store/xdsz0w03ak0r8k65qan2apym2qdjlq4i-vm-test-run-kittens-zfs-transfer.drv`.
Lilly precommit passed 169 cases (26 properties, 143 tests), contracts and forced
Dialyzer; log `/tmp/kittens-import-preflight-lilly.log`. Marshall's dependent
precommit passed 282 cases (26 properties, 256 tests), six JavaScript tests and
forced Dialyzer with its existing upstream suppression; log
`/tmp/kittens-import-preflight-marshall.log`. Native output is
`/nix/store/026pcvjbl2rrpcfnq33r81bxda42rxil-vm-test-run-kittens-zfs-transfer`.
The runner exited zero after QEMU cleanup. Contract discovery and `git diff
--check` also passed. This native suite uses two block-backed pools in one VM; it
does not establish cross-host SSH or relocation orchestration.

Contract review traced ImportJournal.read/prepare, ReceivedDataset.verify, native
owner checks, ZFSDataset.bind, PrivateFiles.directory and synchronized publication.
Preparation does not start a stream or manufacture a disk claim. Actual reservation
authority, transfer quiescence and correct pool locking are caller preconditions;
the missing coordinator must supply them. SSH permits, receiver/resume command
orchestration, disk adoption, temporary credit, handoff, cancellation, all-copy
cleanup and public move actions remain required.


### Destination disk adoption implementation

Architecture impact remains within ADR-0037.
[Disk.adopt/3](../../../lilly/lib/lilly/vm/disk.ex) reloads the exact local image,
checks admitted architecture and resource minima, and invokes native adoption
under the pool lock. It never calls ordinary image-copy initialization.
[ZFSDataset.adopt/3](../../../lilly/lib/lilly/host/zfs_dataset.ex) accepts only a
received final full/incremental stream and matching destination identity/spec.
It publishes an importing claim from private staging by atomic rename before
removing snapshots. `importing`, `import-pruned` and `import-publishing` retain the
original local nonce/GUID and exclude ordinary preparation. Only exact known
snapshot survivors can be pruned. A read-only canonical mount permits rootfs shape
inspection before writable policy and destination-local disk metadata publication.
The rootfs must be the only directory entry, regular, single-link, exactly the
admitted size and owned by root or the preserved profile/slot UID. No adopted
path copies or truncates the guest file.

[ZFS.adoption_child/5](../../../lilly/lib/lilly/host/zfs.ex) verifies GUIDs, backing,
coherent native policy and exclusive canonical mounts during those transitions.
It permits an absent known snapshot only after the durable pruning intent, and
known intermediate readonly/canmount values only during publication. Lost mounts
can be recovered from verified empty canonical mountpoints. Completed adoption
uses ordinary ready-disk accounting, capped at its logical disk commitment; this
does not implement temporary-reservation credit. New `zfs set` effects are
delegated to the lock-owning helper and rejected without a lock.

The [native fixture](../../../nix/verification/tests/machines/zfs-transfer/adoption.exs) uses
content-verified synthetic boot artifacts and a real received ext4 backing file.
The [driver](../../../nix/verification/tests/machines/zfs-transfer/driver.py) interrupts actual
snapshot destruction, mounting and property changes before their callers complete,
then retries from the retained claims. It also checks image mismatch, baseline
refusal, imported-file size mismatch, foreign nonce, ordinary-prepare exclusion,
mount loss during publication, retained file hash and missing-file non-recreation.
These are storage checks, not bootable-image or guest activation acceptance.
The source-built driver passed type/lint checks. The native run passed in 199.27 seconds at
`/tmp/kittens-import-adoption-machine.log`, immutable derivation
`/nix/store/vxz0bpl3bqs3kifczlbr01zr9sz5c74c-vm-test-run-kittens-zfs-transfer.drv`.
Lilly precommit passed 169 cases (26 properties, 143 tests) and forced Dialyzer at
`/tmp/kittens-import-adoption-final-lilly.log`. Final dependent Marshall precommit
passed 282 cases (26 properties, 256 tests), six JavaScript tests and forced
Dialyzer with the existing upstream suppression at
`/tmp/kittens-import-adoption-final-marshall.log`. Both processes exited zero.
The immutable native output is
`/nix/store/c6ghlz85q4q932a6v05v9nb0rxdl31hc-vm-test-run-kittens-zfs-transfer`.
Its runner exited zero after QEMU cleanup. This adoption scenario exercises the
full stopped stream; native baseline/incremental transfer and baseline-adoption
refusal pass separately, but incremental disk adoption has not yet been exercised.
No native claim here establishes a guest boot, a physical host reboot, cross-host
SSH, cancellation cleanup or coordinated source deletion.

Review traced claim parsing/ordinary preparation, source snapshot ownership,
accounting, Image.load, ImportJournal, ReceivedDataset, native tree/mount checks
and locked utility publication. The import states are recognized but cannot pass
ordinary preparation's creating/bound/ready guard. Physical quiescence, current
relocation authority and reservations remain caller prerequisites. No production
Oban caller yet supplies them. Cancellation cleanup must handle partially adopted
claims; SSH permits/stream orchestration, temporary credit, handoff, all-copy
Delete, source cleanup coordination and user actions remain outstanding.


### Incremental disk adoption acceptance

Architecture impact: additional native evidence for ADR-0037, with no change to
its accepted requirements or production interfaces. The
[adoption fixture](../../../nix/verification/tests/machines/zfs-transfer/adoption.exs) now
constructs a distinct placement and immutable descriptor for baseline receipt,
then advances through production guarded preparation to its exact incremental
stream. The source receives a later disk-tail write, so the final hash must differ
from the earlier full-transfer fixture.

The [driver](../../../nix/verification/tests/machines/zfs-transfer/driver.py) checks baseline
adoption refusal, stable destination GUID through incremental receive, and caller
death after native removal of snapshot B but before removal of A. It introduces
an unknown snapshot at that interrupted point and requires refusal without
removing A or changing the importing claim. After removing that fixture-owned
conflict, repeated adoption and ordinary reuse must preserve the final hash,
remove both transfer snapshots, and leave the earlier adopted neighbor unchanged.
This uses synthetic boot artifacts and two pools in one VM; source execution,
SSH, guest readiness, cancellation and handoff are outside this test's scope.

The source-built driver passed type/lint checks and repository contract format
validation passed. No application production code changed; the prior final Lilly
and Marshall precommit results remain the application evidence. The native run passed in
286.84 seconds at `/tmp/kittens-incremental-adoption-machine.log`, immutable derivation
`/nix/store/k8mpypg3vihq0pxnv1zv843sv403r62d-vm-test-run-kittens-zfs-transfer.drv`.

The incremental scenario passed interrupted B/A pruning, unknown-snapshot
refusal, stable GUID, repeated adoption, ordinary reuse, final disk hash and
neighbor identity/content preservation. Native output is
`/nix/store/p5mc9kg399qq6bjz9alawrhxjq2qq0vh-vm-test-run-kittens-zfs-transfer`.
The runner exited zero after QEMU cleanup. The separate full-stream adoption and
existing storage tests also passed in this run. Relocation remains partial: these
results do not provide Oban coordination, SSH authorization, source-stop/handoff
authority, cancellation cleanup or guest boot/readiness acceptance.


### Destination import retirement and physical cleanup

Architecture impact stays within ADR-0037's retained-capacity and permanent-fence
requirements. [Disk.discard_import/2](../../../lilly/lib/lilly/vm/disk.ex) enters
the destination pool lock and invokes
[ImportCleanup.cleanup/2](../../../lilly/lib/lilly/transfer/import_cleanup.ex).
Its caller must already hold current cancellation/deletion authority and prove
stream/VMM/jail quiescence; this entry point does not establish those proofs.

Cleanup reads pre-existing local intent, fences matching adopted/partially adopted
claims as `import-deleting`, and retires the import journal before native effects.
Missing intent can acquire a cancellation tombstone only after native absence; it
cannot adopt an existing child. A previously unbound interrupted receive is bound
to its local creation nonce and destination GUID only after native staging checks.
The current locally recorded stream supplies GUID lineage even if the request
carried an earlier descriptor for that same relocation. Resume state can be aborted
only for unadopted, unmounted read-only staging. The opaque token never leaves the
bounded native reader as a result or diagnostic.

[Native cleanup checks](../../../lilly/lib/lilly/host/zfs.ex) reject replaced GUIDs,
unknown snapshots/descendants, unsafe properties and mount aliases. Verified
snapshots are removed individually, canonical mounts unmounted without force, and
the child destroyed without recursive/force flags. Native/mount absence precedes
ordinary claim tombstones and permanent import retirement. Empty mountpoints are
removed without recursion. Retired retries check absence rather than authorizing
new destruction. No cleanup return releases a Marshall reservation or stream slot.

New native cases cover complete baseline/incremental imports, interrupted full
and incremental receive, missing/replaced data, cancellation before streaming,
interrupted unmount of a partially adopted copy, ready-copy cleanup and neighbor
preservation. The source-built driver passed type/lint checks. The first native execution
failed at interrupted incremental cleanup; log `/tmp/kittens-import-cleanup-machine.log`, immutable derivation
`/nix/store/ilwp40b8wbl1kphqp9bzqlxd6rj7w3zi-vm-test-run-kittens-zfs-transfer.drv`.
Lilly precommit passed 169 cases and forced Dialyzer, log
`/tmp/kittens-import-cleanup-lilly.log`. Marshall's dependent precommit passed at
`/tmp/kittens-import-cleanup-marshall.log`.

Contract review traced pool locking, private journal publication, exact claim
binding, normal provisioning's allowed-state guard, native command ownership,
resume-state parsing and absence checks. `import-deleting` cannot pass ordinary
preparation or adoption. Missing/corrupt ownership keeps cleanup unconfirmed.
SSH permits and revocation, authenticated stream commands, Oban phase/outbox
coordination, atomic handoff/cancel, temporary credit, logical all-copy Delete and
public user actions remain outstanding. Local cleanup is not those integrations.


#### Interrupted incremental accounting correction

A focused native reproduction at `/tmp/kittens-import-cleanup-focus2.log` showed
that an interrupted incremental receive retained 3,709,440 child-accounted bytes
on the original filesystem without an additional visible filesystem. Its local
GUID, read-only/noauto/unmounted policy and baseline snapshot were unchanged.
The ordinary no-child-data rule therefore prevented safe receive abort.
Cleanup now permits those bytes only with a native resume token on owned read-only
unmounted staging and an otherwise exact tree. The documented
[OpenZFS receive abort](https://openzfs.github.io/openzfs-docs/man/master/8/zfs-recv.8.html)
discards saved partial receive state; the implementation then requires strict
normal child accounting, cleared token and known snapshots before further
destruction. Neither ordinary observation/credit nor adoption gains this exception.

The final source-built driver passed, and both final application precommit gates
passed with forced Dialyzer: 169 Lilly cases and 282 Marshall cases plus six
JavaScript tests. Logs are `/tmp/kittens-import-cleanup-final-lilly.log` and
`/tmp/kittens-import-cleanup-final-marshall.log`. That native rerun failed again
at interrupted incremental cleanup: `/tmp/kittens-import-cleanup-final-machine.log`, immutable derivation
`/nix/store/dg32wff6zgycf1qq61qiphj2zrvb1s7r-vm-test-run-kittens-zfs-transfer.drv`.
It additionally checks cancellation without an existing intent record and refusal
to reconstruct missing intent around existing native data. The failed focused
run's temporary KVM ACL was explicitly restored and compared before the final
runner; its cleanup uses exact ACL replacement guarded by an unchanged-ACL check.


The remaining rejection was traced to `snapshot_bindings/3`, which independently
called the strict child-accounting check for the retained baseline. The explicit
abort-only flag now reaches that check as well as the filesystem check. Ordinary
accounting still uses its strict default; after abort, cleanup rereads native state
and uses the strict receive mode. No ownership/GUID, snapshot-set or mount check
was removed. The full native rerun completed successfully; final evidence follows below.


#### Destination cleanup verification completed

The corrected full native suite passed in 457.05 seconds (runner exit zero):

- Derivation: `/nix/store/q24szcdfhffb6w06w4bqf18yy7xx4v8l-vm-test-run-kittens-zfs-transfer.drv`.
- Output: `/nix/store/wzks6xk5vjinl9m3qqirczpij4hnzcmb-vm-test-run-kittens-zfs-transfer`.
- Log: `/tmp/kittens-import-cleanup-snapshot-machine.log`.

Interrupted full/incremental cleanup passed in 58.05 seconds; cancellation of
partially adopted and ready copies passed in 61.49 seconds. These cases prove
actual receive abort, native child absence, retained local tombstones, rejection
of resumed preparation/adoption, recovery after actual unmount and caller death,
and unchanged neighboring disk content. Missing ownership and foreign native
identity still refuse cleanup. Full/incremental adoption and the existing
source-reclamation storage case also passed. These are storage-level checks,
not end-to-end relocation or guest-activation acceptance.

Both application precommit gates passed for this source revision:
`/tmp/kittens-import-cleanup-snapshot-lilly.log` (169 cases, forced Dialyzer zero
errors) and `/tmp/kittens-import-cleanup-snapshot-marshall.log` (282 cases, six
JavaScript tests, forced Dialyzer with one existing suppression). The ADR checker
passed all 38 records. The native runner terminated and its temporary named
`nixbld` KVM ACL grant was confirmed absent afterward.

Architecture impact remains implementation of ADR-0037's permanent retirement
and physical-reclamation requirements. The abort-only accounting exception is
propagated consistently through snapshot and filesystem checks; ordinary capacity
and adoption keep their strict behavior. Current authority and stream/VMM
quiescence remain required from the future coordinator. SSH enrollment/permits,
Oban phase coordination, atomic handoff/cancellation, temporary capacity credit
and the user-facing relocation flow remain outstanding.


### Operator-enrolled transfer identity

ADR-0037 implementation now adds a shared closed SSH endpoint codec (canonical
address, bounded port and exact Ed25519 public blob), a validated Ash storage
type and an optional operator-enrollment field. The generated host migration
and resource snapshot persist this identity with the host. Public enrollment
inspection and credential rotation retain it; control reports/session actions
cannot replace it. Omission is a deliberate lack of relocation capability, not
a fallback to key discovery. Existing ordinary host admission is unaffected.

The relocation capacity transaction now excludes sources/destinations without a
valid enrolled endpoint before any new placement, reservation or stream slot.
The existing destination key-custody implementation uses the same public-key
validator, avoiding a second SSH key grammar. Tests cover malformed SSH option,
address and key inputs; real operator file enrollment and credential rotation;
and database-backed capacity rejection with no relocation records left behind.
The initial schema generation caught an overly broad source replacement in the
enrollment parser; it was corrected before migration generation or test execution.
All three application precommit gates passed: protocol 45 cases (18 properties,
27 tests), Lilly 169 cases (26 properties, 143 tests), and final Marshall 287 cases
(26 properties, 261 tests) plus six JavaScript tests. Dialyzer passed in all three;
Marshall retained its existing single upstream suppression. Logs are
`/tmp/kittens-transfer-endpoint-protocol.log`,
`/tmp/kittens-transfer-endpoint-lilly.log` and
`/tmp/kittens-transfer-endpoint-final-marshall.log`. The final Marshall run also
covers direct Ash rejection of malformed endpoint input and attempted pin
replacement through ordinary configuration. The Ash type maps shared protocol
rejection to the standard `:error` callback result.

`mix ash.codegen --check` passed under the isolated schema partition; log
`/tmp/kittens-transfer-endpoint-schema.log`. The generated migration is
`20260917042936_enrolled_transfer_endpoint.exs`, with host snapshot
`20260917042937.json`. The final ADR structural checker passed all 39 records
(including independent concurrent architecture work). No native
SSH connectivity/authentication claim is made by these checks.

This establishes stored trust identity only. Nix SSH service configuration,
authenticated endpoint/key distribution to the receiving host, permit-bound
commands, connectivity preflight and active-channel revocation remain unfinished.
Oban coordination and handoff must use these identities and cannot infer working
transfer access from enrollment or a fresh ordinary capacity report.


### Pinned SSH producer and local peer binding

The destination now has `Lilly.Transfer.SSH.pull/5`, joining existing private-key
custody to the native stream helper. It accepts a closed local request and an
authenticated enrolled endpoint, prepares private known-hosts data, and invokes
OpenSSH with only the per-relocation identity and a fixed export verb, relocation
UUID and stream kind. No peer paths or arbitrary remote commands are accepted.
The source host-key alias is its enrolled UUID, independent of DNS resolution.

The existing key journal now also retains the source endpoint binding. It is
persisted before known-hosts publication and rejects endpoint changes even when
the derived known-hosts file is missing. Ready-key validation precedes preparing
connection paths; missing or retired keys are not generated by this path. This
fresh-deployment journal revision has no compatibility reader. Key retirement
retains public binding history while removing private material.

Client arguments use a separate known-hosts file, strict Ed25519 pin checking,
only public-key authentication, no agent, no forwarding and no multiplexed
connection. User/system SSH configuration and external known-hosts discovery are
excluded. Semantics were checked against the official
[OpenSSH client configuration manual](https://man.openbsd.org/ssh_config) and
[ssh manual](https://man.openbsd.org/ssh). Root paths containing SSH expansion
syntax are rejected before preparing files. Tests inspect actual `ssh -G`
configuration and exercise local binding loss, rebind refusal and retirement.

A new explicitly exported `ssh-transfer` Nix machine fixture uses the production
client and native pipe against real OpenSSH with disposable keys. It verifies
32 MiB integrity, wrong-host-key and wrong-client-key rejection before the forced
command runs, successful retry and retirement refusal. The first native run
passed. After moving the binding into the existing key journal, the final native
run also passed in 27.29 seconds (exit zero): derivation
`/nix/store/4pcp0d4gcbz9n0s5c03c9fgwllis1wg6-vm-test-run-kittens-ssh-transfer.drv`,
output `/nix/store/6xjf2gdnm1nlvga3bfk9b0kgvy4rkwqd-vm-test-run-kittens-ssh-transfer`,
log `/tmp/kittens-ssh-client-final-machine.log`. Its source-built driver lint
passed. The runner terminated and its named `nixbld` KVM ACL grant was confirmed
absent. This is a local native authentication/streaming test, not independent
physical-host or production permit acceptance.

The consumer command remains trusted local argv: production ZFS receiver
construction and permit-bound coordination must supply it only after durable
receive intent and current authority. This path does not grant source export
authority or verify a received dataset. Closing the local SSH connection is not
proof that remote processes are reaped; source-side permit revocation and process
supervision remain required. Nix production SSH service configuration, export
permits, resume-token exchange, Oban coordination and handoff are unfinished.


Final Lilly precommit passed 173 cases (26 properties, 147 tests) with zero
Dialyzer errors: `/tmp/kittens-ssh-client-final-lilly.log`. Focused key/connection
tests passed 15 cases: `/tmp/kittens-ssh-client-binding-tests.log`. Marshall's
dependent final precommit passed 287 cases (26 properties, 261 tests), six
JavaScript tests and forced Dialyzer with the existing single upstream suppression:
`/tmp/kittens-ssh-client-final-marshall.log`. The ADR checker passed all 39
records; the final scoped diff has no whitespace errors. This implements the
client side of ADR-0037's pinned, per-relocation SSH transfer requirement; source
permit enforcement and full relocation acceptance remain unfinished.


### Read-only source export selection

Before source permits can authorize a stream, the source needs to revalidate
physical ownership without invoking the snapshot-creation recovery path.
`SourceSnapshots.export/2` now decodes the closed transfer descriptor, matches
the source host/pool and exact local workload claim, and reads the current active
snapshot index for the relocation/epoch. Every recorded snapshot must be ready
and retain its local creation nonce and native GUID. The native tree/policy
check rejects unknown snapshots, descendants and changed identities.

Baseline export selects A, incremental export requires exact A-to-B GUID lineage,
and full export requires a final-only journal. Returned `zfs send` argv contains
only locally derived dataset names and fixed switches. No create, cleanup,
metadata recovery or peer-selected path occurs. `snapshot_source/2` now also
requires an existing matching parent ownership record, so export cannot repair
missing parent authority. The other two callers already bind the parent before
requesting this source check; their accepted initialization contract is unchanged.

An explicitly exported `source-export` native check reuses the source-built
ZFS lifecycle fixture. It sends all three supported stream forms through the
native helper, rejects stale relocation/epoch, wrong GUID, missing parent metadata
and foreign snapshots, and rejects export after cleanup. It passed in 381.96
seconds (runner exit zero), with log `/tmp/kittens-source-export-machine.log`,
derivation `/nix/store/csyiqxydy44f5ac43307cfqxaj7r04q0-vm-test-run-kittens-source-export.drv`
and output `/nix/store/wpsyajpmhvfsp1vb57fa8lsw79rqc36d-vm-test-run-kittens-source-export`.
The source-built driver lint passed. The runner terminated and its temporary
named `nixbld` KVM ACL grant was confirmed absent. Lilly precommit passed 173 cases and
forced Dialyzer with zero errors at `/tmp/kittens-source-export-lilly.log`;
Marshall's dependent precommit passed 288 cases (26 properties, 262 tests), six
JavaScript tests and forced Dialyzer with its existing single suppression at
`/tmp/kittens-source-export-marshall.log`. The ADR checker passed 39 records.

This is the physical source check for the pending permit path. It does not grant
export authority, enforce expiry/revocation or establish stream quiescence. The
caller must own the source transfer slot, prevent cleanup/launch races and enforce
current authority throughout execution. Durable permits, the restricted source
SSH endpoint and Oban coordination remain unfinished.


### Durable source permit leases and revocation fences

`Permit.issue/6` now joins every grant/renewal to `SourceSnapshots.export/2` under
the caller's pool lock. `PermitJournal` serializes durable state mutations on a
separate stable exports-directory lock, after the pool lock when both are needed.
The root is trusted durable source-host metadata outside portable guest data.
The record binds the complete descriptor identity, source filesystem GUID and
destination public key. Initial streams are baseline or full; only the exact
baseline-to-incremental lineage may advance. Higher revisions cannot change the
peer or immutable identity. Identical retries retain the original issuance time;
stale/conflicting revisions and shortened expiry are refused.

Leases use trusted source-local UTC seconds and are bounded to 300 seconds at
issuance. Lookup rejects expired/future-issued grants and requires the authenticated
peer key and current stream kind. Expired grants may renew only through a newer
authorized revision and another physical ownership check. Runtime integration
must separately enforce a monotonic deadline and serialize launch registration
with revocation; this metadata lookup is not that launch transaction.

Revocation fencing persists even before the first grant, retains prior public
history and permanently rejects later grants. Canonical permit directories are
atomically published with a synced unissued record before any grant. Missing or
corrupt records in an existing directory cannot recreate authority. An interrupted
initial publication can leave private `.pending-*` metadata outside canonical
lookup paths; those unissued staging artifacts require eventual scoped cleanup
after helper quiescence. They cannot authorize export.

Rootless tests cover bounded expiry, backward local time, exact retry, revision
ordering, immutable peer/descriptor, one-way lineage, full strategy, revocation
before/after issuance, host mismatch and missing/corrupt/symlink state. Lilly
precommit passed 179 cases (27 properties, 152 tests), forced Dialyzer zero errors:
`/tmp/kittens-source-permit-lilly.log`. Marshall precommit passed 288 cases (26
properties, 262 tests), six JavaScript tests and forced Dialyzer with the existing
one suppression: `/tmp/kittens-source-permit-marshall.log`.

The native source-export fixture now exercises issuance against actual source
ownership, refuses renewal with missing parent authority, advances to incremental
and rejects the old phase, rejects grants after fencing while source data still
exists, and fences a second relocation before its first grant. It passed in
468.41 seconds (runner exit zero): log `/tmp/kittens-source-permit-machine.log`,
derivation `/nix/store/jryrm1rh2cy9w066bbmjilyh4n1m6k3j-vm-test-run-kittens-source-export.drv`,
output `/nix/store/8wni9fylidjhkjqbf4vr1ha4j8lizzfz-vm-test-run-kittens-source-export`.
The source-built native driver lint passed. The structural ADR checker passed
40 records, including independent concurrent architecture work. The initial ACL-owning runner exited
75 without changing permissions because another native test already owned the
KVM grant; the actual run reuses that existing access without ACL mutation.

Architecture impact is implementation of ADR-0037's local source permit record.
A persisted grant does not mean SSH authorization has been installed. A persisted
fence does not prove any active or waiting export process is stopped. The source
SSH service, authenticated permit/key delivery, runtime expiry and kill/reap
integration, resume-token exchange, Oban coordination and handoff remain pending.


### Strict source SSH request boundary

ADR-0037 remains accepted/partial; no decision changes. Added
[ExportRequest](../../../lilly/lib/lilly/transfer/export_request.ex) to parse
exact fixed commands and resolve them through the durable permit journal.
The peer key and local host/root remain trusted server inputs; client text cannot
select a path, program, arbitrary phase or identity. Lookup is explicitly not
launch authority across revocation. Existing production SSH client arguments are
checked against the parser. New tests cover malformed/shell input, arbitrary
bytes, missing permits, wrong peer/host/relocation/phase, expiry and fencing.

Scoped contract syntax and discovery passed. Lilly compile, formatting, 182
rootless cases (28 properties, 154 tests) and forced Dialyzer passed. Full Lilly
and Marshall precommit attempts stopped at repository contract coverage: newly
added untracked Antithesis skill assets lack local/subtree contracts. Those
unrelated files were preserved. Marshall's separate format check also reports
its existing enrollment_test.exs; it was not reformatted by this increment.
Marshall consumer checks subsequently passed: 288 cases (26 properties, 262
tests), including distributed tests, six browser tests and forced Dialyzer
with its existing one suppressed upstream warning. ADR structure/link validation
passed for 41 decisions. Logs: /tmp/kittens-export-request-lilly-components.log
and /tmp/kittens-export-request-marshall-tests.log. Neither component-check
result overrides the failed full precommit attempts.

Outstanding: installed SSH service and trustworthy authenticated-key delivery,
serialized exporter launch, native expiry/revocation and reap confirmation,
authenticated control distribution, Oban coordination/handoff/cancellation,
temporary allocation credit and end-to-end relocation acceptance. The new
boundary alone proves none of those capabilities.

### Native export supervision and authenticated-key fixture recovery

ADR-0037 remains accepted/partial. The source exporter increment is now present
in commit `a38e7e2`, including the key index, isolated
[export supervisor](../../../lilly/lib/lilly/transfer/source_export.ex),
[BEAM wrapper](../../../lilly/lib/lilly/transfer/exporter.ex) and
[native sender](../../../lilly/native/source-export/src/lib.rs). Registration holds the pool
and permit mutation locks until the sender owns its stable transfer lock.
Supervision then drops those locks, enforces unchanged-descriptor authority and
bounds renewal with a monotonic deadline. Revocation persists a permanent fence
before confirming that the same transfer lock can be acquired. Uncertain results
must retain snapshots, capacity commitments and transfer slots.

The earlier native test attempt successfully received baseline and incremental
streams with matching snapshot GUIDs, but failed to launch the backpressured
sender from a transient systemd service because that service had no exporter in
its PATH. The fixture now uses the installed absolute executable and writes real
changed ext4 blocks before the final snapshot, ensuring that the delta exceeds
the FIFO's capacity. The corrected run received baseline and incremental streams
with matching GUIDs, observed a blocked native ZFS sender, completed an independent
pool observation during streaming, and revoked through the production API. After
revocation succeeded the observed sender PID was absent and another export failed
without emitting bytes. Full-transfer and cleanup scenarios also passed; the
entire suite finished in 628.12 seconds with runner exit zero. Its output is
`/nix/store/w66j0817ayya25z970kbs8ss5v6b6qx4-vm-test-run-kittens-source-export`.
The corrected immutable derivation is
`/nix/store/r3z99hmll338ixzbkvil7fmxkmkxj0hk-vm-test-run-kittens-source-export.drv`;
its log is `/tmp/kittens-source-export-native-final.log`.

The [OpenSSH fixture](../../../nix/verification/tests/machines/ssh-transfer/default.nix) now
uses production permit lookup for AuthorizedKeysCommand and verifies that the
forced command receives the authenticated public key. Initial execution exposed
two fixture configuration errors: list merging appended ordinary key paths to
OpenSSH's exclusive `none` value, and the shared test store was not an acceptable
trusted ancestor for the authorization executable. The fixture now forces the
key-file list to `none` and copies the executable to a root-owned regular file
under `/etc`, preserving strict permission checks. It still uses a synthetic byte
producer and does not establish an installed production export service. The
corrected derivation is
`/nix/store/qnm5nw689xf6gpqc5l9y3x6bi68hfi08-vm-test-run-kittens-ssh-transfer.drv`;
its log is `/tmp/kittens-ssh-permit-machine-final.log`. It passed in 46.83 seconds
with runner exit zero and output
`/nix/store/pgrvgb0lbb35p75ch2dp0cjqjwzi8ghq-vm-test-run-kittens-ssh-transfer`.
The source-built client received the expected 32 MiB/hash, the forced command
received the authenticated public-key blob, and wrong host pins, ungranted client
keys, fenced permits and retired destination keys were refused. This confirms
new-session permit authorization; active native ZFS stream revocation is a
separate scenario.

The current focused exporter/permit suite passed 23 cases (one property and 22
tests), including native expiry while BEAM supervision stalls, caller death,
revocation, key-index corruption and permanent key retirement. The ADR checker
passed 44 decisions. Log: `/tmp/kittens-exporter-focused-current.log`. The full
Lilly precommit attempt still stops at missing contract coverage for Antithesis
skill assets; this result does not establish a green project gate. Log:
`/tmp/kittens-exporter-precommit-current.log`.

The next integration milestone remains a complete stopped relocation through
Marshall and two Lilly nodes: installed restricted source export, authenticated
key/permit and transfer commands, durable phase/outcome coordination, confirmed
source fencing, atomic placement/epoch handoff and cleanup. Temporary capacity
credit, cancellation and all-copy deletion, running-guest pre-copy, user progress,
distributed races and failure recovery remain required by the accepted plan.
Neither these primitive tests nor this documentation update completes that plan.

The revocation fixture was then tightened to match the actual absolute `zfs send`
command, rather than any process named `zfs`, and to verify that the same sender
PID remains alive after concurrent pool observation immediately before revoking.
This excludes inspection commands or an already exited process from the proof.
The revised derivation is
`/nix/store/zjk1fvlmzx4c1f4qrqzxdxb9nigvj6h8-vm-test-run-kittens-source-export.drv`,
with log `/tmp/kittens-source-export-sender-identity.log`. It passed in 532.19
seconds with runner exit zero and output
`/nix/store/x7ik5jm8524869r9qg0zbzxcjhpm24qq-vm-test-run-kittens-source-export`.
This includes the stronger sender-identity and continued-liveness checks.

### Installed restricted source endpoint

Architecture impact: implements ADR-0037's accepted restricted source service
within Lilly's privileged host boundary; no new domain, protocol version,
persistence authority or decision supersession. The [module](../../../nix/domains/system/transfer.nix)
adds a dedicated SSH listener and a private socket-activated export worker. The
transfer account is excluded from ordinary SSH. Its only accepted key source is
the production permit lookup, with a forced command carrying the selected public
key. Passwords, shells, user rc/environment, forwarding and PTYs are unavailable
through this listener. The account's ability to reach the private socket is part
of the trusted SSH authentication boundary; unrelated local users must not gain
that UID or group.

The non-setuid [native channel](../../../lilly/native/export-channel/src/lib.rs) verifies
SO_PEERCRED against that dedicated account, accepts one bounded frame and one
writable output descriptor, and starts only the configured worker. The descriptor
is the authenticated SSH output pipe; disk bytes bypass both the bridge and BEAM.
A separate local connection carries completion status. Disconnect cancels the
worker, and status follows child reaping. Data EOF alone cannot report success.
The [endpoint](../../../lilly/lib/lilly/transfer/endpoint.ex) validates a private,
closed local configuration without reading Marshall credentials or constructing
missing journal state. Export selects the pool from current permit identity,
rechecks its native binding and invokes serialized SourceExport supervision.

The service preserves enrolled host keys and durable journals, supplies the
OpenSSH privilege-separation account independently of the ordinary listener,
and uses the host-selected ZFS userspace. Its resource slice is separate from
independently supervised guest units. Resource exhaustion may fail an export;
it does not authorize releasing reservations or deleting source snapshots.
Lilly's module generates an optional private export configuration from its own
bound pools. Coordinator issuance/renewal/revocation is still not connected to
this service; enabling an empty endpoint does not enable workload relocation.

The source-built local channel passed six rootless scenarios: exact byte/key
transport, successful bytes followed by worker failure, missing completion,
bridge death with descendant reaping, wrong peer UID, and malformed frames or
file descriptors. The project suite passed 205 cases (28 properties, 177 tests),
including one case invoking those six native scenarios, plus formatting,
compilation and forced Dialyzer with zero errors. Log:
`/tmp/kittens-endpoint-lilly-components.log`. Python is now supplied by the pinned
development shell for that fixture. The initial full Lilly precommit stopped at
the pre-existing missing Antithesis skill contract coverage; log:
`/tmp/kittens-endpoint-precommit.log`. The existing Nix module-configuration check
passed at `/nix/store/azf12nl4nd54j1azs6adk1p7j6hhpxf4-kittens-module-configuration-check.json`.

The new [endpoint machine check](../../../nix/verification/tests/machines/export-endpoint/default.nix)
uses distinct source/destination NixOS nodes, the installed service and actual ZFS
send/receive. It also attempts a malicious command with an accepted key and stops
the listener during a blocked sender, requiring source quiescence before cleanup.
It deliberately supplies synthetic enrollment and public-key distribution; it
cannot establish Marshall coordination, destination adoption or guest relocation.
The first run reached configured listener startup and failed because the module
had not supplied OpenSSH's privilege-separation user. That is now corrected.
The initial attempt was derivation
`/nix/store/y93q2c80vj4br6j6vnyb8sxnh44csris-vm-test-run-kittens-export-endpoint.drv`,
log `/tmp/kittens-installed-export-endpoint.log`; it is not a passing machine result.

The corrected installed-service run passed in 270.19 seconds with runner exit
zero: derivation
`/nix/store/344ph987wqmjrc9lf7vxdfd1s3b24cbk-vm-test-run-kittens-export-endpoint.drv`,
output `/nix/store/vgpw6k677zw14i24qjxvs9isl23dg584-vm-test-run-kittens-export-endpoint`,
log `/tmp/kittens-installed-export-endpoint-final.log`. The destination received
an actual baseline with the source snapshot GUID; an accepted key could not
execute an arbitrary command. Stopping the listener during a live `zfs send`
allowed the production revocation API to confirm quiescence, and the observed
sender PID was absent. The interrupted client returned failure. After restarting
the listener, its fenced key produced no bytes. Source cleanup/deletion succeeded
while the destination retained its received snapshot. This proves the installed
source path across two nested machines, not the missing coordinator, destination
adoption or guest activation.

### Skill coverage repair for required gates

ADR-0028 impact: added a [subtree contract](../../../.agents/skills/CONTRACTS) for
installed development/test assets. Production applications do not import these
assets, and the existing [release allowlist](../../../nix/domains/artifacts/applications/source.nix)
excludes the subtree. The contract records that separation and prevents treating
skill installation/execution alone as repository acceptance. No skill asset,
scanner exemption, validator rule or accepted design was changed. This is a
scope review, not an audit of external browser/mutation/debugging tool behavior.
The unchanged structural checker now covers all 663 maintained source files and
passes 71 contract files, 495 native notes and 13 parsed source documents at that
checkpoint. Full Lilly precommit subsequently passed all 205 cases and forced
Dialyzer with zero errors (`/tmp/kittens-endpoint-lilly-precommit-final.log`).
Protocol precommit passed all 45 cases and forced Dialyzer with zero errors
(`/tmp/kittens-endpoint-protocol-precommit-final.log`). Earlier failed precommit
attempts remain historical failures rather than being relabeled as successes.

The first full Marshall rerun passed browser tests and forced Dialyzer but failed
the log-redaction test's default 100 ms wait for a monitored synthetic crash
(`/tmp/kittens-endpoint-marshall-precommit-final.log`). Its wait now uses the same
one-second bound as Lilly's equivalent crash-report test; the exact crash and
privacy assertions are unchanged. This scheduling tolerance has no architecture
impact. The corrected full Marshall gate passed with exit zero: 296 cases
(26 properties, 270 tests), six browser tests, the 19 contract-validator
regressions and forced Dialyzer (one existing ignored diagnostic, no unignored
errors). Log: `/tmp/kittens-endpoint-marshall-precommit-retry.log`. The shared
worktree included concurrent enrollment changes in this rerun. Final ADR
structure/local-link validation passed all 45 decisions and `git diff --check`
passed. These gates and the installed endpoint result do not close the remaining
Marshall coordinator, destination activation, UI or full guest-relocation gaps.

### Authenticated destination key preparation

Architecture impact: connects ADR-0037's first relocation coordination phase to
the existing PostgreSQL/Ash, Oban and authenticated v3 control boundaries. The
relocation's durable row now retains the enrolled source endpoint at reservation
time, a destination public-key result, and a transactional Oban notification.
The job only wakes polling; it never claims key generation or advances execution.
The bounded `relocation_keys` API authenticates the current destination session
under its host lock, serializes results with the VM lock, accepts identical
retries, requires the exact destination placement and execution epoch in both
commands and results, and rolls back conflicting or foreign results. It grants no source
permit and releases no commitments.

Lilly's optional worker runs one key exchange/effect task at a time alongside
inventory and execution. An operator-selected private transfer root is disjoint
from control, execution, network and pool paths. Key generation and permanent
source-pin binding precede public results; private paths stay local. Restart or
lost replies reuse the existing durable key. Runtime fencing stops the worker;
retired keys cannot be regenerated. The Nix Lilly module supplies the shared
transfer directory when its transfer service is enabled.

The new migration only adds relocation fields and preserves historical schema
files. Tests cover closed schemas, bounds, key/pin/host mismatches and retirement.
The HTTPS consumer test runs the actual asynchronous Lilly key worker against
Marshall and shared PostgreSQL, observes committed public-key publication, and
checks retries, conflicting keys, foreign hosts, stale sessions and revoked
credentials, plus mismatched placement/epoch results and atomic rejection of
mixed valid/unknown result batches. Source placement/epoch and both capacity holds remain unchanged.
This is local control/key acceptance, not a physical relocation test. No new user
admission action is exposed yet; source permit distribution, the remaining
durable phases, cancellation/delete integration, activation and UI remain open.
Full gates passed for the increment: protocol 51 cases with zero Dialyzer errors
(`/tmp/kittens-relocation-keys-protocol-final.log`); Lilly 208 cases with zero
Dialyzer errors (`/tmp/kittens-relocation-keys-lilly-final-fence.log`); Marshall
307 cases, six browser tests and forced Dialyzer with no unignored errors
(`/tmp/kittens-relocation-keys-marshall-retry.log`). The Marshall run retains its
one existing ignored diagnostic. Shared-worktree counts include concurrent
account SSH-key work. An earlier Marshall attempt failed three tests in that
separate feature while it was changing; those failures were corrected in that
work before the passing retry, not hidden by exclusions.

Schema consistency (`mix ash.codegen --check`), ADR structure/local links and
`git diff --check` passed. The existing default Nix module-composition evaluation
passed at `/nix/store/azf12nl4nd54j1azs6adk1p7j6hhpxf4-kittens-module-configuration-check.json`.
The configuration unit test accepts a separate transfer root and refuses
overlapping/store/relative roots without creating state during validation. The
new key worker has not yet been exercised inside the installed two-node machine
suite; its native OpenSSH generation and real HTTPS/PostgreSQL control evidence
come from the application integration test. No disk or guest-movement acceptance
is inferred from these results.


### Authenticated source snapshot and permit requests

Architecture impact: connects ADR-0037 source snapshot creation and expiring
export authority to authenticated Marshall control. The immutable source request
resource retains request identity, source generation, revision, expiry and exact
workload/placement intent. Baseline production requires the current running
source, published destination key, both occupied slots and held reservations.
Renewals use a new revision and pin an already observed snapshot GUID. Results
are historical facts; they do not establish destination receive, current lease
validity or permission to release any commitment. Conflicting result batches
roll back atomically. Existing migrations remain intact; the new migration only
creates the source-request table and its constraints/indexes in its up direction.

Lilly's separate source worker matches its retained execution command, driver
intent and native ownership before snapshot/permit effects. Final-stream effects
require stopped native execution and confirmed jail/network cleanup. Stream
quiescence locking precedes the short pool lock; native utilities therefore
remain owned by the pool helper. A first full transfer now initializes an
unissued export journal before acquiring the stream lock. This grants no access,
preserves active grants and refuses revoked/corrupt records without repair.
The journal regression verifies these boundaries, including missing retained
state. Marshall currently emits baseline requests only; full/incremental support
at the Lilly boundary does not establish the missing stop/final coordinator.

Focused HTTPS/PostgreSQL source/key exchange tests passed 14 cases
(`/tmp/kittens-source-requests-https-final.log`). Protocol precommit passed 61
cases and forced Dialyzer with zero errors
(`/tmp/kittens-source-protocol-precommit.log`). After the initial-full-transfer
fix, Lilly precommit passed 209 cases and forced Dialyzer with zero errors
(`/tmp/kittens-source-lilly-precommit-prepared.log`). Marshall precommit passed
330 cases and forced Dialyzer with one existing ignored diagnostic and no
unignored errors (`/tmp/kittens-source-marshall-precommit.log`). Counts include
concurrent work in the shared worktree. Schema generation consistency passed
(`/tmp/kittens-source-schema-check.log`).

The extended real-guest fixture exercises the actual source effect against native
ZFS and Firecracker, using synthetic control requests and a local destination
key. Its first run failed at missing private fixture-parent creation with
`:unsafe_state_directory`; the parent setup was corrected without weakening
production directory validation. That failed derivation was
`/nix/store/69xhf2minqgfsvaq60c4dh19a1mh6y6g-vm-test-run-kittens-zfs-guest.drv`,
log `/tmp/kittens-source-request-guest-run.log`. Replacement machine runs remain
pending at this checkpoint and do not establish native acceptance. The full
Marshall coordinator, destination receive/activation, cancellation/delete,
progress UI and two-Lilly complete guest-relocation acceptance remain open.


### Source requests for originally stopped workloads

The source exchange now also emits full-snapshot requests for a relocation
reserved while the workload was stopped, provided stopped intent/observation,
source placement/epoch, both disk commitments and both transfer slots still
match. It neither acquires compute nor requires pre-copy temporary headroom.
Running workloads selected for stopped fallback still require the missing
coordinator to stop/fence them; this branch does not infer that transition.
The database tests use the ordinary lifecycle action and a synthetic physical
stop outcome before reservation, then check full-request retries, result
correlation, unchanged placement/stopped state and retained disk-only holds.
A separate test removes destination commitment before polling and checks that no
request is created. This is control/database evidence, not physical stop proof.

The native fixture-parent correction has now allowed actual baseline creation,
lease renewal, stopped incremental creation and source cleanup to pass in
`/tmp/kittens-source-request-guest-fixed.log`. That build predates the initial
full-transfer journal preparation fix; its remaining machine steps are still
running. The newer derivation containing that fix is
`/nix/store/gzp5glik3nwkhf494labb1r6psrm7zs5-vm-test-run-kittens-zfs-guest.drv`,
log `/tmp/kittens-source-request-guest-prepared.log`; baseline creation and
renewal have passed there, with later cases still pending. Neither partial
sequence establishes a passing full machine suite or two-host guest relocation.


The already-stopped source-request increment passed Marshall precommit with
337 cases (32 properties, 305 tests), browser checks and forced Dialyzer with
one existing ignored diagnostic and no unignored errors; runner exit zero.
Log: `/tmp/kittens-source-stopped-precommit.log`. The test count includes ongoing
SSH work in the shared worktree. ADR structure/local links and contract syntax/
coverage passed, and `git diff --check` passed. No schema changed in this increment.
The newer native build also passed stopped incremental creation and source
cleanup; its remaining guest lifecycle/full-transfer cases are still pending.


### Destination receive command boundary

ADR-0037 impact: moved destination receive argv construction into
`Lilly.Transfer.ReceivedDataset.receiver/2`. Under the pool lock it requires an
existing active receiving journal for the exact descriptor, rechecks native
staging through the existing preparation boundary, and derives the target,
canonical mountpoint and local ownership nonce from trusted pool/journal state.
It sets unmounted resumable receive, read-only/noauto policy, disabled
exec/setuid/devices and the expected storage properties explicitly. No caller
path, command string or source ownership nonce is accepted. Received/retired
journals and missing intent cannot produce a command. The caller must still
hold current coordination authority and exclude concurrent streams; this helper
neither streams nor grants adoption/activation.

The existing missing-intent unit regression now includes the receiver boundary.
The real-ZFS receive fixture uses this production builder for its ordinary full,
pre-copy and interrupted-receive cases; separate adoption fixtures retain their
existing setup. Native verification is running as derivation
`/nix/store/3rmn4z7krpp8i1z3d8fb0hg25nzgn4ad-vm-test-run-kittens-zfs-transfer.drv`,
log `/tmp/kittens-destination-receiver-native.log`. No passing machine result is
claimed at this checkpoint. Destination actor/control coordination and the full
relocation acceptance remain incomplete.


The receiver application gate passed 209 cases and forced Dialyzer with zero
errors (`/tmp/kittens-destination-receiver-precommit.log`). The first native run
passed the initial production receive and receipt checks, then refused the
fixture's intentional recreation of a previously received/deleted filesystem.
That refusal is required behavior. The fixture now first asserts production
receiver refusal and then uses an explicit test-only replacement injection to
continue checking native GUID mismatch. The corrected run is derivation
`/nix/store/26i8q89r2j27ih9c8iwyph3ihd92bnlj-vm-test-run-kittens-zfs-transfer.drv`,
log `/tmp/kittens-destination-receiver-fixed.log`; acceptance remains pending.

### Native lifecycle result regression

The source guest run at
`/nix/store/lrixcxk5s7kwpqvm394d2gqg8ks4ri5a-vm-test-run-kittens-zfs-guest.drv`
failed at `reject-start` after confirmed physical deletion. Investigation found
that widening the driver's lock wrapper to accept transfer callback values also
allowed an ordinary lifecycle `with` guard's intermediate `{:ok, File.Stat}`
result to escape when a deletion tombstone existed. No guest restarted, but the
lifecycle result contract was violated. Ordinary lifecycle callbacks now retain
explicit `:ok`/error normalization; only the separately guarded transfer entry
point uses the value-returning wrapper. The deleted-placement fence is unchanged.
Lilly precommit passed again with zero Dialyzer errors
(`/tmp/kittens-driver-result-precommit.log`). The corrected guest derivation is
`/nix/store/j6jg8n69z2z3y5qr8g9nsjlz7k82r8xm-vm-test-run-kittens-zfs-guest.drv`,
log `/tmp/kittens-source-guest-result-fixed.log`; it is running and does not yet
establish a passing full guest suite. These failures are retained as failures,
not relabeled as successful acceptance.


### Destination receive pipeline

ADR-0037 impact: `Lilly.Transfer.Receiver.pull/5` now joins destination-local
preparation, the production receiver argv builder, pinned per-relocation SSH and
native staging receipt. It requires authenticated current coordination authority
from its caller. The existing private key binds the source endpoint before any
receive. A dedicated relocation activity lock spans the attempt; short stream
then pool locks serialize preparation and verification. A linked child runs the
native pipeline without inheriting a pool helper, allowing ordinary pool
observation during transfer. Caller death tears down that child; errors retain
all state and commitments. Final verification requires reacquiring the same
stream lock, native GUID/nonce/snapshot checks and durable receipt. Duplicate
received attempts reverify staging without a second stream. This entry point
returns the local dataset GUID only, with no execution claim or activation.
Cleanup/adoption callers must serialize with the same activity/stream locks and
confirm stopped transfer work; those coordinator paths remain incomplete.

The installed two-node export-endpoint fixture now calls this production
pipeline twice, verifies identical receipt and absence of an ordinary execution
claim, and checks the destination snapshot GUID after source cleanup. It renews
the synthetic source permit before its separate live-sender cancellation case.
The source still uses actual restricted installed SSH/export services and both
nodes use native ZFS. This is disk staging acceptance, not a bootable guest move
or authenticated Marshall receive distribution. Its running derivation is
`/nix/store/69x4nhzv2lxb7fgka7m74iy822lapjj3-vm-test-run-kittens-export-endpoint.drv`,
log `/tmp/kittens-receiver-pipeline-native.log`; machine acceptance remains pending.


Pipeline Lilly precommit passed 209 cases and forced Dialyzer with zero errors,
runner exit zero (`/tmp/kittens-receiver-pipeline-precommit.log`). ADR structure/
local links, contract syntax/coverage and `git diff --check` passed. The corrected
single-node native receiver suite has passed its receive cases and is continuing
through adoption/cleanup. The two-node pipeline test and corrected guest test
are still running; no complete machine result is inferred from partial output.


### Destination native acceptance checkpoints

The corrected single-node ZFS suite passed in 421.98 seconds with runner exit
zero, output `/nix/store/xj509dcw0l7dknk51ayv9w4knip0k4rj-vm-test-run-kittens-zfs-transfer`
(`/tmp/kittens-destination-receiver-fixed.log`). It exercised production receiver
arguments, full/incremental staging, interrupted receive, local ownership checks,
replacement refusal and the existing adoption/cleanup fault scenarios. The
explicit replacement injection is confined to the adversarial fixture after
production refusal is asserted.

The installed two-node SSH pipeline suite passed in 233.41 seconds with runner
exit zero, output `/nix/store/3imx3ypl6sfdlj7zzc881f32pmyj22yh-vm-test-run-kittens-export-endpoint`
(`/tmp/kittens-receiver-pipeline-native.log`). Production Receiver.pull prepared
local import intent, received the source's baseline through the installed
restricted endpoint, verified native receipt and returned the same local GUID on
retry without an ordinary execution claim. Arbitrary SSH command selection was
refused; listener shutdown/revocation reaped the observed native sender. The
source was reclaimed while the destination retained its matching snapshot. This
proves disk staging across nested machines, not Marshall-driven guest activation.

### Authenticated destination receive control

ADR-0037 impact: the new closed receive codec and real Lilly client exchange bind
source-confirmed descriptors, source pins, request IDs and lease expiry. Marshall
retains destination-local dataset GUID receipts on immutable source requests;
source descriptor publication atomically enqueues destination notification.
Current destination sessions lock their host before VM rows. Command delivery
requires a live source permit, unchanged source placement/epoch/generation,
current workload shape/address, disk commitments, applicable compute/headroom
and both transfer slots. No source result means no receive command. Initially
stopped full transfers require disk holds without compute or pre-copy headroom.

Receipts must match retained immutable source evidence and destination identity.
One local dataset GUID is retained across all revisions/phases; conflicting
receipts and mixed valid/unknown batches roll back atomically. A delayed receipt
may record historical evidence after permit expiry, but expired work is not
reissued. Receipt neither switches placement nor releases capacity. The migration
only adds the nullable receipt column; historical migrations remain unchanged.
The source/destination session fencing, foreign receipts, GUID/descriptor
conflicts, retries and unchanged capacity/authority are exercised through real
HTTPS/PostgreSQL client tests. Focused checks passed 17 cases plus three protocol
cases before the final full-gate run. No runtime receive actor is connected yet;
stop/finalization, cancellation/delete, handoff, activation and UI remain open.


### Corrected source guest acceptance

The corrected source/driver guest suite passed in 906.26 seconds with runner
exit zero, output `/nix/store/bg16g666xzm893271phhy8dr94sy78fc-vm-test-run-kittens-zfs-guest`
(`/tmp/kittens-source-guest-result-fixed.log`). It verified baseline creation and
renewal while the actual guest ran, rejected wrong authority and final work
before stop, created/cleaned incremental snapshots after stop, restored guest
writes after abrupt simulated host loss, rejected restart after deletion and
preserved a neighboring guest. That neighbor then stopped, received its first
full snapshot/permit through the corrected preparation path, and was cleaned up.
This closes the observed fixture-parent and driver-return regressions in the
nested guest scope. It does not prove a guest moved between physical Lilly hosts.

### Destination receive runtime and remaining coordination

The optional Lilly receive runtime now runs one control exchange alongside one
native receive task. It continues polling during streaming, keeps pending
receipts bounded, correlates an identical stream's result to its latest command,
and retries retained native state after failure. A source permit starts a local
monotonic deadline of at most 300 seconds. Renewal requires an unchanged
descriptor/pin and nondecreasing signed expiry; unchanged expiry cannot gain time
on wall-clock rollback. Expiry or an authenticated session fence kills the receive
task without claiming cleanup or releasing holds. The normal runtime starts/stops
this worker with its owned control session. Deadline property tests cover expiry,
clock changes, signed-growth bounds and changed descriptor/pin rejection.

The actual receive worker now polls the real HTTPS/PostgreSQL endpoint in the
transport test and reports a stale-session fence. That test intentionally has no
native pool and cannot fabricate a receipt; native pipeline evidence remains the
separate two-node machine suite. Stop/final incremental issuance for running
workloads, handoff/activation, cancellation/delete, native resume control, progress
and complete guest-relocation acceptance remain incomplete.

The first supplemental test attempt exhausted PostgreSQL connection capacity
while other suites were active. Retrying with four schedulers then exposed the
concurrent SSH work's temporarily missing `completion_outcome_id` migration;
`ash.codegen --dry-run` showed only its SSH request/operation changes, not drift
in the relocation receipt schema. After that work supplied its migration, the
focused source/receive and HTTPS suite passed all 17 cases, including stopped
full receives, missing pre-copy headroom and the actual worker fence. Schema
consistency then passed (`/tmp/kittens-receive-runtime-https-schema-retry.log`).
Earlier failed attempts remain failures, not exclusions or modified production
connection limits. Latest Lilly precommit passed 211 cases and forced Dialyzer
with zero errors (`/tmp/kittens-receive-runtime-lilly-precommit.log`). Protocol
precommit passed 66 cases and forced Dialyzer with zero errors
(`/tmp/kittens-receive-control-protocol-precommit.log`). Marshall's preceding
full gate passed 343 cases and forced Dialyzer with one existing ignored diagnostic
and no unignored errors; the final runtime-consumer gate is running separately.


The final Marshall consumer gate passed with runner exit zero: 350 cases
(34 properties, 316 tests), browser checks and forced Dialyzer with the one
existing ignored diagnostic and no unignored errors
(`/tmp/kittens-receive-final-marshall-precommit.log`). It used eight local BEAM
schedulers to bound test database connections while retaining the distributed
and browser gates. Counts include concurrent SSH work. The final source/receive
HTTPS check and schema consistency passed together; ADR structure/local links,
contract syntax/coverage and `git diff --check` also passed. This checkpoint has
no remaining running native jobs. Full relocation completion is still unproven:
running-source stop/finalization, atomic handoff/activation, cancellation/delete,
resume orchestration, capacity credit, progress UI and combined guest-move/failure
acceptance remain outstanding.


### Pre-copy source stop and final incremental control

Architecture impact: implements the next accepted ADR-0037 recovery transition;
status remains partial. The coordinator uses sorted endpoint host locks before
VM serialization and requires a received baseline, fresh image-capable hosts,
unchanged source authority, original holds and both slots. Console invalidation,
source stop generation, immutable relocation-initiated operation/outbox, and the
relocation's composite operation reference commit together. The new migration
adds nullable references and provenance constraints without deleting existing
operation or relocation history; its generated constraint replacement was
reviewed. Capacity admission now checks the immutable image as ordinary admission
does.

Final incremental commands require the exact retained physical stop outcome,
including empty compute and present disk, and pin the received baseline GUID.
Source compute/disk and destination commitments remain held throughout final
receipt. The focused database suite passed 22 tests before supplemental negative
assertions were added. The first attempt correctly refused stop because session
opening clears host freshness; the fixture now reports both hosts fresh and
asserts refusal beforehand. Tests cover absent baseline receipt, missing image,
one stop generation across retry, physical outcome gating, unchanged placement
and epoch, A-to-B command/receipt, and retained reservations. Running full-copy
fallback remains waiting for connectivity preflight. Full Marshall precommit and
schema consistency are running; combined native relocation is not established by
these database tests. Native staging/source-stop checkpoints above remain the
separate physical evidence. Later handoff/activation, cancellation/delete,
resume control, progress and full guest/failure acceptance remain unfinished.


The first full gate ended with one failing newly added fixture assertion
(355/356 cases passed); browser checks and forced Dialyzer passed with the existing
single ignored diagnostic. The missing-image test restored the fixture's
pre-report host inventory, which was empty, instead of its actual report. The
fixture now restores `destination.report.inventory`; production readiness checks
were not relaxed. All 22 focused cases then passed again
(`/tmp/kittens-relocation-stop-fixture-tests.log`). A fresh full gate is running
against this correction. ADR validation passed 47 decisions; contract validation
passed 76 directory files, 566 native notes and 761 covered maintained sources.
Counts include concurrent work. Contract discovery for the new coordinator and
`git diff --check` passed as well.


The corrected full Marshall gate and subsequent `mix ash.codegen --check`
finished with exit zero (`/tmp/kittens-relocation-stop-final-precommit.log`):
356 cases (34 properties, 322 tests), distributed tests, browser checks and
forced Dialyzer passed. Dialyzer retained its one existing ignored diagnostic
with zero unignored errors and no unnecessary skips. No protocol or Lilly code
changed in this increment; their preceding green gates and native checkpoints
remain the separately scoped evidence. Final architecture assessment preserves
ADR-0037's accepted stop-before-final-transfer rule and retained capacity; its
implementation status remains partial for the outstanding phases listed above.


### Authenticated final adoption and atomic authority handoff

Architecture impact: implements ADR-0037's accepted import-before-handoff rule;
status remains partial. A separate closed final-import codec/API records request
intent before leased commands and correlates adoption evidence to the retained
source descriptor and destination-local GUID. The native importer excludes
receive activity/streams, locks the ordinary placement and refuses unrelated VM
claims, any launch intent or tombstones before checking unit/jail/network quiescence.
It reuses idempotent disk adoption and exact local image validation. Import mode
of the receive worker polls independently, fences on session errors and refuses
GUID changes during renewal. A final receive suppresses subsequent stream work,
including renewals racing receipt, because adopted snapshots may already be pruned.

The coordinator then atomically switches placement and successor epoch, increments
generation, resets observation sequence/state, records source-import and target
activation references, and creates the activation outbox. Both endpoint host locks
precede the VM lock. Composite database references bind activation authority and
import ownership; complete-reference checks reject partial commit records.
Generated migrations were reviewed: their drops replace provenance constraints,
not records or columns. Source compute and pruned destination temporary headroom
are released at handoff; both disks and source temporary headroom remain held.
Originally stopped workloads receive stop activation, never start. Repeated
coordinator calls cannot create another activation; later source observations
cannot overwrite destination state. No readiness or cleanup follows yet.

Protocol precommit passed 71 cases and forced Dialyzer with zero errors. Lilly
precommit passed 212 cases and forced Dialyzer with zero errors. Import HTTPS and
schema checks passed 11 cases; its worker has no native pool, so the test proves
polling/fencing only. Before handoff edits, Marshall precommit passed 360 cases
(35 properties, 325 tests), browser checks and forced Dialyzer with its one existing
ignored diagnostic and no unignored errors. Handoff-focused tests passed 7 cases
covering running and stopped activation, held disks, duplicate commit and stale
source outcomes. A final combined Marshall gate remains to run.

The first direct path-flake build was refused by an ignored test FIFO. Native
checks now use an isolated snapshot of tracked and nonignored source files,
without changing the shared index. The first native importer run failed before
adoption: the fixture's installed executable path gave the driver an unresolved
extra symlink to its native launch guard. The fixture now prepends the guard's
resolved immutable directory and excludes Lilly veths from DHCP. The corrected
native fault suite is running; its earlier failure remains a failure. No production
guard was weakened, and synthetic boot artifacts cannot establish guest movement.


Activation review found a concrete gap after the first importer implementation:
ordinary Driver.claim intentionally refuses a pre-existing disk without matching
local VM ownership. Disk adoption now publishes that destination-local ownership
only after its callback verifies final adoption. Matching ownership without launch
intent permits crash retries; unrelated claims and any launch intent still refuse
import work. No launch intent is created by adoption. The native fixture now
exercises ordinary stopped activation against the adopted disk, in addition to
repeated adoption and byte-preserving disk reuse. The expanded gate is running.
The preceding corrected native run passed its injected snapshot destruction,
mount and property-change interruption points, confirming the fixture executable
path correction; its full run is still being observed separately.


The corrected initial importer machine suite finished successfully in 445.27
seconds, output `/nix/store/l8qwzbcal3c7q2hf0718rbgwmlmdrmw9-vm-test-run-kittens-zfs-transfer`
(`/tmp/kittens-importer-native-fixed.log`). This predates the new VM ownership
publication and stopped-activation assertion. An intermediate expanded run was
explicitly stopped after review found that its fixture still expected import to
succeed after activation had created launch intent; it was superseded for that
concrete fixture change, not restarted because of a timeout. The final fixture
instead expects post-activation import refusal and verifies ordinary disk reuse.
Latest Lilly precommit passed 212 cases and forced Dialyzer with zero errors
(`/tmp/kittens-import-activation-lilly-precommit.log`). Marshall's handoff gate
passed 360 cases, browser checks, forced Dialyzer (one existing ignored diagnostic,
no unignored errors) and schema consistency (`/tmp/kittens-handoff-final-precommit.log`).

A further test now races nine handoff calls across the existing three independent
Marshall BEAM peers. It uses shared committed PostgreSQL state and verifies one
activation operation/job, one successor epoch and retained disk holds. Its source
and adoption facts are synthetic control-plane fixtures; it cannot establish
native guest movement. Cleanup breaks only its fixture's cyclic evidence links
and is not a production cleanup implementation. The final Marshall gate is running
with this added distributed case while the native stopped-activation suite runs.


Final native importer/activation verification finished with exit zero in 456.33
seconds (`/tmp/kittens-importer-native-final.log`), output
`/nix/store/8k5d5lzhldpywvk97wf9z2n6l2gxs0py-vm-test-run-kittens-zfs-transfer`.
It exercised the production importer through full/incremental pruning and
publication interruptions, local VM ownership without launch intent, ordinary
stopped activation, post-activation import refusal, missing-disk refusal,
byte-preserving reuse, cleanup and neighbor preservation. No native job from
this increment remains running. These synthetic-image storage checks do not
establish running guest activation or a complete Marshall-driven relocation.

The final Marshall precommit passed 361 cases (35 properties, 326 tests), including
the new three-peer handoff race, browser checks and forced Dialyzer with one existing
ignored diagnostic and no unignored errors (`/tmp/kittens-relocation-race-precommit.log`).
The following whole-repository schema check reported three pending files;
`/tmp/kittens-handoff-schema-dry-run.log` identifies only concurrent
`ingress_services` / `ingress_services_versions` schema work, with no relocation
changes. The earlier handoff schema check passed before that work appeared.
Contract checks passed 78 directory files, 586 native notes and 788 covered
maintained sources; ADR structure/local links and final diff whitespace checks
passed. Counts include concurrent work. ADR-0037 remains partial for readiness,
source cleanup, cancellation/delete, running full-copy preflight, resumable control,
progress UI, public admission and complete multi-host guest/failure acceptance.

## Destination readiness integration, 17 September

ADR-0037 remains accepted and partial. This increment adds an Ash-owned readiness
request with an activation/relocation/generation composite foreign key, immutable
descriptor and deadline, and separate ready/failed results. Exact retained
physical activation evidence starts the deadline; an operation acknowledgement
or running VMM cannot establish guest readiness. The timeout defaults to 120
seconds and is configurable through `MARSHALL_RELOCATION_READINESS_TIMEOUT_MS`
(`1..600000`). Coordinator retries retain the original deadline. Originally
stopped workloads require physical stopped evidence and do not launch a probe.

The authenticated destination exchange fences the host session before VM locks,
records offer before accepting a result, rejects conflicting boot UUIDs and
acknowledges expired receipts without reviving authority. Lilly matches its
retained activation command before and after the existing challenge-bound vsock
probe. Lease renewal keeps its activation ID/generation fixed and does not restart
the probe's deadline. The driver returns the verified guest boot UUID while
preserving its existing `ready/4` return contract. Terminal admission requires
this readiness record for the current committed activation. Source disk and
temporary capacity remain charged; no cleanup authority is issued yet.

Database tests passed the running/stopped and expired cases, fixed deadlines,
mismatched and duplicate receipts, retained holds and readiness predicate. The
real HTTPS test exposed a worker integration defect: readiness fencing was sent
as a receive-worker event. The corrected worker now sends the event its control
supervisor handles. All eleven HTTPS tests subsequently passed, including real
client readiness receipts, conflicting boot IDs and session rotation. These
tests use synthetic guest evidence and cannot establish native guest readiness.

The native guest fixture adds a separate epoch-two guest, retained local start
command and production readiness probe, with wrong activation/generation,
expired lease and stopped-authority refusal. Its descriptor is synthetic and
does not represent a transferred disk. The first build was refused before
execution because the daemon did not advertise `nested-kvm`; the builder has
nested KVM enabled. A local-store build with the required feature is now running
against the same immutable source snapshot. Protocol precommit passed 72 cases
and forced Dialyzer. Full consumer gates, public terminal assertions and the
native fixture are being verified; no native success is claimed yet.

The next coordinator transition must revoke/fence source export, confirm stopped
source authority and physically remove the owned source copy before releasing
its disk and temporary holds. A cleanup request/receipt must retain the exact
source placement and epoch despite the VM now pointing to the destination.
Timeout, changed activation or missing cleanup evidence must retain capacity.
This transition, cancellation/delete, running full-copy preflight, public
admission/UI and complete two-Lilly guest/failure acceptance remain outstanding.

The corrected consumer gates finished successfully
(`/tmp/kittens-readiness-fixed-precommit.log`): Lilly passed 213 cases and forced
Dialyzer with zero diagnostics; Marshall passed 382 cases, browser checks and
forced Dialyzer with its one existing ignored diagnostic and no unignored errors.
The subsequent `mix ash.codegen --check` passed. Counts include concurrent
repository work. Protocol's 72-case gate passed in
`/tmp/kittens-readiness-precommit.log`; that earlier combined run's Marshall part
failed the now-corrected worker-fencing test and could not scan a concurrently
rebuilt router BEAM during Dialyzer, so it is not the successful consumer evidence.
The eight focused relocation tests also passed public terminal denial before
readiness and after timeout, and successful admission after the boot receipt
(`/tmp/kittens-readiness-terminal.log`). ADR, contract and diff whitespace checks
passed (`/tmp/kittens-readiness-structure.log`). The native guest run remains in
progress in `/tmp/kittens-readiness-native-local-enabled.log`.

The native guest suite subsequently finished with exit zero in 935.15 seconds,
output `/nix/store/082x0hdxlg1mpzspisyfkfba3hg4dsfz-vm-test-run-kittens-zfs-guest`.
Its new readiness case took 83.69 seconds including final absence verification:
the production probe returned a verified boot UUID from a real epoch-two guest,
rejected mismatched operation/generation and expired lease requests, refused
readiness after physical stop, then deleted the guest with no remaining pool
allocations. Existing confinement, snapshot/permit, crash-recovery, retained-data
and neighbor-preservation cases also passed. The immutable machine snapshot
predates the worker-event correction; it exercises the unchanged driver/probe,
while the subsequent HTTPS and consumer gates verify that correction. No native
job from this increment remains running. This joins native probe evidence to
separate control-plane readiness tests; it still does not establish a complete
Marshall-driven two-Lilly guest relocation or source cleanup.

## Source retirement integration, 17 September

Architecture impact: implements ADR-0037's post-readiness source removal using
the existing host-before-VM ledger, immutable physical outcomes and ordinary
execution retirement. ADR-0037 remains partial; no accepted rationale changes.
The new Ash cleanup request retains source descriptor/generation, offer and
completion. Readiness authorizes creation once; subsequent destination failure
does not undo an already issued destructive obligation. Missing receipts,
expired leases and unknown outcomes retain source commitments.

Lilly's cleanup worker verifies the stopped source command, revokes and reaps
exports before acquiring execution locks, then matches the local snapshot index
and native dataset GUID. The driver persists a successor deletion fence before
snapshot/disk effects. Snapshot retirement and ordinary disk deletion preserve
ownership outside the portable data. A new read-only history accessor recognizes
either the active claim or its retained deletion tombstone without initializing
missing ownership. This supports retries after physical deletion and metadata
rename. Lease renewal keeps relocation, descriptor and source generation fixed.

Integration review found that deleting the disk through the transfer worker
alone would leave the old source actor reconciling its stopped command. The
cleanup receipt therefore queues a normal source delete operation, narrowly
authorized for that superseded placement. Its native deletion is idempotent;
the ordinary actor retains/replays the physical outcome and retires after its
acknowledgement. Only that exact retained deleted outcome permits the coordinator
to release source disk/temporary capacity, release both stream slots and finish
the relocation. Destination state, commitments, ownership, sharing and address
remain intact. Ordinary stale operations still cannot be delivered or alter
current VM state.

Eight focused database tests passed running/stopped cleanup, missing/foreign/
mismatched/duplicate receipts, unknown source outcomes, deferred release and
unchanged destination authority (`/tmp/kittens-cleanup-retirement-focused.log`).
Eleven HTTPS tests passed real client cleanup delivery, source delete/outcome
exchange and cleanup-worker fencing (`/tmp/kittens-cleanup-https.log`). These
fixtures use synthetic physical evidence, so neither establishes native deletion.
The existing three-Marshall race now also covers duplicate cleanup receipts,
one source delete operation and convergent finish; its full gate is running.

The native guest fixture exercises production source cleanup after a real stopped
full snapshot, rejection of wrong generation/GUID and expired lease, interruption
after deletion intent, and repeat cleanup after metadata retirement. Review found
its first version called revocation while holding the fixture's control-store
lock, violating the callee's no-held-lock precondition. That exact live build was
explicitly canceled with SIGINT (terminal exit one, `/tmp/kittens-cleanup-native.log`).
The corrected fixture runs the effect in a separate worker while its parent owns
the store, matching production. Its replacement is running in
`/tmp/kittens-cleanup-fixed-native.log`; no production lock precondition was relaxed
and no native success is claimed yet. This test still uses synthetic Marshall
commands and does not move a guest between two Lilly hosts.

The first consumer gate encountered a concurrent ingress syntax edit; a later
attempt rejected an unformatted boundary-test addition. Both remain failed runs.
The corrected three-project gate is running in
`/tmp/kittens-cleanup-final-formatted-precommit.log`. Remaining work includes
cancellation/logical Delete across all copies, destination key retirement,
running full-copy preflight, resumable control/progress, public admission/UI and
complete multi-host guest/failure acceptance.

Final source-retirement verification passed. The corrected native guest suite
finished with exit zero in 933.98 seconds, output
`/nix/store/aj5l4nvcpv4r6f16bph48a62lxamms3n-vm-test-run-kittens-zfs-guest`
(`/tmp/kittens-cleanup-fixed-native.log`). The new full-source retirement case
passed in 13.90 seconds: wrong generation/GUID and expired lease were rejected,
interruption after deletion intent retained bytes, production cleanup removed
the owned disk, a repeat succeeded through relocated metadata history, and a
subsequent start was refused. Ordinary delete retry and empty pool allocation
verification also passed. Existing crash recovery, retained data, neighbor
preservation and real-guest readiness checks passed. No native job from this
increment remains running. This proves local full-source cleanup, not a complete
Marshall-driven incremental guest move between two Lilly hosts.

All three application gates passed in
`/tmp/kittens-cleanup-final-formatted-precommit.log`: protocol 73 cases, Lilly 213
cases, Marshall 402 cases (including the three-peer cleanup race), browser checks
and Dialyzer. Both consumer gates forced analysis; Marshall retained its one
existing ignored diagnostic with no unignored errors. Counts include concurrent
work. Schema consistency passed. A final query filter excludes finished
relocation history from source command polling; all 19 focused database/HTTPS
cases subsequently passed against it, followed by schema, ADR, contract and
whitespace checks (`/tmp/kittens-cleanup-final-checks.log`). Remaining scope is
unchanged: cancellation/logical Delete, destination key retirement, full-copy
preflight, resumable control/progress, public admission/UI and complete multi-host
guest/failure acceptance. ADR-0037 remains partial.


## Destination credential retirement completion gate

The next ADR-0037 increment retains an unfinished relocation and its source
storage/stream commitments after confirmed source deletion until destination key
retirement is acknowledged. CleanupRequest persists request, offer and retirement
timestamps with an offer-before-receipt database constraint. Authenticated control
binds the destination host, placement and epoch; receipts only record evidence and
enqueue reconciliation. Both-host/VM locking remains in the coordinator that
releases commitments. No new architectural decision or compatibility path is added.

Lilly excludes receive/adoption and native streaming locks before calling the
existing durable key retirement primitive. Its receipt carries no key material.
Actual local key tests passed erasure, contention, invalid identity/lease/path,
duplicate retry and permanent refusal to regenerate. Nineteen focused database
and HTTPS tests passed before the HTTPS fixture was further strengthened to call
production local key retirement (`/tmp/kittens-key-retirement-focused.log`).
These tests do not establish a complete guest move or physical source deletion.

The three-Marshall race now includes duplicate destination retirement receipts and
convergent completion after that gate. All three precommit suites, including this
race and the strengthened HTTPS fixture, are running in
`/tmp/kittens-key-retirement-precommit.log`; no full-gate success is claimed yet.
Cancellation/logical Delete, running full-transfer connectivity preflight,
resumable control/progress, public admission/UI and full two-Lilly guest/failure
acceptance remain unfinished. ADR-0037 remains partial.


Follow-up scope check against the recovered September 16 plan: ordinary destination
lifecycle requests are still rejected by RelocationGuard.vm_busy?/1 while any
relocation cleanup remains unfinished. The plan permits those actions after
successful activation while excluding another relocation until old copies are
removed. Reconcile this distinction when implementing cancellation/logical Delete;
do not simply bypass the guard before readiness or weaken obsolete-source fences.
The original plan also calls for transfer-slot release independently of delayed
cleanup after confirmed stream exit; current completion releases slots together
with final cleanup. This conservative capacity restriction remains a scope gap,
not proof that the original completion criteria are fully satisfied.

The first full gate failed in a concurrently added ingress fixture because its
private binding/0 helper conflicted with Kernel.binding/0. Renaming that helper to
connector_binding/0 preserves test semantics and has no architecture impact. The
replacement gate is `/tmp/kittens-key-retirement-precommit-fixed.log`. Protocol and
Lilly gates have passed; Marshall is still running. Contract review corrected
copied client comments to describe destination-bound key exchanges. No runtime
behavior changed in that correction.


The replacement gate passed protocol (78 cases), Lilly (222 cases), all 407
Marshall cases including three-peer retirement races, and browser checks. Marshall
Dialyzer then failed on a concurrently introduced SSH default-shape call: a generic
Ash resource struct did not satisfy the helper's two-field map specification;
its two apparent unused-helper reports followed that unreachable call. The SSH
caller now constructs the required minimum-size map explicitly, preserving its
runtime defaults and admission behavior. This is a type-boundary correction with
no architecture impact. Targeted SSH/image tests, forced analysis, schema and
structural checks are running in `/tmp/kittens-key-retirement-final-checks.log`.
The prior full gate remains a failed run, not an all-green result.


Final key-retirement verification completed with exit zero in
`/tmp/kittens-key-retirement-final-checks.log`: all 22 targeted SSH/image cases,
forced Marshall Dialyzer (one existing ignored diagnostic, no unignored errors),
schema consistency, ADR structure/local links, contract structure and whitespace.
Together with the preceding protocol/Lilly gates, 407 Marshall cases and browser
checks, this verifies the increment without claiming the earlier failed full gate
passed. Tests include actual local SSH credential erasure and transfer-lock
exclusion, authenticated HTTPS receipt delivery, and duplicate retirement races
across three Marshall nodes. No native guest suite was rerun for this key-only
increment; it does not prove complete two-Lilly guest relocation. No verification
process from this increment remains running. The full objective remains active.


## Precommit cancellation request and handoff exclusion

This ADR-0037 increment adds the public Ash `cancel_relocation` intent action.
Sorted endpoint host locks followed by the VM lock serialize it with handoff;
current Cedar manage authorization is evaluated after locking, including retries.
The first requesting user/time and the coordinator outbox are durable. A database
constraint rejects simultaneous cancellation and committed handoff. The generated
migration adds only nullable cancellation metadata, its user FK and that check;
its reported destructive operations are in rollback, not the forward migration.

Key preparation, source permit creation/renewal, destination receive and import
polling exclude cancelled transfers. Matching late source/receive/import receipts
remain retained facts and cannot revive the handoff. The coordinator returns
`cancelling` before stop or commit work and keeps source/destination reservations,
transfer slots, receipts and the VM's existing authority. No native revocation,
source restart or physical reclamation is inferred from this intent. Native
cancellation effects and restoration remain required next work; this is not a
completed cancellation feature and is not exposed in the UI yet.

Fourteen focused database cases passed before final manager/revocation and race
coverage was added (`/tmp/kittens-cancellation-focused.log`). They cover running
baseline cancellation and initially stopped full-transfer cancellation before copy,
after source offer, during receive, after import offer and after import receipt,
plus rejection after actual control-plane handoff. Physical facts are synthetic.
The three-Marshall suite now races twelve cancellation/handoff calls against a
fully imported stopped fixture; either committed handoff or cancellation may win,
but no mixed authority is accepted. This suite is currently running.

The first full gate stopped at a missing blank line between native contract
blocks; the separator was corrected without changing contract content. The
replacement gate is `/tmp/kittens-cancellation-precommit-fixed.log`. Full-gate,
three-peer and final permission-test success are not yet claimed. The broader
remaining scope includes native cancellation/restoration, logical Delete of all
copies, lifecycle/stream-slot refinements, running full-transfer preflight,
resumable control/progress, public admission/UI and complete two-Lilly acceptance.


Final cancellation-intent verification passed. Marshall precommit completed with
exit zero in `/tmp/kittens-cancellation-precommit-fixed.log`: 419 cases (including
the three-Marshall cancellation/handoff race), browser checks, forced Dialyzer
with one existing ignored diagnostic and no unignored errors. Schema consistency
also passed. A subsequent focused run covered all sixteen relocation-source
cases including cancellation before key preparation and a late public-key receipt;
formatting, ADR, contract and whitespace checks passed in
`/tmp/kittens-cancellation-final-checks.log`. Permission coverage includes operator
refusal, manager acceptance, revoked-manager retry refusal and owner retry retaining
the original cancellation identity. No verification process remains running.

These are control-plane tests with synthetic storage facts. No native cancellation
suite was run because native cancellation effects have not yet been integrated.
Outstanding permits/receives may retain their previously offered bounded lease;
withdrawn offers do not prove stream cessation. The next required increment must
persist authenticated physical revocation/reclamation receipts and restore the
source with fresh fenced authority, independently of an unreachable destination's
cleanup. Cancellation intent alone neither releases holds nor completes the move.


## Authenticated cancellation source-export revocation

ADR-0037 cancellation now has a closed source revocation command and identity-only
receipt. Marshall offers it only for retained cancellation intent, authenticates
the current source session and records source placement/epoch evidence after an
offer. Duplicate receipts preserve the timestamp and enqueue reconciliation without
changing VM authority or commitments. A database constraint ties offered revocation
to cancellation and completion to an offer. Source restoration and snapshot/destination
cleanup remain separate pending obligations; the coordinator still returns cancelling.

Lilly SourceRuntime now has an independent revocation mode, supervised and fenced
by the root control runtime. The effect validates host identity and a bounded lease,
then uses the existing durable permit fence and sender quiescence primitive. It
returns only after the sender lock is released; a busy sender yields failure while
the permanent permit fence remains in place. This does not require the destination
to be reachable. No snapshots or disks are deleted by this command.

Local tests passed bounded protocol validation and seventeen permit cases,
including the production wrapper's held-sender refusal, permanent renewal denial,
duplicate retry, and invalid host/lease/path rejection. The initial HTTPS fixture
lacked the fresh inventory required by admission; after restoring that fixture
precondition all twelve HTTPS cases passed, including a real revocation worker,
local permit fencing, authenticated receipt, foreign-host refusal and stale-session
fencing (`/tmp/kittens-source-revocation-https-fixed.log`). Database tests cover
unoffered/mismatched/stale and mixed-invalid receipts without partial acceptance.

The installed two-node SSH/ZFS fixture now invokes the typed production wrapper
and adds live blocked-sender revocation without stopping the listener. It checks
sender PID absence, listener availability, refused subsequent pull and local
cleanup, retaining the earlier listener-shutdown case. Native execution is running
in `/tmp/kittens-revocation-native.log`; no native success is claimed yet.
All three application gates are running in
`/tmp/kittens-source-revocation-precommit-fixed.log`. The first gate failed on two
inconsistent helper call names in a concurrently edited ingress protocol test;
those calls now match its existing helper, with no architectural behavior change.
An initial worker map-edit compilation failure was also corrected before testing.


Verification encountered two further concurrent-work failures: Lilly formatting
in newly edited ingress/actor files, then an ingress fixture's overlong Unix socket
path. Formatting preserved semantics; the fixture was independently corrected to
use a short temporary directory. The former runs remain failed. The replacement
consumer gate is `/tmp/kittens-source-revocation-consumers-final.log`; Lilly's 232
cases and forced Dialyzer have passed, while Marshall is still running. Protocol's
81 cases and Dialyzer passed in the earlier protocol gate. Counts include concurrent
work. Native endpoint execution continues on the original live build handle.


The first extended native run terminated with exit one at the second case's
`endpoint-control configure`: the lifecycle fixture reused its default relocation
ID, whose permit the first case had permanently retired. Review identified the
fixture defect while it was running; by the attempted SIGINT its process had
already exited, so it was not actually canceled. The first transfer, command
restriction and listener-shutdown revocation cases passed, but the new live-listener
case did not. The corrected fixture uses a second relocation ID consistently for
snapshot creation, descriptor generation and cleanup, plus a distinct destination
placement. No production fence was weakened. Replacement execution is running in
`/tmp/kittens-revocation-fixed-native.log` from a fresh isolated source snapshot.


Application verification is complete: protocol 81 cases and Dialyzer passed;
Lilly 232 cases and forced Dialyzer passed; Marshall 427 cases including distributed
checks, browser checks, forced Dialyzer and schema consistency passed. Marshall
retains one existing ignored diagnostic, with no unignored errors. The successful
consumer log is `/tmp/kittens-source-revocation-consumers-final.log`. Earlier failed
runs remain recorded above. The corrected native endpoint suite is still running;
application checks do not substitute for its process/SSH/ZFS evidence.


Final native revocation verification passed with exit zero in 425.41 seconds,
output `/nix/store/gpjh55ibl0092fzdb7j815rms2szhgsp-vm-test-run-kittens-export-endpoint`
(`/tmp/kittens-revocation-fixed-native.log`). The corrected second relocation
exercised the production typed source effect against a live blocked ZFS sender:
revocation and duplicate receipt succeeded, the listener stayed active, captured
sender PIDs were absent, a subsequent authenticated pull yielded no bytes, and
owned snapshots/disk cleanup succeeded. Earlier real transfer, arbitrary-command
rejection and listener-stop cancellation cases also passed.

The deliberately blocked destination consumer exited at its approximately
120-second fixture deadline, rather than immediately on source revocation. This
receipt proves local permit fencing and sender quiescence, not remote receive
termination or destination cleanup. Those still need their own authenticated
cancellation effects and evidence before commitments can be released. This suite
uses synthetic control distribution, does not boot a guest, and does not establish
a full Marshall-coordinated two-Lilly workload move. All verification processes
from this increment are terminal. ADR-0037 and the full implementation goal remain
partial/active; source restoration, snapshot/destination reclamation, logical
Delete, lifecycle/slot refinements, preflight/resume/progress, UI and complete guest
acceptance remain outstanding.


## Cancellation source restoration under a fresh epoch

ADR-0037 now has a source-restoration coordinator after authenticated export
revocation. Under sorted endpoint host locks and the VM lock it cancels superseded
pending operations, invalidates terminal authority, advances the retained source
placement to the successor epoch, and commits a stop operation/outbox atomically.
That successor was reserved for the cancelled destination; cancellation forbids
its activation, and the source retains its distinct placement identity. No
reachable/fresh destination requirement is imposed on restoring the source.

A physical stopped receipt for that exact source operation is required before
restarting an originally running workload. An originally stopped workload receives
only the fresh-epoch stop. Restoration completion requires the exact completed
operation and matching immutable physical outcome. Missing/unknown/failed evidence
retains pending restoration. No source/destination copy, compute or temporary hold
is released; cancelled destination activation remains impossible. The retained
source placement also retains its monotonic outcome sequence across the epoch
change. SQL constraints and composite FKs bind the stop/start references and require
revocation before the stop reference and the correct original-state branch.

This deliberate stop-before-restart avoids relabelling a live old-epoch VMM as a
new boot: Lilly's start primitive can otherwise see an already running unit while
its old boot binding remains. Source disk contents and logical identity remain
unchanged. Current destination/terminal lifecycle availability during pending
cleanup still needs the previously recorded refinement.

The first focused run exposed a placement-global sequence collision in a stopped
fixture and an incompatible stale-operation outcome in a running fixture. The
coordinator now preserves source sequence state, and fixtures use valid continuing
sequences and compatible historical states. Twenty focused cases passed, including
running, already stopped and pending-old-stop cancellation, unknown stop evidence,
duplicate advances, exact current outcomes, stale old-epoch observations, retained
reservations and no destination activation (`/tmp/kittens-source-restoration-focused-fixed.log`).
Schema consistency passed. The distributed fixture now includes a forced-cancellation
variant so duplicate revocation and restoration races execute deterministically,
in addition to the nondeterministic cancellation/handoff race. Its teardown clears
only its own cyclic restoration references before removing fixture rows.

Marshall precommit is running in `/tmp/kittens-source-restoration-precommit.log`.
These are control-plane tests with synthetic physical facts, not native guest
restoration evidence. Native cancelled-source boot with retained snapshots,
snapshot/destination cancellation cleanup, retryable restoration failure handling,
logical Delete, lifecycle/slot refinements, full-transfer preflight, resumable
control/progress, UI and full two-Lilly guest acceptance remain unfinished.


Review also found that a completed stop/start's first terminal outcome can remain
pinned while a later observation becomes unknown or failed. Restoration now
requires the current VM observation to match the expected stopped/running state,
in addition to the immutable completion receipt and exact authority/generation.
Regression cases insert uncertainty after both successful stop and successful
start, then require a new matching observation before advancing. The earlier gate
passed 432 cases and forced Dialyzer/schema checks before this final guard; the
final full gate is running in `/tmp/kittens-source-restoration-final-gate.log`.

The final source-restoration gate completed with exit zero: 432 cases (41
properties, 391 tests), forced Dialyzer, schema consistency, ADR validation and
structural contract checks passed; `git diff --check` passed. This run includes
the current-observation uncertainty guards and the deterministic three-Marshall
cancellation/restoration race. Dialyzer retained one existing ignored diagnostic
and reported no unignored errors. Native cancelled-source guest restoration and
the remaining cleanup and acceptance work above are still unverified/unfinished;
ADR-0037 remains partial.

## Native cancelled-source restoration acceptance in progress

The [restoration fixture](../../../nix/verification/tests/machines/zfs-guest/restoration.exs)
extends the real ZFS/Firecracker guest check with a running source cancellation.
It creates a native baseline through the production source effect, revokes through
the typed revocation effect, stops at source epoch 2, restarts at the next
generation, and checks distinct guest boot UUID/challenge with retained dataset
and snapshot GUIDs. It rejects an epoch-1 launch even with a higher generation,
then exercises idempotent snapshot-only cleanup while the restored guest runs.
The driver checks pre-cancellation guest data, retained allocation and eventual
fixture deletion. Control authority is synthetic; this does not cover Marshall
transport, an unreachable destination, cancellation cleanup receipts or release
of reservations.

Native verification is running in `/tmp/kittens-restoration-native.log`, from the
isolated source snapshot recorded in `/tmp/kittens-restoration-native-source-path`.
No success is claimed yet. The test preserves ADR-0037's accepted restoration and
cleanup ordering; implementation status remains partial. Source cleanup command
design must handle cancellation before any descriptor was received, including
local snapshot creation that completed after its last control response. A final
stream descriptor alone cannot represent all such cleanup obligations.

## Cancelled-source snapshot cleanup control

The new closed `RelocationSnapshotCleanup` exchange carries relocation/source
placement/old epoch and a bounded lease, without paths, GUID invention or key
material. Marshall offers it only after recorded source restoration and retains
offer-before-receipt constraints. Authenticated source receipts preserve the first
completion timestamp and schedule coordination; duplicate or late receipts do not
change execution authority. Under both endpoint host locks and the VM lock, the
coordinator releases only source temporary snapshot headroom after this receipt.
Source disk/compute and all destination holds remain charged.

Lilly runs an independent bounded `SourceRuntime` prune worker. The local effect
requires its retained start/stop command and driver intent at exactly the restored
successor epoch. It revokes exports without held locks, then takes the existing
placement/pool locks, retires local snapshot history (including never-created
history), and checks native absence with the existing ZFS ownership policy. It
does not delete the source disk or mutate VM intent. The expanded native fixture
uses this production effect for both baseline and no-first-snapshot cases; that
revision has not yet been submitted while the earlier native restoration run is
still live.

Focused protocol and Lilly negative-authority cases passed. The first Marshall
focused run passed 15/20 cases: five failures came from a new assertion inserted
into a fixture holding a destination session while authenticating with the source
token. The assertion has been moved to the source restoration fixture. Protocol
precommit passed 83 cases and Dialyzer; Lilly precommit passed 238 cases and forced
Dialyzer in `/tmp/kittens-snapshot-cleanup-gates.log`. Marshall's gate is running;
the final source-headroom release adjustment requires a subsequent final gate.
Native restoration, full cancellation cleanup, retries, logical Delete and full
two-Lilly acceptance remain distinct unfinished requirements. ADR-0037 remains
accepted/partial; no architectural decision is superseded by this increment.

The first full Marshall test phase passed 437 cases (42 properties, 395 tests),
including distributed snapshot receipt races. Its forced Dialyzer/schema phase
is still running; this is not yet a final gate pass. The final Marshall rerun must
include source temporary-headroom release and its updated assertions. Structural
ADR/contract checks and whitespace validation passed. The live native run still
uses the earlier direct snapshot-cleanup fixture, so even a success there will
not validate the newly wired production cleanup effect or no-first-snapshot case;
those require the updated native source snapshot and a subsequent run.

The first full gate subsequently completed with exit zero: protocol 83 cases,
Lilly 238 cases, Marshall 437 cases, both forced consumer Dialyzer gates and
Marshall schema consistency passed (`/tmp/kittens-snapshot-cleanup-gates.log`).
The final Marshall gate for source temporary-headroom release is now running in
`/tmp/kittens-snapshot-cleanup-final-gate.log`.

Destination cancellation remains separate. `ImportCleanup.cleanup/2` already
reclaims received/partially adopted data with GUID/nonce and physical-absence
checks, but requires a descriptor and externally proven receive/VMM quiescence.
`Receiver.pull/5` holds the receive activity lock; its child native stream holds
the stream lock and reaps on caller death. Therefore destination cancellation
must first persist a descriptor-independent fence against new key/receive/import
work, stop active receive work, then acquire these same locks before reclaiming.
Key erasure alone cannot establish stream cessation, and a fabricated descriptor
cannot stand in for missing local import history. No destination reservation or
stream slot is released by the source-only work verified here.

The final Marshall gate exited 2 with 436/437 cases passing and forced Dialyzer
passing. Its one failure was an order-sensitive reservation assertion after
source temporary-headroom release: both complete reservation records matched,
but the database returned them in the opposite order. The assertion now compares
records sorted by their reservation IDs, retaining all field checks. No production
change was required. The corrected full gate is running in
`/tmp/kittens-snapshot-cleanup-verified-gate.log`; the failed run remains available
in `/tmp/kittens-snapshot-cleanup-final-gate.log`.

The corrected final Marshall gate completed with exit zero: all 437 cases (42
properties, 395 tests), browser checks, forced Dialyzer, schema consistency, ADR
and structural contract checks passed; whitespace validation passed. The one
existing ignored Dialyzer diagnostic remains, with no unignored errors. This run
includes source temporary-headroom release and verifies retained source disk/
compute and destination commitments. Lilly's updated native release also built
successfully as
`/nix/store/8s45jlvzl4q215lws2g2392ygmfz92c6-kittens-lilly-0.1.0`, from the isolated
source snapshot recorded in `/tmp/kittens-snapshot-cleanup-native-source-path`.
Native cleanup acceptance is still pending and is not implied by the release build.

Native cancelled-source restoration passed with exit zero in 1448.27 seconds:
`/nix/store/nfhc7v8pmjdjz7xa50zyj92csjr06n24-vm-test-run-kittens-zfs-guest`
(`/tmp/kittens-restoration-native.log`). The cancellation case itself took 241.63
seconds and verified a distinct ready guest boot/challenge under source epoch 2,
unchanged native disk/snapshot GUIDs before cleanup, refusal of an epoch-1 launch,
idempotent snapshot cleanup while the guest ran, retained pre-cancellation guest
data and final fixture deletion. Existing guest lifetime, simulated host-loss
recovery, neighbor preservation, source retirement and readiness checks passed.
This run used direct `SourceSnapshots.cleanup`, not the new authenticated cleanup
effect, and used synthetic control rather than a Marshall-driven cancellation.

The updated native run has now been launched in
`/tmp/kittens-snapshot-cleanup-native.log` using the source snapshot recorded in
`/tmp/kittens-snapshot-cleanup-native-source-path`. It replaces direct cleanup with
`SourceSnapshotCleanup.execute/3` and adds cancellation before a first snapshot.
Its predecessor is terminal; this is a new verification revision, not a restart
caused by an observation timeout. The new run is pending. Destination reclamation,
restoration retry, logical Delete and full two-Lilly acceptance remain unfinished.

## Destination cancellation fence and independent stream-slot release

The new `RelocationDestinationRevocation` wire type carries only the cancelled
destination host/placement/epoch, relocation and lease. Its authenticated exchange
requires cancellation and an offer before accepting a receipt; duplicate receipts
retain their first timestamp. It cannot commit a destination, restore a source,
or release disk commitments. The migration adds offered/completed timestamps and
an offer-before-receipt check.

Lilly's dedicated `KeyRuntime` cancellation mode runs `DestinationRevocation`:
permanently retire/erase the key first, then acquire receive activity and native
stream locks before returning. Busy retries retain the key tombstone. Existing
bounded native work may finish before a retry confirms quiescence; key erasure
alone is explicitly not success. Receiver and Importer now revalidate their key
connection after taking their activity/stream locks, closing the cached-path race
where an old connection check could otherwise authorize delayed work after the
revocation receipt. Lock ordering remains compatible with ordinary key retirement.

Under both endpoint host locks, the cancellation coordinator releases stream slots
only after independent source revocation and destination quiescence receipts.
Disk/temporary reservations and pending source restoration are independent. Released
slot history is retained and duplicate advances preserve timestamps. This covers
cancellation; the successful-move slot release refinement remains outstanding.

Eight focused Lilly key/effect tests and twenty focused Marshall relocation cases
passed. Protocol precommit passed 85 cases and Dialyzer; Lilly precommit passed
241 cases and forced Dialyzer. The first Marshall full test phase passed 439/440
cases; the one property failure was malformed UTF-8 reaching `URI.new/1` in the
concurrently developed SSH configuration renderer. Its encoding guard landed
concurrently while this failure was inspected; this increment added a deterministic
`<<128>>` regression input. No SSH architectural decision changed. The first gate
is finishing Dialyzer in `/tmp/kittens-destination-revocation-gates.log`; final
Marshall verification must include the guard, regression and stream-slot release.

The native endpoint fixture now adds a distinct third relocation: a blocked real
SSH pipeline prevents the destination receipt even after key erasure, the source
sender remains alive until its independent revocation, then destination quiescence
and duplicate receipts succeed. Existing source revocation cases remain intact.
This revised native fixture has not yet run; the source snapshot-cleanup native
job is still active in `/tmp/kittens-snapshot-cleanup-native.log`. Destination disk
reclamation, restoration retry, logical Delete and full two-Lilly guest acceptance
remain unfinished. ADR-0037 remains accepted/partial.

The first destination-revocation gate is terminal with exit 2: the single SSH
configuration property failed before its concurrent encoding fix, while forced
Marshall Dialyzer passed. The corrected final Marshall gate is now running in
`/tmp/kittens-destination-revocation-final-gate.log`, including both-receipt stream
slot release. The updated Lilly release built successfully as
`/nix/store/873h73q0l5a3k6m7vb2d8a9pw436xwrr-kittens-lilly-0.1.0` from the isolated
snapshot recorded in `/tmp/kittens-destination-revocation-native-source-path`.
The corresponding native endpoint check has now been launched in
`/tmp/kittens-destination-revocation-native.log`. It is independent of the still
running source snapshot-cleanup guest check; neither native result is claimed yet.

The corrected final destination-revocation Marshall gate completed with exit zero:
440 cases (43 properties, 397 tests), browser checks, forced Dialyzer, schema
consistency, ADR and structural contract checks passed; whitespace validation
passed. One existing ignored Dialyzer diagnostic remains, with no unignored
errors. Combined with the earlier protocol 85 and Lilly 241 passing gates, this
verifies the authenticated exchange/worker, permanent busy-key fence, duplicate
receipts across three Marshall nodes, and both-receipt cancellation slot release
at the application level. The SSH renderer's malformed-UTF-8 regression also
passes. Native source snapshot cleanup and destination revocation jobs remain
active; destination disk reclamation and complete cancellation are still partial.

## Interrupted native runs and destination-local cleanup history

The host restarted during the source snapshot-cleanup and destination-revocation
native runs. Their original logs contain no terminal test result. The subsequent
source snapshot-cleanup rerun is terminal with builder exit 1 in
`/tmp/kittens-snapshot-cleanup-native-resumed.log`: QEMU could not access `/dev/kvm`
as the Nix build user and exited before connecting its monitor. This is an
environment failure before relocation assertions, not passing cleanup acceptance.
Earlier application gate results remain historical evidence for their revisions.

`ImportJournal.for_intent/3` now recovers the exact current stream descriptor from
private destination-local history under the pool lock. It validates the entire
immutable relocation intent, local storage identity, closed record shape and
lineage. Missing history stays absent; malformed or unsafe history fails without
mutation or fabricated GUIDs. Tests cover incremental advancement, retirement,
duplicates, foreign authority/storage, malformed state and unsafe files. The
focused journal suite passed nine cases (one property, eight tests).

`ImportCleanup.cleanup_intent/2` uses this history for existing imports. Without
history it permits only native disk and claim absence verification and empty
mountpoint removal. It requires independent permanent transfer/launch fences and
physical quiescence; it creates no new execution authority and releases no remote
reservations. The native storage fixture now exercises the intent-based entry for
existing staging imports, including partial receives; adoption cleanup still uses
the existing descriptor-based disk entry. Lilly's full
gate and this revised native fixture are pending. Authenticated destination
cleanup delivery, launch fencing and cancellation completion remain unfinished.
This implements part of ADR-0037's accepted cleanup design; its status stays partial.

Lilly's full gate completed with exit zero: 243 cases (30 properties, 213 tests),
forced Dialyzer with zero errors, toolchain, ADR and structural contract checks.
Separate ADR/contracts checks and whitespace validation also passed. Results are
in `/tmp/kittens-intent-cleanup-gate.log` and
`/tmp/kittens-intent-cleanup-structure.log`. The revised native ZFS transfer check
is running from isolated snapshot `/tmp/kittens-import-native-u6o3m8z2`, with log
`/tmp/kittens-intent-cleanup-native.log`. It includes repeated no-history absence
checks and locally recovered lineage for existing imports. It uses a per-command
empty Nix build-users-group under root to address the prior KVM permission failure;
host device permissions were not changed. No native pass is claimed yet.

## Cancelled destination execution fence and local cleanup effect

`Driver.retire_transfer_destination/5` now serializes with ordinary placement
mutations and accepts only absent execution intent or its exact epoch/generation
deletion retry. Foreign VM/deletion ownership and prior activation intent fail
closed. It proves stopped compute, writes terminal intent and matching ownership
tombstones before jail/network cleanup, and retains them when disk cleanup fails.
`Disk.discard_import_intent/2` connects the existing pool lock to local-history
reclamation without a remote stream descriptor.

`DestinationCleanup.execute/3` validates immutable intent, enrolled destination and
a bounded lease before permanently retiring the key. It uses the driver fence,
then receive/stream locks and pool-locked cleanup, rechecking lease and key fencing
before reclamation. Receipt creation also requires a live lease after cleanup.
This is a local effect requiring authenticated pre-handoff cancellation; its
Marshall exchange and supervised delivery remain unimplemented. No reservation
is released by this effect.

The native adoption fixture now uses this effect for the interrupted cancellation
case and checks stale-start refusal after deletion. A separate check rejects
cancellation cleanup of an already activated stopped placement without changing
its intent or creating a tombstone. The running prior native snapshot does not
include this increment; new native acceptance is pending. The first two Lilly
gate attempts stopped at test-fixture compilation because required Client and
Config fields were omitted. Those fixture fields are now supplied; the corrected
gate is running in `/tmp/kittens-destination-cleanup-effect-final.log`.
ADR-0037 remains accepted/partial with unchanged design requirements.

The corrected Lilly gate completed with exit zero: 245 cases (30 properties,
215 tests), forced Dialyzer with zero errors, toolchain, ADR, contract and formatting
checks passed in `/tmp/kittens-destination-cleanup-effect-checked.log`. Intermediate
runs caught a missing pre-created transfer root in the key-fence fixture and a
formatting error; both were corrected without weakening assertions. Whitespace
validation passed. The effect fixture now supplies the same private transfer-root
precondition as configured Lilly runtimes.

The native effect check is running from isolated snapshot
`/tmp/kittens-import-native-bgtzrzuh` in
`/tmp/kittens-destination-cleanup-effect-native.log`, with the same per-command
build-user override. The earlier local-history check is a separate revision and
remains live in `/tmp/kittens-intent-cleanup-native.log`; it has reached adoption
recovery. Neither pending run establishes native acceptance of this new effect.

Both native storage runs are now terminal with exit zero. Local-history cleanup
passed in 414.00 seconds as
`/nix/store/4142pnyy074ja0qm7acznbk0wnbn562p-vm-test-run-kittens-zfs-transfer`.
The destination execution-fence/effect revision passed in 392.10 seconds as
`/nix/store/mgmwjzirnbf0q09irz7g6n5xxibwz5n4-vm-test-run-kittens-zfs-transfer`.
It verifies interrupted adoption cleanup through `DestinationCleanup`, exact
terminal-intent retries, stale-start refusal and rejection of cancellation cleanup
for an activated stopped placement. These storage fixtures use synthetic control
and boot artifacts; they do not establish a Marshall-driven guest move.

## Authenticated destination reclamation and cancellation completion

The closed `RelocationDestinationCleanup` codec carries immutable intent and a
lease, without remote stream GUIDs. `RelocationDestinationCleanups` fences the
destination session, records an offer before accepting matching receipts, preserves
first receipt timestamps and queues reconciliation. Its new migration/snapshot
adds offered/reclaimed timestamps with PostgreSQL offer-before-receipt checks.
The Lilly client validates host/session/epoch, command destination and submitted
acknowledgements. A separate supervised `SourceRuntime` cleanup mode calls the
local effect and retains bounded unacknowledged results; all root-runtime start,
fence, exit and shutdown paths include the new worker.

Cancellation completion requires recorded source restoration, source snapshot
cleanup, destination reclamation and both transfer revocations. Under both host
locks and the VM lock it releases destination reservations and records completion;
source disk/compute and workload/address identity remain retained. Stream release
still occurs independently after its two quiescence receipts. Destination cleanup
may finish before source restoration, but cannot itself authorize source execution.

Tests now cover five precommit cancellation stages, offer-before-receipt,
identity/session mismatches, immutable duplicate receipts, originally running and
stopped completion, HTTPS client/worker fencing and duplicate cleanup/completion
across three Marshall peers. The HTTPS fixture deliberately withholds native
success without a configured destination pool; its later synthetic receipt proves
transport/coordinator behavior only. Protocol precommit passed 87 cases and
Dialyzer; Lilly passed 245 cases and forced Dialyzer. The final Marshall gate is
running in `/tmp/kittens-destination-cleanup-marshall-final.log`; the preceding
gate does not include the latest HTTPS and distributed completion assertions.
Restoration-failure retry, lifecycle availability while cleanup remains pending,
logical Delete across copies, full-copy preflight, progress/resume refinements,
public admission/UI and full two-Lilly acceptance remain unfinished. ADR-0037
remains accepted/partial; no accepted requirement is superseded here.

The first Marshall gate completed with exit zero: 443 cases (44 properties,
399 tests), browser checks, forced Dialyzer (one existing ignored diagnostic),
schema consistency, ADR and contract checks. It predates the final HTTPS worker
and three-node completion assertions, whose full gate remains in progress.
Independent ADR and whitespace checks passed after the documentation update.

The source snapshot-cleanup and blocked-transfer destination-revocation native
checks interrupted by the reboot have been relaunched from their saved snapshots
using the verified per-command KVM build-user override. Their logs are
`/tmp/kittens-snapshot-cleanup-native-kvm.log` and
`/tmp/kittens-destination-revocation-native-kvm.log`. Both have booted their test
VMs; results remain pending. These are retries after terminal interruption/KVM
failure, not restarts prompted by observation timeouts.

The final Marshall gate completed with exit zero: all 443 cases (44 properties,
399 tests), browser checks, forced Dialyzer, schema consistency and structural
ADR/contracts checks passed. One existing ignored Dialyzer diagnostic remains,
with no unignored errors. This revision includes the HTTPS worker's refusal to
invent a physical receipt, session fencing, nine cleanup receipts across three
Marshall peers and exactly one cancellation completion with destination-only
reservation release. Protocol 87 and Lilly 245 passing gates cover the same wire
and consumer changes. Whitespace validation passed. The two restarted native
source-snapshot and blocked-transfer checks remain pending; the complete original
relocation plan is still unfinished for the requirements listed above.

## Lifecycle availability during retained-copy cleanup

`RelocationGuard.lifecycle_busy?/2` now separates start/stop and ordinary recovery
from relocation and maintenance exclusion. After recorded source restoration or
retained readiness on the committed destination, lifecycle can proceed on that
exact placement/epoch while cleanup remains pending. Pending restoration or initial
readiness still blocks it. Another relocation, host maintenance and logical Delete
remain excluded until their respective coordination requirements are satisfied.

Readiness now remains a retained fact across later generations on the same
committed placement. Stop, crash or restart after successful readiness cannot
strand source cleanup even if its obligation has not yet been created. Terminal
admission still requires the current completed start operation and running state;
pending/failed initial readiness cannot be bypassed. Ordinary lifecycle and crash
recovery preserve exact source-deletion operations bound to durable cleanup
requests, instead of cancelling every unfinished operation for the logical VM.
Confirmed ordinary stops release current-placement compute, and normal bounded
crash recovery resumes after establishment of the authoritative placement.

Tests exercise start/stop and crash/recovery before cleanup creation and while its
source-delete operation is outstanding, plus all three source restoration cases.
The initial focused run exposed missing fresh source inventory in the restored
fixtures; ordinary Start correctly continued enforcing that admission condition.
After supplying the report, one order-dependent reservation comparison failed;
sorting by reservation ID retains complete field comparisons. The final full
Marshall gate is running in `/tmp/kittens-cleanup-lifecycle-gate-final.log`.
This closes implementation drift from ADR-0037's accepted lifecycle requirement;
it does not implement logical Delete or restoration-failure retries, and the full
guest relocation/failure acceptance requirement remains open.

The blocked-transfer destination revocation native check completed with exit zero
in 575.45 seconds as
`/nix/store/03jbgyp8zkgn3b8rk3098fqs2j51w3yd-vm-test-run-kittens-export-endpoint`.
It verifies permanent destination key fencing while receive remains busy,
independent source sender revocation, later destination quiescence and duplicate
receipts over real SSH/native streams. The source snapshot-cleanup guest check
remains active in `/tmp/kittens-snapshot-cleanup-native-kvm.log`.

The first lifecycle full gate reached 442/443 cases; its one failure was the
reservation-order assertion subsequently corrected above. The overlapping final
attempt passed 421 cases but invalidated its 22 distributed cases because the
first run still owned the fixed `marshall_admission_1` Erlang node name. This is
test-run interference, not distributed acceptance. The final gate must run again
after both prior processes finish; no concurrent full Marshall runs should be
started merely because their database partitions differ.

Both overlapping processes have now exited (each exit 2 from the recorded test
failures; Dialyzer passed). The sequential gate is running in
`/tmp/kittens-cleanup-lifecycle-sequential.log`. A final contract review also
corrected the older `outcomes-release-requires-physical-result` prose to include
ordinary compute release after retained restoration/readiness; it previously
contradicted the newly permitted lifecycle behavior. Structural contract checks
and whitespace checks scoped to this increment passed. The workspace-wide
whitespace check currently reports an unrelated ADR-0047 edit.

Recovery tracing confirms that Lilly periodically reconciles uncertain stop
cleanup using the same command; unknown stop evidence remains insufficient to
restart. The remaining cancellation-restoration gap is a confirmed failed start:
the coordinator currently retains its completed failed operation indefinitely.
The next implementation must budget retries, atomically issue a fresh stop and
clear the prior start reference, and require that new stop's exact physical proof
before another start. Cleanup and resource retention remain independent.

The sequential lifecycle gate has completed with exit zero: 443 cases (44
properties, 399 tests), browser checks, forced Dialyzer, schema consistency and
ADR/contracts checks passed. One existing ignored Dialyzer diagnostic remains.
This establishes the lifecycle/recovery and source-cleanup preservation increment
at the application level; it does not establish the later restoration retry work.

## Bounded retries of failed source restoration

The restoration coordinator now matches the latest physical outcome for its exact
current failed start, including placement/epoch/generation and retained disk.
An old completed outcome, unknown observation or missing disk cannot trigger a
retry. On an enabled, normal source host, it uses the existing VM recovery budget
for at most three retry cycles per ten minutes, retaining future timestamps if the
database clock moves backward. Exhaustion leaves the obligation and reservations
pending; the periodic reconciler can retry after budget expiry.

Each retry atomically advances to stopped intent, charges the budget, records a
new stop operation/outbox and clears the old cancellation-start reference. Only
that new stop's exact physical confirmation permits another start. Existing
operations and physical outcomes remain historical evidence. No schema change
is required: the existing stop action now accepts the paired start-reference
clear in the same update. Originally stopped restoration remains unchanged.

The focused source suite passed 21 cases before the added explicit missing-disk
and current-sequence checks. It covers unknown stop/start observations, duplicate
failed receipts, three retry cycles, budget exhaustion/future timestamps, budget
expiry and eventual successful restoration with unchanged reservations. The full
gate including the strengthened checks is running in
`/tmp/kittens-restoration-retry-gate.log`. Native source snapshot cleanup has passed
its running-baseline restoration case and reached cancellation before a first
snapshot; the complete native run remains pending. ADR-0037 stays accepted/partial.


## Restoration checkpoint and committed stream-slot release

The restoration-retry gate completed 449 cases (45 properties, 404 tests), browser
checks and forced Dialyzer successfully (one existing ignored diagnostic). Its
subsequent schema consistency check detected the new committed-revocation
constraint changes introduced during that run; this is not a clean schema gate
for the following increment. Native source snapshot cleanup completed in 1424.37s,
including running-baseline restoration and cancellation before the first snapshot:
`/nix/store/1f3igri1czs63m2cbkvjacviisgr7dgv-vm-test-run-kittens-zfs-guest`.
This validates that local guest/effect fixture, not a full Marshall-driven move.

The next increment extends the existing authenticated source and destination
revocation exchanges to committed handoffs. Before either cancellation or commit,
revocation remains forbidden. Handoff already requires final receive/adoption and
source fencing, so transfer permissions are no longer needed after that boundary.
The destination effect retires only transfer credentials and waits for receive,
import and stream quiescence; it does not touch the activated guest's disk or intent.
The source effect permanently fences its permit and confirms sender quiescence.

Under both endpoint host locks and the VM lock, the coordinator releases stream
slots after both receipts, independently of readiness or delayed disk reclamation.
Reservations and the unfinished-relocation exclusion remain intact. The existing
final cleanup path remains an idempotent fallback and preserves earlier slot
release timestamps. New constraint migration permits offered revocations after
commit while preserving offer-before-receipt and pre-handoff cancellation rules.
No wire shape or native effect changes are required. Tests cover stopped and
pre-copy committed moves, premature/mismatched receipts, one-sided quiescence,
duplicate reconciliation and unchanged reservations before guest readiness.
Verification completed: the focused source suite passed 21 cases, protocol
precommit passed 87 cases and Dialyzer, Lilly precommit passed 245 cases and forced
Dialyzer, and Marshall precommit passed 452 cases (45 properties, 407 tests),
browser checks and forced Dialyzer (one existing ignored diagnostic). The final
Marshall schema consistency check exited zero. ADR validation and scoped whitespace
checks passed. Logs are `/tmp/kittens-committed-stream-{focused,protocol,lilly,marshall}.log`.
The Lilly key-worker contract wording was subsequently clarified to name both
cancellation and committed handoff; its behavior is unchanged. No native effect or
wire shape changed in this increment, and no new full guest-move acceptance is
claimed. ADR-0037 remains accepted/partial.


## Logical Delete across relocation placements

Delete now acquires the current/relocation endpoint host locks in UUID order before
the VM lock, rechecks manage permission and rejects a changed placement or newly
appeared endpoint set. The ordinary idempotent user Delete operation, terminal
invalidation, cancelled superseded operations and relocation deletion reference
commit together. A new Ash migration stores the paired deletion timestamp/operation
reference and permits snapshot-cleanup offers for this deletion obligation.

Before handoff, Delete records cancellation to suppress new transfer offers but
never enters restoration. The current source receives ordinary terminal Delete;
its exact physical deleted outcome releases only that placement. Destination
cleanup retains its existing import-only launch fence and permanent key retirement.
Its independent reclamation/revocation receipts release destination commitments.
Unknown outcomes or an unavailable destination retain the logical VM and address.
Delete during an already-started restoration cancels its outstanding stop/start
without rolling source authority back or enqueueing another start.

After handoff, current-destination Delete keeps the committed placement/epoch.
Pending readiness becomes activation-changed; old-source cleanup may begin even
when boot readiness failed. Existing source deletion operations survive the new
user intent. Native cleanup, source deleted outcome and destination key retirement
still govern source storage release. The deletion coordinator, not the source-only
cleanup coordinator, completes the relocation and archives the VM only after the
current Delete proof, both stream revocations and every retained reservation's
reclamation. Address release occurs in that same transaction. Exact user retries
continue returning the original Delete operation after archival.

Lilly's snapshot-only effect now also accepts the retained terminal Delete command
at the source or restored-successor epoch. A dedicated placement-locked driver
entry point verifies existing ownership, the exact deleted intent and unit/jail/
network quiescence before snapshot work. It never changes launch authority or
deletes the disk. Ordinary Delete can initially report incomplete cleanup because
snapshots remain; after snapshot retirement its same revision retries disk deletion.
If ordinary deletion already succeeded before snapshot cleanup was polled, that
stronger physical absence proof suffices; no synthetic snapshot receipt is needed.

The first focused suite passed 29 cases: running/stopped sources before copying,
after snapshot receipt, during restoration and after restoration; unknown/duplicate
outcomes; unavailable destination cleanup; authorization/idempotency; and deletion
after a real control-plane readiness timeout. Protocol (87 cases) and Lilly (245
cases) precommit/Dialyzer gates passed. Additional coverage for Delete during an
existing source cleanup and three-Marshall handoff races is being checked. The
source-built native guest suite is running from `/tmp/kittens-import-native-209mic9p`
with log `/tmp/kittens-logical-delete-native.log`; its new case verifies no source
restart, preserved terminal fences, snapshot retirement and duplicate Delete.
These are scoped application/effect checks, not complete two-Lilly guest relocation.
ADR-0037 remains accepted/partial, with its existing decision unchanged.


The expanded focused suite passed 30 cases, including Delete after a source
cleanup delete operation has already been offered. The first full Marshall run
passed 466 of 467 cases, including all three new independent-Marshall handoff/
Delete races, and forced Dialyzer (one existing ignored diagnostic). Its only
failure was the earlier exclusion test expecting Delete rejection. That test now
retains start/stop exclusion and checks that Delete records its relocation
obligation without releasing reservations. The corrected full gate is running in
`/tmp/kittens-logical-delete-marshall-final.log`; the failed gate remains recorded
in `/tmp/kittens-logical-delete-marshall.log`. Structural ADR and scoped whitespace
checks passed. Native validation remains running, not established by these gates.


The corrected full Marshall gate exited zero: 468 cases (45 properties, 423 tests),
browser checks, forced Dialyzer (one existing ignored diagnostic) and schema
consistency passed. The native guest run remains live and has not yet reached
its new source-Delete case, so native acceptance of this increment is pending.

Follow-up finding (medium, ADR-0037): late first snapshot-cleanup receipts can
arrive after logical deletion archived the VM, because physical disk deletion
can complete without that separate snapshot receipt. The snapshot exchange's
`Ledger.lock!(VirtualMachine, ...)` uses the active read and does not lock an
archived row, despite its stated VM-serialization contract. The source host lock
still serializes its receipt updates and no capacity is released there, but this
must be reconciled explicitly with a retained/history row lock and an archived
late-receipt regression. Audit the other relocation receipt exchanges for the
same archived-row case. This remains implementation work, not a replacement of
the accepted coordination decision.


## Retained VM locks for late relocation receipts

The archived-row finding is addressed in code by `Ledger.lock_history!/2`, which
uses the resource's history read and `FOR UPDATE` under the already-held host lock.
All eleven relocation receipt handlers now use it: key preparation, source snapshot
results, receive, import, readiness, source/destination revocation, snapshot cleanup,
destination cleanup, source cleanup and key retirement. Their active command
selection and execution-authority checks remain unchanged. Readiness reconciliation
continues rejecting archived activation authority. This fixes the accepted
host-before-VM serialization requirement without a schema or protocol change.

The focused source suite passed 30 cases, now deferring the first snapshot cleanup
receipt until after completed logical Delete and archival. It verifies acknowledgement,
first-timestamp preservation and unchanged completed deletion across retries.
A separate three-node regression holds the archived VM row alongside the destination
host lock and issues a source receipt through another Marshall node. It observes
PostgreSQL blocking, verifies the receipt remains unrecorded until release, and
replays through all three nodes. This fixture isolates row serialization; its
synthetic archival is not physical-deletion acceptance. The full gate including
that regression is running in `/tmp/kittens-retained-receipts-marshall.log`.
The native Delete run remains live in `/tmp/kittens-logical-delete-native.log`.
ADR-0037 remains accepted/partial; no accepted decision is replaced.


The retained-receipt full gate exited zero: 473 cases (45 properties, 428 tests),
browser checks, forced Dialyzer (one existing ignored diagnostic), schema consistency
and structural ADR/contracts checks passed. The PostgreSQL blocking regression
passed, establishing actual archived-row locking rather than only successful
receipt acknowledgement. This resolves the medium archived-row finding above
for all eleven inspected receipt handlers. No active command selector changed.
Native Delete validation remains running on the saved source snapshot and is not
claimed complete by this Marshall-only increment.

## Probe lease foundation and interrupted native run (2026-09-17)

Architectural impact: extends ADR-0037's source authorization journal with a
probe-only state, preserving snapshot-export and execution boundaries. The record
has a validated intent and challenge instead of a snapshot descriptor. Probe
renewal preserves identity; key binding and revocation reuse the export mutation
lock and permanent journal. Transition to an actual full export requires the same
intent/key; a probe cannot authorize baseline/incremental export. Existing export
lookup and SSH authorization remain closed to probes until explicit endpoint
integration. No shared protocol or Marshall schema changed in this increment.

Focused journal verification passed 20 cases (one property and 19 tests), including
three new probe scenarios. The full Lilly precommit gate passed 248 cases
(30 properties and 218 tests), contract checks, compilation and Dialyzer with zero
errors. The ADR checker passed all 50 records and scoped diff whitespace checks
passed. Actual SSH connectivity and
the coordinator pre-stop guard are still missing, so running full-copy fallback
must remain disabled. Review found no change to the accepted decision; this is
partial implementation evidence, not authenticated connectivity acceptance.

The earlier native logical-Delete test lost its process handle; host process
inspection confirmed it was no longer running and its log ended before the final
case completed. The same source snapshot was restarted, with output retained in
`/tmp/kittens-logical-delete-native-retry.log`. No pass is claimed for the interrupted
run. Full two-Lilly movement remains a separate outstanding requirement.

## Restricted probe endpoint integration (2026-09-17)

ADR-0037 impact: source SSH authorization now recognizes a probe lease while
keeping export lookup restricted to snapshot-backed grants. The existing private
channel supplies server-authenticated key identity; the new exact probe grammar
fits its existing bounded request field and cannot select programs or paths.
The endpoint rechecks challenge, lease, identity and configured pool and emits a
single bounded response. No C bridge or shared protocol change was needed.

Local focused tests passed 26 cases (two properties and 24 tests). These exercise
endpoint functions, not a real SSH handshake. The full Lilly gate passed 249 cases
(30 properties and 219 tests), contract checks and Dialyzer with zero errors. Native
OpenSSH tests, destination-side pinned SSH invocation and control-plane stop
ordering remain required. The prior journal-only checkpoint's unwired endpoint
statement is superseded only for local dispatch; full authenticated preflight is
not yet complete.

## Destination probe and native fixture (2026-09-17)

ADR-0037 impact: the destination helper reuses the pinned SSH command and native
stream supervisor, with a 30-second maximum and an exact-response consumer. The
consumer is the fixed pinned `cmp` executable; it compares against locally generated
public challenge bytes, requires EOF and successful exits, and never retains
remote bytes. Both host-tool packaging paths include diffutils. The stream lock
continues to serialize transfer activity with destination revocation. Key removal
between preparation and launch causes SSH failure; connectivity success grants no
new execution or storage authority.

Five focused SSH tests pass, including command-prefix equivalence, invalid
challenge/timeout refusal and retired-key refusal. Full Lilly precommit passed
250 cases (30 properties and 220 tests), contract checks and Dialyzer with zero errors.
The existing two-machine installed-endpoint fixture now adds a probe-only lease
with real OpenSSH, wrong-challenge refusal, denied export and permanent revocation.
Native verification is running from source snapshot
`/tmp/kittens-import-native-9rwo1je6`, with log
`/tmp/kittens-probe-endpoint-native.log`; no native pass is claimed yet.
Marshall command/receipt persistence and pre-stop freshness/authority checks remain
unimplemented. The running source must still remain untouched for this strategy.

## Probe control vocabulary (2026-09-17)

ADR-0037 impact: a new pure shared codec distinguishes source lease installation
from destination connectivity. Request IDs correlate immutable intent/generation
with key/challenge/revision/expiry. Results must match the phase as well as request
and lease; only destination commands admit the pinned endpoint. No private keys,
paths or executable arguments cross the boundary. Versioned exchanges retain the
existing sixteen-item, unique-ID limit. Consumers still need host/session fencing,
retained request persistence, current-authority checks and database-clock expiry
before a stop. A valid wire message grants none of those facts.

New tests exercise both roles, substitution of each correlation field, missing and
extra fields, integer and batch boundaries, unsupported versions and arbitrary
peer terms. Protocol precommit passed 90 cases (31 properties and 59 tests)
and Dialyzer; Lilly precommit passed 250 cases and its additional forced Dialyzer
check also passed. Marshall precommit and forced Dialyzer remain running. The ADR checker passed
50 records and scoped whitespace checks passed. Native SSH and logical-Delete jobs
remain separate pending checks.
No source stop was enabled by introducing this schema.

## Authenticated probe effects (2026-09-17)

ADR-0037 impact: Lilly's new typed effect binds source grants to Store execution
identity, workload, generation and the driver's existing running intent/claim.
The placement lock serializes grant publication with local lifecycle mutations.
The grant does not create a snapshot or interrupt the guest. Destination dispatch
requires its host identity and existing key to match the command, then uses the
pinned bounded SSH helper. Lease checks run before effects and after completion;
expired work cannot produce a successful receipt. Key.connection now returns its
already verified public key alongside the same trusted local paths.

Focused source/role and SSH tests passed seven cases before the additional wrong-key
case was added. Full Lilly precommit then passed 253 cases (30 properties and
223 tests), contract checks and Dialyzer with zero errors. These are refusal tests and do not
establish successful privileged source execution. The earlier native endpoint
snapshot covers SSH helpers, not this new effect. Live control-loop delivery and
Marshall request persistence/pre-stop checks remain required. Review found no
change to the accepted decision; execution authority remains separate.

## Probe runtime and native SSH proof (2026-09-17)

ADR-0037 impact: Lilly now starts a separate probe exchange/effect worker only
while its control session is connected. Fencing and termination stop that worker
alongside the other transfer workers without stopping independent guests. The
existing bounded pending-result retry loop handles probe results. Client decoding
checks response host/session/epoch, role-specific command host and unique submitted
acknowledgements. Local HTTP tests cover both roles, foreign hosts, changed session
or epoch, extra fields and invented/duplicate acknowledgements. Fencing tests verify
owner notification and rejection of retired worker messages. Two focused cases
passed; full Lilly precommit passed 255 cases (30 properties and 225 tests),
contracts and Dialyzer with zero errors. Marshall still lacks the route/outbox and stop
guard, so polling this endpoint cannot yet coordinate a relocation.

The installed two-NixOS-machine export suite completed successfully in 682.06s:
`/nix/store/xfyvfww817ngyji83ad1jnwiq74i5sxs-vm-test-run-kittens-export-endpoint`.
Its new probe-only subtest passed in 16.16s and used the real pinned OpenSSH client,
installed restricted listener/channel and exact-response consumer. It exercised
success, wrong challenge, denied disk export, no native sender and permanent
revocation. Existing native stream and revocation cases also passed. The log is
`/tmp/kittens-probe-endpoint-native.log`, from snapshot
`/tmp/kittens-import-native-9rwo1je6`. It predates the typed effect/runtime additions:
this is SSH helper acceptance with synthetic enrollment, not Marshall coordination,
positive source-effect acceptance or a running guest move. Logical-Delete guest
validation remains a separate live run.

The shared-codec consumer follow-up completed Marshall precommit: 473 cases
(45 properties and 428 tests), browser checks and test-environment Dialyzer passed
with one existing ignored warning. The separately requested forced development
Dialyzer is rebuilding its cache and remains live; no completion is claimed yet.

## Native logical Delete completed (2026-09-17)

The restarted guest suite passed in 1598.70 seconds, producing
`/nix/store/npjav1r9lldapc8gzklxqplh9bnmd623-vm-test-run-kittens-zfs-guest`.
The new logical-Delete subtest passed in 142.79 seconds: real source snapshots
initially prevented disk deletion, the authenticated cleanup effect retired them
under terminal intent, retrying the same Delete removed the disk, and later stale
starts remained refused. The guest was not restored during deletion. The log is
`/tmp/kittens-logical-delete-native-retry.log`, using the original immutable snapshot
`/tmp/kittens-import-native-209mic9p`. This is local guest/effect evidence; all-copy
Marshall coordination still relies on the separately passing application and
three-Marshall tests, and full two-Lilly guest movement remains outstanding.

## Probe outbox and exchange (2026-09-17)

ADR-0037 impact: Marshall now stores immutable per-relocation/revision/phase probe
requests with authenticated host binding, expiry and first receipt timestamp.
Both insertion and wake notification are transactional. Expired requests remain
for correlation but are excluded from scheduled notification retries. The generated
migration adds only the probe table/indexes/foreign keys in its up path; its down
path removes that new table. No applied migration was rewritten.

The authenticated probe route fences host/session before locking VM history and
recording exact receipts. Source grants require current running source identity,
held copies and both stream slots. Destination requests require an acknowledged
source grant with remaining lease time and preserve challenge/revision/expiry.
Cancellation, Delete and handoff suppress offers while late receipts remain
idempotent facts. Receipt acceptance does not stop a workload. Coordinator stop
eligibility and running stopped-full source requests remain the next missing link.
The focused outbox scenario passed after correcting a test fixture session-map
access (30 existing source cases passed on the first run). It verifies ordered
issuance, foreign-host and wrong-phase refusal, immutable duplicate timestamps,
unchanged running VM state, stale sessions and Delete suppression. Full Marshall
precommit and schema consistency checks are running; no completed control-plane
preflight is claimed yet.

The earlier shared-protocol consumer verification is now complete: Marshall's
additional forced development-environment Dialyzer passed with the existing single
ignored warning. This completed the previously pending shared-codec gates; it does
not cover the later new outbox, whose full gate is still running.

## Fresh preflight stop guard (2026-09-17)

ADR-0037 impact: running full-copy relocation now shares the existing atomic stop
transition while requiring an acknowledged destination probe. The probe must have
been issued within 30 database-clock seconds, have at least ten seconds of lease
remaining, and match the current source generation/workload, immutable endpoints,
public key and pin. Its source grant must have been acknowledged before destination
issuance. Receipt arrival cannot refresh old issuance. Probe insertion now explicitly
uses database time instead of an application-node timestamp.

The chosen probe ID is stored with the stop operation/generation. A composite
foreign key binds it to the same relocation, and a check constraint requires a
probe reference for running stopped-full stops. This is a new generated migration;
the earlier outbox migration was not rewritten. Existing host freshness, image
availability, commitments, stream slots and operation exclusion still gate stopping.
Full source snapshot requests then require the exact physical stopped outcome;
connectivity and stop intent alone do not authorize snapshots. Application and
schema checks are in progress; no integrated running full-copy guest acceptance
is claimed yet.

Focused preflight-stop verification passed. It rejects old issuance and changed
generation, waits after a control reconnect until fresh host reports arrive, records
one stop/probe reference across retries, rejects snapshot offers for unknown stop
outcomes, and emits a full descriptor request only after a physical stopped outcome.
The freshness fixture was corrected to report host inventory explicitly; no production
guard was weakened. Schema consistency and ADR checks passed. An additional API
route assertion also passed through the real provisioner Plug dispatch and JSON
codec. The final full Marshall gate is running. The earlier outbox full gate passed
474 cases, Dialyzer with the existing single ignored warning, and schema consistency.

## Authorized public relocation action (2026-09-17)

ADR-0037 impact: the VM Ash resource/domain now exposes a relocation action with
only VM identity and a bounded request key. The existing action allowlist admits
eligible users at the control-plane boundary; current record-level manage permission
is checked before and after sorted host/VM locking. The action records no host
choice from user input. PostgreSQL request serialization and the existing relocation
uniqueness/reservation transaction prevent duplicate placements and capacity holds.
Exact retries remain authorized reads of original history, including after cancellation;
revocation cannot be bypassed by reusing a successful key. Capacity failure rolls
back all effects and durable jobs.

All 18 focused capacity/admission tests passed, including three new public-action
cases for automatic selection, unchanged execution authority, exactly-once jobs and
holds, owner/manager access, revoked retries and capacity rejection. Two public-entry
race scenarios across three BEAM/Repo instances are running. This adds an authorized
domain entry point; it does not yet add the machine UI or establish complete native
movement. The prior full-copy stop gate is still running separately.

The full preflight-stop Marshall gate passed 474 cases (45 properties and 429 tests),
browser checks, Dialyzer with the existing single ignored warning, and schema
consistency. This completes application validation for the prior stop increment;
it does not substitute for full native guest movement.

Public admission's distributed suite passed 28 cases, including the two new
same-key/distinct-key races over three independent BEAM nodes and Repo pools.
Nine duplicate calls returned one relocation; distinct calls admitted one relocation
and rejected the rest. Each accepted move retained exactly two placements, two
reservations, both endpoint slots and its two initial jobs without changing execution
identity. The forced lock-wait/revocation scenario also passed: it observed the
remote admission blocked by a real PostgreSQL host-row lock, revoked its manager
while holding that lock, and confirmed denial after release without a new placement
or relocation. The final full admission gate is running.

## Native control-path acceptance follow-up (2026-09-17)

The first final admission gate completed with 479/480 passing: the unrelated SSH
API readiness assertion received 503 instead of 200. It was not a successful
gate, despite the later successful Dialyzer output. Its isolated nine-test SSH API
suite passed; a full rerun passed 484 cases (46 properties and 438 tests) against
the then-current shared worktree. The rerun also completed browser checks, Dialyzer
with the existing single ignored warning, and schema consistency successfully
(`/tmp/kittens-relocation-admission-recheck.log`). No cause has yet been established
for the first readiness failure.

ADR-0037's decision is unchanged. The local native guest fixture now exercises
the typed source probe effect with exact retries and rejects stale generation,
changed workload, expired leases and revoked authority. Independent process,
snapshot and disk-identity observations check that successful grants preserve
the running source and provide no disk export. Its first native run is in progress;
the earlier SSH helper acceptance does not prove this new effect path.

A dedicated `relocation-fleet` check now reuses the real three-Marshall/two-Lilly
topology with enrolled transfer host keys and production restricted SSH services.
It uses public admission and actual control daemons throughout. A controlled
listener outage holds the baseline transfer while the guest writes a distinct
post-snapshot marker; destination boot must retain that marker and the earlier
data. The scenario also returns to the former host under a new placement, checks
source reclamation and deletes the final workload. Syntax and contract checks
pass; native execution is pending. This starts integrated acceptance and does not
cover all interruption, cancellation, storage-pressure and update scenarios yet.

The first typed-probe guest run reached revocation but failed because the fixture
held its control-store lock in the effect process. Production uses an isolated
task. The fixture now follows that boundary, preserving the no-held-lock revocation
guard; the native retry is running from `/tmp/kittens-import-native-8z4bx8w_`.
The integrated relocation fleet is running from `/tmp/kittens-import-native-7iz62b7u`.

The worktree additionally extends the fleet scenario with an initially stopped
full transfer, unchanged private address, empty destination execution cgroup and
an explicit subsequent Start that verifies the retained guest data. This case is
not in the currently running immutable snapshot and needs the next native run.

The corrected typed source-probe native subtest passed in 24.24 seconds
(`/tmp/kittens-typed-source-probe-native-retry.log`). It confirmed grant/retry,
refusal of stale generation, changed workload, expired and revoked authority,
no export grant, unchanged guest process identities, no source snapshots, stable
dataset GUID and readable guest data. The larger guest suite remains running;
this scoped result is not a completed suite or two-host relocation claim.

The first relocation fleet build stopped at the generated driver lint check:
`ipaddress` was imported by the shared header but used only by the omitted
staleness scenario. Moving that import to its own scenario preserves both test
variants. The retry, including the initially stopped case, runs from
`/tmp/kittens-import-native-xyg7_3iu` with log
`/tmp/kittens-relocation-fleet-native-retry.log`.

The worktree now also includes cancellation after baseline creation with the
destination Lilly daemon stopped. It requires source restoration and data under
a fresh epoch before destination cleanup can finish, retains the destination disk
hold during the outage, then verifies cleanup after daemon restart. It uses the
public cancellation action and observes database facts without injecting progress.
This additional case is not in the active immutable snapshot and remains unrun.

### Remaining interrupted-transfer implementation gap

Current-source inspection confirms an unimplemented ADR-0037 requirement, not
merely missing acceptance evidence. `ReceivedDataset.receiver/2` uses `zfs receive
-u -s`, retaining partial receive state, but `Receiver.pull/5` retries the same
ordinary SSH request and `SourceSnapshots.send_arguments/3` constructs only full
or incremental sends. The transfer codecs/exchanges have no resume-token request
path. ZFS's existing resume-state observations support refusal and safe cleanup;
they do not authorize or execute resumed transfer. A validated, authority-bound
resume path is required before receiver restart and update interruption can be
claimed to resume copying. The native interrupted-copy acceptance must prove
that path, including wrong-lineage refusal, instead of treating retained partial
state or repeated ordinary requests as completed resume support.

## Bounded source resume-token validation (2026-09-17)

ADR-0037 impact: the new native `lilly-resume-token` helper uses the pinned
OpenZFS decoder rather than parsing diagnostic text. Before decoding it bounds
the version-1 token to 8192 bytes and declared unpacked payload to 16384 bytes.
It requires exact typed snapshot name and to/from GUIDs, rejects duplicate and
unknown fields and raw/saved/redacted modes, and emits only a fixed success marker.
The helper links the existing pinned ZFS userspace dependency; it gains no
privileges and performs no send or dataset mutation.

`SourceSnapshots.resume_export/3` first executes the same ownership, pool-lock,
nonce and native lineage checks as ordinary export, then validates the token
before returning resumed-send argv. This is a source capability, not a wired
coordinator resume path. Delivery, destination token retrieval and supervised
runtime selection still need implementation. Two focused refusal tests pass;
the native helper builds with warnings as errors. Lilly's full gate and new real
full/incremental token checks in the ZFS transfer fixture remain pending.

The surrounding typed-probe guest run later failed at the existing readiness
fixture's single Delete call with `zfs_dataset_cleanup_unconfirmed`; the earlier
24.24-second probe subtest passed. The cause of unconfirmed cleanup is not yet
established. The fixture now retries that exact deletion authority within sixty
seconds, matching production retry semantics, and still requires Driver success.
It does not bypass ownership or remove datasets directly. A full guest rerun is
required; the failed run is not a suite pass.

The source-token Lilly gate now passes 257 cases (30 properties and 227 tests)
and Dialyzer with no warnings, after formatting the new guard. The initial helper
build caught the pinned libnvpair API's const string pointer and large-file feature
requirements; those compiler errors were corrected without relaxing warnings.
Native token validation and the guest cleanup retry are running from
`/tmp/kittens-import-native-yq8a7tf3`, with logs `/tmp/kittens-resume-token-native.log`
and `/tmp/kittens-typed-source-probe-native-final.log`.

The second relocation fleet run passed enrollment and real guest provisioning,
then failed in its guest-data preparation fixture before relocation admission.
Its old error did not identify which assertion failed. The fixture now records
only fixed stage labels and exception classes, preserves private console output,
uses absolute utility paths in its transient guest writer, and matches the
existing native fixture's 120-second initial prompt deadline. These changes do
not establish the cause or a passing scenario; another native run is required.

Both new native token checks passed: the interrupted incremental case verified
its real token binding before resume, and the native stream case verified a full
token, wrong name/GUIDs and damaged-token refusal before resumed receive. The
broader ZFS transfer suite remains running. These results establish the decoder
boundary, not coordinator-driven resume. The third relocation fleet run now uses
`/tmp/kittens-import-native-68hyrk3i` and log
`/tmp/kittens-relocation-fleet-native-third.log`, including the cancellation case
and revised guest-data fixture.


## Destination resume-token ownership boundary (2026-09-17)

The preceding source-token native suite completed successfully in 439.92 seconds,
with artifact `/nix/store/9vmd6llv9fy0azpwrgzij343gssmjzf7-vm-test-run-kittens-zfs-transfer`.
It proves native token decoding and full/incremental transfer behavior, not the
coordinator resume path.

`ReceivedDataset.resume_token/2` now requires active receiving intent for the exact
stream, current pool identity, no ordinary placement claims, the local nonce and
a stable destination GUID. `ZFS.resume_child/4` verifies unmounted read-only noauto
staging, safe local properties and exact retained baseline lineage in two native
reads. It returns only a bounded unchanged native token; the destination GUID is
bound in the local journal before returning. Stream quiescence and current
reservation/relocation authority remain caller obligations. The source still must
decode and validate the token before any resumed send is authorized.

The native fixture now exercises retrieval from interrupted full and incremental
receives, exact retry, changed stream, wrong filesystem GUID, missing/wrong baseline,
changed nonce, unsafe properties and retired-intent refusal. It keeps token values
out of driver and exception diagnostics. This new fixture is running from
`/tmp/kittens-import-native-hm4_7vj6`; its log is
`/tmp/kittens-destination-resume-native.log`. The application gate is recorded in
`/tmp/kittens-destination-resume-precommit.log`; all 257 cases and forced Dialyzer
pass with zero warnings. ADR and contract structural checks also pass. Native
destination-token acceptance remains pending.

Architecture impact stays within ADR-0037's accepted resumable-transfer design.
No receive receipt or execution authority is granted by token retrieval. The
protocol, coordinator delivery and supervised resumed-send selection are still
unimplemented; this boundary alone does not establish restart/update recovery.


Inspection of the remaining transport identifies a direct integration route:
Marshall already issues the exact stream descriptor and current source permit;
the destination can send its verified token through the pinned restricted SSH
request, and the source can validate it against that permit under the existing
registration locks. Tokens need not become Marshall database payloads. This is
not implemented yet. The local export-channel packet currently limits commands
to 127 bytes, so a bounded resume verb also requires coordinated native packet,
parser and refusal-test changes. Receiver preparation must distinguish absent,
completed and partial state; a failed token lookup must never silently authorize
an ordinary replay into uncertain staging.


## Restricted resumed-export request (2026-09-17)

The destination-token native full/incremental retrieval and negative cases passed
in the 72.25-second partial-import subtest. Its encompassing storage suite is
still running; this does not prove the full suite or supervised transfer resume.

`ExportRequest` now recognizes a distinct bounded `lilly-resume-v3` grammar with
one shell-inert version-1 token envelope. It resolves the same durable permit as
ordinary export. `SourceExport` selects `SourceSnapshots.resume_export/3` under
its existing pool/permit registration locks, then rechecks the lease before
starting the exporter. `SSH.resume_command/4` retains the ordinary pinned key,
host pin and transport restrictions. The native local channel now has a fixed
8320-byte command field, sufficient for the 8192-byte token and closed prefix;
its peer authentication, descriptor validation and separate completion byte stay
unchanged. Source and bridge must be deployed together. No rolling compatibility
is claimed, consistent with ADR-0037's fresh-deployment scope.

New tests cover command injection/size refusal, transport restriction preservation
and a long native channel request with empty diagnostics. The Lilly gate passes
259 cases (30 properties, 229 tests) and forced Dialyzer with zero warnings in
`/tmp/kittens-resume-ssh-precommit.log`. Automatic receiver retry
selection remains to be wired; this change alone does not resume a coordinator
transfer. Marshall still owns the existing descriptor and permit authority.

The third relocation fleet run passed real guest-write preparation and public
pre-copy admission, then failed because the source's observed state was no longer
running after the native baseline appeared. The fixture lacked the observed
state/reason in its failure. A new read-only diagnostic records bounded control
facts without guest data; the unchanged running-state assertion remains required.
The next run uses `/tmp/kittens-import-native-7vmdwqq7` and
`/tmp/kittens-relocation-fleet-state-diagnostic.log`. The root cause is unresolved;
no successful relocation or fix is claimed.


## Supervised receiver resume and running-observation contention (2026-09-17)

`Receiver.pull/5` now recovers a completed native receive whose receipt was lost,
selects a verified destination token for partial state, and sends that token through
`SSH.pull/6` to the existing permit-bound source validator/exporter. Ordinary replay
requires `ReceivedDataset.fresh_receiver/2` to prove native absence for full/baseline
or the exact safe, token-free baseline for incremental transfer. A failed token
lookup cannot by itself authorize ordinary replay. Pool/stream/activity ownership,
key retirement, source expiry/revocation and native receipt validation remain in
force. No new Marshall token storage or execution authority is introduced.

The import-receipt contract now explicitly permits recovery from quiescent exact
completed native state after a lost process acknowledgement; it does not invent
a successful exit status. The Lilly gate passes 259 cases and zero-warning forced
Dialyzer (`/tmp/kittens-receiver-resume-precommit.log`). The preceding destination
ownership storage suite completed in 444.67 seconds, artifact
`/nix/store/11isiwp3kgflz869ylljhhw3156mpr78-vm-test-run-kittens-zfs-transfer`.

A new two-machine fixture feeds a bounded real authenticated SSH stream prefix to
native receive, closes its input, confirms retained owned resume state and retries
through `Receiver.pull`. Source data is written inside the mounted fixture ext4
filesystem before the baseline. The endpoint suite is running from
`/tmp/kittens-import-native-sh_er16_`, log `/tmp/kittens-receiver-resume-native.log`.
It must pass before this is claimed as cross-machine resume acceptance; incremental
supervised resume and daemon-update interruption still need separate evidence.

Inspection during fleet-failure diagnosis found a concrete contract mismatch:
`Executor.start/5` translated `Driver.adopt`'s `execution_unavailable` result into
an unknown identity observation even though reconciliation requires temporary
execution-lock unavailability to retry without replacing the previous observation.
Running adoption now returns retry for that result. The native source-probe fixture
holds the real placement lock while another task reconciles a running guest,
requires retry, then releases it and requires a fresh running observation. This
is not yet proven to be the fleet failure's cause; the diagnostic run remains
necessary. The new Lilly gate is `/tmp/kittens-running-lock-retry-precommit.log`;
native contention acceptance remains pending.


The running-lock correction passes the full Lilly gate (259 cases, forced
Dialyzer zero warnings), ADR structure and contract checks. Its native fixture
is now running from `/tmp/kittens-import-native-f48v98of`, with log
`/tmp/kittens-running-lock-retry-native.log`. The earlier typed-probe guest suite
has passed readiness and cancellation-restoration subtests but remains running;
none of these interim results establishes the new contention regression yet.


The earlier typed-probe/readiness guest suite completed successfully in 1536.52
seconds, artifact `/nix/store/vvdr5aa7cz8jslslhpzhvq0kpvdw7c1w-vm-test-run-kittens-zfs-guest`.
It includes real readiness, cancellation restoration and logical Delete, but
predates the running-lock correction. That correction's native run remains live.

The endpoint fixture now additionally creates a final source snapshot after new
synced ext4 writes, advances the same source permit to incremental, interrupts
that receive and retries through the same receiver. It requires exact A/B GUIDs
and cleared native resume state. This new incremental case is not in the active
immutable baseline-resume run and remains unrun; it must not be counted as evidence
until a subsequent snapshot completes it. The current baseline run is retained.


The supervised baseline-resume subtest now passes in 39.70 seconds: native receive
was interrupted after a bounded authenticated stream prefix, owned resume state
was confirmed, and `Receiver.pull` completed and verified the snapshot through the
restricted resume request. Its exact retry passed too. The encompassing endpoint
suite is still running (`/tmp/kittens-receiver-resume-native.log`); incremental
resume and update interruption are not established by this baseline result.


The baseline-resume endpoint suite subsequently failed at its second fixture
renewal: the helper reused revision 2 with a changed expiry, correctly rejected
by the production permit journal. The 39.70-second resume subtest remains scoped
passing evidence, not a suite pass. The fixture now reads the current authorized
permit and increments its durable revision for each renewal/advance. It does not
change permit enforcement. Contract checks pass. A new endpoint run includes the
incremental case and this fix, from `/tmp/kittens-import-native-kmsh0jhn`, log
`/tmp/kittens-incremental-resume-native.log`.


## Native receive bandwidth control (2026-09-18)

The stream helper now relays data with nonblocking kernel splice between two
pipes. A monotonic token bucket bounds the configured byte rate with at most
64 KiB burst credit. Its loop continues checking caller EOF, deadline, diagnostics
and child outcomes while throttled; cleanup still kills/reaps both process groups
before releasing ownership. No payload enters BEAM or diagnostic output.

`Stream.run/5` passes an explicit validated rate to the helper, overriding ambient
environment. `Receiver.pull/6`, `SSH.pull/7` and `ReceiveRuntime` carry the positive
operator rate for production receives. Startup defaults to 64 MiB/s and rejects
zero, nonintegers and values above 1 GiB/s. Nix exposes
`services.lilly.transferBytesPerSecond`. Local unthrottled utility/probe calls can
still explicitly use the native API's zero rate; coordinator receive cannot.
This implements ADR-0037's bandwidth control, not byte-progress reporting or
storage-pressure recovery, which remain outstanding.

Seven focused native stream tests passed before the final polling optimization,
including byte integrity, cancellation, reaping, measured throttling and timeout
while throttled. The full Lilly gate for the final code is running in
`/tmp/kittens-transfer-rate-precommit.log`. A rate-enabled real SSH/fleet acceptance
run is still required. This helper change preserves existing control-plane and
execution authority; no architectural decision is replaced.

The diagnostic fleet run confirmed `unknown` with reason `identity_mismatch` at
generation 1 while desired state remained running. It predates the lock-retry
correction. The separate real running-guest contention regression passed inside
the source-probe subtest in 24.74 seconds; its full suite remains running. A fleet
rerun with the correction is required to establish that it resolves the observed
failure; the diagnosis is consistent with it but not conclusive by itself.


The resume endpoint rerun passed both interrupted baseline (38.29 seconds) and
final incremental (40.34 seconds) subtests through the supervised receiver and
restricted exporter. The remaining endpoint scenarios are still running; these
results do not establish the suite or update recovery. They predate rate control.

The final bandwidth implementation passes all 260 Lilly cases (30 properties,
230 tests), forced Dialyzer with zero warnings, ADR structure and contract checks.
A new fleet run includes both the lock-contention correction and receive rate
control, snapshot `/tmp/kittens-import-native-49vuoaxc`, log
`/tmp/kittens-relocation-fleet-lock-rate.log`. Its result remains pending.


## Native progress-counter boundary (2026-09-18)

The native stream helper can now emit a private fixed nine-byte counter frame
at most once per second plus completion. Counts represent bytes spliced into the
consumer pipe during this attempt, not persisted ZFS bytes. Payloads and child
diagnostics remain outside this protocol. Progress output is nonblocking; a full
output pipe revokes and reaps work instead of blocking cancellation indefinitely.
The counter saturates by refusing signed-64-bit overflow, rather than wrapping.

`Stream.run/6` optionally forwards counters to a local PID with the stream task's
PID as attempt identity. Its parser requires the exact lock acknowledgement,
bounded framing and monotonically increasing signed-range counts. A final counter
still cannot substitute for helper exit, native receive verification, adoption or
resource release. The production receive runtime and control-plane/UI progress
path are not wired to this optional API yet. This is only the native reporting
boundary, not completed user-facing progress.

A real native pipeline test checks intermediate monotonic counters and the exact
final transported byte count without timing-dependent frame-count assumptions.
The first gate found the pinned Elixir runtime's required pin in a bit-size match;
the next found adjacent contract blocks without a blank separator. Both were
fixed. The final gate is `/tmp/kittens-stream-progress-precommit-final.log` and is
still running at this checkpoint. Previously launched native snapshots predate
this progress protocol and cannot validate it.


The final progress gate passes 261 cases (30 properties, 231 tests) and forced
Dialyzer with zero warnings. This includes real native throttled counter delivery,
byte integrity, timeout and process-reaping checks. Runtime/control-plane/UI
propagation and multi-machine acceptance of progress remain outstanding.


## Attempt-scoped receive-worker progress (2026-09-18)

`Receiver` now forwards only its current linked stream task's counters, retagged
with the receiver task PID. Both stream and receiver waits enforce their original
absolute deadlines even when progress messages are queued. `ReceiveRuntime`
accepts only its live receive task's nondecreasing counters before lease expiry,
coalesces one byte count, and assigns a new UUID per attempt. A read-only progress
query returns request ID, attempt ID, stream kind and transported bytes, or nil
when the attempt is inactive/fenced/expired. Counters cannot renew authority,
create pending receipts or release capacity. Same-stream lease renewals preserve
the current attempt; a retry starts a distinct attempt at zero bytes.

A regression test covers old-task, decreasing, malformed, expired and fenced
updates, verifies no receipt/deadline mutation, and checks the exact public report.
The full Lilly gate is `/tmp/kittens-runtime-progress-precommit-final.log` and is
running. Marshall exchange/persistence and UI propagation remain incomplete;
currently launched machine snapshots predate this receive-worker integration.


The endpoint suite completed successfully in 692.29 seconds, artifact
`/nix/store/dcza7lsq2j2visknmfxcnn95jc0y320c-vm-test-run-kittens-export-endpoint`.
It proves real baseline/incremental interrupted receive and supervised resume,
exact receipt retry, SSH restrictions and source/destination revocation. It
predates rate/progress additions and does not establish Marshall guest movement
or update recovery. The next endpoint fixture additionally requires positive
attempt-tagged progress from the rate-enabled receiver; that revision is unrun.

The receive-progress regression caught a boolean error when querying an inactive
worker; the explicit nil check now returns nil as contracted. The corrected full
gate is `/tmp/kittens-runtime-progress-precommit-retry.log`, still running.


The first attempted nil-check replacement missed the formatter's parenthesized
expression; the rerun correctly retained the failing inactive-query regression.
The expression is now explicitly boolean. Dialyzer also rejected direct use of
Task's opaque monitor reference; monitor/alias cleanup now stays with the existing
enclosing `Task.shutdown/2`, which always executes. The corrected gate log is
`/tmp/kittens-runtime-progress-precommit-corrected.log`; all 262 cases pass and
forced Dialyzer is completing. A new endpoint run includes configured rate control,
real progress forwarding and both resume cases, snapshot
`/tmp/kittens-import-native-kcjpsp6j`, log `/tmp/kittens-runtime-progress-native.log`.


The corrected receive-progress full gate completed successfully: 262 cases and
forced Dialyzer with zero warnings. Native progress forwarding remains pending,
and Marshall/UI progress delivery is still unimplemented.


## Shared progress schema and attempt ordering (2026-09-18)

`KittensProtocol.RelocationProgress` now defines a closed five-field report:
request UUID, attempt UUID, positive attempt sequence, finite stream kind and
nonnegative transport-byte count. Integers fit signed 64-bit storage; batches
are bounded to sixteen distinct request IDs. Unknown fields, malformed identities,
invalid kinds, duplicates and out-of-range values reject the entire input.
The module remains pure, with no host, Ash or credential dependencies.

Receive workers now attach a BEAM-monotonic positive sequence to each new attempt.
Its ordering scope is the authenticated host session/epoch: control runtime startup
always creates a fresh session UUID before Client.open, so a BEAM restart cannot
reuse the previous sequence namespace. A worker restart within the same BEAM uses
the same increasing counter source. Marshall must join that authenticated session
and retained request before accepting reports, and use sequence/attempt identity
to prevent late older attempts replacing newer progress. This consumption and
persistence are not implemented yet; no endpoint silently accepts this schema.

Boundary and round-trip property tests cover the codec. Protocol, Lilly and Marshall
precommit gates are running sequentially in `/tmp/kittens-progress-codec-all-gates.log`.
The codec and ordering are required preparation for control-plane/UI progress,
not completed progress delivery or additional execution authority.


The progress-schema protocol gate passes 92 cases and zero-warning Dialyzer;
Lilly passes 262 cases and zero-warning forced Dialyzer. Marshall's full gate is
currently running, including its distributed tests. Schema consumption and
persistence remain the next implementation work; no progress API is exposed to
users from this codec-only boundary yet.


## Restored-source deletion retry and native progress evidence (2026-09-18)

The lock-retry guest run (`/tmp/kittens-running-lock-retry-native.log`) is
terminal with a failure in early-cancellation cleanup: restoration and the guest
data read succeeded, but the fixture required the first `Driver.delete` call to
succeed and received `:zfs_dataset_cleanup_unconfirmed`. This result does not
establish the cause of incomplete native reclamation. The fixture now retries
only that result at the identical epoch 2 / generation 4 with a fixed 60-second
deadline, retaining production deletion checks and failing unexpected errors.
Persistent cleanup failure remains a failure. No architecture decision or
production deletion behavior changes; ADR-0037 remains partial.

Contract syntax/discovery passed in `/tmp/kittens-restored-delete-checks.log`.
The native rerun uses snapshot `/tmp/kittens-import-native-9w9nh0c5` and log
`/tmp/kittens-restored-delete-native.log`; acceptance is still pending.

The rate/progress endpoint run (`/tmp/kittens-runtime-progress-native.log`) has
passed its interrupted baseline and incremental resume subtests (53.21 and
50.59 seconds), including the positive receiver progress assertion. Its full
suite is still running. This evidence covers native SSH transfer and local
progress forwarding, not Marshall progress persistence or complete relocation.


## Authenticated bounded progress persistence (2026-09-18)

Architecture impact: ADR-0037's informational progress path now reaches an Ash
resource through the existing authenticated receive exchange. One validated map
per relocation stores the latest sample, source request revision, session epoch
and database observation time. The closed shared codec bounds peer counters and
batch sizes. Current destination host/session authentication precedes VM locking;
request, workload, phase, lease and holds are rechecked before accepting telemetry.
Older revisions and attempts, decreasing counters, foreign requests and reports
after cancellation/delete/commit/completion cannot mutate progress. Duplicate
samples do not refresh freshness. No progress mutation updates receipts, jobs,
reservations or execution authority. UI delivery remains outstanding.

Optional telemetry preserves receipt-only v3 exchanges; it does not reinterpret
unsupported protocol versions. The Lilly client includes validated telemetry in
its normal polling exchange, with no extra sample queue. Tests cover codec
closure, persisted schema boundaries, session restart, attempt retry, delayed
reports, source renewal, cancellation and actual client/server TLS transport.
Their results are pending in `/tmp/kittens-progress-persistence-tests.log`.

Concurrent merge work briefly exposed conflict markers in runtime configuration
during codegen; the completed merge removed them without changes by this task.
Codegen then proposed recreating an operation index and constraint already
installed by `20260917113026_relocation_source_retirement.exs`: the merged resize
snapshot had older operation metadata. The new operations snapshot reconciles
that metadata; those duplicate DDL statements were removed from the new migration.
Only the nullable receive-progress column is added or removed by this migration.

Protocol precommit passes 95 cases. The combined Lilly run encountered six test
failures including an existing temporary-directory collision and an already-owned
fixture lock while another test process was active; it is not a passing gate.
The prior Marshall run likewise failed distributed peer startup because
`marshall_admission_1` was already in use. Both require isolated reruns. No
production behavior has been weakened to accommodate these failures.

The native rate/progress endpoint suite completed successfully, artifact
`/nix/store/67wb4gha3ycg94g78knf578gpcrsj2k8-vm-test-run-kittens-export-endpoint`.
The restored-source cleanup retry and integrated fleet runs remain pending.

The first focused progress run exposed a missing internal Ash action allowlist
entry: both direct persistence and the TLS client test were denied. The explicit
`Relocation.record_receive_progress` action is now allowed only through the
existing internal coordinator/Cedar path; no user action was added. The rerun
includes renewal ordering and persisted type boundaries and is recorded in
`/tmp/kittens-progress-persistence-tests-retry.log`.

The concurrent merge brought ADR-0050 and ADR-0051 into the decision chain. They
supersede ADR-0037's capacity policy while carrying forward unrelated relocation
requirements. Progress does not change that policy or release startup/disk holds.

The corrected focused run passes all 45 tests, including the actual Lilly HTTPS
client exchange, unchanged receipt/capacity/placement authority, old-session
rejection, attempt and renewal ordering, cancellation suppression, and persisted
map bounds (`/tmp/kittens-progress-persistence-tests-retry.log`, exit 0).
A fresh Lilly precommit is running in `/tmp/kittens-progress-wire-lilly-retry.log`
after confirming no other Lilly test process was active. Marshall's complete
gate remains outstanding; other full Marshall runs are currently active and
are not restarted or terminated by this task. Schema consistency is checked in
`/tmp/kittens-progress-schema-check.log`. UI and native full movement remain open.

The isolated Lilly rerun passes all 267 cases (30 properties, 237 tests) and
forced Dialyzer with zero warnings in `/tmp/kittens-progress-wire-lilly-retry.log`.
`mix ash.codegen --check` also exits 0. These supersede the collided Lilly run;
they do not replace the pending complete Marshall gate or native fleet acceptance.


## Manager relocation controls and bounded status (2026-09-18)

The machine page now requests automatic relocation and cancellation through the
existing authorized Compute actions. Server-owned VM identity and admission key
are used; no browser-selected destination or transfer mode is accepted. Every
refresh obtains current access and the manager-only bounded status projection.
The projection selects one latest relocation, source request and readiness
request and returns only phase, mode, cancellability, latest attempt bytes and
observation age. Host/placement identities, keys, descriptors and permits remain
private. Cancellation is shown as restoration/cleanup pending until actual
completion, not as immediate reclamation. Readiness failure explicitly retains
the source copy. Byte counts are not completion percentages.

Architecture impact: this is the authorized UI/observability portion of the
carried-forward ADR-0037 plan, consistent with current ADR-0050/0051 capacity
policy and ADR-0022 access refresh. No new execution or mutation authority is
introduced. The 14 machine LiveView tests pass, including move/cancel, refreshed
progress, projection field bounds and denial after manager-to-viewer downgrade
(`/tmp/kittens-relocation-ui-tests.log`). Compiler warnings, contract syntax and
ADR structure checks pass. Complete Marshall precommit and rendered browser
inspection remain pending. Downtime reporting and broader phase-specific UI
coverage are not yet implemented.

The native fleet lock/rate run is terminal with a timeout awaiting first move
completion (`/tmp/kittens-relocation-fleet-lock-rate.log`), after passing the
source-running assertion and the post-baseline guest write. It does not prove
complete relocation. Its wait now logs only whitelisted phase enums, revisions
and completion booleans when they change, sampled at most every ten seconds.
The read-only diagnostic SQL validates against the current test schema in
`/tmp/kittens-relocation-phase-sql-check.log`. A rerun against the same original
implementation plus diagnostics uses snapshot `/tmp/kittens-relocation-phase-lkwv6lyq`,
log `/tmp/kittens-relocation-phase-native.log`; it deliberately predates newer
progress/UI and merged capacity changes to isolate the existing failure.


## Control-plane observed downtime (2026-09-18)

The authorized relocation status now derives observed downtime from the source
stop operation's pinned immutable physical outcome. Missing physical stopped
evidence yields no metric, as do initially stopped workloads and deletion flows.
A normal handoff does not finish the interval: only destination readiness or
confirmed source restoration does. While outstanding, it uses the database clock.
The UI explicitly identifies control-plane observation timing, which cannot
measure exact guest service availability. This adds no authority or storage
mutation and preserves ADR-0037's carried-forward recovery requirements.

The focused tests are in `/tmp/kittens-relocation-downtime-tests.log`; assertions
cover absent evidence, a confirmed source stop, ongoing readiness failure, and
a frozen interval at readiness. The initially stopped transfer keeps downtime
absent. The complete Marshall gate remains pending while another full run is
active. Native diagnostic relocation and restored-source deletion runs remain
active and have not yet established full movement or final cleanup acceptance.

The downtime/UI run passes 46 tests. After adding exact receipt-to-readiness
duration, failed-readiness and initially-stopped assertions, the final source
suite passes all 32 tests (`/tmp/kittens-relocation-downtime-final-tests.log`).
Contract syntax and the 52-ADR structure/link check pass. The complete Marshall
gate is now running in `/tmp/kittens-relocation-ui-full-precommit.log` using
test database partition `relocation_final`, after the competing gate exited.

The native phase diagnostics have reached a source-applied baseline descriptor
with the source still running and no destination receipt. This is an intermediate
observation, not yet a terminal diagnosis; the original run remains active.


## Initial receive-worker monotonic deadline defect (2026-09-18)

The diagnostic native run repeatedly publishes source-confirmed baseline permits
without a destination receipt. Source review identified a concrete scheduling
defect: `ReceiveRuntime.init/1` initialized `retry_at` to zero, while admission
requires `System.monotonic_time(:millisecond) >= retry_at`. The BEAM monotonic
epoch can be negative, so a fresh worker could poll forever without starting its
first effect. This affects receive, import, readiness and cleanup modes, not
just SSH transport. `retry_at` now initializes from the same monotonic clock as
all subsequent retry comparisons. No lease duration, fencing or receipt rule
changes; this corrects implementation of carried-forward ADR-0037 recovery.

The regression checks the initial retry clock bounds and delivers the first
leased command for all four modes, requiring an effect task to start. Deliberately
incomplete native configuration makes each synthetic effect fail before host
resources can be touched; the test establishes scheduling, not transfer success.
The complete Lilly gate passes all 268 cases and forced Dialyzer with zero
warnings in `/tmp/kittens-receive-initial-clock-precommit.log`.

The native confirmation snapshot `/tmp/kittens-relocation-clock-89678c0c` is the
existing phase-diagnostic snapshot with only the initial retry deadline changed.
It runs in `/tmp/kittens-relocation-clock-native.log`. The previous diagnostic
run is left running; its observation timeout was not treated as a reason to
restart it. Full relocation acceptance remains unproven.


## Complete Marshall gate and early-cancellation native result (2026-09-18)

`/tmp/kittens-relocation-ui-full-precommit.log` passes 534 cases (50 properties,
484 tests), browser-state checks and forced Dialyzer with one existing documented
upstream exclusion and no unsuppressed findings. This validates the merged
application/UI/progress/downtime tree at that run; the subsequent Lilly initial
retry-clock correction has its separate 268-case zero-warning Lilly gate.

The native restored-source rerun passes the previously failing early-cancellation
cleanup subtest in 273.75 seconds (`/tmp/kittens-restored-delete-native.log`).
The assertion still requires production Driver.delete success and physical
absence; only bounded identical-authority retries were added. Remaining native
guest suite steps are active, so this is scoped evidence, not a full suite claim.
