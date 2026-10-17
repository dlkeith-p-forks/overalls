# stop-retains-disk-until-restart

Priority: P1. Confidence: high for source contract; faulted physical sequence untested here.

## Claim and assertion

A completed stop must mean the VMM and network attachment are physically absent while the same owned disk and address remain reserved and can boot again under a new start generation. Proposed missing `Always`: **`lifecycle.completed_stop_has_no_vmm_and_retains_disk_identity`** at every accepted stop completion. This is safety. Proposed missing `Sometimes(cond)`: **`lifecycle.stopped_guest_restarts_from_same_disk_after_interruption`**, with `cond` requiring a stop followed by a fresh start, same disk GUID/content and a new physical boot that reaches current readiness. This is progress after healed interruption.

## Evidence and failure history

`lilly/lib/lilly/vm/driver.ex:1138-1173` sets non-running intent before shutdown, jail cleanup and network detach, and returns success afterward. `:1397-1435` treats unreadable unit status as `stop_unconfirmed` and waits/forces stop if graceful shutdown exceeds 30 s. `marshall/lib/marshall/compute/outcomes.ex:210-218` releases compute but not disk reservation only when matching stopped outcome is applied. `marshall/lib/marshall/compute/lifecycle.ex:26-30,69-120` advances generation and retains exact-key idempotency; `:54-65` has a narrow fresh-start path for physically stopped VMs. `nix/verification/tests/machines/fleet/scenarios/lifecycle.py:37-60` checks unchanged ZFS GUID across stop/start and compute/disk reservation `false:true` after stop. Accepted ADR-0017 claims durable actor and disk survival. This is evidence of intent and a bounded test, not a blanket guarantee.

Failure history: crash between non-running intent and actual shutdown, unreadable unit status, incomplete network detach, lost stop outcome, and concurrent fresh start or repeated stop request. Early compute release could permit host overcommit while old VMM runs; disk deletion would lose stopped user data.

## Independent oracle and workload

Use one real VMM backed by ZFS with a guest data marker. Capture PID/start-time/cgroup, network attachment, dataset GUID, reservation flags and address before stop. Inject stop interruption; on any Marshall completed stop, independently verify no VMM and no attachment, unchanged dataset GUID/content, `compute_held=false`, `disk_held=true`, retained address. After heal, issue fresh start and verify boot challenge/readiness, disk content and address. A timeout is uncertain until physical observation and accepted outcome reconcile.

Configured limit menu: graceful shutdown 30,000 ms and 100 ms polling (`driver.ex:1404,:1430`); stop before/after unit exit, before/after network detach and outcome commit; one versus repeated idempotent stop; fresh versus duplicate start key. Preserve unaffected neighbor guest.

## Branch/replay guidance and scope

SUT-side missing assertion at `Driver.stop/4` successful return and `Outcomes.apply!/2` stop completion, with a replay anchor for `:stop_unconfirmed`. Existing-assertions scan in `antithesis/scratchbook/existing-assertions.md` found **no** Antithesis callsites. A native/TCG physical oracle is needed; mock executor state cannot prove actual VMM absence or disk retention. No diagnostic event delivery gates the lifecycle outcome.

Open questions:

- Can the hosted storage/guest fixture inspect disk GUID, network detach, and fresh boot without substituting modeled physical effects? `(partial: native GUID test exists; hosted composed TCG fixture unrun)`

Next probe: The native fleet lifecycle scenario already checks ZFS dataset GUID across stop/start and unit inactivity, but its stop assertion does not inspect network attachment and the hosted TCG storage/guest design has not executed this composed sequence. Probe actual TCG guest boot UUID, real ZFS GUID, and link/nft attachment across stop/start; keep native fleet result as test presence only.

### Investigation Log

#### Can the hosted storage/guest fixture inspect disk GUID, network detach, and fresh boot without substituting modeled physical effects?

- Examined: `nix/verification/tests/machines/fleet/scenarios/lifecycle.py:37-60; antithesis/scratchbook/emulated-storage-feasibility.md; antithesis/scratchbook/emulated-guest-feasibility.md`.
- Found: The native fleet lifecycle scenario already checks ZFS dataset GUID across stop/start and unit inactivity, but its stop assertion does not inspect network attachment and the hosted TCG storage/guest design has not executed this composed sequence. Probe actual TCG guest boot UUID, real ZFS GUID, and link/nft attachment across stop/start; keep native fleet result as test presence only.
- Not established: No current hosted/native execution was run in this investigation; source and test presence alone do not establish the physical outcome.
- Conclusion: partial; Retain hosted composed-feasibility question partial; cite native scenario without claiming current pass.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-real-inner-zfs-backed-lilly-plus-tcg-guest; unbuilt, no Firecracker proof; independent witness: retained QEMU PID/boot challenge/overlay plus independent guest or connector effect; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R1`: `Sometimes` witnesses one designated recovered history. Track its exact operation ID, observed preconditions and dependency restoration; separately check that operation’s terminal state after a measured quiet interval. Missing oracle/precondition is unexercised, not a pass or a liveness violation. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.
