# delete-release-follows-physical-retirement

Priority: P0. Confidence: high for source contract; faulted native path untested.

## Claim and assertion

An accepted delete cannot archive the VM or release its reservation/address until the exact current placement's VMM and network are stopped, disk is absent, cleanup is complete and the matching physical outcome is durably accepted. Proposed missing `Always`: **`lifecycle.delete_release_requires_current_physical_retirement`**. This is safety; check each archive/release mutation and current physical state. Proposed missing `Sometimes(cond)`: **`lifecycle.delete_recovers_from_uncertain_cleanup_to_confirmed_retirement`**, where `cond` is a faulted delete whose cleanup was initially unconfirmed and later reached a matching accepted deleted outcome and physical absence. This is progress after a recoverable failure, conditional on eventual service availability.

## Evidence and failure history

`lilly/lib/lilly/vm/driver.ex:1280-1327` persists deleted intent and tombstone before shutdown, jail/network detach, boot-log removal and disk delete; only then returns deleted. `:1397-1435` refuses unreadable unit status and waits for physical stop before proceeding. `lilly/lib/lilly/vm/actor.ex:345-395` journals outcome and delays cleanup-failed retry; `:485-497` retires actor only after exact current delete outcome is acknowledged. `marshall/lib/marshall/compute/outcomes.ex:86-103,129-160` binds outcome to operation and current placement; `:210-229,365-369` releases all and archives only from matching deleted outcome and all reservations reclaimed; cleanup-specific path at `:141-145` checks `compute_empty`, `disk_present=false`, `cleanup_complete`. `nix/tests/machines/fleet/scenarios/lifecycle.py:37-99` independently checks ZFS GUID retention on stop and VM unit/ZFS/disk absence on delete; this is a bounded native test, not a new Antithesis assertion. ADR-0017's tombstone and durable ownership rationale supports this as a claim to test.

Failure history: fail unit stop, jail cleanup, network detach or ZFS deletion; crash actor before/after journal commit and before Marshall acknowledgement; drop physical outcome reply; issue a superseding generation. False retirement would let new placement consume disk/address while old physical effects survive.

## Independent oracle and workload

Use a real ZFS pool and VMM service in native NixOS or owned TCG machine. Record placement/epoch/generation, physical VMM PID/cgroup, network attachment, ZFS dataset GUID/existence, Marshall reservation/address/archive and exact accepted outcome ID. Request delete, inject one cleanup interruption, and sample at each durable transition. `Always` compares archival/release to both accepted exact outcome and independent absence checks. After healing, `Sometimes` requires confirmed absence and completed delete. Preserve a neighbor guest and verify its process snapshot and disk GUID. Stop is a separate retained-disk state: do not require disk absence for stop.

Configured limit menu: graceful shutdown 30,000 ms (`driver.ex:1404`), 100 ms polling (`:1430`), retry disk cleanup after 100 ms with 2,000 ms lock wait (`:1313-1317`), actor cleanup delay up to 30 s (`actor.ex:362-372`); one versus repeated cleanup faults, before versus after outcome journal, old versus current generation. Avoid a time-based liveness failure while faults remain permanent.

## Branch/replay guidance and scope

SUT-side missing assertions at `Driver.delete/4` after each cleanup boundary, `Actor.maybe_retire/3`, and `Outcomes.apply!/2` at reservation release/archive; record IDs, booleans and closed reason atoms only. Distinct `Reachable` marker for cleanup-failed retry could be useful but is subordinate to the progress property. All Antithesis assertions are **missing** per `antithesis/scratchbook/existing-assertions.md`. Hosted service simulation cannot prove ZFS/VMM absence; use owned native/TCG physical evidence. Diagnostic delivery is independent under ADR-0149.

Open questions: None after the source inspection above.
