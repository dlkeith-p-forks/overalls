# backup-published-manifest-retention-compatible — Published backup points pass retention schema

P1; safety; medium confidence in the hypothesized fault, high confidence in the
source ordering and validator. Proposed primary SDK assertion: `Always`, literal
unique message **"Newly published backup point passes its retention manifest validator"**.
Every new tag-visible `host-manifest` produced by the coordinator must pass the
same parser and temporal schema used by `Repository.retain` before being treated
as a complete point. `Always` fits a producer/consumer safety contract: one
malformed published point is a violation even if later retention safely refuses
deletion. Instrumentation is missing in the [fresh scan](../existing-assertions.md).

## Source-grounded hypothesis

`nix/domains/system/backups/journal.py:113-133` persists `started_at=int(time.time())`.
`nix/domains/system/backups/runtime.py:207-225` samples a new completion wall time,
writes `complete=True`, uploads the manifest with `Repository.backup`, records
the ID, transitions completed and only then invokes `retain`. There is no
producer-side call to `Repository.manifest` between manifest construction and
upload. `nix/domains/system/backups/restic.py:213-254` rejects `started_at >
completed_at`; `:256-295` validates *every* manifest before any `forget` batch.
The generated real-Restic operator suite injects a manually reversed-time
manifest and verifies inspect/restore/prune refuse without mutation
(`nix/verification/tests/evaluation/backup-operators.py:580-668`). Discovery assumptions A12
models start=2000, completion=1000 and predicts a backward wall-clock step
could make a coordinator-published point fail later retention. A full clock-step
through actual coordinator and Restic was not executed. This is **not a confirmed
runtime defect**. The validator's fail-closed behavior is correct and must be
preserved.

## Fault history and independent oracle

In a disposable host-recovery fixture with real encrypted Restic, start a normal
capture and pause after the durable start sample but before the complete manifest
is built. Move only the isolated producer wall clock backward past the saved
start, then allow actual capture, cleanup and manifest upload to finish. Do not
patch the stored manifest directly: that would test the validator only. Enumerate
`host-manifest` snapshots independently by Restic after the operation; a lost
upload reply still may leave a published point. For each newly advertised point,
run the *real* inspect/validator path and compare to the manifest bytes from
Restic `dump` plus the workload's known run ID. Any new tag-visible point that
the parser rejects fails the primary property, regardless of journal or status.

After restoring normal time, run a second ordinary backup and scheduled/manual
retention under the same owner lock. If the first malformed point was published,
record whether retention refuses all forgetting and whether older valid points
remain intact; do not score retention's conservative refusal as a separate bug.
If the coordinator instead prevents publication or writes a schema-compatible
completion time, verify the second valid point can be retained and all its
referenced component IDs remain restorable. Keep retention graph closure under
`backup-retained-manifest-closure`; this property is specifically producer-side
schema compatibility.

The independent oracle is the encrypted repository's actual snapshot/tag list,
dumped manifest bytes, public CLI inspect result, and pre/post snapshot ID sets.
It is not `journal.phase == completed` or a mocked parser call. Record the clock
step's observed before/after values and the run ID without printing secrets.
SUT-side `Reachable` **"Backup completion wall time precedes durable start time"**
would guide the rare interleaving before upload; `Reachable` **"Backup manifest upload completed before retention check"** distinguishes publication from a failed upload. These are branch/replay anchors, not proofs of safety.

## Values and environment

Sweep no step, backward step smaller/equal/greater than elapsed capture time,
step at start/after first component/before manifest construction/after upload,
and a forward control. Use one host-state component initially; add guest and
PostgreSQL only after the minimal real-Restic path works. Vary `keep_last` 1/2/12
and one older valid point; grace 86400 seconds and `forget` batch 128 are separate
reference-closure concerns unless triggered by this history. Record the actual
thirty-minute cadence and up-to-five-minute jitter as ADR-0070's **nominal**
RPO plus capture runtime, never as a hard deadline during outages.

Clock injection must occur in a disposable VM/time namespace or through a
typed, build-scoped wall-clock seam that leaves the actual coordinator, journal,
Restic upload and retention paths intact. Antithesis tenant clock faults are
unverified; topology notes global clock jitter cannot create independent
container skew (`deployment-topology.md:165-167`). A native isolated campaign
is authorized for later work, but no clock-step or full Restic repro was run in
this discovery. A parser-only 2000→1000 check confirms the schema, not the
publication behavior. No live S3, production clock or credentials are involved.

## Open questions

- Can the native isolated clock fault alter the coordinator's wall time while
  keeping Restic, TLS S3 and the fixture's other clocks healthy? `(partial:
  source ordering and modeled reversed time are known; no actual clock-step
  campaign or tenant capability has been demonstrated)`
- Does a backward step through actual capture finish with a tag-visible point,
  or does an earlier runtime/Restic check prevent upload?

### Investigation Log

#### Can the native isolated clock fault alter the coordinator's wall time while keeping Restic, TLS S3 and the fixture's other clocks healthy?

- Examined: `journal.py:113-133`, `runtime.py:207-225`, `restic.py:213-295`,
  discovery assumptions A12 and `deployment-topology.md:165-167`.
- Found: start and completion use independent wall samples; the later retention
  validator rejects reversal. The topology requires confirmation of clock-fault
  availability and states outer clock jitter is global.
- Not found: a controlled namespace/VM clock step or typed source seam driving
  actual coordinator+Restic in this checkout.
- Conclusion: partial. Preserve the hypothesis label until the proposed native
  or scoped typed fault history runs.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `storage`. real-Restic-isolated-target; native-guest-ZFS-companion; independent witness: actual Restic tag/manifest parser, target publication marker and independent restored component hash. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Selected profile (2026-10-17):** `backup-restic` selects the five `backup` commands with `compose.backup.yaml`, which gives each command a disposable encrypted Restic file repository on a dedicated private named volume. Bootstrap requires the production operator, pinned Restic and a real probe repository that initializes and enumerates empty there. A local file backend is deliberate: the production operator returns one failure status for repository unavailability and validator refusal, so a network-attached repository would make unavailable reads look like refusals. This profile exercises no ZFS, host capture, S3 or live recovery target and has no hosted run or baseline yet.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

## Authored assertion snapshot

**Authored assertion snapshot (2026-10-13 15:03 UTC):** Primary `always` message is present at `antithesis/workload/backup/scenarios.py:235`. Actual coordinator publication plus raw Restic/production inspect; backward wall-clock step remains unimplemented. It is outside the currently staged control-core selection. This records source presence, not a passing hosted or native result.
