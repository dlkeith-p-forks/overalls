# ADR-0055: Queued machine cloning through Ash and Oban

- ID: ADR-0055
- Date: 2026-09-18
- Status: superseded
- Implementation: implemented
- Components: Marshall Compute, Marshall SSH, Lilly, Porsche, shared protocol, machine LiveViews
- Supersedes: none
- Superseded by: ADR-0162

## Context

Users need independent copies of existing guest disks through the management API,
SSH commands and browser. Relocation moves one workload and preserves its address;
cloning instead creates another workload with distinct execution and access
identity. Reusing relocation handoff or source deletion would lose user data.

The user explicitly authorized this design, multiple queued clones, Ash domain
modeling, Oban execution, layered tests and implementation in a new worktree before
commit, merge and push. No backward compatibility or feature negotiation is required.

## Decision

Compute owns Ash CloneRequest and CloneEffect resources. AshOban dispatch and
scheduled reconciliation advance durable database state; jobs, SSH sessions and
browser connections are not authority. Actor/request-key identity is unique across
sources. Exact retries retain the destination; changed inputs conflict. Every
new key creates another queued request, serialized by a per-source sequence.
PostgreSQL permits only one active request per source. Queue acceptance reserves
name and destination identity, not host resources. Execution captures the source's
then-current contents, specifications and power state, not its submission-time state.

Check current source manage and provisioning permission at acceptance and again
under execution locks. Owners and managers may clone; lower roles cannot. Queued
revocation prevents new copying. Already admitted physical recovery survives
revocation or disconnection. Subsequent actions and polling recheck authority.

Acquire the queue advisory lock, immutable image/profile locks, sorted unique host
locks, then VM locks. Reserve destination resources, source restart capacity,
snapshot headroom and one transfer slot on each distinct host before stopping.
Same-host copying occupies one slot and charges both copies and snapshot retention.
Stable source checks exclude lifecycle, resize, relocation and maintenance.

Stop a running source, prove physical quiescence, then journal snapshot intent and
bind the native GUID. Restore the source immediately after capture while copying
continues independently. An originally stopped source stays stopped. A retry after
capture never substitutes a newer snapshot. Restoration completion ends automatic
power-state restoration: later clone work must not override subsequent user intent.
Source start/stop can resume after restoration; destructive operations and the next
clone wait for source snapshot cleanup.

Snapshot-index transitions explicitly record clone purpose. A clone keeps its
source's execution epoch, so a new transfer may reuse that epoch across a clone
transition only after the predecessor journal is fully retired, with a fresh
transfer ID and unchanged physical identities. Historical IDs cannot be reused,
regressed epochs fail, and late retired cleanup cannot change the current pointer.
Relocation-only chains retain their increasing-epoch requirement. Capture still
requires the current driver generation and confirmed stop.

Copy all guest disk contents, including user credentials, but no RAM. The
Inception multi-disk profile remains ineligible, matching ADR-0054's unverified
transfer boundary; [ADR-0072](0072-multi-disk-workload-transfer.md) later
accepted the verified single-dataset multi-disk path and removed this
exclusion. The requester
owns a private new VM with a new name, placement, address and independent disk;
sharing grants, sessions and ingress publications are not copied. Retain image,
profile and resource sizes. Automatically place locally or on another eligible
host. Use independent ZFS send/receive, not a persistent origin-dependent ZFS clone.

Portable clone descriptors explicitly bind distinct VM/placement/address identities
and independent epochs. They cannot validate as relocation descriptors. Existing
low-level journal fields retain their transfer-ID spelling; the clone purpose and
both identities are validated throughout storage and permit handling. Scoped SSH
keys and pinned endpoints carry remote data; local copies bypass SSH. Adoption
establishes destination-local ownership, never execution authority.

Before adoption publishes a ready disk, validate any retained host UID against the
admitted source slot and change it to the new destination slot. Ordinary ready-disk
checks continue to require destination ownership. Local transfer pipelines enforce
the same immutable source permit and bounded monotonic lease as remote transfers.

Publication races cancellation under the same transaction. Before publication,
cancellation fences transfers and reclaims only the unfinished destination and
owned snapshots. After publication, ordinary lifecycle controls manage the copy.
Match its execution-time source power state and require guest readiness on starts.
Cleanup has independent persisted obligations and does not authorize source disk
deletion. Release reservations and slots only after physical evidence.

Keep user pages bounded, use streams, and route UI and Porsche actions through the
same Ash actions. Show queue position and independent restoration/copy/cleanup
progress. Retain form request IDs through retries and refresh; allocate another key
for a new intentional submission. Porsche supports clone and request retry/cancel.

## Alternatives

Rejecting simultaneous requests prevents legitimate multiple copies. An in-memory
queue loses accepted work on failover. Oban uniqueness alone cannot enforce domain
idempotency or source exclusion. Sharing one snapshot between requests would copy
older contents than the selected per-request capture behavior. Keeping the source
stopped throughout remote copying increases interruption unnecessarily. Reusing
relocation's coordinator risks changing source ownership or deleting its disk.

## Consequences

Each queued request can interrupt the source once. Large queues and slow cleanup
increase wait time. Independent disks consume additional physical storage; retained
snapshots need conservative headroom while the source resumes writing. Forced
shutdown provides crash consistency, not application-level consistency. Guest
secrets are intentionally copied and are disclosed in the user flow.

Ash resources and jobs remain independent of host-native execution. The additive
database migrations preserve existing machines. Deploy the changed consumers as
one coordinated release, without an old clone protocol compatibility path.

## Invariants and verification

- One destination per distinct actor/key; FIFO activation under concurrent jobs.
- No stop or host allocation for rejected or merely queued work.
- Revoked queued requesters cannot start copying; lower roles cannot mutate VMs.
- Snapshot identity remains fixed across retries and source restarts.
- Snapshot cleanup and cancellation never delete the source disk.
- Physical uncertainty retains commitments; receipts bind host, effect and intent.
- Later lifecycle intent is never overwritten by delayed clone recovery.
- Unit and reference-model property tests cover protocols, queue histories and
  invariants; database/distributed tests cover transactions and races. Real
  NixOS/ZFS/KVM tests are required for storage, isolation and restart claims.

## Implementation evidence

[Clone request](../../../marshall/lib/marshall/compute/clone_request.ex) models
Ash/PostgreSQL queue identity and AshOban dispatch/reconciliation.
[Cloning actions](../../../marshall/lib/marshall/compute/cloning.ex) enforce current
access, idempotency, names and user recovery intent.
[Coordinator](../../../marshall/lib/marshall/compute/clone_coordinator.ex) and
[placement](../../../marshall/lib/marshall/compute/clone_placement.ex) persist phases
and capacity preparation. [Host effects](../../../lilly/lib/lilly/clone/effects.ex)
connect clone commands to guarded storage operations.
[Transfer validation](../../../protocol/lib/overalls_protocol/disk_transfer.ex)
distinguishes copy identity from relocation.
[Queue tests](../../../marshall/test/marshall/compute/cloning_test.exs) cover repeated
submissions, queue order, cancellation, revocation and activation with PostgreSQL.
[Three-node admission tests](../../../marshall/test/marshall/compute/distributed_admission_test.exs)
verify concurrent distinct submissions and exact retries.
[Native fixture](../../../nix/tests/machines/zfs-guest/cloning.exs) passes source
restoration, independent copying, replay, cancellation and source deletion.
[SSH/browser fleet acceptance](../../../nix/tests/machines/fleet/scenarios/porsche.py)
passes cross-host cloning, browser request identity across refresh, distinct
copies, private ownership and booting both copies after source deletion.
[Architecture review](../reviews/2026-09-18-machine-cloning.md) records the passing
application, migration, contract and native checks and resolved findings.

The [restart recovery review](../reviews/2026-09-26-clone-restart-recovery.md)
adds generated duplicate-receipt and published-clone restoration histories plus
native public-retry coverage. Same-pool incoming storage is recognized through
its private journal and native identity solely to defer source readiness until
adoption; unknown ownership stays fail-closed. The deferral probe checks stable
parent identity without relying on coherent receive-time counters, granting no
capacity or execution credit. Slot release still depends on all cleanup evidence,
and newer source generations cannot be overwritten. Execution and production
recovery results are tracked separately from these test definitions.

The [2026-09-25 production acceptance](../reviews/2026-09-25-production-clone-relocation.md)
created a healthy new source but its clones failed before physical work because
an older published clone retained the host's transfer slot after source restart
failure. The next-day review records supported recovery of a fresh clone and both physical
relocation directions, while the original clone disappeared externally before recovery;
the historical native results above retain their original scope.

[Cancellation and current-authority verification](../reviews/2026-09-25-clone-cancellation-verification.md)
adds actual-action generated histories and five observed three-independent-BEAM
schedules, including both publication/cancellation and admission/revocation orders.
The new [native browser journey](../../../nix/tests/machines/clone-cancellation/driver.py)
tracks actual cancellation cleanup and queued revocation separately from its build
and execution status. The proposed three-party account/source lock cycle did not
reproduce; production lock order is unchanged. Existing native and multi-disk
verification retain their earlier scopes.
The eighth cancellation capture failed queued activation with `source_unavailable`
before physical work. Offline recovery of its disposable DB established the stored
refusal, while the exact activation-time predicate remains unproven. The fixture
now observes fresh source receipts after operator startup before its first manual
advance; all production guards and later refusal outcomes remain unchanged.
The ninth capture failed initial host admission before reaching that wait. Some
reports were accepted, but the exact predicate behind repeated `invalid_report`
refusals is not retained. Complete cancellation/control acceptance remains pending.

The clone-cancellation fixture now pins and instruments the actual authenticated
host-report guards to retain only finite rejection stages and exact signed sample
ages across rollback. Seven synthetic exchange/sink checks pass; native diagnosis
remains pending and cannot classify the ninth historical failure. Integration of
`186a1ea4` preserves owned-staging validation order; the integrated Lilly gate passes
413 checks with zero forced Dialyzer findings. The frozen `186a1ea4`-based Marshall gate
passes 1,182 checks with zero forced Dialyzer findings; later test-helper and updater
verification integration retains its separate scope. The
[verification review](../reviews/2026-09-25-clone-cancellation-verification.md)
keeps these scopes separate from upstream production recovery and native evidence.

## Open questions

No unresolved choices for supported single-disk profiles. Inception's
multi-disk copy path was accepted and implemented by
[ADR-0072](0072-multi-disk-workload-transfer.md); its native verification
obligations are tracked there.

The [competing activation history review](../reviews/2026-10-02-clone-competing-activation.md)
extends the published-restoration property with a second stable stopped VM.
Queue acceptance remains allocation-free; occupied-slot activation refuses,
explicit retry preserves identity, and verified cleanup permits activation while
original release timestamps survive duplicate advances. The focused 14-check
suite and pre-integration 1,413-check Marshall gate passed, including forced
Dialyzer. Integrated upstream Marshall precommit also passed 1,417 checks
(216 properties, 1,201 tests), seed505231, with zero forced Dialyzer errors;
its exact result and scope are retained in the same review. This is rollback-sandbox
control-plane evidence, not native restoration or hosted availability.

The [distributed race error review](../reviews/2026-10-03-distributed-race-error-oracles.md)
repairs a verification gap: opaque activation failures cannot pass as ordinary
clone placement refusals merely because rollback preserves accounting. The
focused two-property distributed suite passed seed202304 in60.2seconds. Full Marshall
precommit passed 1,423 checks (222 properties, 1,201 tests), two exclusions,
seed59328,1465.7seconds; forced Dialyzer44.48seconds, zero errors/skips/unnecessary
skips, exit0. Production clone authority and lock order are unchanged.

The [host-lock reach property](../reviews/2026-10-03-distributed-host-lock-reach.md)
adds three independent peer operations: clone activation and opposite-source
relocations. All tagged blocking chains reach a separate holder before release;
durable activation, actual endpoints and complete accounting are checked. Its
focused run passed seed `219491` in 51.6 seconds, exit 0. The complete file passed
three properties, seed `396307`, in 162.6 seconds, exit 0. Full pre-integration
gates passed 1,424 checks (223 properties,1,201 tests), two excluded, seed893479,
1305.7seconds; forced Dialyzer48.96seconds with zero errors/skips, exit0.
Merged checks remain required; this does not establish native transfer or hosted fault
coverage. Production lock order and authority remain unchanged.

## Related decisions

[ADR-0162](0162-clone-cleanup-liveness.md) supersedes the clause that releases
transfer slots only at the end of a request: slots now release at stream
quiescence, cleanup has a deadline that retains the physical obligation, and
unconfirmed effects carry a closed reason.

[ADR-0017](0017-durable-vm-actors-and-host-ownership.md),
[ADR-0018](0018-persisted-sharing-and-user-machine-access.md),
[ADR-0037](0037-workload-placement-and-relocation.md),
[ADR-0046](0046-porsche-ssh-management.md),
[ADR-0053](0053-vm-disk-limit.md),
[ADR-0054](0054-inception-development-profile.md).
