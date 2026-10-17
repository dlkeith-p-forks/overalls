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

Open questions: None after the source inspection above.
