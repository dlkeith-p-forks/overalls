# backup-time-skew-never-activates-historical-authority

P1; medium confidence; safety. Proposed `Always` message **"Restored mixed-time backup remains isolated from live fleet authority"**. SDK instrumentation is **missing** per [fresh scan](../existing-assertions.md). This is about cross-component time skew, not backup manifest reference closure or the ability to restore each component independently.

Source: `nix/modules/backups/runtime.py:122-165` inventories and captures each guest sequentially, `:166-186` captures PostgreSQL afterward, and `:188-225` captures host metadata then publishes a complete manifest. `lilly/lib/lilly/backup.ex:181-211` copies pool ownership/import metadata under a pool lock, which protects each local copy but not one fleet-wide instant. The CLI restores components into a chosen empty private directory and writes the manifest there (`nix/modules/backups/runtime.py:313-345`); no automatic activation step is shown. ADR-0070 `docs/architecture/decisions/0070-host-recovery-backups.md:86-102,120-125` explicitly requires an isolated database and quarantine reconciliation before historical control-plane authority is served. ADR-0158 `docs/architecture/decisions/0158-durable-guest-identities.md:105-110` says an older DB alongside newer retained guest disks cannot establish safe UID reuse until reservations and sequence are reconciled. `marshall/lib/marshall/accounts/guest_accounts.ex:10-14,65-99` shows allocation uses a noncycling DB sequence.

History: during a slow controlled backup, create a guest/account, change one guest disk, and relocate/delete another between guest snapshot, database capture and host-metadata capture. Finish a manifest with every component individually valid. Restore the selected manifest to an empty private target while the live fleet remains running. Compare each component's capture timestamp/IDs; then attempt any documented activation/claim step only within a separate fenced recovery fixture. Include an older DB/newer retained disk identity case and verify it remains quarantined until reservations are reconciled. Do not inject old DB rows into a live production primary merely to reach the assertion.

Independent oracle: record independent guest sentinel content and ZFS GUIDs at each capture, authoritative DB account/VM/UID rows and sequence, host ownership journals, restore target path, live service endpoints and actual guest process identities. A `complete: true` manifest means capture/cleanup success, not a simultaneous fleet state. The test must prove the restored components did not become live authority or allocate a UID colliding with a retained disk without an explicit reconciliation witness. An aggregate backup-suite exit or manifest flag is insufficient.

SUT guidance: proposed `Reachable` **"Complete backup contained component captures from different authority times"** identifies the subtle valid state; proposed `AlwaysOrUnreachable` **"Historical restore stayed in isolated target before reconciliation"** checks optional restore. The workload `Always` checks live endpoint/process and UID allocation effects. This property does not demand automatic historical repair, which ADR-0158 explicitly leaves unsupported.

Values: 0/1/multiple guest captures, move/create/delete before/between/after captures; DB capture earlier/later than disk; guest flush confirmed/unconfirmed; one/two retained disks carrying later UID; restored sequence below/equal/above retained UID; manifest complete/failed. Hosted real Restic/PostgreSQL can show component time skew and isolation; native ZFS/guest evidence is needed for retained-disk and actual activation claims. Preserve original live fleet custody while restoring into a dedicated recovery environment.

Open questions: None for the backup CLI. It has no activation/claim command; the safe oracle is private restore isolation, with historical activation requiring a separate fenced reconciliation drill.

### Investigation Log

#### Is there a repository-provided operator activation or claim command for a restored private target?

- Examined (2026-10-13): `nix/modules/backups/runtime.py:257-345`, `nix/modules/backups/default.nix:92-107`, `nix/tests/machines/backups/driver.py:187-258`, ADR-0070 `:86-102,120-125`, and ADR-0158 `:105-110`.
- Found: the operator CLI exposes `list`, `inspect`, and `restore`; restore requires an empty private target, runs component `restic restore --verify`, and writes the manifest there. The machine test restores PostgreSQL to a separate `isolated` database and starts a Marshall operator probe against it. ADR-0070 requires fencing and explicit reconciliation before serving traffic; ADR-0158 calls historical-restore UID repair unsupported.
- Not found: an automatic or operator `activate`/`claim` command in the backup CLI. The isolated operator probe does not establish safe activation of mixed-time authority.
- Conclusion: resolved. Scope the directly testable invariant to no automatic activation and private restore isolation. A later fenced historical activation/reconciliation drill is separate, and its UID reservation checks cannot be inferred from this CLI.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `storage`. hosted-restic-or-tcg-zfs-limited; independent witness: owned ZFS GUID/marker, independent Restic enumeration/isolated restore hash and fenced target. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R11`: The current safety claim is quarantine of a mixed-time restored graph. No later serving activation is promised until a separate reconciliation receipt binds database sequence, UID/home, disk GUID, Store host binding, execution epoch and live endpoints. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.
