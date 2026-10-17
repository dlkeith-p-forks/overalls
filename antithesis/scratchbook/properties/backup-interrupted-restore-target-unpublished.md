# backup-interrupted-restore-target-unpublished — Interrupted restore never publishes a partial target

P0; safety; high source confidence. Proposed primary SDK assertion: `Always`,
literal unique message **"Interrupted backup restore leaves its partial target unpublished"**.
For an isolated target that has begun restoring a valid selected host point, a
failed/interrupted component restore must leave no final `manifest.json`, and
the bytes already verified must remain inspectable without silently declaring
the target complete. `Always` fits because every observed failure boundary must
preserve the invariant. Add a separate `Reachable` marker **"Backup restore interruption retained a verified component prefix"** so a vacuous no-restore timeline is visible. SDK instrumentation is missing in the [fresh scan](../existing-assertions.md).

## Source and contract

- `nix/modules/backups/runtime.py:313-345`: `Repository.manifest` validates
  selected point before target creation; target must be absolute, private and
  empty. Indexed `restic restore --sparse --verify` calls precede the final
  `atomic_json(target / "manifest.json", manifest)`. The marker is a restore
  target publication indicator, not the repository's already uploaded point.
- `nix/modules/backups/runtime.py:277-285`: all operator operations use the
  host owner lock; a competing restore returns 75 while the first is active.
  `nix/modules/backups/restic.py:103-125` rechecks credential custody per
  repository command. `nix/modules/backups/common.py` owns bounded child drain
  and atomic JSON writes.
- `nix/tests/evaluation/backup-operators.py:673-728,858-959,1261-1341,1354-1427`
  supplies real local-Restic tests for missing component, SIGTERM/SIGKILL/timeout,
  concurrent operations and credential change. Those cases inspect partial
  prefixes, assert absent marker, refuse same-target retry and verify a fresh
  target. They are existing focused evidence, not a new Antithesis run.
- `docs/backups.md:326-340` prescribes preserving partial output and explicit
  fresh-target retry. ADR-0070 requires isolated restoration and reference
  closure; neither permits partial output as a complete recovery point.

## Fault history and independent oracle

Create a valid encrypted real-Restic point with at least host-state and one
other component, each containing unique deterministic sentinel bytes/hashes.
Inspect the complete manifest before restore. Start the real operator restore
into a newly created empty private target. At a chosen component index, block
actual Restic `restore` after one or more prior components have completed, then
SIGTERM, SIGKILL, force the configured command timeout, or cut repository access.
Independently inventory the target after the child is drained. Assert verified
prefix bytes match the ledger, no final `manifest.json` exists, and no external
consumer treats numbered directories as complete. Retry into the nonempty target:
it must refuse without changing the inventory. After restoring dependencies,
retry explicitly into a *different empty* target; the final marker must equal
the selected repository manifest and every component sentinel must match.
The second success is a useful `Sometimes(cond)` progress witness only after
the exact repository, credentials and service have been observed healthy; it is
not part of the primary safety assertion.

The oracle uses target filesystem bytes, modes, symlink-safe inventory and
independent Restic snapshot enumeration, not CLI exit alone, status counters or
the manifest flag alone. A RESTIC command timeout is an uncertain effect until
the process group is drained and the target re-inventoried. Do not read or log
secret contents. Keep a synthetic password file and fixture-only database row.

## Values, guidance and environment

Vary 2/3/4 components, interruption at first/middle/final index, host/guest/
PostgreSQL component order, SIGTERM/SIGKILL/timeout, source snapshot missing,
credential failure, and concurrent lock contention. Use configured
`command_timeout` at a small isolated value, recording actual value. A SUT-side
`Reachable` hook after a verified component and before `atomic_json` would give
a precise replay anchor; an instrumentation hook at final marker publication
must include target identity and selected manifest ID only, never payload bytes.
The workload can enforce primary `Always` from independent target inventory.

The existing local-Restic fixture covers the Python/Restic ordering. A native
isolated NixOS machine campaign must add real ZFS guest disk and actual service
wrapper if claiming complete host recovery; `nix/tests/machines/backups/driver.py:187-255`
currently proves successful host/database isolated restore, not interruption of
the native guest-disk leg. No production restore or old-node activation is
authorized by this property. Historical authority quarantine is the separate
`backup-time-skew-never-activates-historical-authority` property.

## Open questions

- Can the native isolated backup machine inject a kill after verified real guest
  disk output while preserving an independent target inventory? `(partial: real
  local-Restic interruptions and successful native host/database restore exist;
  the composed native interruption has not been run)`
- Which authorized consumer, if any, reads a restore target before the operator
  marks it complete? The CLI has no activation command, so the immediate oracle
  is marker and bytes, with consumer refusal scoped to a future reentry workflow.

### Investigation Log

#### Can the native isolated backup machine inject a kill after verified real guest disk output while preserving an independent target inventory?

- Examined: `nix/tests/evaluation/backup-operators.py:858-959`,
  `nix/tests/machines/backups/driver.py:187-255`, `runtime.py:313-345` and
  `deployment-topology.md:96`.
- Found: generated SIGTERM/SIGKILL/timeout cases already drive real local Restic
  per component; the native machine successfully restores host and DB contents.
- Not found: a current native interrupted guest-disk restore with independently
  inventoried partial target.
- Conclusion: retain the partial tag; select this as an isolated native campaign
  variant rather than claiming the existing cases establish it.

#### Which authorized consumer, if any, reads a restore target before completion?

- Examined: `runtime.py:252-345`, `docs/backups.md:313-350`, ADR-0070 and
  ADR-0158. No backup CLI activation or automatic claim command is exposed.
- Conclusion: the candidate asserts the concrete marker/byte boundary. An
  eventual serving transition needs a separate, defined reconciliation receipt.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `storage`. real-Restic-isolated-target; native-guest-ZFS-companion; independent witness: actual Restic tag/manifest parser, target publication marker and independent restored component hash. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

## Authored assertion snapshot

**Authored assertion snapshot (2026-10-13 15:03 UTC):** Primary `always` message is present at `antithesis/workload/backup/scenarios.py:172`. Production restore CLI with fixed Restic interruption gate, marker/prefix and fresh retry; no hosted run. It is outside the currently staged control-core selection. This records source presence, not a passing hosted or native result.
