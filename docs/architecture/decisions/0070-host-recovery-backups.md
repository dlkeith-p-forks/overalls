# ADR-0070: Short-retention host recovery backups

- ID: ADR-0070
- Date: 2026-09-18
- Status: accepted
- Implementation: implemented
- Components: NixOS, Lilly storage and guests, Marshall Fleet, deployment secrets
- Supersedes: none
- Superseded by: none

## Context

The user authorized implementation, architectural documentation, tests, and merge
and push to main. The purpose is recovery from node or disk loss on Overalls,
Dungarees and future hosts. Deleted data does not need archival retention.
The same S3 destination serves the fleet, but each hostname needs independent
repository encryption. Marshall's encrypted runtime database URL determines the
PostgreSQL server to capture. Backup visibility belongs in the existing admin
fleet dashboards without making execution depend on Marshall availability.

The user explicitly selected flush-only guest coordination, continued capture
when a guest is stopped or unresponsive, a thirty-minute schedule with jitter,
and typed code and unit/property/native verification. They rejected a backwards
compatibility requirement for this new facility.

## Decision

Use the opt-in `services.overallsBackups` module and Restic over HTTPS S3. Place
one repository at `prefix/hostname`, with an independently generated encryption
password in the inventory's `hostname-backup` SOPS document. Host and recovery
recipients retain decryption capability through the existing secret system.
A hostname selects a repository; it never derives an encryption key. Plaintext
keys, database URLs and S3 credentials remain outside the Nix store and telemetry.
Changing recipients does not rotate a Restic repository's encryption key.

Schedule every thirty minutes with a configurable stable random delay of up to
five minutes. Explicitly configure that delay on both fleet hosts. Serialize
backup, cleanup, retention, integrity checks and operator repository operations.
Retain the latest twelve **complete host manifests**, with no daily/monthly/yearly
archive tiers. A manifest references separately captured guest, host and database
components. Retention follows references, including shared components; failed
runs never displace successful points. Unreferenced failed-run components have a
one-day grace period. Daily prune reclaims unreachable repository data. Provider
versioning and object-lock policies can retain older bytes independently.

Use a durable local host state machine: preparing, capturing, cleaning,
publishing, completed or failed. Each transition and captured component is
atomically persisted and synced. Terminal state requires verified cleanup;
interrupted work retains cleanup intent and is retried on boot and periodically.
A complete host manifest is published only after all required components succeed
and temporary native snapshots are confirmed absent. Marshall observes this
state; it does not orchestrate or gate backup progress. The Python coordinator retains this independent durable state machine. This
decision originally left Lilly snapshot transitions in its native journal because
Lilly had no Ash resource runtime; transition validation alone would not supply
durable effect recovery. [ADR-0074](0074-durable-lifecycle-state-machines.md) now
adds that runtime and a per-run snapshot graph with atomic audit, preserving the
independent coordinator, native ownership proofs and cleanup requirements.

Lilly inventories persistent VM ownership claims and takes an owned native ZFS
snapshot of each ready VM, including every configured drive. Before capture it
attempts an authenticated current-boot `sync` request over host-only vsock. This
is bounded and best effort: no freeze, pause, stop or guest start is permitted.
A missing helper, timeout or failed sync degrades the run but does not exclude
disks. The snapshot is crash-consistent; application-level transactions that have
not reached disk may require normal crash recovery. Pool space is checked before
capture and during upload. Cleanup requires the exact local nonce and GUID, never
a name alone. Lilly's existing pool ownership and mutation locks also govern
backup snapshots. Copy pool ownership/import/tombstone metadata under that lock
instead of creating an unrecognized snapshot of the pool parent.

Capture selected role state from read-only ZFS snapshots when it resides on ZFS;
other host files use normal Restic capture. Include host identity and declarative
recovery configuration, encrypted secret documents, Lilly control/network/VM and
transfer journals and image artifacts, Porsche key state, Audi SSH key state,
configured ACME certificate state and Ziggy's metadata spool. Under
[ADR-0105](0105-public-audi-wildcard-custody.md), public Audi ACME account and
certificate keys are Cloak ciphertext in Marshall's database backup, paired
with the separately protected Cloak keyring; Audi has no certificate directory
to back up.
Private-service TLS is a bundle-delivered fleet wildcard certificate under
[ADR-0078](0078-fleet-wildcard-certificate.md): its ciphertext is already
captured with the encrypted secret documents and no per-host certificate
state directory exists.
Ziggy requests, prompts and responses are not an executable replay log.

Use online `pg_dump` custom-format logical capture of precisely the database
identified by Marshall's runtime `DATABASE_URL`, with its CA and TLS verify-full.
No independent database endpoint, local fallback, base backup or replication
privileges are introduced. Validate client/server compatibility and archive
readability. Restore into an isolated database with explicit ownership/grant
reconstruction and the original application keyring; never start production
reconciliation against a restored historical authority automatically.
This logical host-recovery facility supplements the existing physical restore
drills for HA deployments. It does not remove their WAL, synchronous-replication,
physical-manifest verification or fencing requirements.

The independent fleet collector projects only closed state/failure labels and
bounded timestamps/counts. Admin views distinguish disabled, never-run, running,
healthy, degraded, failed, stale and unknown, retaining last-success information.
Neither these observations nor restored metadata authorize compute execution.
Node replacement requires fencing the old node and explicitly reconciling new
native GUIDs and current control-plane authority before serving traffic.

## Alternatives

- One shared Restic repository with multiple passwords: passwords unlock the
  same repository master keys, so they do not create per-host encryption domains.
- Freezing filesystems: disrupts interactive development and creates thaw/recovery
  obligations the user explicitly declined.
- Live copies of changing VM disk files: cannot establish a single crash-consistent
  disk image; native ZFS snapshots give a stable reader without staging full disks.
- Long retention tiers: conflict with recovery-focused deletion semantics.
- Physical PostgreSQL backups: require more privileges and server configuration,
  and risk choosing a different server from the application connection authority.
- A Marshall-controlled workflow: loses availability precisely when the control
  plane or its database is unavailable. Fleet monitoring remains observational.

## Consequences

The maximum nominal successful-point window is roughly six hours, but outages
can leave older last-good points. RPO is thirty minutes plus jitter and capture
runtime; this is not synchronous replication. Guest flush can briefly add I/O
latency without blocking writes as a filesystem freeze would. Independent
component captures have different timestamps, so disaster recovery must reconcile
historical control-plane state and disk contents in quarantine.

Backup snapshots consume pool headroom until upload and cleanup finish. Full
initial uploads and daily prune require bandwidth and capacity planning. Root
runtime credentials and metadata staging require private filesystem permissions.
S3 endpoint, bucket, region and real credentials remain deployment inputs;
production enablement stays off until those are supplied.

## Invariants and verification

- Stopped/unresponsive guests still get disk capture attempts; failed DB capture
  cannot suppress earlier guest attempts or publish a complete host point.
- Crash after native creation without a receipt remains discoverable by durable
  ownership intent; foreign snapshots and replaced datasets cannot be deleted.
- Terminal completion requires capture success, publication and verified cleanup.
- Every retained manifest's components survive retention; invalid manifests or
  missing retained references prevent all deletion.
- Credentials never enter argv, public descriptors, manifests or telemetry.
- New Python modules and tests pass strict type checking; Elixir interfaces have
  typespecs and consumer compiler/Dialyzer gates remain required.
- Native acceptance must exercise real ZFS, TLS S3, the configured remote
  PostgreSQL connection, guest sync and isolated restoration. Unit mocks alone
  do not establish recoverability or live Firecracker behavior.

## Implementation evidence

The [uploaded point property](../../../nix/verification/tests/evaluation/backup-operators.py)
adds generated actual local-Restic manifest interruption, byte-exact restore and
retention expiry histories; full13-test suite1418s passed in the [review](../reviews/2026-10-03-backup-upload-publication-histories.md).
S3/native-reader/during-upload acceptance remains separate.

The [reader retirement repair](../../../nix/domains/system/backups/common.py) preserves
unreaped group identity and requires native task death proof before returning to
cleanup. Actual leader-exit and pthread properties are in the [review](../reviews/2026-10-03-backup-reader-group-retirement.md);
pinned compilation/type/runtime8s and packaged cleanup121s passed. The inherited native shutdown bound remains an explicit
contract gap; command timeout is not reader death proof.

The [publishing recovery property](../../../nix/verification/tests/machines/backup-cleanup/packaged_cleanup.py)
adds installed cleanup for synthetic publishing journal boundaries; combined
native execution passed in 155 seconds, exit 0, in the [review](../reviews/2026-10-03-backup-publication-recovery.md).
This is not actual upload or producer-death acceptance.

The [packaged cleanup property](../../../nix/verification/tests/machines/backup-cleanup/packaged_cleanup.py)
exercises the installed service/operator through interrupted preparing, capturing
and cleaning runs, shared-lock contention and foreign nonce refusal. Pinned typing
passed; native execution passed in 138 seconds, exit 0, in the [review](../reviews/2026-10-03-backup-packaged-cleanup.md).
Full capture/upload composition remains separate.

The [native identity/pre-GUID properties](../../../nix/verification/tests/machines/backup-cleanup/native_cleanup.py)
retain original descriptors while replacing actual native objects, and exercise
cleanup before snapshot creation or GUID recording. Typing and the combined
thirty-seven-history native check passed (169 seconds, exit 0) in the [scoped review](../reviews/2026-10-03-backup-native-identity-intent.md).
Sequential replacement refusal does not establish concurrent mutation fencing.

The [native cleanup worker-death property](../../../nix/verification/tests/machines/backup-cleanup/native_cleanup.py)
adds actual systemd worker/helper SIGKILL before/after native destruction, exact
retained descriptor and once-only successful destruction across replay. Typing
passed; combined native execution passed in 134 seconds, exit 0, in the
[worker-death review](../reviews/2026-10-03-backup-cleanup-worker-death.md). It
does not establish complete packaged cleanup orchestration or power loss.

The [native host cleanup property](../../../nix/verification/tests/machines/backup-cleanup/native_cleanup.py)
extends HostCapture proof refusal and post-destroy replay checks to real ZFS and
mounts. Pinned Python 3.13 typing and native execution passed (98 seconds,
exit 0), as recorded in the
[scoped review](../reviews/2026-10-03-native-backup-cleanup.md). This does not grant
new production or historical recovery authority.

The [owned cleanup history review](../reviews/2026-10-03-backup-owned-cleanup-histories.md)
records two additional generated properties through real HostCapture cleanup/release:
exact retained intent and zero destructive calls on proof refusal, pre-GUID cleanup,
and once-only destruction across uncertain retry. The pinned Python 3.13 Nix gate
passed all thirteen workflow tests, including both properties. Controlled native
command results do not extend the historical native ZFS acceptance scope.

The [module](../../../nix/domains/system/backups/default.nix),
[coordinator](../../../nix/domains/system/backups/runtime.py),
[journal](../../../nix/domains/system/backups/journal.py),
[reference retention](../../../nix/domains/system/backups/restic.py),
[Lilly boundary](../../../lilly/lib/lilly/backup.ex) and
[owned snapshots](../../../lilly/lib/lilly/host/backup_snapshot.ex) implement the
initial workflow. [Guest flush](../../../nix/domains/artifacts/guest/flush.py) is installed
in the NixOS and Ubuntu images. Fleet projection (`nix/domains/system/fleet-monitor/backup_status.py` at kittens revision `a99f74f0`, repository deleted)
and admin rendering (`marshall/lib/marshall_web/live/admin/dashboard_live.ex` at kittens revision `a99f74f0`, repository deleted)
provide observational status.

[State and credential tests](../../../nix/verification/tests/evaluation/backup-state.py),
[failure and generated retention tests](../../../nix/verification/tests/evaluation/backup-workflow.py)
and [the strict typing gate](../../../nix/verification/tests/evaluation/backup-types.nix) provide
unit-level evidence. [Native recovery tests](../../../nix/verification/tests/machines/backups/default.nix)
pass real ZFS, TLS S3, configured remote PostgreSQL, isolated file/database restore,
retention, exclusions and credential-independent cleanup. The recovery test also
starts a fresh Marshall release against its restored database. An unrelated
keyring fails to decrypt the real AshCloak wildcard and account fields; the
matching restored fixture keyring decrypts them and verifies saved digests.
[Firecracker recovery tests](../../../nix/verification/tests/machines/zfs-guest/backups.py) pass
flush-only running/stopped/unresponsive captures, isolated disk restore, transfer
coexistence, foreign snapshot refusal and cleanup after process loss following
native creation. Both application precommit/Dialyzer gates pass; the
[review](../reviews/2026-09-18-host-recovery-backups.md) records scope and counts.
The [recovery guide](../../operations/backups.md) documents explicit operator fencing and
replacement-identity reconciliation. This establishes isolated implementation
acceptance, not production enablement, physical power-loss testing or automatic
restoration of historical authority. The extended native drill additionally pins
the boundary that a release booted in operator mode against the isolated restored
database binds no listeners and runs no Oban queues, plugins, staging or peer
leadership; the fixed Lilly fence characterizations and the full findings are in
the [historical-authority characterization review](../reviews/2026-09-26-historical-authority-characterization.md).

The [operator verification review](../reviews/2026-09-26-backup-operator-verification.md)
tracks [generated public-runtime histories](../../../nix/verification/tests/evaluation/backup-operators.py)
against local encrypted Restic: complete manifest parsing, shared-reference
retention, lock contention, refusal inventories and explicit fresh-target recovery
after partial restoration. This adds verification of existing decisions; native
and production evidence retains its original scope.

The [custody review](../reviews/2026-09-26-custody-backup-key.md) adds the
[backup-custody evaluation check](../../../nix/verification/tests/evaluation/backup-custody.py):
the documented zero-failure password key ceremony, the exact `repository`-label
wedge when a rotated password deploys without the preceding `restic key`
ceremony together with its previous-generation recovery, and the
restore→decrypt→repository-access composition including the
historical-generation refusal leg. The wedge and the operator key ceremony were
previously undocumented; this decision and its runtime contracts are unchanged.
Native and production evidence retains its original scope.The [updater custody histories](../../../nix/verification/tests/machines/auto-update/custody_histories.py)
pin host-side behavior when a host is removed from any SOPS document its
configuration still selects, including `hostname-backup`: recipient-keyed
resolution fails closed at updater staging (`operation_failed`/`stage`) with the
documented capped backoff, retains the last published bundle and recovers after
a custody or configuration fix. Evidence only; no recipient or repository-key
semantics changed.
The [interruption and custody review](../reviews/2026-09-27-backup-interruptions.md)
extends those histories: credential-custody validation (already required on the
capture path) is now enforced by [repository commands](../../../nix/domains/system/backups/restic.py)
immediately before every repository operation, closing a refusal asymmetry for
operator list/inspect/restore/init and scheduled prune/check. Generated
SIGTERM/SIGKILL/timeout interruptions per restore component, kill-during-upload
reconciliation through the cleanup unit, one-day orphan grace, the
published-before-completion point semantics and the mid-restore credential-swap
closure are pinned with real runtime processes. Restored `.lilly-zfs` ownership
metadata with divergent live GUID identity is refused by the claim/journal
layers without reactivation. These are evidence additions and one custody-gate
repair under the accepted decisions above; no decision changed.

## Open questions

The production S3 endpoint, bucket, region and credentials have not been supplied.
They are required for enablement, not for isolated implementation verification.

## Related decisions

- [ADR-0029](0029-database-durability-and-recovery.md): historical database recovery restrictions.
- [ADR-0044](0044-recovery-only-secret-documents.md): recovery-only secret custody.
- [ADR-0060](0060-detailed-fleet-monitoring.md): independent fleet observations.
- [ADR-0062](0062-interactive-monitoring-dashboards.md): administrator dashboards.
- [Implementation review](../reviews/2026-09-18-host-recovery-backups.md): evidence and remaining acceptance.
