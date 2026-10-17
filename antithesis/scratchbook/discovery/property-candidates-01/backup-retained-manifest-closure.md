# backup-retained-manifest-closure

P0; medium-high confidence; safety. Planned SDK instrumentation is **missing** per the [fresh scan](../../existing-assertions.md). Proposed `Always` message: **"Retained backup manifest references restorable component snapshots"**. After a successful publish/retention boundary, every component ID referenced by each retained complete host manifest is still present and independently restorable at its recorded content hash. `Always` checks each settled retained point. A failed/incomplete run need not create a manifest; a listed but unverified manifest is not a successful restore claim.

Source: `nix/modules/backups/runtime.py:132-154,166-197` records guest, PostgreSQL and host-state component snapshot IDs after individual Restic backups; `:200-225` requires cleanup, publishes the complete manifest last, then starts retention. `nix/modules/backups/restic.py:213-254` validates manifest structure; `:256-295` checks retained references before computing forget candidates. `nix/modules/backups/journal.py:157-172` gates terminal state on cleanup. ADR-0070 is the accepted backup decision. The code order and contract motivate a property; they do not establish that all referenced bytes remain restorable under faults.

History and independent oracle: seed distinct deterministic bytes in representative guest, database and host-state paths; capture their hashes and the manifest run ID in a separate workload ledger. Use actual Restic repository commands from an observer process to list manifest IDs and referenced IDs, then independently restore each retained component into an isolated destination and hash the selected files. Run capture and retention concurrently with interruption after each component backup, after manifest publication and during batched `forget`; restart and repeat with a previously retained point. A component that is listed but unavailable or mismatched is a violation only for a retained completed manifest after repository recovery settles. Reconcile a timeout by querying repository/journal, not assuming failure.

SUT guidance: `Reachable` **"Backup retention encountered a completed manifest with shared component references"** in `ResticRepository.retain` when two retained points share an ID; `Reachable` **"Backup publication completed after owned snapshot cleanup"** at `runtime.py:223-225`. These mark meaningful paths. An optional `AlwaysOrUnreachable` **"Backup retention forget set excludes all retained component IDs"** before batched forget is a targeted safety check on a workload-dependent path. SDK integration for Python must use actual documented binding; no current callsite exists. Record IDs and hashes only, never database contents or credentials.

Value menu: `keep_last` 1/2/3; component count 1/2/configured guest bound; two runs with unique/shared components; retention age before/at/after 86400-second orphan grace; forget batch 127/128/129; fault after component backup, manifest backup, journal completion and within forget batch. Hosted real Restic/repository/process storage can test repository closure; TCG ZFS guests test capture path; native machine execution is required for actual owned host snapshots and full guest restore authority. Do not claim database consistency from file hashes alone.

Open questions: Does the configured Restic repository allow stable component ID reuse across retained points, and how is it represented? Which exact guest/host subset can be restored and hashed without overwriting live system state?

### Investigation Log

#### Does Restic reuse component IDs?

- Examined: `nix/modules/backups/runtime.py:132-225` and `restic.py:256-295`.
- Found: manifest references snapshot IDs; retention uses sets, so shared references are handled conceptually.
- Not found: a source path that intentionally reuses a prior Restic snapshot ID.
- Conclusion: keep shared-reference coverage conditional on a feasible fixture; unique IDs suffice for the core closure invariant.

#### Which restore subset is safe and independently checkable?

- Examined: `nix/modules/backups/runtime.py:120-225`, `restic.py:213-295` and the [SUT environment analysis](../../sut-analysis.md#antithesis-environments-and-independent-oracles).
- Found: component snapshots and manifest are separable; operator restore has an isolated target option in `runtime.py:317-345`.
- Not found: a complete list of paths that can be safely compared in hosted TCG/native scenarios.
- Conclusion: pick an isolated deterministic sentinel per component before implementing the oracle; do not use a live restore target.
