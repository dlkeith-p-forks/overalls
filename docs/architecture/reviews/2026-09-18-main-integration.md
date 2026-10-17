# Main branch integration

## Scope and architecture impact

Integrate the pending ingress, relocation and deployment checkpoint with remote
main and the existing local resize commits. This integration preserves the
accepted decisions rather than introducing a new architectural choice.
ADR-0050 remains usage-based overcommit; ADR-0051 remains resizing. The colliding
fenced ingress record moves to [ADR-0052](../decisions/0052-fenced-local-guest-ingress.md),
with its rationale, status and ADR-0007 supersession preserved.

## Resolution evidence

[VM actions](../../../marshall/lib/marshall/compute/virtual_machine.ex) and
[authorization](../../../marshall/lib/marshall/authorization/ash_authorizer.ex)
retain relocation, cancellation, resize and resize retry.
[Executor adoption](../../../lilly/lib/lilly/vm/executor.ex) retains transient
execution-lock retries and resize-specific guest readiness. The
[native guest fixture](../../../nix/tests/machines/zfs-guest/driver.py) retains
relocation restoration, overcommit and resizing scenarios with distinct identities;
its [probe](../../../nix/tests/machines/zfs-guest/probe.exs) applies the larger
overcommit shape only to that scenario.

## Validation and remaining gaps

The ADR checker passes all 52 decisions. The merged protocol precommit passes.
Lilly reports 261/267 passing tests/properties and zero Dialyzer errors.
Six test failures remain, including a temporary-directory collision during
concurrent test activity; that observation does not explain every failure.
Audi and Porsche precommit pass, including forced Dialyzer. Marshall reports
526/531 passing tests/properties: catalog query timeout, resize/lifecycle races
and relocation receive/progress failures remain. Concurrent edits include a
resize exclusion fix after the suite loaded its code; it is not validated by
that run. Contract syntax/coverage and all ADR structure checks pass.

Other work continued editing relocation sources during validation, so these
results do not establish a stable, exhaustively verified final revision. This
review covers merge resolutions, not a new semantic audit of the entire
checkpoint. Native NixOS/Firecracker and deployment acceptance were not rerun.
The existing ADR-0037, ADR-0046, ADR-0047 and ADR-0051/0052 gaps remain open.

## Worktree and stash preservation

The follow-up integration commits every worktree snapshot, including the detached
resize worktree and the new Porsche acceptance worktree. Identical synchronized
snapshots are merged into history while retaining main's newer source, tests and
implementation evidence. The recovery worktree's absolute dependency symlink is
preserved in its historical snapshot, not installed over main's dependency directory.

Commit `88d6c4d1` preserves the exact tree from recovery stash `306e449c`.
Its recovery-only policy implementation, contracts, regression tests and ADR-0044
already match main. The later inventory-derived secret configuration remains
authoritative; the older stash must not replace it with an empty host inventory.
The stash is retained as an additional recovery reference.

This consolidation introduces no new architectural decision. Pending source
behavior follows ADR-0037 (authorized relocation status and initial receive retry),
ADR-0047 (UTC publication lifetime comparisons), and the existing resize and
recovery decisions. Native acceptance remains bounded by their linked reviews.
