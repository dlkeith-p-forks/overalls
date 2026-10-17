# VM directory cleanup

## Scope and architecture impact

Repair ordinary ZFS deletion and retained-record retries to meet ADR-0017's
existing requirement to remove pool VM directories after physical cleanup.
The inherited storage contracts of ADR-0031/0035/0037 remain unchanged. No
protocol, database, resource ownership or deployment decision changes.

## Findings and implementation

A medium-severity implementation gap was corrected: dataset deletion confirmed native and mount absence but left the
canonical host directory behind. Retired claims returned success without
revisiting that directory, so retries could not repair accumulated leftovers.

[Dataset deletion](../../../lilly/lib/lilly/host/zfs_dataset.ex) now invokes
[empty-directory cleanup](../../../lilly/lib/lilly/host/empty_directory.ex)
only after the existing root/pool binding, ownership, native absence and mount
checks, while holding the pool mutation lock. Cleanup uses `File.lstat` and
nonrecursive `File.rmdir`; only root-owned directories or already-absent paths
are accepted. Nonempty paths, symlinks, other file types and filesystem failures
prevent success. Parent sync is required even when the path was already absent.

Active records remain deleting on cleanup or sync failure. Retired records
remain available for retries. Claims, deletion fences and lock inodes remain
intact. The sole ordinary deletion caller is the pool-locked Disk API; its error
continues to prevent the driver from confirming physical deletion. The filesystem
helper's injectable observations support rootless tests; production callers use
its fixed root ownership check and real sync command.

## Verification

[Rootless tests](../../../lilly/test/host/empty_directory_test.exs) exercise empty,
absent and repeated cleanup, filesystem errors, failed sync and retry, ownership,
symlinks, regular files, nested directories and FIFOs. Generated unexpected
filenames and bytes must survive refusal unchanged.

[Native lifecycle probes](../../../nix/verification/tests/machines/zfs-lifecycle/probe.exs)
assert directory absence after every successful deletion. The
[machine suite](../../../nix/verification/tests/machines/zfs-lifecycle/driver.py) covers real
interrupted destruction, retained-record repair, foreign ownership, remaining
mounts and replacement datasets. An isolated sync wrapper fails only the VM
parent sync and checks active/retired retries cannot acknowledge success early.

The pinned `devenv shell` Lilly `mix precommit` passed 279 tests/properties
(31 properties and 248 tests), compiler/format checks, contracts and forced
Dialyzer. The separate ADR validator passed 52 records. The task-branch native
suite passed in 471.80 seconds; the integrated native suite passed in 458.56
seconds, including every cleanup, retry, sync-failure and neighbor-preservation
probe. After integrating current main, Lilly's full gate passed 284
tests/properties (31 properties and 253 tests), forced Dialyzer and ADR validation.
Later upstream fleet/browser/documentation changes left the native lifecycle derivation
unchanged: `/nix/store/iv5szph2vbxm00hssqpw5himwdx0a3fg-vm-test-run-overalls-zfs-lifecycle.drv`.

## Host reconciliation

On Overalls, a fresh local audit found exactly 61 VM directories: seven live
native datasets and 54 empty leftovers. Under the existing `.lilly-storage/owner.lock`
flock, a one-off operator script rechecked pool GUID binding, root ownership,
retired claims and immutable specs, archived/deleted database rows, released
compute/disk reservations, native dataset absence, mount absence and empty
contents. It removed only those 54 directories using nonrecursive `rmdir` and
fsynced the parent before releasing the lock.

Postchecks confirmed seven unchanged dataset GUIDs/mountpoints, byte-identical
active and retired metadata, all 54 retained deletion records, unchanged database
rows and the same pool-lock inode. No production release was activated by this
operation. One older archived row has startup flags still set; its compute/disk
holds are false, and capacity accounting gates startup flags on those holds.
The audit preserved that row and all other database state.
Production release deployment remains separate from this repair.
