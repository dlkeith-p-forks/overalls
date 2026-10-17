---
sut_path: /home/ghuntley/src/kittens-antithesis-reset
commit: c835eb1017d24a001215c319373fa4204d64269b
updated: 2026-10-13
external_references: []
scope_answer: "Repository only (Recommended)"
research_started_at_commit: 9fe1e493b2090d44bacd16089049cd12b316d58a
---

# Failure and degradation modes

This pass examines extant implementation and contracts across Marshall, Lilly,
Audi, Brady, Ziggy, Porsche, Enrico and Galileo, plus shared protocol, native
helpers, guests, backups and Nix orchestration. HEAD is the stated baseline; the
worktree contains the authorized reset changes. Deleted research/harness files
were not inspected. Findings below distinguish implemented branches from claimed
invariants and proposed experiments. No repository files were changed; this
external research note changes no architecture, ADR, HLDD behavior or verification
claim. Relevant accepted decisions include ADR-0017, 0037, 0070, 0097, 0100,
0126, 0136, 0140 and 0142; their historical evidence is not evidence from this pass.

## Fault boundaries and interpretation

The repository's fault reference describes asymmetric inter-container packet
faults, whole-container hangs and throttling, and termination/clock faults whose
availability depends on configuration. It explicitly marks termination disabled
by default (`.agents/skills/antithesis-research/references/faults.md:10-19,49-69`).
These are planning assumptions, not confirmed tenant settings.

Automatic outer faults and explicit native faults need separate coverage records.
If a container hosts nested NixOS/QEMU machines, an outer hang freezes their common
environment; it does not independently exercise a host crash with PostgreSQL still
advancing, a guest-only death, or a selective virtual-link partition. QMP
stop/resume/power loss, host systemd freeze/restart, Firecracker termination,
vsock helper loss, native child suspension and ZFS/storage faults therefore need
explicit commands and acknowledgments of the selected target. Existing native
test sources demonstrate narrower mechanisms: destination loss is armed only
after a received dataset exists (`nix/tests/machines/clone-permutations/destination-loss.py:106-133`),
and the executor observer freezes its service from outside that cgroup
(`nix/tests/machines/executor-loss/observer.py:129-143`). Test presence establishes
neither passing execution here nor automatic Antithesis coverage of those faults.

## Marshall: ambiguous commit, authority and physical receipts

Admission uses a transaction and an account/idempotency advisory lock, reads
retained history, returns an exact replay, and rejects a changed request shape
(`marshall/lib/marshall/compute/admission.ex:39-85`). A useful fault cuts the reply
after commit, restarts the requester or BEAM, then retries the same identity from
another Marshall. The oracle must inspect the whole joined allocation: VM,
placement, reservation, address, operation, dispatch job and audit. Counting only
successful HTTP replies would miss duplicate committed work or stranded partial
allocations. Before-commit failure and after-commit reply loss are different
histories; observed errors do not settle which occurred.

Control requests run in `async_nolink` supervised tasks; socket termination does
not cancel those tasks (`marshall/lib/marshall/control/socket.ex:105,118-142`). A
disconnected client can therefore hold an uncertain mutation while the server
commits it. Shared client code refuses disconnected/over-limit calls, times out
pending calls, and explicitly prohibits implicit redelivery
(`protocol/lib/overalls_protocol/control/client.ex:52-65,124-143,175-182`). Exercise
one-way reply loss, duplicate correlation IDs, request saturation, reconnect,
and version refusal. Closed envelopes reject unsupported versions and extra or
malformed shapes (`protocol/lib/overalls_protocol/control/envelope.ex:68-105`);
malformed-input rejection must not advance a domain exchange.

Slowness must not become physical absence. Outcome processing requires current
reservation coherence, suppresses recovery during unresolved relocation, and
retains disk/address after ordinary failed starts
(`marshall/lib/marshall/compute/outcomes.ex:165-184`). Partition Marshall from Lilly
while guests continue, then race old outcomes with new lifecycle intent. Expected
properties are hypotheses: stale evidence must not free newer holds, authorize a
second runnable placement, or manufacture a crash restart. Database lock-holder
loss also deserves an independent observer: ADR-0126 preserves TCP/client loss
bounds while explicitly distinguishing them from a query deadline and from
uncertain commit replay (`docs/architecture/decisions/0126-bounded-database-client-recovery.md:34-55`).

Magic-link delivery has an unavoidable external boundary. SMTP is bounded by a
ten-second owning task, retries retain Message-ID, and the code contract explicitly
declines exactly-once inbox delivery across SMTP acceptance/database uncertainty
(`marshall/lib/marshall/accounts/deliver_auth_email.ex:104-129`). Cut the database
connection after SMTP acceptance; the oracle should require stable delivery
identity, correct payload erasure on committed terminal status, and valid current
token authority, not one observed email
(`marshall/lib/marshall/accounts/deliver_auth_email.ex:155-160`).

## Lilly: intent, launch, observation and acknowledgment

The command store validates host/version binding and monotonically retains
execution-epoch/generation, including stale deliveries and exact duplicates
(`lilly/lib/lilly/control/store.ex:11-50`). Publication writes and syncs private
staging data, publishes, then syncs the directory; a write error is explicitly
uncertain publication (`lilly/lib/lilly/host/private_files.ex:36-69`). Under a native
lock, publication runs through its owning helper
(`lilly/lib/lilly/host/private_files.ex:83-91`).
Fault at each stage, reopen, and deliver old/new commands. The oracle compares
retained revisions and identity, rather than assuming an error preserved the
previous bytes.

Actors persist an attempt before starting one executor task, reread durable
intent before accepting its asynchronous result, and stop on invalid store state
(`lilly/lib/lilly/vm/actor.ex:222-242,272-323`). Driver launch-attempt markers reject
the same or older authority (`lilly/lib/lilly/vm/driver.ex:1474-1492`). Fault between
attempt marker and systemd submission, after physical launch but before outcome,
and after outcome persistence but before acknowledgment. Recovery may
conservatively require a fresh explicit start in the first case; “eventually
running” is an invalid unconditional oracle. Journal recording preserves identical
fact IDs/sequences, and acknowledgments clear only the current ID
(`lilly/lib/lilly/vm/journal.ex:95-152`). The observable target is no repeated launch
for one authority and replay of the retained outcome.

The executor labels a failure `crashed` only when its journal proves the same
epoch/generation previously ran; cleanup uncertainty becomes unknown
(`lilly/lib/lilly/vm/executor.ex:517-542`). Unit status distinguishes transitional
or unreadable observations from contradictory evidence, requiring cgroup emptiness
before stopped (`lilly/lib/lilly/vm/unit.ex:170-217`). Freeze systemctl, hold VM/network
locks, suspend watchers, and kill actors while preserving VMMs. Check retained
compute/disk obligations and physical PID/cgroup/boot continuity independently.

Relocation/clone faults must cut across both copies. Destination revocation retires
its key before acquiring receive/stream locks and returns unconfirmed for busy
work (`lilly/lib/lilly/transfer/destination_revocation.ex:7-31`). Source revocation
requires durable permit fencing and sender lock release; snapshot cleanup is
separate (`lilly/lib/lilly/transfer/source_revocation.ex:6-11`;
`lilly/lib/lilly/transfer/source_runtime.ex:45-52`).
Marshall source-storage release requires retained retirement, cleanup and completed
delete evidence (`marshall/lib/marshall/compute/relocation_cleanup.ex:19-27`).
Interrupt receive, lose either revocation reply, then race cancellation, handoff,
Delete and restored-source start. Oracles need per-copy ownership, snapshot GUIDs,
current epoch, actual streams and charged reservations/slots. Intents and key
deletion alone do not prove quiescence or reclamation.

## Authority failures in Audi, Galileo, Ziggy and Porsche

Audi classifies transport/HTTP errors and expired grants as inconclusive renewal:
the existing lease survives without extension, with a retry bounded by its deadline.
Other refusals revoke (`audi/lib/audi/authority/renewal.ex:6-27`). Stream guards kill
owners on refusal/expiry, and an unlinked watchdog covers guard death or suspension
(`audi/lib/audi/authority/stream_guard.ex:10-15,96-104,126-150`). Partition during
renewal, revoke membership or relocate concurrently, then release delayed grants.
The oracle needs request-start/expiry times and actual socket closure/bytes; a
temporarily retained authorized stream is not itself a bug. DNS refresh preserves
old snapshot deadlines on failure and halts automatic refresh on explicit version
refusal (`audi/lib/audi/dns/replica.ex:48-91`). Test stale publication expiry and
operator restart separately from ordinary outage recovery.

Galileo authorizes before body upload or upstream connection, supplies native
frontend cancellation, and classifies refusal separately from authority outage
(`galileo/lib/galileo/http.ex:190-250`). Its upstream contract closes an attempt on
failed/invalid renewal or expiry while allowing a silent authorized response
(`galileo/lib/galileo/upstream.ex:40-44`). Delay upload reads, response writes and
renewal independently. An external mock provider should count accepted requests
and expose canceled connections; frontend errors alone cannot establish that
upstream work stopped. The implementation routes native socket cancellation
through ThousandIsland (`galileo/lib/galileo/http.ex:208-220`).

Ziggy differentiates immutable accounting retry from provider effects. Its spool
fsyncs admission before effects, poisons on persistence errors, and rejects corrupt
restart state (`ziggy/lib/ziggy/spool.ex:87-111,260-285,396-407`). Reporter acknowledgment
removes only the matching completed receipt; version refusal switches to probes
without discarding it (`ziggy/lib/ziggy/reporter.ex:20-23,35-77`). Claimed model tasks
remain uncertain after loss rather than being reclaimed for a second provider
attempt (`ziggy/lib/ziggy/agent_worker.ex:69-72`); lease errors kill the owner
(`ziggy/lib/ziggy/lease.ex:42-90`). Fault provider acceptance, streaming, completion
checkpoint and control acknowledgment independently. Require an external attempt
ledger and preserve unknown usage; zero usage is not a valid substitute.

Porsche submits one mutation per invocation with an identity allocated before
submission, then observes receipt-correlated progress. Timeout/death does not
cancel or repeat it (`porsche/lib/porsche/runner.ex:10-15,58-88`). Session close is
best effort in termination (`porsche/lib/porsche/connection.ex:115-128`). Cut replies
and kill channels while operations continue, then inspect receipts through fresh
current authority. Reconnecting transport must not inherit account authority or
silently execute the user's command again.

## Brady, Enrico, native descendants and guest recovery

Brady places its optional cache outside proxy availability. Cache recovery retries
every five seconds, revalidates native mount custody after startup, pauses writes
on stale pressure, and stops storage on changed custody without stopping listeners
(`brady/lib/brady/cache/recovery.ex:25-75`). Partial writes conservatively retain
reservation; only complete synced objects enter the index
(`brady/lib/brady/cache/store.ex:210-233,245-291`). Fault data write, metadata,
publication, cleanup and pressure freshness under simultaneous readers. Check
complete public bytes, no credential-bearing reuse, bounded physical/pending cost,
and neighbor streaming, not persistence of a disposable object.

Enrico bounds active refreshes and caches attempt receipts in memory; restart or
receipt eviction ends local replay retention while Marshall retains durable intent
(`enrico/lib/enrico/manager.ex:58-83,257-278`). Generation checks reject delayed task
completion (`enrico/lib/enrico/manager.ex:170-224`). Kill manager/task during fetch and retry from
Marshall; inspect published refs and native repository locks, not the vanished
in-memory receipt. The Git helper uses subreaper ownership, group kill and adopted
child reaping, with bounded cleanup failure preserving uncertainty
(`enrico/native/git-owner/src/main.rs:140-188`).

Descendant custody is a shared failure surface. Host-lock, source-export and
transfer-stream keep unreaped leaders through group signaling and wait for all
adopted children before confirming completion
(`lilly/native/host-lock/src/lib.rs:282-299`; `lilly/native/source-export/src/lib.rs:415-437`;
`lilly/native/transfer-stream/src/lib.rs:255-297`). Schedule caller EOF, owner death,
stdout blockage, timeout and a child escaping its session on both success and
failure paths. A successor must not acquire mutation/transfer ownership while a
descendant can still mutate. These wait loops also identify a liveness question:
escaped descendants may retain custody indefinitely; fault tests must distinguish
safe retained ownership from false successful cleanup.

Guest readiness validates current boot identity and actively probes units,
networking and root fsync (`nix/packages/guest/readiness.py:28-64,123-154`). Guest
daemon death, helper freeze or disk-full can therefore disagree with a running
Firecracker process. Terminald explicit kill interrupts credit-stalled writers
and PTY pumps before PID retirement (`nix/packages/terminald/src/session.rs:323-343`),
while local pressure must not stall neighbors
(`nix/packages/terminald/src/session.rs:634-646`). Verify
guest process, boot, stream and storage state independently; native isolation is
outside what source inspection or mocked executor tests establish.

## Durable measurement, backups and host orchestration

Request recording is separate from effect authority. Recorder state transitions
fsync a private stage, rename and directory-sync before acknowledgment; storage
failure poisons the writer (`nix/modules/otel-guest/receiver/src/durable_slo.rs:518-587`).
Kernel producer identity/death proof and deadlines settle pending measurements;
recorder restart alone cannot prove producer death
(`nix/modules/otel-guest/receiver/src/request_recorder.rs:151-175,306-319`). Producer
ambiguous RPCs report gaps while preserving work semantics
(`elixir/request_accounting/lib/overalls/request_accounting/producer.ex:49-82`). Cut
committed admission/completion replies, kill only recorder versus only producer,
and corrupt an initialized checkpoint. Oracles require conservation, monotonic
coverage, stable lifetime and no fresh poisoned snapshot, separate from whether
the request effect succeeded.

Backups recover interrupted runs through durable cleaning and reject unresolved
cleanup; only complete component capture plus cleanup publishes a host manifest
(`nix/modules/backups/runtime.py:78-92,199-238`). PostgreSQL capture validates version,
archive readability and hash using runtime TLS authority
(`nix/modules/backups/postgres.py:104-155`). Restic partial backup is failure, and
retention validates references before deleting (`nix/modules/backups/restic.py:153-174,256-293`).
Fault upload/manifest acknowledgment, pool pressure, cleanup and prune concurrently.
Check referenced component presence, exact nonce/GUID cleanup and verified isolated
restore; historical restored metadata must not automatically serve execution
authority (ADR-0070, `docs/architecture/decisions/0070-host-recovery-backups.md:79-102`).
Guest flush is bounded best effort, so degraded crash-consistent backup remains a
valid outcome, not guaranteed application-consistent recovery.

Nix updater stops socket activators before services, retains a recovery descriptor
and attempts prior role restoration after failed switching
(`nix/modules/auto-update/runtime.py:573-586,638-677`). Private readiness must be
affirmative before advancing lastHealthy
(`nix/modules/auto-update/runtime.py:880-924`). Kill updater
during switch or revoke custody while probes lag. Check selected generation,
running roles, durable ownership and surviving guests separately from a green
health response.

## Prioritized schedules and oracle needs

1. **P0: committed reply loss.** Admission/control/receipt replay across independent
   Marshalls, with PostgreSQL continuously observed. Require a durable joined
   allocation oracle and exact request identity.
2. **P0: Lilly journal/launch interruption.** Cut all three intent/launch/outcome
   boundaries, then restart. Require independent cgroup/PID/boot observations and
   stable journal/outcome identity.
3. **P0: two-copy recovery.** Partial receive plus cancellation/handoff/Delete,
   endpoint reply loss and source-restoration failure. Require physical copy,
   permit, stream, GUID and capacity ledgers; quiet periods test eventual cleanup.
4. **P1: stale authority.** Lease expiry, late renewal, membership withdrawal and
   version refusal under blocked I/O. Require byte/connection and current-binding
   observers with service-specific refusal semantics.
5. **P1: native descendant custody.** Escaped child plus EOF/timeout/owner loss,
   including successful leaders. Require independent child/lock observations and
   positive confirmation that both success and failure paths were reached.
6. **P1: storage and orchestration.** Recorder commit cuts, Brady cache pressure,
   Enrico refresh death, backup publication/prune and updater interruption. Require
   distinct measurement, effect, disposable-cache and recoverable-manifest oracles.

## Assumptions

Properties above are candidates, not guarantees verified by this pass. No tests
were executed. Bounded recovery checks need a quiet window longer than actual
reconnect, cleanup and worker backoff, with deliberate conservative refusal
excluded from unconditional progress claims. Secrets, command arguments, terminal
bytes and provider payloads must stay outside diagnostic/property metadata.

## Open Questions

Termination/clock configuration, nested virtualization availability,
explicit QMP access, fault persistence semantics and independent observer placement
remain unconfirmed. The source-only scope cannot establish which fault categories
are enabled in the tenant, whether an inner crash preserves the intended ZFS
durability model, or whether observer reachability survives an outer fault.
