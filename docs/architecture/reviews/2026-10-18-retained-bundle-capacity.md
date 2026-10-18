# Retained launch-bundle capacity review (2026-10-18)

## Problem and architecture impact

The allocation audit previously treated failure of the current launch-bundle
decoder as failure to recognize an otherwise exactly owned ready ZFS child.
One retained disk could therefore withhold the entire pool's capacity, including
unrelated healthy neighbors. The live audit encountered retained FreeBSD
version-3 bundles without the now-required kernel descriptor. This identifies
the failure trigger; it does not authorize launching that older shape.

The correction separates conservative storage recognition from executable
bundle acceptance under [ADR-0152](../decisions/0152-lean-pool-locked-preparation.md)
and [ADR-0159](../decisions/0159-remove-legacy-compatibility.md). There is no new
decoder, conversion, stored format, capability, deployment role or cleanup
authority. No accepted decision or implementation status changes. In particular,
ADR-0159's strict current format remains the only launch path.

## Authority and accounting

[`ZFSDataset.audit_child`](../../../lilly/lib/lilly/host/zfs_dataset.ex) still
requires the exact durable claim/spec binding, current host/pool/VM nonce,
native GUID, owned mount shape, complete closed file set, drive UID/type/length
and matching `disk.json` plus `disk-ready.json`. Any failure in those checks
continues to withhold the pool. Unknown children, foreign ownership and damaged
disk metadata are not recognized by this exception.

The fallback additionally requires a safely contained private single-link boot
marker no larger than 16 KiB and nonempty, single-link, root-owned regular boot
artifacts with mode 0444. Combined marker/artifact sizes must fit the protocol's
1 GiB bundle reservation. It does not decode the invalid marker's contents.
Unsafe custody or an exceeded bound still withholds the pool.

Only after those independent storage checks pass may
`WorkloadBundle.load/2` returning `:invalid_workload_bundle` recognize the child
without allocation credit. Its actual bytes remain included in measured ZFS
free space. The unchanged
[`Budget.physical_disk_available`](../../../marshall/lib/marshall/compute/budget.ex)
cannot offset an outstanding creation hold with that disk's allocation; settled
virtual disk promises remain separate from physical admission. This correction
changes neither the budget arithmetic nor startup settlement.

The disk's launch and readiness checks continue to require a valid current
bundle. Recognition rewrites no disk, manifest, marker or ownership metadata and
does not make an old image launchable, admitted, ready or deletable. Existing
cleanup and incompatible-state procedures retain their separate authority.

## Verification boundary

The focused [`zfs-retained-bundle` machine scenario](../../../nix/verification/tests/machines/zfs-lifecycle/retained-bundle.py)
prepares two real owned disks on a disposable mirrored ZFS pool and changes one
boot marker to unsupported version 999. Fresh probe processes require no credit
for that child, positive credit for its neighbor, readiness refusal and unchanged
marker SHA-256 on repeated observations. Corrupt disk metadata, unsafe kernel
permissions, a foreign nonce and an unexpected file must still withhold the pool. Restoring the original
marker restores both allocation credits before ordinary fixture deletion.

The focused check passed on 2026-10-18: test script 221.51 seconds, exit 0, at
`/nix/store/sy507h2ghlj0143c3snyfa06glk5x1c9-vm-test-run-overalls-zfs-retained-bundle.drv`.
It executed every positive and refusal step above, restored the original bundle
and deleted only its two disposable fixture disks.

This is a native storage test, with no guest boot or live fleet deployment. It
does not prove concurrent bundle replacement, every malformed bundle shape,
crash or physical power-loss behavior, workload availability or the removal of
production retained data. Lilly precommit retains its separate result; test
presence alone is not a passing result. Generated
ownership/capacity histories remain the preferred extension to this bounded
native case.

The current Lilly compiler passed with warnings as errors, its forced development
Dialyzer run reported zero errors, and 54 focused tests passed in 6.7 seconds.
The complete current test/precommit result remains separate. Narrow test-only
prerequisites avoid the pinned Hegel context-pattern expansion recursion and
restore bounded generator forms, real predicates and alphabets; they preserve
the original refusal and ownership oracles and change no dependency revision or
production storage contract.
