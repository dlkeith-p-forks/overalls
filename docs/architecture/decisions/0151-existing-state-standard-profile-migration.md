# ADR-0151: Existing-state Standard profile migration

- ID: ADR-0151
- Date: 2026-10-10
- Status: superseded
- Implementation: partial
- Components: Marshall persistence, Lilly control, Lilly native storage, deployment
- Supersedes: none
- Superseded by: ADR-0159

> Superseded by [ADR-0159](0159-remove-legacy-compatibility.md) only for this whole decision; the migration completed on both hosts. ADR-0159 carries every other requirement of this record forward unchanged.

## Context

[ADR-0147](0147-standard-profile-name.md) accepted Standard naming for fresh
installations only. It explicitly excluded legacy aliases, existing-state import
and mixed-release compatibility. Incoming commits `70e2aaf6` and `76c6ce42` add a
Marshall database migration and automatic Lilly startup migration for retained
`antithesis` profile values. That materially expands the accepted deployment
boundary even though the address octet and profile policy are unchanged.

The independent-observability review found that the incoming raw rewrite of
`claim.json` bypasses the lifecycle publication boundary. A retained v1 claim must
be archived exactly before any payload changes; rewriting it first loses original
custody and can conflict with an archive retained by an interrupted migration.
The authorized observability work includes repairing this custody violation.
Acceptance of the wider deployed-state naming policy remains unresolved, so this
extension is proposed and ADR-0147's accepted rationale and status remain intact.

## Decision

Propose a one-way, spelling-only existing-state migration from `antithesis` to
`standard`. Keep the 10.20.0.0/16 address pool, network rules, tool permissions,
placement identity, host/pool binding, operation identity, generations, physical
receipts and resource commitments unchanged. Retain the closed Standard-only wire
schemas; this is neither a legacy wire alias nor mixed-release compatibility.

Run the Marshall migration through the reviewed release migration workflow before
dependent applications start. Update current address/VM rows and persisted command
snapshots together with the address constraint. Historical PaperTrail/version rows
remain recorded history. A rollback must not silently restore the retired name or
make legacy documents executable.

Lilly must validate the persistent command-store host/version binding before
mutating retained profile values. Operate only on validated operator-owned private
command records, execution bindings and tombstones, and owned ZFS claim/disk/ready
records. Preserve every field outside the exact profile projection, perform bounded
enumeration and fail closed on malformed, foreign or unsafe state. Restart after a
partial migration must resume idempotently without launching an unproven guest.

Lifecycle claims must use their normal pool storage lock and reviewed journal
boundary. Load and validate the v1 envelope, retain its exact original bytes, and
publish state-only v2 before changing the live profile payload. Apply that change
through the existing same-state Ash publication, retaining resource ID and state
and advancing revision once. Never rewrite an immutable `.lifecycle-v1` archive or
invent a diagnostic acknowledgment, physical outcome or scheduling authority.
Plain private markers retain their separate native schemas and durable publication
boundary. Diagnostics use the reviewed Events catalog with a numeric count only.

## Alternatives

Keep fresh-only naming and require a separately planned offline migration. That is
the accepted ADR-0147 policy and remains valid until this extension is accepted.
Restore a legacy alias throughout wire and execution schemas; that would broaden
compatibility and does not address malformed or foreign retained state. Rewrite
all JSON recursively without schema and custody review; that can corrupt lifecycle
history and is rejected by the existing archival and publication contracts.

## Consequences

The proposed migration enables recovery of retained installations without changing
their network or tool authority. It adds startup mutation and irreversible
database-upgrade behavior, requiring explicit deployment evidence. Individually
durable files can leave a partially completed host migration; replay must converge
or refuse before actor initialization. Guest/VMM survival, native storage recovery
and multi-host rollout cannot be established by a pure JSON transformation test.

## Invariants and verification

- Refuse wrong host/version binding, unsafe private paths, malformed claims and
  conflicting archives before replacing their bytes.
- Preserve exact original v1 archives, including whitespace and retained events;
  preserve ID/state and advance the live payload revision once through Ash.
- Verify interrupted archive/v2/profile publication, repeated startup and mixed
  old/new private markers without resetting intent or accepting a stale outcome.
- Preserve unrelated fields, disk contents, current authority and historical audit
  rows; current address constraints must reject the retired profile after migration.
- Run pinned component/typing/contracts/ADR/HLDD checks and a packaged native
  retained-state upgrade with real running guests before deployment acceptance.

## Implementation evidence

The incoming Marshall migration (`marshall/priv/repo/migrations/20261010013000_rename_antithesis_profile.exs` at overalls revision `9fe1e493`, repository deleted)
updates retained address/VM rows, command snapshots and the address constraint.
After it was applied on every deployed database, ADR-0159 pruned that file; the
closed Standard address constraint a fresh installation creates is in the
[inception profile migration](../../../marshall/priv/repo/migrations/20260918034812_inception_profile.exs).
ProfileRename (`lilly/lib/lilly/control/profile_rename.ex` at overalls revision `9fe1e493`, repository deleted) and
Runtime (`lilly/lib/lilly/control/runtime.ex` at overalls revision `9fe1e493`, repository deleted) introduce startup migration
with the reviewed pool-locked journal correction and prior host/version binding.
The filesystem/property tests (`lilly/test/control/profile_rename_test.exs` at overalls revision `9fe1e493`, repository deleted)
cover exact v1 custody, same-state revision, retained/conflicting archives, envelope
refusals, host/pool locks and execution tombstones. The focused combined Lilly
selection passes 31 checks (five properties and 26 tests) in 3.5 seconds, recorded
at `/tmp/overalls-profile-migration-custody-focused.log`. Loading the original
`76c6ce42` importer in a disposable VM fails the exact-archive regression with exit
2 and zero of one passing in 0.4 seconds; the original archive is absent, recorded
at `/tmp/overalls-profile-migration-raw-baseline-witness.log`.

The actual Ecto migration test (`marshall/test/marshall/profile_rename_migration_test.exs` at overalls revision `9fe1e493`, repository deleted)
passes one check in 0.3 seconds, seed 551224, recorded at
`/tmp/overalls-observability-profile-marshall-focused-fixed.log`. It migrates
populated disposable PostgreSQL tables twice, verifies current profile and nested
snapshot updates, preserves unrelated values and historical versions, and checks
the new constraint's admission/refusal and irreversible down path. This does not
exercise a full retained production schema or a running Lilly host.

The [focused review](../reviews/2026-10-10-profile-migration-custody.md) independently
reviews the correction. Journal validation covers envelope/resource/state/legacy
events, not the complete native Dataset binding. The 16,384-file limit bounds
candidate count after wildcard traversal, not traversal memory/work. The frozen
complete Lilly precommit passes 541 checks (104 properties and 437 tests) in
75.3 seconds, seed 95084, and forced Dialyzer with zero errors, skips and unnecessary
skips in 14.82 seconds. The full shell is 149.526942544 seconds, recorded at
`/tmp/overalls-lilly-profile-custody-final-precommit.log`. The frozen current
Marshall precommit exits 0 with 1387 passing checks (235 properties and 1152
tests), two excluded, seed 922173, in 1510.0 seconds. Its 32 terminal/accessibility
and four dashboard checks and workspace TypeScript gate pass; forced Dialyzer has
zero errors, skips and unnecessary skips in 61.94 seconds, after PLT preparation
of 13.38 and 324.95 seconds. The raw log is
`/tmp/overalls-observability-profile-marshall-final-precommit.log`.
The earlier independent native captures predate these incoming changes. The
corrected full relocation gate now exits 0 with all 19 subtests, using the incoming
profile implementation and guest source. Its realized output is
`/nix/store/11ibfwp2xv1jdf53vn3gr3q22mhdc3hg-vm-test-run-overalls-relocation-fleet`;
the VM-run footer is 3,643.75 seconds, the following script footer 3,643.99 seconds
and the Bash wrapper 3,654.445 seconds, at
`/tmp/overalls-relocation-trust-native-final.log`. Exact derivation, unchanged
fault/oracle scope and the preserved earlier failure are recorded in
[ADR-0149](0149-independent-observability.md). This running-guest relocation
capture does not seed a retained legacy host for packaged upgrade. Neither it
nor the component checks accept the proposed policy or establish that upgrade.

ADR-0159 Push 6 deleted the Lilly startup migration, its runtime call, its
`lilly.profile_renamed` event and its tests; the Lilly links above are permalinks
to the last revision containing them. The applied Marshall migration remains.

## Open questions

Accept or reject the existing-state deployment extension independently of the
authorized custody repair. Define the supported historical state matrix and
operator recovery after a refused or interrupted migration, complete native
Dataset binding validation and bounded traversal, and record an actual
retained-database/host native upgrade before rollout. The archive-recovery tests
prepare interrupted states; they do not kill a migrating native host. No rollout
is established by the current source integration.

## Related decisions

[ADR-0147](0147-standard-profile-name.md) retains the accepted fresh-installation
policy pending this proposed extension. [ADR-0149](0149-independent-observability.md)
requires exact legacy diagnostic custody and state-only current journals.
[ADR-0036](0036-automatic-host-updates.md) defines the release migration
workflow. [ADR-0017](0017-durable-vm-actors-and-host-ownership.md) defines native
ownership and guest lifetime. The
[focused review](../reviews/2026-10-10-profile-migration-custody.md) records findings
and scoped evidence.
