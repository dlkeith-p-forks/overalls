# guest-readiness-binds-current-physical-boot

Priority: P0. Confidence: high for intended contract and call order; composed fault behavior untested.

## Claim and assertion

A running/guest-ready result after start, provision, resize or clone must be tied to the current placement, execution epoch, generation and physical boot, with current launch authority rechecked after guest waiting. Proposed missing `Always`: **`lifecycle.guest_ready_receipt_matches_current_physical_boot_and_execution`**. This is safety and must be checked when a positive physical outcome is recorded/accepted. Proposed missing `Sometimes(cond)`: **`lifecycle.new_boot_reaches_current_guest_readiness_after_recovery`**, where `cond` means a new boot with authenticated current authority receives its matching readiness receipt and reaches accepted running state after an injected interruption; this is meaningful progress, not `Sometimes(true)`.

## Evidence and failure history

`lilly/lib/lilly/vm/driver.ex:491-545` checks current authority and `Boot.current` before using cached readiness or waiting, then checks the same boot again before committing readiness. `:550-714` requires a trust receipt for exact placement/epoch/generation/challenge; `:940-975` rechecks current claim and `Boot.current` around credential delivery and bounded guest vsock readiness. `:1222-1259` requires physical running confinement and preserves boot challenge when logical generation advances. `lilly/lib/lilly/vm/executor.ex:388-465` reports running only after trust and required provisioning/Inception readiness, with failed or timed-out paths separately handled. `lilly/lib/lilly/vm/actor.ex:345-391` journals the observed result before publication; `marshall/lib/marshall/compute/outcomes.ex:86-103,129-160,210-213` checks operation placement/epoch/generation before applying it. This is an accepted source claim, not a verified guarantee. Ordinary native readiness testing appears in `nix/verification/tests/machines/fleet/scenarios/runtime-readiness.py`; it is not Antithesis instrumentation.

Failure history: crash Lilly during vsock wait, rotate execution generation or replace VMM after the pre-wait boot read, replay an old guest response or cached trust receipt, and recover while database/control delivery is delayed. A stale readiness success would grant current-running status to an obsolete boot.

## Independent oracle and workload

Run the real pinned guest under QEMU TCG with vsock or native KVM, authenticated Marshall/Lilly transport, and persistent placement directories. From outside Lilly capture VMM PID/start time/cgroup and guest boot UUID/challenge response; query current operation, accepted outcome, and guest-ready status. Force a second physical boot and generation change across a blocked readiness response. On every accepted positive result compare the durable boot receipt and challenge with the independently observed current guest response and placement/epoch/generation. After releasing faults, require at least one exact new-boot readiness success. A response timeout is inconclusive until durable operation and physical identity reconcile.

Configured limit menu: readiness default 120,000 ms (`driver.ex:946`), lock reacquisition at most 2,000 ms (`:949,:961`), Inception 2,400,000 ms (`executor.ex:445`); test just-before/after deadline and one versus two physical boots; legacy `provisioning_readiness: false` is a separate weaker scope and must not be claimed to have provisioning proof.

## Branch/replay guidance and scope

SUT-side missing assertion at `Driver.ready_boot/4` after final `Boot.current` and at `Provisioning.ready` commit, plus a replay anchor for stale boot refusal and successful new-boot commit. Compare opaque IDs/challenge hashes only. All Antithesis assertions are **missing** per `antithesis/scratchbook/existing-assertions.md`; ordinary ExUnit/native assertions are separate. Hosted TCG can test guest protocol and boot identity but cannot establish Firecracker jail/cgroup isolation; native KVM is needed for that physical claim.

Open questions: None after the source inspection above.
