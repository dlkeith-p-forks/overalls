# Backup workload scope

The `backup` template uses the production `nix/domains/system/backups/*.py` operator and
the pinned Restic executable against a private, disposable encrypted repository.
Raw Restic enumeration and restored file hashes form the independent oracle;
operator `inspect`, `prune`, `backup`, and `restore` are exercised as the system
under test. A fixed Restic gate creates an upload reply-loss or component restore
interruption window. No persistent host, S3 bucket, production credentials, or
live recovery target is used.

The commands cover retained manifest reference closure, an uploaded point whose
local reply was lost, a partial restore with absent publication marker and fresh
retry, coordinator-produced manifest schema compatibility, and private-target
quarantine of separately timed components. Antithesis does not step the wall
clock backward here, so the coordinator compatibility command uses a labelled
STUB (harness) for an SDK-chosen quarter of cases: `backward_clock_step`
preloads the image's pinned libfaketime into the coordinator process alone and
`helper_clock_step.py`, named as its Restic executable, steps that clock back
120 seconds when the host-state upload begins. Restic and the raw oracle are
unaffected and every existing `always` check applies. It is not evidence of a
real host clock step. The mixed-time fixture contains
synthetic host and guest bytes; it has no activation or reentry receipt and makes
no claim about live fleet authority or UID reconciliation.

The `backup-restic` selection runs these commands with `ANTITHESIS_BACKUP_ROOT`
pointing at a dedicated private named volume from `config/compose.backup.yaml`;
`fixture_root()` refuses a relative, linked or group/other-writable root rather
than falling back elsewhere. Without that variable the process temporary
directory is used. The repository is a local file backend on purpose: the
production operator's single failure exit status cannot distinguish network
unavailability from a validator refusal, so a remote backend would weaken the
oracle under network faults.

`backup-interrupted-cleanup-owned-only` still needs a disposable native ZFS
fixture that runs the production `HostCapture` with read-only independent GUID,
nonce, mount, and journal observations. The workload container has no ZFS
authority. No hosted SDK assertion for that property is emitted until this
fixture exists. Native machine tests under `nix/verification/tests/machines/backup-cleanup/`
are separate historical evidence.
