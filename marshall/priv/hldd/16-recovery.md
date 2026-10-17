# Backup and recovery

## Experimental native daemon recovery

The optional FreeBSD/OmniOS recovery fixture observes one real flush-daemon
failure within the same boot. Managed SSH verifies the root-owned PID marker,
saved executable mode/hash and live process. The fixture removes execute
permission, kills and confirms the daemon reaped, then requires three refusals
over the still-live readiness channel. A finally block restores the saved mode;
the supervisor must create a different PID with identical bytes/mode and boot
identity before real flush/refusal and readiness checks resume.

Four host snapshot-parser/failure-cleanup tests and Ruff/ty pass. The exact
vendor-base FreeBSD candidate completed both clean boots with real daemon death,
three live-channel refusals, exact executable restoration, a new supervised PID
and current-boot flush restored. The review binds the image, firmware/VMM hashes
and per-boot receipts. The final reviewed canonical-roots/SSH/blocking-flush image
also passed the same complete two-boot boundary. OmniOS requires its own replay;
admission remains false. This scope cannot establish
guest-crash durability, storage recovery, relocation, host failure or fleet
availability. A clean service restart is separate from a guest crash.

Evidence: [native recovery oracle](repo:nix/verification/tests/support/native_recovery.py),
[machine variant](repo:nix/verification/tests/machines/native-services/default.nix),
[native review](repo:docs/architecture/reviews/2026-10-17-native-kernel-attestation.md).

The separate [abrupt-crash fixture](repo:nix/verification/tests/support/native_crash_recovery.py)
flushes and reads back retained home bytes, observes actual VMM SIGKILL, then
boots the same disk under new MMDS identity. It requires a new boot ID, exact
retained bytes, old flush/workspace/terminal authority refusal, a native UFS
snapshot check or completed zero-error ZFS scrub, and final clean shutdown.
Seven host boundary checks passed. The first actual FreeBSD crash run exposed
scheduled-only UFS sync: after an acknowledged flush and SIGKILL, fsck discarded
managed-home and marker bytes. The correction uses `/dev/ufssuspend` to wait for
UFS suspension and soft-dependency drains, then immediately resumes before
acknowledgement. The final reviewed FreeBSD image passed all eight crash checks:
complete service oracles before/after observed SIGKILL, same-disk restart with
fresh MMDS/boot identity, exact retained marker/home bytes, stale-authority
refusal, native UFS snapshot background fsck and final clean exit. The review
binds exact image/kernel/firmware/VMM hashes and immutable crash/service receipts.
Pinned OmniOS ZFS sync already
blocks on `spa_sync_allpools`, but its crash scenario still needs execution.
This does not establish physical stable-media/host power-loss durability,
interrupted expansion or fleet recovery.

## Durable guest identity reservations

GuestAccount UUIDs and the noncycling UID range are permanent reservations,
including after retirement. Login `u<uid>` and home `/home/u<uid>` belong to that
allocation, never to the present owner of an email address. Preserve historical
rows and consumed sequence values; deleting reservations or resetting the
sequence is not an allocation-exhaustion recovery procedure.

Restoring an older database alongside newer retained guest disks is unsupported
until its guest UUID/UID reservations and sequence have been reconciled against
all retained state. A database restore can omit later identities whose files still
exist on disks, so the restored sequence alone cannot prove a UID is unused.
No external reservation registry or automatic historical-restore reconciliation
is implemented by this change. Both generated-identity guest lifecycle
journeys passed retirement, physical cleanup and retained shared home/process
checks on base `63a1443c` plus the durable feature before main integration.
Separate incoming `d4499c4c` merged eight-subtest lifecycle captures also passed
on NixOS (438.33 seconds) and Ubuntu (574.18 seconds); neither reconciles a
historical restore or establishes later incoming source. Complete Ubuntu SSH and
native editor acceptance retain their separate gaps under
[ADR-0158](repo:docs/architecture/decisions/0158-durable-guest-identities.md).

## Browser editor authority and worker recovery

A lost Marshall or database cannot grant new editor authority. Existing Audi
communication expires within its thirty-second lease unless current-account,
stored-login, write and exact execution/release authority renews. Hints prompt an
earlier renewal. A closed/expired lease or changed account, gateway, host session,
placement or execution cannot revive; reconnect requires fresh admission. Relay
closure is not proof that a guest terminal or extension process terminated.

Expired or revoked cookie/login identity starts the fixed browser sign-in flow
on a safe navigation. A fresh real login replaces the host cookie rather than
preserving a permanent unavailable page. Current write/account refusal stays
forbidden, while missing route/execution or unanswered login lookup remains
unavailable. New authentication cannot restore the old credential or expired
stream.

Systemd owns personal workers and mode-0600 sockets independently of the root
broker. Broker restart preserves them and saved personal data only when the
root-owned launch digest still matches UID/name/protocol/commit/release/origin.
Changed legitimate identity requires successful stop before replacement;
unanswered metadata and foreign socket custody refuse without stopping it.
If the worker exits,
the next freshly authorized broker use starts a new personal process without
deleting home or extension data. Upstream extension-host activity, its five-minute
idle timer and 1500-second reconnection grace govern automatic shutdown, rather
than an exact timestamp of the last raw relay close.

Operational Login/Credential/Lease/asset-receipt cleanup uses bounded seven-day
expiry batches, retaining credentials still referenced by leases. Audit versions
follow the separate ninety-day inventory. Neither pruning nor process restart
grants identity or cleanup authority over another account. Old guest disks retain
their immutable package capability; recreate from a matching image to acquire a
new release. Standalone native and full NixOS Marshall/Audi/Lilly/Firecracker
broker restart/worker loss passed with saved data. Actual NixOS stop/start preserved
placement/epoch, advanced logical generation, rotated challenge and guest boot UUID,
and required exact current-generation physical running/Provisioning readiness.
That record precedes the observability cutover. The merged driver requires the
current-generation authenticated physical start outcome's `guest_ready: true`;
the guest helper still proves its confined boot and host-local Provisioning journal.
No lifecycle diagnostic delivery is required for current readiness.
Ubuntu failed before these recovery assertions; physical faults and recurring
probe histories remain gaps in [scenario coverage](#coverage).

## Interrupted provisioning and templates

Source2 restart eligibility comes from the durable image manifest4 identity and
explicit source2 capability. An unavailable capability cannot roll back an
accepted crash, confirmed resized sizes or the next fresh host report. Recovery
refuses the restart and releases only confirmed stopped compute, retaining disk
and address. A confirmed resize completes with a fixed
`workspace_source_unavailable` failure so ordinary cleanup remains possible.
Existing command snapshots, boot bundles and journals remain immutable; obsolete
sourced guests require recreation on a current image. See [lifecycle](#lifecycle)
and the [source2 review](repo:docs/architecture/reviews/2026-10-10-browser-launcher.md)
for component and native evidence boundaries.

Repeated Start of a proven confined running VMM adopts the exact current intent's
generation into the same placement/epoch boot journal without replacing its
challenge or restarting the process. Missing, corrupt, foreign and regressing
boot identities remain refused. Current-generation readiness is still required;
the generated metadata histories and native repeated public Start with unchanged
process identity passed. Lilly keeps clone effect results only in memory: after
a Lilly restart Marshall re-offers every effect without a receipt and Lilly
re-executes it; correctness rests on idempotent effects and durable journals
(permits, snapshot index, copy journal, received datasets, keys), not on a
pending-result journal. Native clone cancellation accounting, restoration and
cleanup also passed. The final complete native clone matrix passed in 1539.61
seconds, including both independent cloned-guest relocations and surviving-copy
reads after source deletion. Native foreign/corrupt boot refusal and relocation
destination retry/cancellation accounting remain open.

Provisioning retries retain the launch-time readiness deadline and exact boot
binding. Stop/delete supersede progress only after physical cleanup; a progress
journal never proves that a process stopped or a disk disappeared. Foreign host
bindings and stale revisions cannot cancel progress.

A running boot without a readiness journal for its current generation, such as
one whose logical generation advanced, acquires one only under the placement lock
after the readiness claim confirms matching physical confinement and the exact
current boot record; the new journal supersedes the previous generation's record
([provisioning journal](repo:lilly/lib/lilly/vm/provisioning.ex)). Cached ready
records still require confinement; unfinished records retain their original
deadline. The original readiness rollout verified 20 retained Overalls boots and five Dungarees boots
through passive boot-bound polls before declaring activation. Both hosts then
activated `c98a375c` healthy; passive post-switch checks verified ready journals
for 17 Overalls and five Dungarees current retained boots. Three deletions preceded
activation. Historical terminal measurements retained the same digest. This does not
authorize resetting expired progress or rewriting finished SLO failures.

Template recovery resumes published staging, verification and sealing intents
under the exclusive image lease. A create interrupted before private mountpoint
permissions are set may repair those permissions only after matching native
dataset shape, owner nonce and any recorded GUID. Retirement confirms absence
before writing the deleted tombstone. Quarantine replacement creates a fresh
incarnation after confirmed retirement and rehashes source bytes. Foreign GUIDs,
owner tags, snapshots or unexpected files are refused without recursive cleanup.
Template state records survive release changes. Lifecycle journals accept only
the state-only v2 envelope; corrupt or other-version primary state fails closed
without rewriting, and diagnostics cannot gate actors or outcome ACKs.

Actor restart begins without volatile execution proof or a proof-target binding.
Recovery must verify the current confined VMM before publishing boot or live rows.
An exit observer retained after a negative observation preserves its genuine
terminal report; it cannot restore withdrawn authority. Replacement VMMs require
their own verified target and armed watcher before receiving the longer backstop.
Stopping the actor closes its observer while independently managed guests survive.
See the [execution proof boundary](#lifecycle) and scoped
[verification evidence](#coverage).

Root-disk preparation has no pre-cloned standby to recover: ADR-0177 retired
standby disks after both hosts drained them, so an interrupted create leaves
only its own owned dataset for ordinary disk recovery. A leftover `standby-*`
dataset is unknown storage; accounting withholds the pool rather than adopting
or deleting it, and an operator removes it (see [storage](#storage)). The
120-second native operation bound does not turn timeout into proof of cleanup.

## Retained profile migration

ADR-0151's one-way rename of retained `antithesis` profile values to `standard`
completed on both hosts; the 2026-10-11 preflight found no retained
`antithesis` value, and ADR-0159 removed the Lilly startup step. Lilly acquires
its host lock and validates the command store's retained host/version binding
before reading commands or starting actors. A missing lock, foreign store binding
or unreadable or malformed stored command refuses startup through the normal
lock-release path. Correct the binding or preserved source explicitly; never
erase evidence to force startup. The
[custody review](repo:docs/architecture/reviews/2026-10-10-profile-migration-custody.md)
records the historical migration scope; ADR-0159 pruned the applied migration
file. ADR-0147's accepted fresh-install
rationale remains intact; ADR-0151 is superseded by ADR-0159.

## Independent observability recovery

Disposable fleet reboot tests retain the public Audi issuer root separately from
encrypted credential bundles and restore that same root before Galileo starts.
Missing trust postpones startup; no fallback CA or additional private-key custody
is introduced. After a relocation endpoint reboot, actual host-bound Ziggy and
Audi-private readiness must recover within the existing setup bound before a
further guest is admitted. The earlier full relocation run passed its occupied
cancellation and endpoint-restart prefixes, then failed the next fresh guest on
a missing volatile public root before injecting its next fault. The corrected
complete native matrix passes all 19 subtests in 3643.75 seconds, including real
reboot/private readiness, endpoint updates, new-boot retry, source-pressure
fallback and destination ENOSPC recovery under unchanged faults and deadlines.
Its disposable machines share one KVM failure domain; retained-state upgrade,
physical-host power loss and production rollout remain separate. The
[verification ledger](#coverage) retains both the failure and exact passing scope.

Provisioner application documents now require version 4 on both endpoints;
control transport and native intent/descriptor versions remain independent.
The cut's database migration invalidated live connection freshness and
incremented host epochs while preserving all consumed session nonces, immutable
outcome receipts and historical diagnostic data; ADR-0159 pruned that applied
data statement. A delayed version-3 nonce cannot become
new authority. Upgrade Marshall and Lilly as one coordinated cut.

Observe collector/spool failures through Grafana and service logs. Do not erase
state journals or physical outcomes to clear a diagnostic backlog.
The trace spool confirms delivery only after a bounded, completely framed HTTP
success contains a valid OTLP response with absent or zero rejected spans. The
Collector's explicit empty `partial_success` is a valid success. Malformed,
truncated or nonzero-rejection replies retain pending data for retry; response
warning text stays private. Confirmed delivery clears pending work while retaining
the immutable archive until its configured expiry.
Successful delivery advances immediately to the next pending batch. Idle or
failed attempts back off for 250 milliseconds; maintenance and numeric health
publication use a separate cadence during continuous drain. Archive quotas and
service resource limits still apply, so production traffic and retention require
separate sizing evidence.
Existing native process, boot, storage and lease fences determine recovery even
while the observability backend is unavailable. Local properties cover this
independence. The [focused native recovery fixture](repo:nix/verification/tests/machines/fleet/scenarios/observability-recovery.py)
configures the production collector and trace spool, stops them on the worker,
reopens Lilly without replacing native VMMs, settles a fresh stop/start readiness
receipt, and recovers retained diagnostic custody. Its companion
[submission recovery histories](repo:nix/verification/tests/machines/fleet/scenarios/submission-recovery.py)
keep the before/after native launch barrier and exact-generation outcome oracle.
The final typed packaged recovery capture passed in 707.93 seconds on its
pre-Starship/pre-profile runtime. Its observer-outage subtest passed in 113.51
seconds, including the original 180-second drain bound
and an exact fresh native execution/revision, host, placement and running-transition
query through real Tempo. Both-host and generated before/after native-submission
daemon-loss histories also pass. These disposable-machine results establish that
scoped recovery journey. Earlier captures remain in the [verification ledger](#coverage);
merged guest execution, retained-state upgrade, physical host power loss,
production archive sizing and rollout remain separate acceptance work.

## Lost database clients

New production Repo connections check client disconnection during active SQL
once per second and request a 15-second TCP unacknowledged-data limit. They keep
the 15-second idle-transaction timeout and TCP keepalives after 15 seconds,
every 5 seconds, with three probes. Healthy SQL may run longer than the network
limit. A failed network connection can terminate sooner than under the previous
30-second limit; callers must still resolve uncertain commits through durable
idempotency. Existing connections keep their startup settings until reconnection.

The native recovery check observes three row-lock waiters before client-machine
loss and preserves the 20-second holder/35-second total reclamation assertions.
The combined correction passed a captured candidate, with the adopted recovery
executable inputs reviewed against that capture. Complete integrated NixOS and
Ubuntu terminal journeys separately passed machine-loss recovery, retained
effects and revocation. Physical/managed-provider acceptance remains separate. See
[ADR-0126](repo:docs/architecture/decisions/0126-bounded-database-client-recovery.md)
and the [verification reference](#reference).

The additional `database-recovery-active` fixture holds the same row lock during
a real ninety-second server statement, observes active holder state and three
queued waiters, then crashes the client machine. It retains the twenty-second
holder and thirty-five-second all-connection bounds. The initial active-holder
crash variant passed in 60.51 seconds with all ten sessions reclaimed in 19.518
seconds; it predates the final matrix and seeded submission orders.
The final six-case matrix combines both holder states with machine crash,
bidirectional packet loss and client-to-server packet loss. Link cases freeze
client userspace, retain kernel sockets and require positive DROP counters in
the tested direction. Seeded waiter submission permutations do not establish
PostgreSQL queue order. All six cases passed capture
`1790973915375-2537070-0.jsonl`, reclaiming all ten sessions in 19.432–27.882
seconds and subsequently reacquiring the row. The
[history review](repo:docs/architecture/reviews/2026-10-02-database-loss-histories.md)
retains pre-injection fixture failures and exact directional counters. Surviving
release contenders, repeated reconnect histories, uncertain commits and hosted
faults remain separate gaps.

## Guest CLI replacement

The immutable seed retains the previous managed executable until its candidate
registers. A spawn failure or unsuccessful ninety-second registration result
restores the prior executable before restarting the executor. Boot reconciliation
uses the installed bytes and saved applied identity; merely restarting systemd
must not leave an unexecutable candidate installed indefinitely. The existing
registration/status I/O error propagation remains outside this bounded repair.
The supervisor waits for graceful exit between commands before normal activation.

Actual-supervisor generated histories inspect file bytes, inode identity, drain
and retry in disposable Linux namespaces; their ready files represent synthetic
registration. A dedicated strict NixOS guest journey passed invalid-format and
registration-timeout recovery with the same supervisor, exact prior executable,
fresh Marshall fences and completed operator tool work after each failure.
Direct candidate injection bypasses artifact delivery. The
[recovery review](repo:docs/architecture/reviews/2026-09-26-guest-cli-recovery.md)
keeps these scopes separate from historical two-distribution private delivery,
power-loss/I/O failures and production rollout. Registration is readiness, not
code attestation or semantic rollback authority.

## Backup custody

Host backups use separate encrypted Restic repositories and independent passwords
per hostname. The default schedule is thirty minutes with a bounded per-host
delay; retention keeps twelve complete recovery points. Defaults are policy, not
proof that a deployment has configured or successfully restored backups.

```nix
services.overallsBackups = {
  enable = true;
  s3 = {
    endpoint = "https://objects.example.com";
    bucket = "node-recovery";
    region = "your-region";
    prefix = "hosts";
  };
  randomizedDelaySec = 300;
  retention.keepLast = 12;
};
```

Provision the encrypted host document with `RESTIC_PASSWORD`, `AWS_ACCESS_KEY_ID`
and `AWS_SECRET_ACCESS_KEY`. Keep an independent recovery identity off-host. A
hostname change selects a different repository unless explicitly migrated.

Rotating the `RESTIC_PASSWORD` value is a custody ceremony, not only a document
edit: add the new password to the repository with `restic key add` while the
old value remains published, deploy the replaced document, verify, then remove
the old key. Deploying the rotated document without that step wedges every
repository-mediated operation — scheduled backups report `failed` with the
`repository` failure label, inventories are untouched, and recovery decrypts
the previous document generation from Git history and adopts the published
password through `restic key passwd`. Recovery points captured before a
recovery-recipient turnover keep the historical recipient envelope for their
full retention window; keep the retiring identity available until those points
age out. The working-tree `check` and retention do not warn about stranded
historical generations today.

Role discovery includes selected host identity and configuration, Lilly journals
and owned drives, Marshall's logical database dump and encrypted key custody,
service keys, and selected spools. It does not back up every filesystem or memory.
Do not add managed guest pool parents to generic `extraPaths`.

A running guest receives a bounded boot-specific sync request. No freeze occurs;
an unconfirmed flush is recorded and capture can continue. Guest snapshots are
crash-consistent, not a transaction across applications and hosts. Stopped guests
are not started for backup.

```sh
systemctl start overalls-backup.service
overalls-backup list
overalls-backup inspect --snapshot FULL_SNAPSHOT_ID
overalls-backup check
overalls-backup read-check
overalls-backup cleanup
```

List reports host-manifest candidates; inspect validates the selected manifest
structure. Neither command proves that every referenced component is available;
restoration verifies each component as it is read.

Managed operations share a host lock. Do not run independent Restic mutations
concurrently. Failed cleanup retains ownership evidence and prevents publication
of a complete point. Never erase a journal to make backup status healthy.

Host snapshot cleanup compares the durable dataset GUID and local nonce before
unmounting or destroying. Foreign or inherited markers, changed GUIDs, conflicting
mounts and unavailable inspection retain the descriptor without destructive work.
An unrecorded snapshot GUID does not prevent cleanup when the remaining native
proofs match. Confirmed absence removes intent; an absent snapshot with a claiming
mount refuses. Uncertain inspection after destruction retains intent for retry.

Two generated properties through real cleanup/release passed the pinned Python 3.13
Nix check (thirteen workflow tests). They check exact descriptor bytes, command
counts and retry convergence using controlled ZFS/findmnt responses. This adds no
native mount, ZFS or power-loss evidence; see [scenario coverage](#coverage).
The [native HostCapture cleanup fixture](repo:docs/architecture/reviews/2026-10-03-native-backup-cleanup.md)
adds real snapshot/mount proofs, foreign-sentinel preservation and injected
inspection outages with exact once-only cleanup. Thirteen native histories
passed in 98 seconds. The [worker-death extension](repo:docs/architecture/reviews/2026-10-03-backup-cleanup-worker-death.md)
adds real transient worker/helper SIGKILL before/after destroy with mounted and
unmounted snapshots; the combined twenty-one-history native check passed in
134 seconds. Concurrent replacement during cleanup, full packaged orchestration and power
loss remain separate.
The [identity and pre-GUID fixture](repo:docs/architecture/reviews/2026-10-03-backup-native-identity-intent.md)
now replaces actual datasets/snapshots between cleanup calls without rewriting
descriptors, and tests intent before snapshot creation or GUID recording. Its
combined thirty-seven-history native check passed in 169 seconds. Replacement
during cleanup is still unverified.
The [packaged cleanup property](repo:docs/architecture/reviews/2026-10-03-backup-packaged-cleanup.md)
adds installed service/operator recovery histories for preparing, capturing and
cleaning interruptions. Foreign nonce uncertainty must remain visible and retryable;
valid cleanup closes the interrupted run as failed without advancing last success.
Native execution passed (138 seconds, exit 0); full capture/upload composition remains separate.

Every repository-touching operation — capture, init, list, inspect, restore,
prune and both integrity checks — validates private credential custody
immediately before repository access: the password file must be a regular,
single-link, owner-private, nonempty bounded file, and S3 repositories need
their credential environment. Insecure or missing custody closes the operation
with the `credentials` failure before any repository access; failed scheduled
runs keep the previous last-success timestamp.

An interrupted run is reconciled by the cleanup unit (boot and every five
minutes): a run that did not complete is recorded `failed(interrupted)` with
its cleanup retried, and its already-uploaded component snapshots remain as
unreferenced orphans retained for a one-day grace before retention may forget
them. If the run was stopped between manifest upload and completion, the
published host-manifest point stays listable, inspectable, restorable and
retention-counted; the local journal still records the run as
`failed(interrupted)`. An uncatchably killed writer leaves its Restic
repository lock behind: exclusive retention and integrity checks refuse closed
(no deletion) until
an operator removes the stale lock with `restic unlock`. Recovery never mutates
repository contents or a pool.

The [uploaded-point property](repo:docs/architecture/reviews/2026-10-03-backup-upload-publication-histories.md)
adds generated real local-Restic interruption after completed manifest upload,
exact payload restoration and keep_last 1/2/3 reference retention/expiry. The full
13-test suite passed in 1418 seconds; S3 and native mounted-reader recovery remain separate.

Backup subprocess retirement now keeps direct-leader identity unreaped until
its same-group readers and threads have stopped. Unavailable proc inspection
withholds cleanup; a zombie leader alone does not prove thread death.
The [reader-group review](repo:docs/architecture/reviews/2026-10-03-backup-reader-group-retirement.md)
records regression witnesses, pinned runtime8s and packaged cleanup121s passes. Command timeout does not
bound uninterruptible kernel shutdown; the inherited strict elapsed-time
requirement remains unverified for that boundary. Escaped reader groups and durable
deferred cleanup need separate containment and recovery evidence.

## Isolated restoration

1. Fence the failed host and old authority. Disconnection alone does not prove it
   is safe to run another copy.
2. Recover repository credentials off-host. The recovered document generation
   must be one the available identity can open: the current tree, or Git
   history when a recipient turnover happened since the point was captured.
   Build an isolated recovery machine
   with the original repository location. Keep serving applications, workers,
   host reconciliation and customer traffic disabled.
3. Restore a complete manifest into an empty private directory:

   ```sh
   overalls-backup restore --snapshot FULL_SNAPSHOT_ID --target /var/lib/recovery
   ```

   A failed component restore leaves earlier numbered output for inspection and
   does not write the final `manifest.json`. Preserve partial output, resolve the
   cause and explicitly retry into a fresh empty private directory. The command
   refuses an already populated target.

4. Check manifest digests, component inventories, original paths and drive sets.
   Restore PostgreSQL into a new isolated database with a compatible `pg_restore`,
   initially using `--no-owner --no-acl`. Reconstruct intended roles separately.
5. Recover the matching ordered Cloak keyring. Test application decryption,
   including retained certificate and ACME key material. SQL readability is
   insufficient. Keep issuance queues paused.
6. Restore all guest drives with sparse-file preservation. New datasets have new
   GUIDs; old ownership receipts do not automatically authorize them. Reconcile
   replacement host/pool identities and test boot/data in isolation.
7. Reconcile post-backup revocations, credentials, login/terminal authority, host
   epochs, VM generations, reservations and pending work against surviving state
   before any production activation.

```mermaid
flowchart LR
  Backup[Complete encrypted recovery point] --> Isolate[Restore without serving or workers]
  Isolate --> Verify[Verify data and key decryption]
  Verify --> Reconcile[Reconcile surviving physical state and authority]
  Reconcile --> Gate[Operator recovery acceptance]
  Gate --> Serve[Enable current authority and traffic]
```

Historical backups can resurrect revoked credentials and obsolete commands.
Automatic historical fleet reconciliation is not available. This manual therefore
does not prescribe a generic final activation command. Preserve uncertain capacity
until physical obligations are settled.

Recorded protection evidence pins the current boundary without changing it. In the
native restore drill the release boots operator-mode against the isolated restored
database with no serving listeners and an Oban instance normalized to no queues,
plugins, staging or peer leadership, so no AshOban trigger or queue consumer runs;
decryption succeeds only with the matching restored keyring. Lilly's
monotonic-per-placement command receipts, unauthorized and stale-session fencing
and guest-facing fresh-incarnation refusals retain fixed-test evidence. An
ambient-host inventory assertion was removed because readable empty inventory is
legitimate acceptance. The present native unit-inventory fixture uses real
tracked units and cgroups to inspect acceptance, omitted-placement refusal and
unknown-cgroup refusal. Its incoming `d4499c4c` merged subtest passed in 8.22
seconds within the complete native-zfs run that later failed unrelated
auto-update receipt validation: fixture `enrollment.json` omitted its required
string `revision`. No complete native suite pass is claimed. Later incoming
`bee03919` restores a deterministic child-BEAM unknown-unit/failed-scan utility
fixture; its incoming focused unit capture is separate from native cgroup
inventory. Composition of
inventory refusal into Runtime's host-wide initialization fence remains
source-inspection evidence, without a recorded complete native startup-fence
journey. A code-level historical-authority quarantine
gate remains a **proposal-only design pending user delegation** (candidate ADR-A
quarantine gate, ADR-B default-deny re-enablement); see the
[characterization review](repo:docs/architecture/reviews/2026-09-26-historical-authority-characterization.md).

Database HA, WAL archival, PITR and independent failure domains are separate from
the host logical backup. Test actual restore and key recovery. Retain original
state until acceptance, and record RPO/RTO from measured drills.

Evidence: [backup procedures](repo:docs/operations/backups.md),
[database recovery limits](repo:docs/operations/database-recovery.md),
[backup module](repo:nix/domains/system/backups/default.nix).

The [operator verification review](repo:docs/architecture/reviews/2026-09-26-backup-operator-verification.md)
tracks generated complete-manifest, reference-retention, host-lock and refusal
histories through local encrypted Restic. This evidence is separate from the
recorded native TLS, ZFS, database/keyring and guest recovery acceptance.
The [custody review](repo:docs/architecture/reviews/2026-09-26-custody-backup-key.md)
adds the exported `backup-custody` evaluation: the zero-failure key ceremony,
the exact wedge label and its previous-generation recovery, and
restore→decrypt→repository-access composition with the historical-generation
refusal, all synthetic.

## VM actor completion before recording

A generated local recovery history holds a completed executor result in a
suspended actor's mailbox while its journal still contains only attempt intent.
Actor death and two replacement lifetimes preserve one completed launch and the
exact recovered outcome identity and sequence. The four-property file passed;
the [recovery review](repo:docs/architecture/reviews/2026-10-03-lilly-completed-launch-recovery.md)
limits this evidence to actual actors and a durable controlled executor. Native
systemd, Firecracker, ZFS and full application death remain open.

## Host-effects engine loss

Lilly's leases live in `lilly-hostd`
([ADR-0176](repo:docs/architecture/decisions/0176-host-concurrency-single-writers-and-effects.md)
decision 4):

- **Lilly stops or crashes.** The session closes. hostd stops every queued wait,
  kills and reaps every command of that session through `cgroup.kill`, and only then
  releases its leases. This is the same fencing the per-lock helpers gave on caller
  death.
- **One Lilly process dies.** For example, a VM actor task killed by preemption.
  Lilly's session process releases that holder's leases, and hostd kills their
  commands before the release completes.
- **hostd stops or crashes.** Lilly is bound to it and stops too. systemd kills
  hostd's whole cgroup, including in-flight utilities, and a utility that outlives a
  crashed hostd still holds its inherited lock descriptor, so no successor is granted
  while it runs. On restart hostd kills any command cgroups left by its predecessor.
  VMMs are transient units outside hostd's cgroup and keep running.
- **A guest SSH session is live during a hostd or Lilly restart.** Its detached
  ingress bridge runs in its own `lilly-ingress-<key>.scope` in
  `lilly_ingress.slice`, outside both units, so the session continues
  ([ADR-0187](repo:docs/architecture/decisions/0187-detached-ingress-bridges.md)).
  The restarted Lilly lists live bridges through hostd. It gives each one with a
  readable record a keeper, which has 30 seconds to see its execution current
  again. It ends a bridge with no record at once, and one whose execution is not
  current in time. Editor and nested HTTPS connections still end, and their
  clients reconnect.

- **A template copy is in flight.** It runs as a durable hostd job keyed by
  its source, pending file and size. It survives a Lilly restart and keeps the
  template lease; the restarted Lilly attaches to it instead of copying again.
  A hostd restart still kills it, and the template journal restarts the build
  from its last state.

Evidence: the [hostd session tests](repo:lilly/native/hostd/src/tests.rs)
(`session-death-fences`, `durable-job-survives-session`) and the [lock test](repo:lilly/test/host/lock_test.exs)
(`holder-death-kills-leased-command`). Native evidence of cgroup custody under the
production unit comes from the module-based machine tests recorded in ADR-0176.

## SSH host authority recovery

The dedicated SSH CA has a recovery-only SOPS document and a separate Overalls
runtime bundle. Physical host SSH keys decrypt bundles; they are not the SSH CA.
Recover only into private runtime storage and verify the derived public key
against `secrets/ssh-host-ca.pub`. Changing SOPS recipients must preserve CA bytes.
An actual CA replacement requires independently verified explicit client trust
reconciliation; neither the installer nor proxy silently accepts a new authority.
Reissue cached gateway and guest certificates under the replacement authority.
Restarting a gateway retains a still-valid cached certificate, so signer
replacement and restart alone do not complete rotation.
The signer is online in Marshall, unlike TLS's root/intermediate arrangement.

The [publishing recovery property](repo:docs/architecture/reviews/2026-10-03-backup-publication-recovery.md) tests persisted
publishing journals through installed cleanup with retained component/manifest
references and unchanged last success. Combined native execution passed in 155 seconds; synthetic references
do not prove upload durability or producer-death recovery.
