# ADR-0164: ARC budget, dnode limit and safe guest memory decrease

- ID: ADR-0164
- Date: 2026-10-13
- Status: accepted
- Implementation: partial
- Components: fleet host budgets, NixOS host profile, auto-update resource policy
- Supersedes: none
- Superseded by: none

## Context

Both fleet hosts (125 GiB RAM) capped the ZFS ARC at 4 GiB while serving
hundreds of mounted guest datasets (ADR-0146 standbys, templates, guests).
ARC metadata sat at 3.86 GiB of 4 and dnodes at 1.1 GiB, above the default
dnode limit, so `arc_prune` had consumed most of a core for nineteen days
(host load 18–23) and every storage operation paid for metadata eviction. The
guest memory budget (`guestMemoryMiB` 116036) left no room to raise the ARC,
and the resource policy (ADR-0045 evidence, ADR-0036) refused every CPU, RAM
and quota decrease as maintenance.

## Decision

1. **ARC budget.** `budgets.arcMaxMiB` is 24576 on overalls and dungarees and
   `guestMemoryMiB` is 95232, keeping the same host envelope. The host profile
   sets `zfs_arc_dnode_limit` to a quarter of the ARC maximum beside
   `zfs_arc_max` at boot.
2. **Live application.** The updater's resource policy writes and verifies
   `zfs_arc_dnode_limit` beside `zfs_arc_max` on every apply, so the change
   needs no reboot.
3. **Safe memory decrease.** A RAM ceiling decrease is compatible. Immediately
   before changing the slice, apply reads `lilly.slice` `memory.current`; the
   decrease is applied only when that use plus two GiB of headroom fits under
   the new ceiling, otherwise it refuses `resource_decrease_unsafe` and leaves
   every setting untouched, which fails the update and keeps the previous
   revision serving. CPU and quota decreases still require maintenance.

## Alternatives

- Rebooting the hosts with a larger ARC: rejected; the resource policy already
  applies module parameters live, and a reboot evicts every guest.
- Keeping 128 standbys and raising the ARC further: rejected with ADR-0163;
  the standby count buys nothing beyond one sealed disk per image.
- Allowing any decrease: rejected; a ceiling below live use would make the
  kernel reclaim from running guests.

## Consequences

The ARC holds the fleet's dataset metadata; `arc_prune` returns to idle and
pool-lock holders stop paying for eviction. The guest budget Marshall admits
against shrinks by about 20 GiB per host while about 14 GiB is allocated. An
unsafe decrease is a refused update with a closed reason, not a maintenance
window.

## Invariants and verification

- `zfs_arc_dnode_limit` equals `arcMaxBytes / 4` after boot and after apply.
- A RAM decrease is applied only if `memory.current + 2 GiB ≤ new ceiling`,
  read just before the change; a refused decrease changes nothing.
- CPU and quota ceilings never decrease outside maintenance.
- Unit tests `nix/tests/machines/auto-update/resources_test.py`; the native
  `auto-update` resource fragment raises, safely lowers and then refuses an
  unsafe decrease.

## Implementation evidence

- Budgets and boot parameters: [overalls](../../../fleet/hosts/overalls/host.json),
  [dungarees](../../../fleet/hosts/dungarees/host.json),
  [host profile](../../../nix/hosts/profile.nix).
- Live application and safe decrease:
  [resources.py](../../../nix/modules/auto-update/resources.py)
  (`compatible`, `Transition.apply_native`, `dnode_limit`).
- Tests: [resources_test.py](../../../nix/tests/machines/auto-update/resources_test.py),
  [native_resources.py](../../../nix/tests/machines/auto-update/native_resources.py).
- Fleet activation (ARC size, `arc_prune` CPU, host load) is recorded in the
  [storage churn review](../reviews/2026-10-13-storage-churn-and-capacity-damping.md)
  when it happens, dungarees first.

## Rollout note (2026-10-13)

The compatibility predicate runs in the *live* updater (its own
`resourcePolicyHelper`), not the candidate's, so the first push carrying the
budget change (`31b56c321`) was refused on both hosts at preflight with
`lilly_binding_change`: the old predicate still rejected the RAM decrease. The
budgets were reverted in a corrective push so the updater that permits a safe
decrease deploys first, and the budget change follows in its own push. Any
future decrease of a ceiling has the same two-push shape.

## Open questions

- Whether the two GiB headroom should scale with the number of running guests.

## Related decisions

- [ADR-0163](0163-bounded-standby-refill-and-capacity-damping.md): fewer
  mounted standbys reduce the metadata the ARC must hold.
- [ADR-0045](0045-declarative-lilly-enrollment.md): enrollment validates the
  initial budgets; ordinary resource transitions are the updater's.
- [ADR-0036](0036-automatic-host-updates.md): the updater applies the policy.
- [ADR-0031](0031-sparse-zfs-storage-and-capacity.md): ZFS storage and
  capacity accounting.
