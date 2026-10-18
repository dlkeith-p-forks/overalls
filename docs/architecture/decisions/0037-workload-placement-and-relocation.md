# ADR-0037: Workload placements and fenced ZFS relocation

- ID: ADR-0037
- Date: 2026-09-16
- Status: superseded
- Implementation: partial
- Components: Marshall Compute, Lilly Control, Lilly VM, shared protocol, NixOS
- Supersedes: ADR-0005, ADR-0035
- Superseded by: ADR-0050, ADR-0149, ADR-0155, ADR-0197

## Context

[ADR-0197](0197-memory-suspension-and-demand-wake.md) replaces only the
memory-migration/stopped-source and cross-host-relay prohibitions where this
record carries them, and extends owner pins with automatic-suspension prevention
and wake. Unrelated requirements and historical rationale remain in force.


[ADR-0155](0155-stopped-only-relocation.md) removes live pre-copy: every move
stops the source and sends one full stream; the `lilly-a` baseline, incremental
streams, temporary headroom and the strategy choice are gone. It carries forward
the fenced authority, cancellation, readiness and cleanup requirements below.
Pre-copy text and evidence in this record are historical.

[ADR-0149](0149-independent-observability.md) replaces application diagnostic
transport, persistence and presentation, with Lilly v4 and Ziggy v2 documents.
It carries forward unrelated authority, isolation, transactional audit/accounting
and recovery requirements. The original rationale and historical evidence follow.

[ADR-0050](0050-usage-based-overcommit.md) replaces the capacity admission and
mutable resource-budget requirements while carrying forward unrelated requirements.
This record preserves the original rationale and implementation evidence.

Admission already considers multiple provisioners and rejects a request when no
eligible fresh pool has capacity. Retained disks currently bind subsequent starts
to the original host. A user needs to move an existing workload between distinct
Lilly machines without losing its disk, identity, sharing or private address.
ZFS backing makes disk replication possible but does not transfer execution
authority, host ownership, memory state or routing automatically.

## Decision

The user approved placement-based relocation, live pre-copy, stopped-transfer
fallback, automatic destination selection, per-relocation SSH credentials and
guest readiness before source removal. This is a fresh-deployment breaking
change: no data conversion, rolling compatibility or host picker is required.

Carry forward ADR-0005 and ADR-0035 except the prohibition on relocation, the
snapshot prohibition inherited from ADR-0031, permanent original placement and
the provisioner v2 requirement. Normal stop/start still retains its placement;
capacity exhaustion still fails immediately. Recovery remains bounded to three
attempts in ten minutes and never silently migrates a workload.

### Identity and authority

Model WorkloadPlacement and Relocation as Ash resources. A VM points to its
current placement and a monotonically increasing execution epoch. Each move,
including a return to a former host, creates a distinct placement. Keep old
placement tombstones permanently. Commands, outcomes, journals, local launch
guards, console access and cleanup bind placement and epoch. Import authority
never grants permission to launch. Use provisioner v3 only in the completed
implementation; remove v2 instead of adding a compatibility path.

Use one per-placement capacity reservation ledger for compute, logical disk and
temporary snapshot headroom. Reserve both destination capacity and one transfer
slot on each participating host before interrupting the source. Order host row
locks by UUID before VM locks. Database constraints and transactions enforce one
current placement and one unfinished relocation per VM. All physical effects are
idempotent and reconciled through durable Oban coordination; Lilly performs
privileged local effects and streaming.

### Transfer and commit

1. Choose an eligible destination with fresh capacity, verified exact immutable
   image artifacts and working authenticated transfer access. Reserve resources.
2. For pre-copy, reserve one extra logical disk size of temporary headroom at
   each endpoint, in addition to normal metadata headroom. Send baseline snapshot
   A while the source runs. If that headroom is unavailable, use a full stopped
   transfer. Do not run an unbounded convergence loop.
3. Invalidate console authority, suppress recovery and persist a source launch
   fence. Request graceful shutdown, retain the forced-stop timeout, then confirm
   no VMM, waiting launcher, mounts or network access remain.
4. Send final snapshot B as A-to-B incremental, or the full stopped snapshot.
   Verify snapshot GUID lineage and the immutable disk descriptor. Import only
   guest disk data; ownership claims, journals, keys and host identity remain
   host-local. Establish destination-local ownership and remove unnecessary
   destination temporary snapshots before activation.
5. Atomically commit the destination placement and new execution epoch with a
   durable activation outbox. Cancellation races this transaction and is allowed
   only before commit. After commit, never automatically restart the stale source.
6. For an originally running workload, boot the destination and wait for a
   challenge-bound vsock readiness response for that placement, epoch and boot.
   A Nix guest service checks multi-user.target, writable root and required
   networking; use a configurable 120-second timeout. This is guest readiness,
   not application health. An originally stopped workload remains stopped and
   requires a verified import instead.
7. Remove the source disk, owned snapshots and transfer artifacts. Confirm
   physical reclamation before releasing disk commitments and completing the
   relocation. Cleanup failure remains charged and retried, including after
   individual Oban jobs exhaust their retries.

Retain source compute through precommit interruption so cancellation can restart
it with fresh fenced authority. Release source compute only after physical stop
and handoff. Cancellation restores the original running/stopped state and leaves
any unreachable destination import fenced with a durable cleanup obligation.
Destination boot/readiness failure after commit retains the fenced source copy;
it does not authorize rollback to a potentially stale disk.

An authorized explicit retry stops the committed destination under a new
generation, confirms physical quiescence, reacquires fresh startup capacity and
enqueues a new destination activation. Its new readiness request has its own
fixed deadline; old failed requests and deadlines remain immutable. Retry request
identity survives repeated user submissions. Delete supersedes an unfinished
retry. No retry changes placement/epoch or authorizes the source to execute.

### SSH and bounded host work

The destination generates a private authentication key for each relocation and
keeps it local. Authenticated Marshall control distributes its public key to the
source. Source host endpoint/key are bound to enrolled host identity and strictly
pinned at the destination. No fleet-wide client key or administrative key reuse.

Use a dedicated restricted SSH fixed-command export endpoint, without shell,
forwarding or caller-supplied paths. Durable expiring permits bind relocation,
peer, placement and snapshot lineage. Renewal and revocation are idempotent;
revocation also terminates and reaps existing stream processes. SSH transport
key exchange is separate from application permit and execution authority.

Stream bounded-memory ZFS send into resumable unmounted receive using a dedicated
helper, not the existing bounded-output command runner. Separate bounded
diagnostics from disk bytes. Transfer-specific locks survive worker death; never
hold the pool observation lock throughout streaming. Unreconciled counters make
only the affected pool unavailable for new admission. Continue control exchanges,
inventory and outcomes. Release transfer slots only when streaming has ceased.

### Other operations and deployment

Serialize start, stop, maintenance and relocation; reject conflicting lifecycle
requests during handoff. Logical Delete supersedes through the coordinator and
cleans every retained placement before VM archival or address release. Preserve
owner, sharing, immutable image, shape, profile and private address. Reconnect
terminals after the destination becomes ready; existing TCP sessions may break.

Nix stages kernel, initrd and manifest for the exact immutable image and installs
the transfer helper, restricted SSH service and guest readiness service. The guest
Nix store travels inside its disk. Independent host updates must preserve durable
transfer and authority state; service restart must not resurrect a fenced source.

## Alternatives

Memory migration couples CPU/VMM/device versions and is unnecessary for disk
portability. Shared storage changes failure and deployment boundaries. Static peer
keys give broader, longer-lived access than a scoped transfer needs. Copy-then-
delete without a fenced authority transaction permits double execution. A second
reservation ledger makes capacity transitions harder to prove atomic.

## Consequences

Relocation includes guest reboot and downtime. Live pre-copy can shorten downtime
but needs conservative extra storage on both hosts. Source cleanup is part of
completion, not best effort. An inaccessible sole source disk cannot be relocated;
this does not provide disaster recovery or automatic evacuation. Keep historical
migrations; apply new schema migrations to fresh verification databases only.

## Invariants and verification

- Three Marshall instances race admission, relocation, cancellation, handoff and
  deletion against shared PostgreSQL without duplicate execution authority.
- Real ZFS and nested Firecracker on two Lilly machines preserve guest-written
  data, boot readiness, address/identity and confirmed source absence.
- Inject failures around each durable phase, lost replies, receive interruption,
  source reboot, stale commands, returning to a former host, cancellation during
  stop and handoff, readiness failure, cleanup failure and host updates.
- Verify full pools select stopped fallback, all retained copies remain charged,
  import-only placements cannot execute, and unrelated pools remain observable.
- Verify unauthorized SSH commands/keys/peers and host-key mismatch fail closed;
  revocation terminates an already established transfer.
- Run all three application precommit gates, ADR/contracts checks, generated
  schema checks and affected Nix machine suites. Distinguish nested-machine
  evidence from independent physical-host acceptance.

## Implementation evidence

The [source-export custody review](../reviews/2026-10-05-source-export-adopted-children.md) records retained leader identity, all-adopted-child waiting across sessions and fail-closed uncertain reaping. Fresh integrated package passed111seconds (2library properties,10integration checks,rustfmt/Clippy), including escaped completion and seven failure paths. Historical selector mutants are scoped to their reached cases. Current consumers, actual ZFS/authenticated SSH and physical transfer-slot acceptance remain open; supersession and partial status unchanged.

The [adopted-child custody review](../reviews/2026-10-05-transfer-stream-adopted-children.md) records
actual native premature-completion counterexamples, repaired expanded package
properties and scoped selector mutations. Source/test identity after integration
is checked separately from exact-helper consumer execution and physical
storage/host acceptance. Accepted rationale and partial status are preserved.


The Audi relocation composition reached committed handoff and destination
readiness but timed out awaiting source cleanup. Its
[review](../reviews/2026-09-17-audi-ingress.md) retains the failed result and scope.
The [source cleanup driver](../../../lilly/lib/lilly/vm/driver.ex) now distinguishes
closed post-tombstone failure stages and pool-lock contention for diagnosis;
this adds no deletion authority and does not establish cleanup acceptance.

Current status remains partial. The evidence below records successive checkpoints;
older statements of unfinished work describe those checkpoints. The latest control
path reaches authenticated final import, atomic placement/epoch handoff with
an activation outbox, a durable destination guest-readiness exchange, and source
retirement with physical deletion evidence. Destination key retirement now gates
completion through an authenticated receipt, with local, HTTPS and three-Marshall
verification recorded in the relocation review.
Cancellation/delete coordination, running full-copy connectivity preflight,
resume/progress and full multi-host relocation acceptance remain outstanding.

[Transfer descriptors](../../../protocol/lib/overalls_protocol/relocation.ex)
validate closed v3 messages, immutable workload identity, distinct endpoints,
epoch progression and snapshot GUID lineage. The explicit `source_dataset_guid`
binds exporter ownership; received snapshot GUIDs establish replicated lineage,
while destination filesystem ownership requires its own locally observed GUID. Their
[tests](../../../protocol/test/relocation_test.exs) cover JSON round trips,
malformed objects, bounds and incoherent lineage. This is a shared codec only;
neither runtime consumes it yet.

[Placement records](../../../marshall/lib/marshall/compute/workload_placement.ex)
and [admission](../../../marshall/lib/marshall/compute/admission.ex) now allocate
an immutable copy identity in the same transaction as the VM and job. The VM's
required current-placement reference is bound to its own VM ID through a deferred
composite foreign key; host/pool values are derived calculations. Composite
references also bind placements to the correct pool host and reservations to the
same placement/VM/host/pool tuple. Historical migrations are preserved.

[Reservations](../../../marshall/lib/marshall/compute/reservation.ex) now use
per-placement uniqueness and include temporary disk commitments in the same
ledger. [Budget arithmetic](../../../marshall/lib/marshall/compute/budget.ex)
credits only placement-keyed physical allocations and separately subtracts
temporary headroom from physical capacity. The executor now derives physical specifications from placement IDs, so ZFS
ownership and allocation observations use those same placement keys. Real machine
verification of the converted paths remains outstanding.

[Operations](../../../marshall/lib/marshall/compute/operation.ex) now persist
immutable placement and execution epoch. Command selection and terminal readiness
require matching current authority; receipts remain associated with the original
placement host. [Physical outcomes](../../../marshall/lib/marshall/compute/outcomes.ex)
bind to the operation's placement, with composite database constraints and
per-placement sequence uniqueness. Delayed source evidence is retained without
mutating current destination state. The v3 envelope now requires explicit
placement/epoch fields and verifies them against the immutable operation. Earlier
control versions and stores are rejected. [Coordination tests](../../../marshall/test/marshall/compute/placement_execution_test.exs)
simulate database handoff and verify stale-command, outcome and receipt behavior;
they do not perform a physical relocation.

[Execution codec](../../../protocol/lib/overalls_protocol/execution.ex),
[client](../../../lilly/lib/lilly/control/client.ex), control endpoints, enrollment,
host/session DB constraints and Nix runtime configuration now require v3. The
command store orders intent by execution epoch then generation, and generated
outcomes carry both placement and epoch. Console payload v1 and image manifest v2
remain separate formats. The [journal](../../../lilly/lib/lilly/vm/journal.ex) now binds host, VM and
placement, durably orders attempts by epoch/generation and retains the epoch of
confirmed running history. Actors discard superseded-epoch asynchronous results;
crash classification requires matching epoch and generation.
The [native guard](../../../lilly/native/launch-guard/src/lib.rs) and
[launch intent](../../../lilly/lib/lilly/vm/intent.ex) now require the exact
placement/epoch/generation and running state. The executor passes command
placement and epoch through every lifecycle driver action; launch-attempt markers
bind the same authority. Old binary formats fail closed. Tests execute the actual
helper to reject stale epochs, mismatched placement, invalid state and unsafe files,
and preserve its shared lock across exec.
[Command stores](../../../lilly/lib/lilly/control/store.ex), actor/journal paths,
physical specifications, units, disks and network device identities now use
placement IDs. Logical VM identity remains in commands and outcomes; private
addresses and MACs still derive from unchanged profile/slot. Unit tests exercise
independent same-VM placements and journals. Console lookup rejects ambiguous
runnable placements. Console controls and updates now require placement and
execution epoch. The relay closes mismatched updates without ingesting bytes or
activating writers, and Lilly requires exact actor authority before attachment.
Late closes and rejected opens cannot detach a different placement/epoch's gate.
[Persisted terminal authority](../../../marshall/lib/marshall/terminal/authority.ex)
and session/writer/mailbox records now bind placement, execution epoch and generation.
Composite foreign keys prevent terminal records referencing another VM's placement.
A changed execution identity invalidates existing sessions, advances writer fences
and resets mailbox relay/payload state. Local input fences
retain placement identity and monotonically ordered execution epoch/generation pairs;
renewed execution requires a newer writer fence. Reopening preserves attempted-input
watermarks, and gates reject authority for another placement or execution epoch.
A return to a former host has not yet been exercised with real guests.

[Disk metadata](../../../lilly/lib/lilly/vm/disk.ex) now resides in the host-local
ZFS ownership index, outside the portable child dataset. Dataset deletion verifies
local metadata and retains it with the tombstone. Dataset contents admit only the
guest disk and a known interrupted-copy temporary file; transferred metadata cannot
serve as local readiness or ownership evidence. The lifecycle machine fixture checks
portable contents, corruption refusal, missing-disk refusal and retained metadata.

[Relocation identity](../../../marshall/lib/marshall/compute/relocation.ex) and
[transfer slots](../../../marshall/lib/marshall/compute/transfer_slot.ex) now persist
immutable copy pairs, successor epochs, initiator/request history and per-host
occupancy. Composite foreign keys constrain each endpoint to its VM and host.
Partial unique indexes allow only one unfinished relocation per VM and one occupied
slot per host across send/receive roles. The host-locked pair allocator reuses exact
occupied slots, rolls back on contention and refuses finished or released history.
The [capacity preparation helper](../../../marshall/lib/marshall/compute/relocation_capacity.ex)
selects a destination from locked hosts, reserves its placement and compute/disk,
occupies both transfer slots, and holds source/destination temporary bytes in the
same enclosing transaction. It prefers pre-copy when both endpoints have one disk
of physical headroom, otherwise selecting stopped transfer. Stopped workloads
reserve disk without compute. Freshness, stable intent, current manage permission,
occupied slots and capacity are rechecked. Source execution authority and existing
compute/disk holds remain unchanged. Physical headroom is calculated separately
from the logical guest-disk cap. These internal helpers now schedule destination
key preparation through the relocation row and its Oban notification. They do not
yet admit user moves or drive disk transfer. Source baseline permit distribution
is connected below. Slot
release remains unavailable until coordinated stream-termination evidence is
implemented.

[Relocation exclusion](../../../marshall/lib/marshall/compute/relocation_guard.ex)
now blocks new ordinary lifecycle intent and endpoint maintenance until relocation
finishes, independently of released stream slots. Exact lifecycle retries may
return their existing operation. Lifecycle rechecks placement/epoch after taking
the VM lock so a move cannot make it mutate under a former host's lock. Current
failure/stop evidence during relocation retains commitments and does not issue
ordinary crash-recovery starts. Delete archival/address release now requires all
placement commitments, including temporary bytes, to be reclaimed; the cleanup
worker that drives remaining copies is still unimplemented.

[Destination key custody](../../../lilly/lib/lilly/transfer/key.ex) now generates a
private Ed25519 key under the local transfer directory and publishes only its public
key after syncing the key, journal and new directory entries. Its host/relocation/
placement binding is permanent. Pending generation is recoverable; ready keys are
never regenerated after loss/corruption, and retirement leaves a tombstone before
removing key files. This does not revoke an already established SSH stream; the
future permit/stream coordinator must confirm that separately. Pinned OpenSSH is
included in production, development and operator-bundle host tools. Tests execute
real key generation and public derivation, but not a peer SSH transfer.

[Guest readiness](../../../nix/domains/artifacts/guest/readiness.py) now has a Nix-installed
vsock listener restricted to host CID 2. Responses bind boot-supplied placement,
epoch and challenge plus the kernel boot ID, and require active multi-user/network
units, expected /32 address/routes and a root write/fsync probe. The
[shared verifier](../../../protocol/lib/overalls_protocol/readiness.ex) rejects
mismatched boot expectations. The [Lilly client](../../../lilly/lib/lilly/vm/readiness.ex)
validates Firecracker's handshake and polls under a single configurable deadline
(default 120 seconds). The [launch driver](../../../lilly/lib/lilly/vm/driver.ex)
persists a [boot record](../../../lilly/lib/lilly/vm/boot.ex) before preparing
Firecracker's configuration and launch-attempt marker. It reuses a challenge only
for retries before that authority has attempted launch, and rotates it for newer
physical boot attempts. The jail passes placement/epoch/challenge into the guest
and configures its private vsock endpoint.

The real guest suite initially found a filtered route query that omitted required
interface fields; a regression also exposed an overly short connection timeout.
Both were corrected. The corrected guest/client suite passed in 697 seconds:
actual nested Firecracker/vsock readiness, stale identity rejection, retained-data
stop/start, abrupt simulated host-loss recovery and independent-neighbor deletion.
The driver now exposes readiness observation with local claim, current intent,
exact boot record and confinement checks before and after waiting, without holding
the placement lock during the socket wait. Its own native guest suite passed in
690 seconds, including wrong epoch/generation refusal, retained data after simulated
host loss and independent-neighbor cleanup. Relocation phase integration and
authority checks before cleanup remain outstanding. Readiness is not application health or cleanup authority.

User admission and atomic job enqueue, atomic terminal invalidation at handoff, Oban coordination,
SSH streaming, ZFS import, readiness integration, cleanup and user actions remain unimplemented.
The [native ZFS parser](../../../lilly/lib/lilly/host/zfs.ex) now accepts snapshot
property rows without converting native not-applicable values to capacity. Its
[regression fixture](../../../lilly/test/fixtures/zfs_snapshot_properties.tsv)
comes from the pinned native ZFS implementation. The native accounting reader now
accepts explicit expected child/snapshot GUID bindings for `lilly-a` and `lilly-b`,
rejecting missing, replaced and additional snapshots. It counts child
`usedbydataset + usedbysnapshots`, including blocks shared by snapshots exactly
once. This is physical observation, not ownership or allocation credit. Production pool observation now derives expectations from local disk claims, a
durable current-journal index and native creation nonces. It still caps physical
credit at the disk commitment; temporary-reservation credit remains unimplemented. Native
parser/tree reads remain bounded to 4 MiB, with at most 4096 child filesystems
and two snapshots per child; exceeding either limit withholds observation.
The [native observation suite](../../../nix/verification/tests/machines/native-zfs/driver.py)
passed this reader against real shared snapshot blocks, wrong/deleted GUID bindings,
strict default rejection and cleanup, alongside its existing policy/pressure and
400-child checks. Fixture-supplied expectations are not production ownership proof.
A [source snapshot journal](../../../lilly/lib/lilly/transfer/snapshot_journal.ex)
now persists the creation nonce before a native effect, binds each snapshot GUID
once and fences both slots before retirement. It supports full stopped transfer
without a baseline, cancellation before generation, and binding an interrupted
create during retirement solely for cleanup. Confirmed deletion retains a permanent
tombstone. Private-file, immutable identity and transition checks are exercised by
[rootless tests](../../../lilly/test/transfer/snapshot_journal_test.exs). This is a
journal primitive: the caller must verify native nonces/GUIDs and physical absence,
hold the pool lock, reserve headroom and prove final-source stop. The [per-placement index](../../../lilly/lib/lilly/transfer/snapshot_index.ex)
now persists initialization before journal publication, refuses missing bound
journals and permits a new relocation only after retirement at a strictly newer
epoch. Historical retired cleanup cannot select a newer journal or delete reused
snapshot names. [Source snapshot effects](../../../lilly/lib/lilly/transfer/source_snapshots.ex)
create with the durable nonce, verify native policy and immutable GUIDs, recover
interrupted creation, and destroy only the exact owned snapshot without recursive
or forced flags. Disk deletion refuses retained snapshots before changing its claim.
[Ownership observation](../../../lilly/lib/lilly/transfer/snapshot_ownership.ex)
joins those records to local disk claims before native accounting and allocation
verification. Unknown markers, missing bound snapshots and replaced GUIDs fail
closed. Application gates pass. The expanded native lifecycle machine suite passed
in 1107 seconds, including actual interrupted snapshot creation/deletion, foreign
marker and replaced GUID rejection, stale cleanup after name reuse, retained disk
content, source reclamation and neighbor preservation. It invokes source-built
Lilly storage APIs in one NixOS machine, without a VMM or remote receiver. These APIs still require
caller-proven execution authority, pool locking, reserved headroom, physical stop
for the final snapshot and stream quiescence for cleanup. No Oban/runtime caller
provides those prerequisites yet. Pool observation errors now become explicit
unavailable entries carrying configured identity and no capacity counters or credit.
The shared protocol validates their closed schema, Marshall matches enrolled
identity and clears only that pool's freshness/credit, and telemetry records
retained physical counters as unknown. Every enrolled pool must still be present;
missing, duplicate, mismatched and stale reports remain rejected. Focused tests
verify neighboring-pool admission, retained reservations and recovery. All three
application gates pass, including forced consumer Dialyzer.

A [destination import journal](../../../lilly/lib/lilly/transfer/import_journal.ex)
now persists a destination-local nonce and immutable endpoint/workload/epoch,
source filesystem and local pool identities before receive. It binds the local
filesystem GUID once, separately from the source GUID. Full stopped imports omit
baseline lineage; pre-copy permits only a received baseline's exact incremental
successor. Completion requires the exact stream/target snapshot and bound local
GUID, with native staging policy, stream termination and resume-token absence
remaining caller obligations. Retirement fences future preparation/completion and
retains exact deletion tombstones, including cancellation before receive. Rootless
tests verify these transitions and rejection of unsafe/malformed state. Lilly's
full gate passes 162 cases; the dependent Marshall gate passes 282 cases and six
JavaScript tests. Both forced Dialyzer gates pass. The native staging verifier now consumes this journal; receiver command
coordination, import ownership adoption, activation and Oban integration remain
unimplemented. Missing local state cannot be reconstructed from received
properties; new preparation requires caller-proven native absence.

A [native transfer suite](../../../nix/verification/tests/machines/zfs-transfer/driver.py) now
passed native baseline and incremental interruption/resume, full stopped transfer,
abort of incomplete receive, mismatched-lineage refusal and ext4 contents after
nonrecursive source reclamation. It uses two block-backed pools within one outer
machine; it does not exercise Lilly/Oban or SSH orchestration. Destination import ownership and policy remain explicit implementation gaps. The
[implementation review](../reviews/2026-09-16-workload-relocation.md) records
reconstructed feasibility findings, implementation evidence and remaining gaps;
its recovery note distinguishes reconstruction from the original review prose.

The [native streaming helper](../../../lilly/native/transfer-stream/src/lib.rs) and
[Lilly wrapper](../../../lilly/lib/lilly/transfer/stream.ex) now connect trusted
absolute producer/receiver argv through a kernel pipe without sending disk bytes
to the BEAM. A separate stable transfer lock spans both process groups; deadlines,
caller EOF, diagnostic overflow and child failure kill and reap both sides before
exit. Leader PIDs remain unreaped until cleanup to prevent group-ID reuse, and
subreaper behavior retains ownership until descendants exit. Diagnostics are
bounded and discarded. The Nix host-tools package builds/installs the helper with
the same strict compiler flags as existing helpers. Rootless tests pass 64 MiB
content/hash preservation, caller-death and deadline cleanup, native contention,
child failure and input/diagnostic bounds. The expanded real ZFS transfer check
passed in 43.34 seconds, including helper-backed receive, caller EOF during partial
receive, successful resume and matching raw disk hashes. This uses two block-backed
pools in one NixOS machine. Both consumer gates pass with forced Dialyzer. The
helper is not yet connected to expiring SSH permits, native destination
ownership verification, local transfer actors or Oban coordination. Native exit
success alone does not authorize activation, handoff or source cleanup.

[ReceivedDataset](../../../lilly/lib/lilly/transfer/received_dataset.ex) now verifies
an existing destination-local journal under caller-held pool ownership before
recording receipt. It matches destination host/pool/placement and local creation
nonce, refuses active/deleted ordinary claims, binds the destination GUID once,
and checks exact snapshot lineage through
[ZFS.receive_child/4](../../../lilly/lib/lilly/host/zfs.ex). The native read requires
read-only, unmounted, noauto staging with local exec/setuid/devices=off, no remaining
resume token, no mount alias/extra descendant and unchanged parent/backing identity.
Repeated verification rechecks native state even after a recorded receipt. Retained
import history blocks blank-disk provisioning and reconstruction of a missing
parent owner record; existing import roots must be private directories. New
Nix cases passed these requirements, copied-marker/GUID substitution and retained
import-history fences. The full native transfer suite passed in 94.31 seconds;
application gates passed 169 Lilly and 282 Marshall cases plus forced Dialyzer. This is not rootfs shape/image validation, allocation
credit or executable disk adoption. The caller must still prove current relocation
and reservation authority plus stream quiescence before verification.

The destination verifier now also exposes guarded import preparation. It verifies
local destination/parent binding, excludes ordinary claims and requires native
absence for new intent. Incremental preparation rechecks native baseline lineage
before advancing the journal. The native fixture uses this entry point; expanded
machine validation passed in 115.45 seconds, including full-transfer retries,
missing-journal refusal and baseline-to-incremental advancement with foreign
snapshot rejection. Lilly and Marshall precommit passed. Preparation remains separate from permit
authority, transfer execution and disk adoption.

Destination [disk adoption](../../../lilly/lib/lilly/vm/disk.ex) now verifies the
exact local image and delegates to a durable
[dataset adoption path](../../../lilly/lib/lilly/host/zfs_dataset.ex). Import-only
claim states precede snapshot pruning, mounting and writable-policy publication;
ordinary provisioning rejects those states. Only a verified final receipt can
create them, and every retry retains its destination-local nonce/GUID. Rootfs
shape and destination-local disk markers must validate before the claim becomes
ready. The native transfer suite passed in 199.27 seconds, including full-stream
adoption after actual interrupted snapshot/mount/property effects, mount loss,
retained disk hash, ordinary reuse and missing-disk non-recreation. Lilly and
Marshall precommit passed. An expanded native run passed in 286.84 seconds,
including baseline/incremental disk adoption, caller death between B/A snapshot
removals, unknown-snapshot refusal, final disk hash and adopted-neighbor preservation.
The fixture uses synthetic boot artifacts and does not establish guest activation. Production relocation coordination remains unimplemented. A local cancellation
cleanup entry point now fences import claims and journals, aborts owned incomplete
receive state, removes exact known snapshots and the child without force/recursion,
and confirms native/mount absence before permanent tombstones. The full native
suite passed interrupted full/incremental receive cleanup, cancellation after
interrupted adoption/unmount, ready-copy cleanup and neighbor preservation in
457.05 seconds; both application precommit gates passed. Current
cancellation/deletion authority and stream/VMM quiescence
remain caller prerequisites; reservation release and coordinated cancellation are
not implemented by local cleanup.

Operator enrollment now accepts a closed pinned SSH endpoint through the shared
[transfer identity codec](../../../protocol/lib/overalls_protocol/transfer_ssh.ex)
and a [validated Ash type](../../../marshall/lib/marshall/compute/transfer_endpoint.ex).
The host stores it independently of rotating control credentials; reports and
sessions cannot replace it. Relocation capacity preparation rejects endpoints
without enrolled identity. All three application gates and Ash schema consistency
passed; operator-file tests cover pin retention across credential rotation and
rejection of replacement through ordinary configuration. Connectivity,
distribution to Lilly, dedicated Nix SSH
service configuration and permit-bound export remain unimplemented.

A [pinned destination SSH client](../../../lilly/lib/lilly/transfer/ssh.ex) now
joins existing per-relocation key custody to the native streaming helper. The
key journal binds the enrolled peer before publishing private known-hosts data.
The client excludes ambient SSH configuration, agents, forwarding and shared
connections. A new [native SSH fixture](../../../nix/verification/tests/machines/ssh-transfer/default.nix)
passed real authentication, 32 MiB integrity, wrong-host/client-key rejection
before export, and retired-key refusal in 27.29 seconds. Lilly and Marshall
precommit passed, including forced Dialyzer.
This does not implement the source export service, permits, resume-token exchange
or coordination, and does not prove remote process quiescence.

Read-only source export selection now verifies the closed descriptor against the
ready local disk, existing parent ownership and active relocation snapshot index
before returning locally derived send arguments. Baseline/full/incremental GUID
lineage and native nonces/policy must match. The dedicated native source-export
check passed all three send forms, stale epoch/GUID rejection, missing-parent
refusal without repair, foreign-snapshot refusal and export refusal after cleanup
in 381.96 seconds. Both application precommit gates passed. This entry point is
not a permit and remains unconnected to production export authorization.

The [source permit issuer](../../../lilly/lib/lilly/transfer/permit.ex) now
revalidates physical ownership before each durable lease. Its
[permit journal](../../../lilly/lib/lilly/transfer/permit_journal.ex) binds peer
key and descriptor identity, enforces increasing revisions and bounded expiry,
permits only matching baseline-to-incremental advancement, and retains permanent
revocation fences even before issuance. Both application gates passed. The native
source-export suite passed issuance, missing-ownership renewal refusal, matching
incremental advancement, old-phase rejection and fencing before/after issuance
in 468.41 seconds. Lookup is not a launch transaction,
and fencing is not active-channel revocation. Runtime expiry, process termination,
authenticated distribution and the source SSH service remain unimplemented.

The [export request boundary](../../../lilly/lib/lilly/transfer/export_request.ex)
now accepts only the exact fixed SSH verb, relocation UUID and closed stream
kind, then resolves the request against the authenticated peer's local permit.
It rejects alternate whitespace, shell syntax and extra arguments without
normalization. Rootless tests exercise the actual client's request grammar and
wrong-peer/host/phase, expiry and revocation refusal. This remains a read-only
boundary: production SSH identity delivery, serialized launch registration and
active sender supervision are still outstanding.

The subsequent [source export supervisor](../../../lilly/lib/lilly/transfer/source_export.ex)
now serializes native sender registration against permit mutation and pool
ownership checks. The [native exporter](../../../lilly/native/source-export/src/lib.rs)
streams inherited stdout directly, enforces a monotonic lease and retains its
stable lock until sender descendants are reaped. Its
[wrapper tests](../../../lilly/test/transfer/exporter_test.exs) cover byte isolation,
revocation, native expiry during stalled BEAM supervision, renewal, caller death,
lock contention and bounded diagnostics. Permanent key bindings and confirmed
revocation have [journal tests](../../../lilly/test/transfer/permit_journal_test.exs).
The export request boundary can now generate a restricted OpenSSH authorized-key
line binding the forced command to the selected public key. These entry points
still require trustworthy installed SSH identity delivery and authenticated
coordinator inputs. Earlier statements about absent supervision describe the
preceding implementation increments, not the current code. Native test execution
and its limits are recorded in the relocation review; integrated relocation
remains unimplemented and this ADR remains partial.

The [installed source module](../../../nix/domains/system/transfer.nix) now supplies a
dedicated restricted SSH listener, root AuthorizedKeysCommand and a private
socket-activated worker. Its [native channel](../../../lilly/native/export-channel/src/lib.rs)
passes the authenticated stdout descriptor from the fixed SSH bridge to the root
worker; it checks local peer credentials and returns completion separately from
disk bytes. The [endpoint](../../../lilly/lib/lilly/transfer/endpoint.ex) selects
its pool from private local configuration and the live permit before invoking
the existing export supervisor. The transfer account is denied on ordinary SSH,
and helpers remain non-setuid. Export services have their own bounded slice and
use the host-selected ZFS userspace. Lilly's Nix module can generate the private
export configuration when the optional service is enabled. The
[two-node endpoint check](../../../nix/verification/tests/machines/export-endpoint/default.nix)
passed native transfer, arbitrary-command refusal, listener-stop cancellation,
confirmed source revocation and cleanup with the received snapshot retained.
It uses synthetic control distribution and does not establish destination
adoption or guest relocation. Authenticated control distribution and relocation
coordination remain outstanding; details and executed results are in the review.

The optional deployment described above is historical. [ADR-0071](0071-required-lilly-transfer.md)
now requires the restricted service on every enabled Lilly host; its
[review](../reviews/2026-09-18-required-lilly-transfer.md) separates configuration
validation from pending production activation and endpoint registration.

The [destination key control exchange](../../../marshall/lib/marshall/compute/relocation_keys.ex)
now polls unfinished relocation rows through authenticated, current v3 host
sessions. Capacity preparation retains the source's enrolled pin in the immutable
relocation record and creates an Oban notification job in the same transaction.
The [Lilly key worker](../../../lilly/lib/lilly/transfer/key_runtime.ex) creates or
reuses its durable local key, binds that pin, and returns only the public key.
Commands and results bind the destination placement and execution epoch.
Matching results are idempotent; conflicting keys and foreign/stale sessions
cannot replace them. The optional runtime worker is separate from execution and
inventory work and stops when control is fenced. HTTPS integration tests exercise
the actual worker, OpenSSH key generation and PostgreSQL API together; they do
not establish source permit distribution or disk movement. Key preparation is
the first connected coordination phase. User relocation admission, subsequent
phase coordination and end-to-end guest movement remain incomplete.

The [source request exchange](../../../marshall/lib/marshall/compute/relocation_sources.ex)
now persists immutable snapshot/permit requests after destination key
publication. Requests retain revision, expiry, source generation and placement
identity; renewals pin an already observed snapshot GUID. Current source sessions
receive them only while source execution intent, reservations and both transfer
slots remain valid. Exact results are idempotent and conflicting batches roll
back. Results establish historical snapshot/permit facts, not completed receive
or continuing lease validity.

The [source worker](../../../lilly/lib/lilly/transfer/source_runtime.ex) polls
independently of ordinary execution. Its [effect boundary](../../../lilly/lib/lilly/transfer/source.ex)
matches the retained command and driver intent before native snapshot creation
and permit publication. Originally stopped workloads receive full requests while
their stopped intent/observation, disk commitments and transfer slots remain
valid, without reserving compute or pre-copy headroom. Final-stream requests require confirmed stopped execution
and an exclusive stream lock; initial export preparation grants no access and
cannot repair corrupt or revoked authority. Marshall produces baseline requests
for running pre-copy and full requests for originally stopped workloads.
The pre-copy stop and final incremental control path is described below.
Handoff, activation and complete guest-movement acceptance remain unfinished.

The destination's [receive command builder](../../../lilly/lib/lilly/transfer/received_dataset.ex)
now requires existing active receiving intent and rechecks local/native staging
under the pool lock. It derives fixed resumable, unmounted, read-only receive
arguments and local ownership markers from that intent and the trusted pool.
Returning arguments does not start a transfer, verify its completion or authorize
adoption. The [destination receive entry point](../../../lilly/lib/lilly/transfer/receiver.ex)
now joins preparation, pinned SSH streaming and native receipt verification.
A relocation activity lock serializes attempts; separate stream/pool locks protect
short preparation and receipt checks. Streaming runs in a linked child without a
pool lock. A duplicate completed receive revalidates its local/native identity
without streaming again.

The [destination receive exchange](../../../marshall/lib/marshall/compute/relocation_receives.ex)
now offers the latest source-confirmed descriptor only while its permit remains
live and source intent, placement, shape, address, reservations and slots still
match. Source descriptor publication enqueues a durable destination notification.
Authenticated current destination sessions may record the matching local dataset
GUID; conflicting batches roll back and all revisions retain one destination
filesystem identity. Expired historical receipts may record facts without
reissuing expired work. The migration adds a nullable receipt field to retained
source requests. HTTPS/PostgreSQL integration exercises the real Lilly client
and verifies that receipt does not move authority or release holds. The
[receive runtime](../../../lilly/lib/lilly/transfer/receive_runtime.ex) polls
independently while one native receive runs, retains bounded pending receipts and
uses a monotonic lease deadline. Only the same descriptor/pin with nondecreasing
signed expiry may extend that deadline. Fencing or expiry stops the task; it does
not release capacity or claim physical cleanup. The ordinary control runtime
starts and stops this worker with its authenticated session. Runtime HTTPS tests
prove polling/fencing with no native pool configured; the separate two-node native
pipeline proves disk staging. Combined Marshall-driven native relocation,
interrupted-stream resume coordination, cancellation and later phases remain open.

[ADR-0046](0046-porsche-ssh-management.md) adds durable SSH request receipts over
these existing actions. The [operation resource](../../../marshall/lib/marshall/compute/operation.ex)
and [outcome coordinator](../../../marshall/lib/marshall/compute/outcomes.ex) now
pin the first applied terminal outcome. Receipt polling checks its immutable
operation/VM/placement/epoch/generation binding and requires archival for deletion
success. This extends outcome evidence without changing placement authority or
reclamation rules; late/reordered observations cannot replace the pinned result.


The [relocation coordinator](../../../marshall/lib/marshall/compute/relocation_coordinator.ex)
now stops a running pre-copy source only after a confirmed destination baseline,
fresh ready hosts with the immutable image, unchanged source authority, and both
reservations and transfer slots. It locks endpoint hosts in UUID order before the
VM, then atomically fences consoles, increments generation, enqueues a relocation
stop operation and records its source placement/epoch/generation reference.
Source compute and disk remain held. The source exchange issues the final
incremental request only after the exact operation retains a matching immutable
physical stopped outcome with compute empty and disk present. It pins the received
baseline GUID and preserves the destination filesystem identity through final
receipt. [Database tests](../../../marshall/test/marshall/compute/relocation_sources_test.exs)
exercise this transition and reject missing receipt, stale host reports, missing
image and changed generation. This is control-plane evidence, not a combined
native guest move. Running full-copy fallback still requires an authenticated
connectivity preflight before stop; admission/UI, handoff/activation, cancellation,
cleanup and full failure acceptance remain incomplete.


The [import exchange](../../../marshall/lib/marshall/compute/relocation_imports.ex)
now records adoption intent before offering a renewable control lease for a
received final descriptor and local filesystem GUID. Its separate
[wire codec](../../../protocol/lib/overalls_protocol/relocation_import.ex) rejects
baselines. The [importer](../../../lilly/lib/lilly/transfer/importer.ex) matches
configured pool/image and pinned peer, excludes receive activity and streams,
then uses the ordinary placement lock to prove absent execution authority and
quiescent unit/jail/network state. Exact local journal identity precedes disk
adoption; verified adoption publishes destination-local VM ownership so ordinary
activation can reuse the existing disk. No launch intent is created. Its independent worker keeps polling during effects and applies the
same monotonic lease/fence rules as receives. Final receipt suppresses further
stream work, so import retries after snapshot pruning never restart receiving.

The coordinator now requires retained final adoption evidence before atomically
switching placement/epoch, incrementing generation, resetting observation state,
recording commit references and enqueueing destination activation. Composite
foreign keys bind the activation to its destination authority and the import to
its relocation. Source compute and pruned destination temporary headroom are
released in that transaction; both disks and source temporary snapshots remain
charged. An originally stopped workload receives a stop activation. Database
tests cover both states, duplicate coordinator calls, activation outbox and
late source observations. Nine concurrent handoff calls across three independent
Marshall peers converge on one successor epoch and one activation job. HTTPS tests cover real Lilly client and import-worker
polling/fencing without fabricating native execution. The expanded native
importer fixture passed full/incremental adoption faults, local VM ownership
publication, ordinary stopped activation, post-activation import refusal and
retained data. This storage fixture uses synthetic boot artifacts and does not
establish a bootable guest move. Destination activation delivery
and readiness, cancellation races and source cleanup still require integration
and full acceptance evidence.

The [readiness request](../../../marshall/lib/marshall/compute/readiness_request.ex)
binds one immutable deadline to the activation operation, generation and final
descriptor. The [state coordinator](../../../marshall/lib/marshall/compute/relocation_readiness_state.ex)
requires the exact destination's retained physical activation outcome before
creating it. A running VMM alone is insufficient: the
[authenticated exchange](../../../marshall/lib/marshall/compute/relocation_readiness.ex)
accepts only an offered request's matching guest boot UUID. Duplicate receipts
are idempotent; conflicting boot UUIDs fail, and late receipts cannot revive a
timed-out request. Originally stopped workloads require physical stopped evidence
and no guest probe. Neither case releases source storage.

The [Lilly probe](../../../lilly/lib/lilly/transfer/readiness_probe.ex) binds the
request to its retained destination start command and calls the driver's existing
challenge-bound vsock verifier. Local command and confined execution are checked
before and after waiting. The independent worker renews control authority without
resetting the native probe deadline. Terminal admission remains closed until
Marshall retains readiness for that same activation. Configure
`MARSHALL_RELOCATION_READINESS_TIMEOUT_MS` in Marshall's runtime environment
(including its Nix service environment file): default `120000`, valid range
`1..600000`. The deadline is measured from the immutable activation outcome and
does not reset on coordinator or worker retries. Database tests cover running,
stopped, duplicate, mismatched and expired receipts; native verification and
transport evidence are recorded in the relocation review. Source cleanup and a
complete Marshall-driven guest move remain unfinished.

The [cleanup coordinator](../../../marshall/lib/marshall/compute/relocation_cleanup.ex)
now creates a durable [source obligation](../../../marshall/lib/marshall/compute/cleanup_request.ex)
only after destination readiness. Its [closed wire format](../../../protocol/lib/overalls_protocol/relocation_cleanup.ex)
fixes the source descriptor and stopped generation. The independently leased
[Lilly worker](../../../lilly/lib/lilly/transfer/source_cleanup.ex) matches its
retained source command, permanently revokes and reaps exports, fences launch,
retires exact snapshot GUIDs and uses ordinary guarded disk deletion. It can
retry after claim metadata moves into the retained deletion tombstone; missing
ownership or a mismatched descriptor never reconstructs a cleanup claim.

The cleanup receipt queues a normal source delete operation at the next source
generation. This lets the ordinary actor publish and acknowledge a deleted
physical outcome and retire its active command. The provisioner selector permits
this narrowly bound operation for the superseded source placement; ordinary
stale operations remain suppressed. Source outcomes complete only this operation
and never replace destination state. The coordinator requires its exact retained
deleted outcome before releasing source disk/temporary reservations and both
stream slots, then marks the relocation finished without archiving the VM or
releasing its address or destination resources. Once cleanup intent exists, its
irreversible obligation remains retryable if the destination subsequently fails.

Database tests cover both original states, receipt replay and mismatch, unknown
source outcomes, delayed release and unchanged destination authority. HTTPS
tests exercise the real client, source deletion delivery and worker/session
fencing. Native verification is recorded in the relocation review; the separate
fixtures still do not establish a complete two-Lilly guest relocation. Cancellation,
logical Delete across all copies, key retirement, full-copy preflight, public
admission/UI and complete multi-host acceptance remain unfinished.

## Open questions

None blocking implementation. Independent physical-host and production workload
acceptance remain environment-specific obligations.

## Related decisions

[ADR-0061](0061-maintenance-evacuation.md) adds fixed-cohort evacuation admission
and campaign-bound source eligibility, reusing this decision's transfer and cleanup
semantics. Ordinary user relocation retains normal-host admission.

- [ADR-0005](0005-vm-lifecycle-and-storage.md)
- [ADR-0035](0035-zfs-only-provisioning.md)
- [ADR-0010](0010-capacity-admission-transactions.md)
- [ADR-0017](0017-durable-vm-actors-and-host-ownership.md)
- [ADR-0019](0019-terminal-session-and-writer-authority.md)
- [ADR-0026](0026-host-maintenance-and-retirement.md)
- [ADR-0033](0033-nixos-machine-verification.md)
- [ADR-0036](0036-automatic-host-updates.md)

[ADR-0045](0045-declarative-lilly-enrollment.md) replaces the inherited ADR-0012 one-year credential ceiling and adds retryable operator enrollment preparation; placement and relocation requirements remain unchanged.


Destination credential retirement is now coordinated by
[RelocationKeyRetirement](../../../marshall/lib/marshall/compute/relocation_key_retirement.ex).
Confirmed source deletion creates a durable key-retirement obligation; only an
offered receipt from the destination placement and epoch permits final release.
[Lilly's key runtime](../../../lilly/lib/lilly/transfer/key_runtime.ex) excludes
receive/adoption and native stream activity before permanently retiring local key
material. Duplicate receipts and tombstone retries are idempotent. The
[focused tests](../../../lilly/test/transfer/key_runtime_test.exs) exercise actual
key erasure, transfer-lock exclusion and refusal to regenerate retired credentials.
This does not establish complete multi-host relocation acceptance.


Cancellation now has an authorized
[request boundary](../../../marshall/lib/marshall/compute/relocation_cancellation.ex)
through `Compute.cancel_relocation`. It serializes with handoff under both endpoint
host locks and the VM lock, rechecks current manage permission, and persists the
first requesting user/time with an atomic reconciliation job. PostgreSQL forbids
cancellation intent together with committed destination authority. New key, source,
receive and import offers stop; retained late physical receipts remain acceptable.
This is cancellation **intent**, not completed cancellation: native revocation,
source restoration under fresh authority and destination reclamation remain
unimplemented, and all obligations remain charged while it is pending.


Cancellation source revocation now connects
[authenticated control](../../../marshall/lib/marshall/compute/relocation_revocations.ex)
to [Lilly's local effect](../../../lilly/lib/lilly/transfer/source_revocation.ex).
It permanently fences the source permit and requires confirmed sender quiescence
before an identity-bound receipt. Offered/completed timestamps remain durable;
receipt alone cannot restore source execution or release commitments. Local, HTTPS and extended native endpoint checks passed. The native suite
confirmed source sender absence while its listener remained active; its blocked
destination consumer exited at its fixture deadline, so remote cancellation is
not implied by the source receipt.
Cancellation source restoration, snapshot cleanup and destination reclamation are
still unfinished, so the complete cancellation workflow remains partial.


[Cancellation restoration](../../../marshall/lib/marshall/compute/relocation_restoration.ex)
now advances the retained source to fresh execution authority after export
revocation, using a confirmed stop before any restart. It restores original
running/stopped intent only through exact completed physical outcomes and retains
all cleanup commitments. Source outcome sequences remain placement-global across
the epoch change. Focused control-plane tests passed; distributed/full gates and
native cancelled-source boot evidence are recorded separately in the review.
Snapshot and destination reclamation, restoration-failure retry, and the complete
cancellation workflow remain partial.

Cancelled destinations now have an independent
[revocation exchange](../../../marshall/lib/marshall/compute/relocation_destination_revocations.ex)
and [local effect](../../../lilly/lib/lilly/transfer/destination_revocation.ex).
The effect retires the key before trying receive/stream locks, retains its fence
on busy retries, and returns only after local transfer quiescence. Receive and
import recheck the key after taking their locks, preventing cached paths from
reviving cancelled work. Existing bounded work may finish before quiescence is
confirmed; the receipt does not establish destination disk reclamation.
Cancellation releases stream slots only after both source and destination receipts,
independently of disk cleanup. Successful-move slot release still awaits refinement.
Application and native verification are recorded in the review; destination copy
reclamation and the complete workflow remain partial.

The native guest suite now verifies cancellation of a running baseline source:
fresh-epoch stop/restart, a distinct challenge-bound ready boot, retained data and
GUIDs, stale-epoch launch refusal, and snapshot-only cleanup while running. The
successful artifact and scope are recorded in the relocation review. That run
used synthetic control and direct snapshot cleanup; production cleanup-effect
acceptance and a complete Marshall-driven cancellation remain pending.

Cancelled sources now have a separate
[snapshot cleanup exchange](../../../marshall/lib/marshall/compute/relocation_snapshot_cleanups.ex)
and [local effect](../../../lilly/lib/lilly/transfer/source_snapshot_cleanup.ex).
Offers require recorded source restoration; the effect matches successor-epoch
local execution, revokes exports, retires locally journaled snapshots and verifies
native absence without deleting the source disk. It does not require a received
stream descriptor. Snapshot receipts remain separate from destination reclamation
and permit the coordinator to release only source temporary headroom. Source
disk/compute and destination commitments remain held. Application and native verification for this
increment is recorded in the review; the full workflow remains partial.

Destination storage cleanup can now recover its stream descriptor from validated
private local history through
[ImportJournal.for_intent](../../../lilly/lib/lilly/transfer/import_journal.ex)
and [ImportCleanup.cleanup_intent](../../../lilly/lib/lilly/transfer/import_cleanup.ex).
Missing history permits only verified absence, without fabricated stream GUIDs.
This storage primitive requires independent transfer/launch fencing and quiescence.
Verification scope and the interrupted native runs are recorded in the review.

The local [destination cleanup effect](../../../lilly/lib/lilly/transfer/destination_cleanup.ex)
now combines permanent key retirement, never-activated placement deletion fencing,
transfer exclusion and intent-based storage reclamation. Its driver guard rejects
prior execution intent and retains tombstones on failed cleanup. The native storage
fixture passed its interrupted-effect and activated-copy rejection checks. The
[authenticated exchange](../../../marshall/lib/marshall/compute/relocation_destination_cleanups.ex)
records destination reclamation separately from stream revocation. Cancellation
completion now releases destination reservations only after source restoration,
both copies' required cleanup and both stream revocations; source workload identity
and resources remain retained. The review records application gate results and
remaining integrated guest/failure acceptance, restoration retries and logical Delete.

Ordinary start/stop and bounded crash recovery now resume on the restored source
or ready committed destination while retained-copy cleanup remains pending.
[Lifecycle exclusion](../../../marshall/lib/marshall/compute/relocation_guard.ex)
keeps initial readiness/restoration, another relocation and maintenance protected.
Retained readiness survives later generations on that same placement/epoch, so
subsequent stop or failure cannot strand source cleanup. Lifecycle cancellation
preserves the old copy's exact cleanup operation. Current terminal start/outcome
checks remain enforced. Logical Delete still needs its all-copy coordinator.

Failed cancellation starts now use a bounded restoration retry cycle: a current
failed receipt with a retained disk can issue a fresh stop, clear the prior start
reference and charge the existing three-per-ten-minute recovery budget. Another
start requires that new stop's physical proof. Unknown/missing-disk evidence and
budget exhaustion preserve pending restoration and reservations. Future timestamps
remain charged; periodic reconciliation can retry after budget expiry. The review
records application checks and remaining integrated failure acceptance.


Committed handoffs now also qualify for the existing source and destination
revocation exchanges. The coordinator can release transfer slots after both
independent quiescence receipts, before guest readiness or old-disk reclamation,
while preserving all disk commitments and unfinished-copy exclusions. Pre-handoff
active transfers remain ineligible for revocation. The relocation review records
the new constraint migration, application checks and outstanding integrated acceptance.


Logical Delete now binds its idempotent user operation to the unfinished relocation
under both endpoint host locks and the VM lock. Before handoff it supersedes
restoration while retaining independent staging cleanup; after handoff it permits
old-source cleanup despite failed readiness and preserves already-issued cleanup
operations. Only current-copy deleted evidence, independent old-copy reclamation,
transfer revocation and all retained commitments reclaimed permit VM archival and
address release. Lilly can retire source snapshots under exact terminal Delete
intent so the ordinary delete revision can finish. The relocation review records
the new migration, first passing checks and pending distributed/native acceptance.


Late relocation receipt handlers now lock the retained VM through its history read,
including after archival, while active command selection retains ordinary visibility
and authority checks. This reconciles receipt serialization with logical Delete's
archival boundary. The review records focused and distributed lock evidence; it
is not proof of complete multi-host guest relocation.

### Probe-only lease foundation (2026-09-17)

The [source permit journal](../../../lilly/lib/lilly/transfer/permit_journal.ex)
now supports a short-lived probe state containing the relocation intent, public
key and challenge without invented snapshot GUIDs. Its shared durable key index
and permanent revocation fence cover probe and export states. Only a full export
with identical intent and key can replace a probe; existing export lookups reject
probe records. The [journal tests](../../../lilly/test/transfer/permit_journal_test.exs)
exercise expiry, wrong identity/challenge, renewal, missing key index, permanent
revocation and transition restrictions. This is a local storage foundation only:
SSH probe authentication/response, destination effect, typed control exchange and
Marshall's pre-stop guard remain unimplemented. ADR-0037 remains partial.

### Restricted probe endpoint (2026-09-17)

[Probe request parsing](../../../lilly/lib/lilly/transfer/probe_request.ex) and the
[installed endpoint](../../../lilly/lib/lilly/transfer/endpoint.ex) now accept a
separate fixed probe verb with relocation/challenge UUIDs. AuthorizedKeysCommand
resolves either a live export or probe through the durable key index and returns
the same restricted forced command. The authenticated worker rechecks the exact
probe grant and configured pool before writing one challenge line, without
inspecting native storage. Export requests still require snapshot descriptors.
Focused tests cover authorization formatting, dispatch, invalid commands, missing
key index and revocation. They call the endpoint locally and do not establish real
OpenSSH possession or connectivity. Native SSH verification, destination effects,
control exchange and Marshall's stop guard remain outstanding.

### Destination probe client (2026-09-17)

The [SSH client](../../../lilly/lib/lilly/transfer/ssh.ex) now runs a bounded probe
using its existing relocation key, pinned source key and native stream owner lock.
It uses identical SSH restrictions and a fixed `cmp` consumer to require the exact
challenge line and successful SSH exit; received bytes are not persisted or passed
to BEAM. A local expected-response file contains only the canonical public
challenge. Both source-built and bundled host tools include pinned diffutils.
The [installed endpoint fixture](../../../nix/verification/tests/machines/export-endpoint/driver.py)
now tests probe-only authentication, wrong challenge, export refusal and revocation;
its native run is pending. Control exchange, current-authority checks and Marshall's
pre-stop decision remain outstanding, so this helper alone does not enable moves.

### Probe control vocabulary (2026-09-17)

The [probe codec](../../../protocol/lib/overalls_protocol/relocation_probe.ex)
defines separate source `grant` and destination `probe` commands. Each binds the
immutable intent, source generation, public key, challenge, revision and expiry;
only the destination phase carries a pinned source endpoint. Correlated results
include phase and lease identity, so a grant acknowledgement cannot substitute for
a connectivity result. The closed v3 exchange bounds batches to sixteen unique
requests. [Boundary tests](../../../protocol/test/relocation_probe_test.exs) cover
round trips, result substitution, malformed fields and collection/version limits.
This vocabulary is not yet connected to a Marshall outbox or Lilly control loop;
current-authority and freshness checks remain consumer obligations.

### Authenticated probe effect (2026-09-17)

The [Lilly probe effect](../../../lilly/lib/lilly/transfer/probe.ex) now consumes
the typed commands. Source grants require the exact retained running command,
workload and driver claim under the placement lock before journal publication;
no snapshot or stop occurs. Destination probes check the command's public key
against the existing verified key before invoking the pinned SSH helper. Both
phases enforce locally bounded lease time before effects and before receipts.
[Effect tests](../../../lilly/test/transfer/probe_test.exs) cover missing/stale or
terminal source authority, role mismatch, invalid leases, wrong destination keys
and retired credentials. Positive source execution and delivery through the live
control loop remain unverified; Marshall outbox and stop wiring are still absent.

### Probe runtime and native SSH verification (2026-09-17)

The [control client](../../../lilly/lib/lilly/control/client.ex) validates probe
responses against the current host/session and each command's role. The
[control runtime](../../../lilly/lib/lilly/control/runtime.ex) starts and fences a
separate [probe worker](../../../lilly/lib/lilly/transfer/source_runtime.ex), retaining
bounded unacknowledged results independently of ordinary execution exchanges.
[Local HTTP tests](../../../lilly/test/lilly/control/probe_client_test.exs) cover
host/session/acknowledgement confusion and retired worker fencing.

The installed endpoint suite passed real pinned SSH probe success, wrong challenge,
probe-only export refusal and permanent revocation across two NixOS machines
(682.06s; artifact `xfyvfww817ngyji83ad1jnwiq74i5sxs-vm-test-run-overalls-export-endpoint`).
That snapshot verifies SSH helpers, not the later typed effect/runtime or Marshall
coordination. Marshall route/outbox, pre-stop checks and integrated guest acceptance
remain outstanding; source interruption is still disabled for running full copies.

### Native Delete and probe outbox follow-up (2026-09-17)

The real guest Delete/snapshot-cleanup suite passed in 1598.70s (artifact
`npjav1r9lldapc8gzklxqplh9bnmd623-vm-test-run-overalls-zfs-guest`). It verifies local
terminal cleanup and stale-start refusal, not a full two-Lilly relocation.

[Probe requests](../../../marshall/lib/marshall/compute/probe_request.ex) now retain
phase, host, revision, validated wire payload, expiry and first receipt timestamp.
The [authenticated exchange](../../../marshall/lib/marshall/compute/relocation_probes.ex)
issues source leases only under current running authority and retained reservations,
then destination probes only after source acknowledgement. Expired history is
retained; duplicate receipts preserve timestamps. The authenticated provisioner API
now exposes this exchange. Coordinator stop gating and the final full-copy snapshot
path remain disabled pending their implementation and verification.

### Fresh preflight before running full-copy stop (2026-09-17)

The [probe coordinator](../../../marshall/lib/marshall/compute/relocation_probes.ex)
now exposes a current-authority proof check using database-clock issuance age,
remaining lease and exact matching source/destination request history. The
[relocation coordinator](../../../marshall/lib/marshall/compute/relocation_coordinator.ex)
retains that proof reference atomically with a running full-copy stop, after the
existing host freshness/image/commitment checks. A composite foreign key and check
constraint bind the proof to the relocation. The
[source exchange](../../../marshall/lib/marshall/compute/relocation_sources.ex)
issues the full snapshot request only after its exact physical stop is confirmed.
Validation is in progress; full Marshall-driven two-Lilly movement remains unverified.

### Authorized relocation admission (2026-09-17)

The public [Compute domain](../../../marshall/lib/marshall/compute.ex) now exposes
`relocate` with only a VM ID and bounded idempotency key. Its
[admission implementation](../../../marshall/lib/marshall/compute/relocation_admission.ex)
serializes request identity in PostgreSQL, locks hosts in UUID order before the VM,
rechecks current manage permission, and delegates automatic destination/mode
selection to the existing capacity transaction. Same actor/VM/key retries return
retained relocation history without allocating again and still require current
permission. The resource transaction already queues key preparation and coordination.
Focused tests cover owner/manager admission, denied and revoked access, retries,
capacity rejection and durable jobs. Three-node public-entry races and permission
revocation during a real lock wait pass. User-facing progress and controls remain absent.

### Integrated native acceptance fixture (2026-09-17)

The new [relocation fleet scenario](../../../nix/verification/tests/machines/fleet/scenarios/relocation.py)
uses public admission, three Marshall instances, two real Lilly services and
enrolled restricted SSH endpoints. It holds the baseline transfer until a guest
write after snapshot creation, then requires the destination to retain that write,
reclaim the source and return to the former host under a new placement. Syntax and
contract checks pass; native execution is in progress. The
[local source fixture](../../../nix/verification/tests/machines/zfs-guest/source.exs) also adds
typed running-source probe coverage. Its first run reached revocation but failed
because the fixture inherited its control-store lock. The corrected isolated task
passed its native subtest in 24.24 seconds, including unchanged guest processes,
absent snapshots, stable disk identity and retained guest data. The surrounding
guest suite and integrated fleet run remain in progress; no full movement
acceptance is established yet.

### Resume-token validation foundation (2026-09-17)

The [native token helper](../../../lilly/native/resume-token/src/lib.rs) bounds the token
envelope before decoding with pinned OpenZFS, checks exact typed snapshot lineage
and rejects unsupported modes without printing input. The
[source snapshot boundary](../../../lilly/lib/lilly/transfer/source_snapshots.ex)
now offers resumed-send argv only after its existing native ownership checks and
the token binding check. The full Lilly gate passes 257 cases and Dialyzer;
native full/incremental token acceptance is in progress. Coordinator delivery,
destination token retrieval and actual runtime resume selection remain absent.
This does not establish completed transfer resume support.


### Destination resume-token retrieval (2026-09-17)

[ReceivedDataset](../../../lilly/lib/lilly/transfer/received_dataset.ex) now joins
active exact-stream receiving intent with local ownership and a destination GUID
before returning an opaque token. [ZFS](../../../lilly/lib/lilly/host/zfs.ex)
requires stable safe staging and exact baseline lineage. The source validator
remains responsible for decoding and checking source snapshot identity. The
[native fixture](../../../nix/verification/tests/machines/zfs-transfer/received.exs) now checks
partial full/incremental retrieval and ownership/lineage refusal; its run is
pending. The preceding source-token native suite passed in 439.92 seconds.
Coordinator-driven delivery and runtime resume remain incomplete; implementation
status stays partial. See the [review](../reviews/2026-09-16-workload-relocation.md)
for the exact validation scope and outstanding work.


The [export parser](../../../lilly/lib/lilly/transfer/export_request.ex) and
[source registration](../../../lilly/lib/lilly/transfer/source_export.ex) now
support a bounded resume request through the existing authenticated permit and
native source validator. The [SSH builder](../../../lilly/lib/lilly/transfer/ssh.ex)
preserves pinned transport restrictions, and the local native channel carries
bounded token-sized requests. Receiver retry selection and end-to-end validation
remain outstanding; see the review for pending gates and the unresolved source
observation failure in the fleet fixture.


[Receiver](../../../lilly/lib/lilly/transfer/receiver.ex) now selects the verified
resume request on retry, recovers lost receipts from quiescent completed native
state, and requires independently verified fresh state before ordinary replay.
The Lilly gate passes 259 cases and forced Dialyzer; a real interrupted SSH retry
fixture is running. The prior destination-token storage suite passed in 444.67
seconds. This does not yet establish daemon-update recovery or complete relocation.
Running-guest reconciliation now retries temporary placement-lock unavailability
instead of reporting an identity mismatch; its native contention test is pending.


The two-machine supervised baseline-resume subtest now passes (39.70 seconds),
including interrupted native receive, verified token retrieval, restricted resumed
export and exact completed retry. The encompassing endpoint suite is pending;
new incremental interruption coverage remains unrun. The previous typed-probe
and readiness guest suite passed in 1536.52 seconds; the newer lock-contention
regression still needs native evidence. These scoped results do not establish
full Marshall relocation or daemon-update recovery.


### Native receive rate control (2026-09-18)

The [native stream helper](../../../lilly/native/transfer-stream/src/lib.rs) now uses
nonblocking kernel splice and a monotonic rate bucket with a 64 KiB burst cap.
[Runtime configuration](../../../lilly/lib/lilly/control/config.ex) and the
[NixOS module](../../../nix/domains/system/lilly.nix) default production receive to
64 MiB/s with a positive configurable ceiling of 1 GiB/s. The receiver carries
that setting through SSH to native custody. Focused throttling/timeout tests pass;
the final full gate and rate-enabled native acceptance remain pending. Byte
progress and storage-pressure handling remain incomplete. See the review for
scoped evidence and the separate fleet observation failure.


The final rate-control Lilly gate passes 260 cases and zero-warning forced
Dialyzer, plus ADR and contract checks. The previous endpoint snapshot passed
both supervised baseline and incremental resume subtests (38.29 and 40.34 seconds);
its full suite is pending. A new fleet snapshot includes rate control and the
running-lock fix, with acceptance still in progress. Byte progress, pressure
handling, UI and the original integrated fault matrix remain outstanding.


### Native byte-progress protocol (2026-09-18)

[Stream](../../../lilly/lib/lilly/transfer/stream.ex) and its native helper now
support optional bounded monotonic counters tagged with the current attempt's
PID. Counts measure transport into the consumer pipe, never durable data or
capacity credit. Backpressure revokes work rather than blocking cancellation.
Native counter tests and the full gate are in progress. Receive-runtime,
control-plane persistence and UI propagation remain unimplemented; this boundary
does not change the partial implementation status.


The [receive worker](../../../lilly/lib/lilly/transfer/receive_runtime.ex) now
coalesces counters only from its current leased attempt, with a fresh attempt
UUID on retry. Expired, fenced, old-task and decreasing updates are ignored;
progress cannot mutate deadlines or receipts. Receiver forwarding retains exact
task identity and an absolute deadline. Marshall persistence and UI propagation
remain outstanding. The final receive-progress gate is in progress; existing
machine evidence predates this worker integration.


The full two-machine restricted endpoint suite now passes in 692.29 seconds,
including baseline/incremental interruption/resume, exact retries and revocation.
That immutable snapshot predates rate/progress additions and is not Marshall
relocation or update-recovery evidence. The review records its artifact and the
remaining native progress validation.


RelocationProgress (`protocol/lib/overalls_protocol/relocation_progress.ex` at overalls revision `a99f74f0`, repository deleted)
now defines bounded attempt-scoped transport telemetry. Attempt ordering combines
the authenticated host session/epoch with a BEAM-monotonic positive sequence;
control runtime restart opens a fresh session. The receiving application must
validate durable request identity and reject stale attempt updates. Shared codec
and consumer checks are in progress. Marshall consumption/persistence and UI
remain outstanding; parsing this report grants no receipt or resource credit.


### Authenticated receive progress persistence (2026-09-18)

The receive exchange now carries optional bounded attempt telemetry from
[Lilly's receive runtime](../../../lilly/lib/lilly/transfer/receive_runtime.ex)
through the shared v3 codec.
[Marshall's receive coordinator](../../../marshall/lib/marshall/compute/relocation_receives.ex)
checks the current destination session and retained source request under host/VM
locks, ignores stale or inapplicable observations, and stores one latest report
using the validated Ash type (`marshall/lib/marshall/compute/receive_progress.ex` at overalls revision `a99f74f0`, repository deleted).
Session epoch, attempt sequence, request revision and nondecreasing attempt bytes
prevent late observations replacing newer work. Progress updates grant no
receipt, execution authority, scheduling action or capacity credit.

The focused persistence and transport run passes all 45 tests in
`/tmp/overalls-progress-persistence-tests-retry.log`; full consumer gates and UI
remain outstanding, so relocation remains partial.
The native endpoint suite with rate control and receiver progress forwarding
passed in `/tmp/overalls-runtime-progress-native.log`, artifact
`/nix/store/67wb4gha3ycg94g78knf578gpcrsj2k8-vm-test-run-overalls-export-endpoint`.
That fixture does not establish Marshall progress delivery, UI behavior or
complete guest relocation.


### Initial relocation UI (2026-09-18)

[Machine controls](../../../marshall/lib/marshall_web/live/machines_live.ex)
invoke existing authorized relocation/cancellation actions and display a
[bounded manager status projection](../../../marshall/lib/marshall/compute/relocation_status.ex).
The page shows mode, phase, latest attempt bytes and report age, including
readiness failure, restoration and cleanup states. All 14 machine LiveView tests
pass, including stale-manager denial and progress refresh. Downtime display,
rendered browser review and full phase coverage remain pending. The native fleet
run timed out after post-baseline writes; diagnostic rerun details are in the
relocation review. No complete movement acceptance is claimed.


The status projection additionally computes **observed downtime** from the pinned
physical stop outcome's receipt time through destination readiness or source
restoration. Missing stop evidence and initially stopped workloads yield no
metric. This is labeled control-plane observation timing, not exact guest service
availability. The 46-test UI/source run and final 32-test source run pass;
full Marshall validation and native relocation acceptance remain open.


A native baseline stall exposed an initial receive-worker retry deadline of zero,
which was never reached under a negative BEAM monotonic clock. The
[receive worker](../../../lilly/lib/lilly/transfer/receive_runtime.ex) now
initializes its deadline from that clock; regression coverage proves first-effect
scheduling in receive, import, readiness and cleanup modes. All 268 Lilly tests
pass; native movement confirmation is running, as recorded in the review.


The complete merged Marshall gate now passes 534 cases, browser-state checks and
forced Dialyzer with only the documented upstream exclusion
(`/tmp/overalls-relocation-ui-full-precommit.log`). The previously failing native
early-cancellation cleanup subtest passes with bounded same-authority retries;
the full guest suite subsequently passed, including restored-source deletion
(`/nix/store/z7795cvkcs9k4v7ybwf75fq3gzj4linx-vm-test-run-overalls-zfs-guest`).
Source-rendered desktop/mobile UI layout review also passed. These are scoped
results; the corrected-clock relocation fleet and broader acceptance remain active.

### Recovery and pressure acceptance implementation (2026-09-18)

The [native failure scenarios](../../../nix/verification/tests/machines/fleet/scenarios/relocation-failures.py)
exercise actual transfer interruption, daemon restart, source reboot after stop,
post-stop cancellation, failed readiness, Delete during cleanup, updater activation
on both endpoints and physical ZFS pressure. Disposable proxy path gates withhold
real control messages; they never manufacture results or mutate database authority.
The updater case requires a native resume token and preserved source guest process
identity. The pressure cases preserve configured guest-root policy and exercise
stopped-copy selection and destination space exhaustion followed by recovery.
Implementation of these scenarios does not establish that they pass.

The current ADR-0050/0051 capacity policy and Budget contract retain conservative
temporary holds. The earlier temporary-credit optimization is not implemented and
is not an outstanding requirement of that newer policy; native verification of
retained charges and pressure recovery remains required. No authority, protocol
or reservation policy changes are introduced by this acceptance increment.

### Explicit destination boot retry (2026-09-18)

The recovered plan required a retryable post-handoff failure. Previously failed
readiness retained the source but excluded every recovery action except Delete.
[Retry admission](../../../marshall/lib/marshall/compute/relocation_retry_admission.ex),
its [retained request](../../../marshall/lib/marshall/compute/relocation_retry.ex)
and the then-current coordinator implemented the explicit stop/restart sequence
above. The UI then offered an authorized destination-boot retry.
ADR-0197 removes that cold-retry coordinator for new memory-preserving moves;
the retained resource and exact historical receipts remain readable. Historical failed receipts remain acknowledgeable
without satisfying the newer request. The new migration adds only the retry table
and its operation/relocation bindings, request uniqueness and pending-retry index.
The 48 focused source/UI cases pass, including idempotency, permission denial,
physical-stop and capacity gating, late receipts, fresh readiness and Delete
supersession. Three independent Marshall peers also cover identical/competing retry
keys, failed/ambiguous activation, physical-stop-gated restart and concurrent Delete.
The complete Marshall gate passes 547 cases, six browser checks and
forced Dialyzer with its documented upstream exclusion. Native retry acceptance
remains pending. The latest merged fleet attempt timed out before destination
import acknowledgement; the review records the failure and diagnostic rerun.

The [effect worker](../../../lilly/lib/lilly/transfer/receive_runtime.ex) now emits
only closed failure reasons and suppresses repeated equal failures without changing
receipts, leases or cleanup authority. Lease expiry and task exits use fixed
reasons without exposing exit payloads; stale expiry messages preserve renewed
work. Its privacy and suppression tests are part of the passing 273-case Lilly
gate, with zero forced Dialyzer findings. This is
diagnostic evidence, not resolution of the integrated native stall.

Destination import now distinguishes fixed jail-cleanup, network-detach,
disk-adoption and ownership-publication failures at the existing execution guard.
The guard retains the same ownership, stopped-unit, intent and deletion checks
and effect order; underlying failure payloads remain private. Generated diagnostic
tests cover closed import reasons, wrapped private payload rejection, duplicate
suppression and unchanged pending receipts. This improves diagnosis of the
900-second import-stage timeout recorded in the
[Audi review](../reviews/2026-09-17-audi-ingress.md); it does not establish a fix
or completed native import acceptance.

The subsequent `z9ztiy_b` native fleet snapshot passes both the initial running
move and return to the former host (1035.58 and 1209.29 seconds). Those subtests
verify final guest data, readiness, physical source cleanup, one retained disk
reservation and a new placement/increasing epoch on return. The suite continues
with initially stopped relocation and the recovery matrix; complete native
acceptance remains open. The latest diagnostic increments are not in that live
snapshot. See the linked implementation review for exact logs and build evidence.
The latest shared-worktree Marshall gate also passes 551 cases and six browser
checks, with the same single documented upstream Dialyzer exclusion and no
unsuppressed findings. This includes the current Lilly test dependency; native
stopped relocation and the remaining recovery matrix are still unverified.

Further diagnostic refinement distinguishes closed native producer/consumer/pipe
failure classes and fixed import-guard stages, preserving guard ordering, native
reaping and all authority checks. Pool contention remains explicit through the
adoption callback. The updated Lilly gate passes 278 cases with zero Dialyzer
findings; native execution of these latest distinctions remains pending. These
observations have not yet established or repaired the integrated stall's cause.

The isolated [source export entry point](../../../lilly/lib/lilly/transfer/endpoint.ex)
now reports a fixed structured failure event and allowlisted reason to stderr,
flushing before its existing failure exit. stdout remains exclusively the SSH
data channel. Property coverage rejects wrapped/private payloads and checks
silent success; the current Lilly gate passes 303 checks (34 properties, 269
tests) and forced Dialyzer with no findings. This closes a source-side diagnostic
gap without changing permits, leases, ownership or retry behavior, and does not
establish recovery from the observed baseline-transfer timeout.

Transfer preparation, receipt verification, import and source registration opt into
a two-second pool-acquisition retry window through
[Storage](../../../lilly/lib/lilly/host/storage.ex). Only acquisition contention
is retried; protected effects run at most once. Existing two-argument callers
retain their single-attempt behavior. Native handshake and release bounds remain
independent of the retry window. Source permit/native checks still run after
ownership, and caller death or lease fencing still cancels a waiting task.
Native-lock properties cover transient/permanent contention, effect failures,
exceptions and waiter cancellation. The version including import journal reads
and shared disk adoption passes 307 Lilly checks (35 properties, 272 tests),
including forced Dialyzer with no findings. This
reduces sensitivity to brief inventory lock holds. The Audi native fleet run
including all four opt-in acquisition sites now passes in 2004.31 seconds,
including eventual physical source cleanup after closed failure/lock-contention
retries. No starvation fix or cause for each retry is claimed; the Audi review
records the exact immutable snapshot and retained log.

A subsequent Audi custody-fault run passes its storage-permission scenario but
times out during relocation source cleanup. A bounded observation finds the
source pool held by a native helper with a ZFS child in uninterruptible sleep;
that sample does not identify a persistent kernel stall or its operation.
Snapshot retirement and final source deletion now also opt into the two-second
acquisition retry without repeating effects or relaxing deletion proofs.
Native command uncertainty logs only a closed utility/reason, elapsed time and
numeric helper PID. Private arguments/output remain excluded. These refinements
await application/native verification; no recovery or starvation fix is claimed.

Multi-disk transfer under [ADR-0072](0072-multi-disk-workload-transfer.md)
keeps this record's single-dataset stream design: the placement dataset
carries every profile-derived drive, destination adoption now requires the
exact drive-name set with per-drive publication
([ZFSDataset](../../../lilly/lib/lilly/host/zfs_dataset.ex)), stopped evidence
requires all drives ([executor](../../../lilly/lib/lilly/vm/executor.ex)), and
admission charges the full logical footprint for pre-copy headroom,
destination mirroring and temporary holds
([capacity](../../../marshall/lib/marshall/compute/relocation_capacity.ex)).
Inception admission, footprint and evacuation tests pass in
[inception tests](../../../marshall/test/marshall/compute/inception_test.exs);
native two-disk acceptance is tracked by ADR-0072's review.

## Later local readiness guard evidence (2026-10-02)

The [competing relocation history](../../../marshall/test/marshall/compute/relocation_competing_history_test.exs)
uses actual public admission and authenticated endpoint revocations to check
allocation-free refusals, release only after both stream receipts, and competitor
admission while restoration and disk cleanup remain pending. Exact original slot
IDs and first-release timestamps survive replay. Its combined focused execution
passed two properties (seed281508,49.7seconds); full batch gates remain pending.
The [review](../reviews/2026-10-02-relocation-and-workflow-backlog-histories.md)
retains native cessation and independent-process gaps. This evidence preserves
the superseded decision's retained relocation requirements and rationale.

The [common runtime boot property](../../../marshall/test/marshall/operations/invalid_runtime_boot_property_test.exs)
exercises invalid relocation-readiness timeout strings through fresh real Mix
startup with test-build beams, alongside other common guards. The
[review](../reviews/2026-09-29-antithesis-property-audit.md) records its scoped
execution. This checks refusal before application callbacks, not relocation,
production-built release startup or native recovery. The superseded decision's
rationale, statuses and historical acceptance remain unchanged.
