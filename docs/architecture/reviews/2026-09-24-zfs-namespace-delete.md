# Fenced ZFS namespace deletion review

## Observed failure and uncertainty

On September 24, Overalls had two deleted OSS placements whose native ZFS
children remained `deleting` and whose Marshall outcomes were `unknown` with
`cleanup_failed`. Ordinary `zfs destroy` reported `dataset is busy`. The exact
GUID-bound claims, absence of snapshots and children, inactive VM units, and
healthy pool were checked before a manual ordinary destroy attempt. The attempt
also returned busy. Other systemd services held mount namespace copies of the
same child at its canonical path. Both placements were later destroyed by
Lilly's normal reconciliation, with tombstones and freed capacity, after the
automatic update service exited. This is evidence of transient mount retention,
but does not identify the final process that released the reference.

## Architecture impact

[ADR-0112](../decisions/0112-zfs-namespace-delete.md) adds a narrow recovery
effect after the existing VM, jail, network, claim and GUID fences. The helper
inventory and recheck constrain ordinary unmount to the claimed ZFS root in
other namespaces. An active holder or ambiguous mount prevents deletion and
capacity release. The host lock owns the native effect; Lilly retains the
existing tombstone and verified-absence rule. Bounded retry delay reduces work
and duplicate audit events while uncertainty persists. No protocol, admission
authority or VM execution contract changes.

## Verification and remaining gaps

The dedicated NixOS check creates real Firecracker guests, starts a late
sandboxed service after a guest mount, tests deletion and survivor readability,
then proves an open file blocks another deletion until released. Unit/property
tests cover retry bounds. The final source-built machine check passed in 342
seconds. It detached nine copies after starting two late sandboxed services,
left those services and the neighboring guest active, observed the `busy`
audit outcome with the claim still `deleting`, then destroyed the disk after
the holder exited and verified no guest allocations remained. The native
package check also passed synthetic exact-root, alias, descendant, duplicate
and malformed mount inventories.

After commit `5d2e892d` reached healthy status through the auto update service
on both physical hosts, a disposable OSS guest was created on Overalls and
relocated to Dungarees. Lilly's structured cleanup event reported 13 detached
mount namespace copies on Overalls; its source dataset disappeared. The guest
accepted SSH commands after relocation as `geoffrey.huntley` in
`/home/geoffrey.huntley`. Deletion succeeded on Dungarees, whose cleanup event
reported nine detached copies; its ZFS pool then had no VM child. The existing
NixOS guest on Overalls still accepted SSH commands. This establishes the
helper's production privileges and the create, relocate and delete path. The
exact source of the original busy reference remains unproven.
