# Native host cleanup worker death

## Architecture impact

Baseline `feb8692e0a1f159dcd02ff58945aeb83bcfc873a`. This verifies existing
ADR-0070 cleanup intent and retry requirements; production HostCapture, runtime,
commands, credentials and deployment are unchanged. The earlier thirteen native
ownership/inspection-outage histories retain their separately recorded 98-second
passing execution in the [ownership review](2026-10-03-native-backup-cleanup.md).

## Native property and oracle

`worker_death` extends the same mirrored-ZFS fixture. Four fixed witnesses and
four generated combinations vary before/after native destroy, mounted/unmounted
snapshot, recorded/unrecorded snapshot GUID and one/two/three recovery replays.
A real transient systemd unit runs the production HostCapture cleanup. The pinned
native ZFS wrapper pauses only at the selected effect boundary. A before-effect
barrier never submits delayed work after timeout. Barrier JSON atomically binds
the selected phase and exact snapshot destroy command.

Independent native GUID/list/findmnt queries distinguish the still-present
snapshot before destroy from its confirmed absence after destroy. Native unmount
has already completed when a mounted history reaches either barrier. SIGKILL
kills the actual worker and its helper cgroup. The fixture requires main exit
status nine, inactive/failed unit, empty/absent cgroup and byte-identical durable
intent. Recovery must remove intent and converge with exactly one successful
native snapshot destruction. Before-effect death records two command attempts
but only one successful destruction; after-effect death must not reissue destroy.
An independent foreign snapshot keeps its exact GUID and immutable contents.

The successful-destroy ledger is written only after pinned native ZFS exits
successfully, before the after-effect barrier. Native facts bypass that wrapper;
its ledger is not the only evidence of snapshot absence. The parent reads the
retained descriptor through the production typed validator as well as comparing
exact bytes. A bounded finally stops the transient unit before deleting the
pause flag, preventing a failed fixture from releasing delayed physical work.

## Contracts and review

Reviewed root/nix/test/backup ancestor contracts, HostCapture cleanup/release,
common.run process groups, and fixture contracts. Fresh review caught non-atomic
barrier publication, which could expose incomplete JSON; temporary-file rename
corrected this fixture race. The final oracle also observes the entire killed
cgroup rather than treating main PID disappearance as helper exit. Final fresh
source and independent runtime evidence reviews found no remaining blocker.

## Execution

The final copied fixture and production modules passed pinned Python 3.13 Ruff
format/lint and ty in `backup-types`, exit 0, in 10 seconds; archive
`1791013969182-2302280-0.jsonl`, log `/tmp/overalls-backup-worker-types-final.log`.
Existing state/workflow/status tests also execute. This is typing evidence, not
native worker execution.

The combined native ownership and worker-death check passed in 134 seconds,
exit 0; archive `1791013997003-2327202-0.jsonl`, log
`/tmp/overalls-backup-worker-native.log`. The actual property command took
66.01 seconds; VM script 86.24 seconds. Thirteen original ownership histories
and eight worker-death histories completed; native worker units fourteen through
twenty-one record SIGKILL status nine. Composed driver validation passed.
Fresh independent review confirmed terminal success, all eight SIGKILL workers
and exact native scope. All-file Ruff/format/ty, logging, handbook receipts,
ADR structure (136 decisions) and generated options/coverage/views passed.
Evaluated Nix handbook validation passed in 31 seconds, exit 0; archive
`1791014733103-2624625-0.jsonl`. Contract discovery/parser checks passed
(117 CONTRACTS, 2335 native notes, 189 parsed and 2493 maintained source files);
these are structural checks, separate from semantic source/oracle review.

## Remaining gaps

This is component-worker death inside an isolated transient unit, not complete
packaged backup service/systemd-cleanup orchestration or host power loss.
Concurrent dataset/snapshot identity replacement and native intent-before-creation
histories remain separate. The test kills the whole worker/helper cgroup; it does
not establish behavior with a deliberately surviving autonomous utility. Hosted
Antithesis faults and historical authority reactivation are not covered.
