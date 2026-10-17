# ADR-0144: Keep guest datasets out of Nix build namespaces

- ID: ADR-0144
- Date: 2026-10-07
- Status: accepted
- Implementation: partial
- Components: Lilly Host, NixOS deployment
- Supersedes: none
- Superseded by: none

## Context

A templates-off benchmark delete on Overalls (2026-10-07) waited more than
nine minutes. During that time Lilly's ADR-0143 stage diagnostics recorded 42
consecutive `lilly.zfs_delete_unconfirmed` events at stage `destroy`, each
paired with `lilly.zfs_namespace_cleanup_unconfirmed`. Read-only inspection
found:
- no live process in a foreign mount namespace holding the guest dataset;
- one namespace pinned by a `nix-daemon` build worker's descriptor that
  contained the exact dataset root at its canonical path, while the host had
  already unmounted it.

The build had started after the guest was created, so the guest mount was
copied into the build's namespace.

Nix sandboxes builds in user namespaces, so copies taken from the more
privileged namespace are locked. A host unmount does not propagate to them, and
an ordinary unmount from Lilly's [namespace helper](../../../lilly/native/zfs-namespace-unmount/src/lib.rs)
is refused even for root. The helper correctly fails closed, and deletion
waits until the build exits. Overalls builds continuously (auto-update and
development), which explains the historical 5–23 minute delete tail on busy
days. [ADR-0112](0112-zfs-namespace-delete.md) covers systemd service copies
and descriptor-pinned namespaces whose mounts are not locked; this case is
outside it.

## Decision

On every Lilly host with ZFS pools, `nix-daemon` runs in its own slave mount
namespace (`PrivateMounts=yes`). A wrapper `ExecStart` removes every Lilly pool
mount (`umount --recursive --lazy` of each pool path) in the daemon process's
own namespace, then `exec`s the daemon. `ExecStartPre` gets a separate
namespace, so it cannot do this. The namespace stays a slave so host unmounts
still propagate. With no pool mount left, later guest mounts have no parent to
propagate into, and build sandboxes, which copy the daemon's namespace, never
contain a guest dataset. The daemon starts after `zfs-mount.service`; a pool
remounted after the daemon starts requires a daemon restart.

Root builds must not bypass this. Root otherwise builds in the local store from
its own namespace, and the auto-updater runs `nix build` as root on every
deploy. So:
- the `overalls-auto-update` service sets `NIX_REMOTE=daemon`;
- Lilly hosts set `NIX_REMOTE=daemon` for root shells.

Builds therefore never inherit a guest dataset, whenever the guest was created.
The namespace helper's fail-closed rules are unchanged.

Authorization: the user's request to make deletion faster and the explicit
instruction to do whatever is needed on this development fleet (2026-10-07).

## Alternatives

- **Make the helper detach locked copies or force unmounts.** The kernel forbids
  unmounting locked mounts; lazily detaching or killing the build would
  violate ADR-0112's never-force rule.
- **Make the pool mount private on the host.** This would also stop propagation
  into service and jailer namespaces that rely on host unmounts propagating,
  widening the blast radius beyond Nix.
- **Report deletion before physical destroy.** This contradicts the accepted
  rule that deletion observes dataset absence before success.

## Consequences

- Deletes no longer wait for unrelated Nix builds.
- `nix-daemon` no longer sees host mounts made after it starts; builds do not
  need Lilly pools or later mounts.
- Changing the unit restarts `nix-daemon` on activation, as any daemon unit
  change does.
- Other user-namespace holders (manual `unshare -U`) can still block deletion,
  which ADR-0112 keeps failing closed.

## Invariants and verification

- A sandboxed Nix build running while a guest dataset is mounted MUST NOT
  prevent that guest's fenced deletion. Covered by the native
  [namespace-cleanup test](../../../nix/verification/tests/machines/zfs-guest/namespace-cleanup.py)
  (`nix-sandbox-never-holds-guest-dataset`).
- The existing service-copy, descriptor-pinned, proc-less, generated-history and
  open-file subtests MUST keep passing.
- Production: deletes during builds complete without repeated stage-`destroy`
  refusals.
- Native iterations reproduced the production failure:
  - **Root local-store build:** the sandbox inherited the caller's namespace.
  - **`ExecStartPre` plus `MountFlags=private`:** the unmount ran in a separate
    namespace, and the private daemon namespace itself retained the guest mount
    because no host unmount propagated into it.
  - **Fix:** the in-process wrapper with slave propagation addresses both.

## Implementation evidence

[Lilly module `nix-daemon` isolation](../../../nix/domains/system/lilly.nix)
(`nix-builds-exclude-guest-datasets`) and
[auto-update daemon routing](../../../nix/domains/system/auto-update/default.nix)
(`update-builds-use-isolated-daemon`). The native namespace-cleanup suite passed
(test script finished in 1652.69s), including `nix-sandbox-never-holds-guest-dataset`
and every pre-existing subtest; see the
[latency review](../reviews/2026-10-05-create-clone-delete-latency.md). Production:
- deployed as `4ab664a5`;
- `nix-daemon`'s namespace held 0 pool mounts on both hosts (Overalls host: 9);
- a live NixOS test build's sandbox held 0 guest mounts;
- with six test-build processes running, a live cycle deleted its VMs in 3.2 s
  and 4.2 s, with no `zfs_delete_unconfirmed` events.

On 2026-10-16 the same failure appeared outside Nix: on Overalls, Prometheus
and VictoriaLogs (`PrivateUsers=true`) and a rootless podman held slave copies
of `/var/lib/lilly/pool` (`master:176`) inside user namespaces, so every guest
dataset mount propagated into them locked and fenced deletion reported
`zfs_dataset_cleanup_unconfirmed` (11 guests needed manual dataset destruction).
Dungarees runs none of these and deleted cleanly. The
[Lilly module](../../../nix/domains/system/lilly.nix) now adds `lilly-pool-propagation`,
which makes each pool mount recursively private before Lilly starts, so guest
mounts no longer propagate into any other namespace and existing slaves leave
the pool's peer group. Namespaces created while guests are mounted still copy
those mounts; the nix-daemon unmount above remains the guard for builds.

## Open questions

None.

## Related decisions

- [ADR-0112](0112-zfs-namespace-delete.md)
- [ADR-0143](0143-faster-create-clone-delete.md)
