# ADR-0112: Fenced ZFS deletion across mount namespaces

- ID: ADR-0112
- Date: 2026-09-24
- Status: accepted
- Implementation: implemented
- Components: Lilly VM, Lilly Host, NixOS deployment
- Supersedes: none
- Superseded by: none

## Context

Lilly deletes a placement only after stopping its VMM, cleaning its jail and
network, and verifying the durable ZFS ownership claim. On September 24, two
deleted placements on Overalls remained in `cleanup_failed` while ordinary
`zfs destroy` reported a busy dataset. The host had no VM unit for those
placements, but other services had copies of the ZFS mount in separate mount
namespaces. Both placements were ultimately destroyed by Lilly without a host
reboot. The timing, close to an automatic update build ending, does not prove
which mount copy held the last reference. Repeated one-second attempts produced
excessive ZFS work and audit events while Marshall retained the reservation.

## Decision

After the existing physical-stop and jail/network cleanup, Lilly persists the
deleting fence and verifies the exact native dataset GUID and claim. A native
helper owned by Lilly's host lock inventories other mount namespaces. It may
perform an ordinary unmount only when the namespace contains exactly one ZFS
root mount with the claimed dataset source at its canonical placement path and
no related alias or descendant mount. It rechecks inside that namespace
immediately before unmount. A busy mount, unreadable inventory, namespace race,
unknown alias, detected race or failed command leaves deletion unconfirmed. Lilly then uses
its existing nonrecursive, nonforced `zfs destroy` and confirms native absence
before retiring the claim. No force or lazy detach, process kill, host restart
or capacity release follows an uncertain result.

Repeated `cleanup_failed` outcomes for the same delete command use a bounded
exponential delay up to 30 seconds. A newer command clears the delay. Audit
events contain a placement ID, bounded outcome atom and count of detached
namespaces; they contain no mount path, utility output or guest payload.

## Alternatives

Waiting indefinitely for unrelated services or builds to exit leaves disk
reservation and deletion stuck. A forced ZFS destroy or lazy unmount could hide
an active file reference without proving physical cleanup. Restarting host
services or the physical host risks unrelated running guests. Unmounting by
path without checking source, root and namespace would allow one placement's
deletion to disturb a different mount.

## Consequences

The helper scans bounded `/proc` mount inventories, so a host with an unreadable
or unusually large namespace set may retain a deletion fence until the next
retry or operator investigation. Ordinary unmount can still return busy for a
live file handle. Namespace copies created after the scan are handled by later
reconciliation. Lilly's host lock prevents competing Lilly effects; foreign
host processes remain outside its control, so every physical effect is checked
again before a deleted outcome.

## Invariants and verification

- No namespace operation precedes the durable deleting fence and exact native
  GUID/claim verification.
- Unknown, busy and detected raced mounts preserve the dataset and retained capacity.
- A later guest remains running and readable while an older guest is deleted.
- A live file holder blocks deletion; releasing it permits the same fenced
  deletion to finish.
- A real NixOS machine check exercises Firecracker, late sandboxed mount copies,
  a busy holder and a surviving guest without rebooting the host.

## Implementation evidence

The [delete path](../../../lilly/lib/lilly/host/zfs_dataset.ex),
[native helper](../../../lilly/native/zfs-namespace-unmount/src/lib.rs) and
[command lock](../../../lilly/lib/lilly/host/command.ex) implement the boundary.
The [actor](../../../lilly/lib/lilly/vm/actor.ex) uses bounded
[retry delays](../../../lilly/lib/lilly/vm/delete_retry.ex). The
[machine scenario](../../../nix/tests/machines/zfs-guest/namespace-cleanup.py)
and [property test](../../../lilly/test/vm/delete_retry_test.exs) are the
verification points. The source-built machine scenario passed in 342 seconds:
it detached nine late namespace copies, preserved a running neighbor, blocked
deletion for an open file, then completed the same fenced deletion after release.
Production auto update reported revision `5d2e892d` healthy on Overalls and
Dungarees. A disposable OSS guest was created on Overalls, relocated to
Dungarees, reached a shell as `geoffrey.huntley` in `/home/geoffrey.huntley`,
and was deleted. The source and destination datasets disappeared; Lilly's
structured events recorded 13 and nine detached namespace copies respectively.
An unrelated NixOS guest remained reachable and readable after deletion.

The [Galileo production review](../reviews/2026-10-02-galileo-production.md)
reproduces a second inventory gap: a retained namespace can hide proc, making
path-based self/mountinfo unavailable after entry. The helper now pins the
host proc directory and opens current inventory through that handle only after
entering the inspected namespace, including the pre-unmount recheck. It does
not reuse a pre-opened host inventory or relax any exact-root/refusal fence.
The extended native fixture hides proc in its private child before retaining
the namespace descriptor; its new stage reproduced unconfirmed deletion before
repair. The repaired full native check passed in 563 seconds including build
time, preserving busy-file refusal and the unrelated guest. The review records
Lilly's 468-check full gate and zero-error forced Dialyzer. After both hosts
recorded healthy `b9790a5c`, the original source deletion completed normally.
Original source and target request receipts succeeded; exact-two SQL/ZFS/systemd
audits confirmed deleted rows, released reservations, absent datasets and inactive
VMM units. This establishes the observed proc-less recovery, not arbitrary churn.

## Open questions

The [descriptor history review](../reviews/2026-10-02-namespace-descriptor-histories.md)
records a passed six-case native verification extension: one/two/four distinct
empty namespaces, duplicate descriptors, optional original closure before
cleanup and hidden proc. Independent complete descriptor identities and actual
before/after target mounts must accompany dataset absence and survivor checks.
Production helper behavior and configured limits remain unchanged. Native
execution failed the first generated exact-root precondition before deletion;
the corrected complete native run subsequently passed all six histories and
the original busy-file fence/retry cases in 1,986.83 seconds. This does not establish descriptor races
during a sweep.

The focused diagnostic in `/tmp/overalls-namespace-focused-isolated.log` passed
in 164.09 seconds: both retained descriptors saw the canonical root plus three
jail bindings while running and only the canonical root after normal stop.
Corrected generated histories stop at generation 2 before copying namespaces
and delete at generation 3. This diagnoses the fixture precondition; full native
deletion subsequently passed in the separate complete capture
`1790976634771-19384-0.jsonl`, while during-sweep races remain unverified.

The integrated native check reused the exact corrected namespace derivation,
with no runtime input changes. Integrated Marshall precommit passed1,417checks
and forced Dialyzer with zero errors; evaluated HLDD passed. The
[descriptor history review](../reviews/2026-10-02-namespace-descriptor-histories.md)
links exact captures and distinguishes cached native evidence from a new VM run.

The 2026-10-02 [HTTPS acceptance review](../reviews/2026-10-02-https-egress-production.md)
identified a descriptor-pinned namespace held by a Nix daemon after its last
inhabitant exited. The helper now inventories these descriptors as well as live
process namespaces, with the same exact-root and ordinary-unmount restrictions.
The extended native scenario retains a descriptor after reaping the child and
requires deletion without disturbing its holder or the surviving guest. The
review records executed checks and production cleanup separately. On healthy
`99f13b26`, the original pending Ubuntu deletion completed through its unchanged
request. Independent scoped SQL/ZFS/systemd proof confirmed released reservations,
absent dataset and inactive unit; subsequent proof covered all nine acceptance
fixtures. This establishes the observed recovery, not arbitrary descriptor churn.

The exact process that held the final ZFS reference in the original incident
remains unknown. The production cleanup events establish that the new helper
operates with Lilly's privileges, but do not attribute that incident to a
particular service.

## Related decisions

- [ADR-0017](0017-durable-vm-actors-and-host-ownership.md): durable placement
  actor, host lock and physical cleanup requirement.
- [ADR-0023](0023-retained-capacity-telemetry.md): retained capacity follows
  verified physical cleanup.
- [ADR-0074](0074-durable-lifecycle-state-machines.md): durable lifecycle audit.
- [ADR-0144](0144-nix-builds-exclude-guest-datasets.md): Nix build namespaces exclude guest datasets.
