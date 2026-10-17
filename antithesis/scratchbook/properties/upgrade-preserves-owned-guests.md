# upgrade-preserves-owned-guests

Priority: P1. Confidence: high for intended lifecycle boundary; physical faulted upgrade untested here.

## Claim and assertion

Switching Lilly's release or current credential material must preserve every unrelated owned guest's physical VMM identity and durable disk identity while the new release reauthenticates and resumes control. Proposed missing `Always`: **`lifecycle.upgrade_preserves_owned_vmm_and_disk_identity`**. This is safety at each observed upgrade transition for a retained guest. Proposed missing `Sometimes(cond)`: **`lifecycle.upgraded_lilly_reauthenticates_with_surviving_guest`**, where `cond` requires candidate `lastHealthy`, a fresh host connection epoch and guest traffic through the same VMM; this checks progress after a successful upgrade.

## Evidence and failure history

`nix/modules/auto-update/CONTRACTS` explicitly requires independent guest preservation and no storage format/reboot. `runtime.py:580-662` stops/restarts consumers and secret preparation, but does not call guest stop; `:926-940` records healthy only after role checks. `lilly/AGENTS.md` states Firecracker process lifetime must not depend on Lilly application lifetime. `lilly/lib/lilly/control/runtime.ex:149-213` restores durable commands and actors on restart. `nix/tests/machines/fleet/scenarios/updates.py:1-24` captures VMM snapshots across actual Lilly release upgrade and probes guest network afterward; `:26-48` does the same for encrypted credential-only update while checking the release path is unchanged. Test presence and historical result do not prove arbitrary faulted upgrades.

Failure history: kill updater after consumer stop or switch, kill Lilly on new release startup, rotate credential bytes at same closure, and delay Marshall reconnection. An upgraded status or `lastHealthy` with a replacement/dead guest would lose user work; unchanged release path alone says nothing about current credential material.

## Independent oracle and workload

Use a native NixOS/real VMM guest or owned TCG guest with a persistent disk marker. Before update, capture each guest's PID/start-time/cgroup, disk dataset GUID and guest data challenge. Apply release and credential-only candidate updates, interrupt at activation seams, then compare same physical identities and disk content while polling new Lilly authenticated connection epoch. Require eventual guest traffic and candidate healthy only after healing. Explicitly exclude guests the user concurrently stopped/deleted or whose own VMM crashed; preserve a no-lifecycle-intent control guest for this oracle.

Configured limit menu: release versus credential-only update, one and two guests, one interrupt before/after Nix switch, `healthTimeout` 10/120/1800 s (`default.nix:139`), one credential unit failing and recovered. Avoid claiming new guest creation works while database remains unavailable.

## Branch/replay guidance and scope

SUT-side missing assertions at post-switch Lilly process restart and Runtime's restored-command reconciliation should pair opaque placement/epoch with expected native VMM target; workload oracle remains necessary for independent physical identity. All Antithesis assertions are **missing** per `antithesis/scratchbook/existing-assertions.md`. Hosted service-only runs cannot prove VMM survival. Separate from the healthy-revision property: a fully healthy host may still have lost an unrelated guest.

Open questions: Which native fixture can retain and independently identify guest VMM/cgroup and disk across the release switch? `(partial: fleet update already compares native VMM PID/start/cgroup and traffic; disk GUID continuity and faulted switch coverage need a combined probe)`

### Investigation Log

#### Which native fixture can retain and independently identify guest VMM/cgroup and disk across the release switch?

- Examined: `nix/tests/machines/fleet/scenarios/updates.py:1-48`, `nix/tests/machines/fleet/helpers.py:323-328`, `nix/tests/support/vm-processes.py:1-55`, `nix/tests/machines/fleet/scenarios/lifecycle.py:41-97`, and `nix/tests/machines/auto-update/driver.py:125-145`.
- Found: the fleet update scenario performs actual release and credential-only updates, compares VMM process snapshots before/after, and probes guest network traffic. The snapshot reads cgroup descendants and kernel PID/start-time plus executable identity, so a replacement Firecracker is detectable. Other native fleet lifecycle code reads the VM ZFS dataset GUID through stop/start and physical delete.
- Not found: disk dataset GUID comparison integrated into the upgrade scenario, a guest disk challenge repeated after update, or a faulted updater switch while keeping the same native guest. The updater's single-host retained process is not a native owned VMM.
- Conclusion: partial. Extend `updates.py` with the existing ZFS GUID and persistent guest-data oracle around the same switch, then add interrupted activation variants. The current scenario supports VMM survival on successful upgrades only; it is test presence, not a fresh run in this research pass.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `no selected hosted template`. native-only-currently; independent witness: actual Nix closure, migrator/systemd/secret and enabled role health; surviving guest VMM/cgroup/disk where applicable. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R1`: `Sometimes` witnesses one designated recovered history. Track its exact operation ID, observed preconditions and dependency restoration; separately check that operation’s terminal state after a measured quiet interval. Missing oracle/precondition is unexercised, not a pass or a liveness violation. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.
