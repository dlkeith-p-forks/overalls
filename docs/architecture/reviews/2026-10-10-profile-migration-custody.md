# Existing-state profile migration custody review

## Scope and impact

Read-only review of incoming `70e2aaf6` and `76c6ce42` against the observability
branch's accepted ADR-0149/ADR-0140 custody contracts. Reviewed the complete diff,
root/component/control/host/repository contracts, the runtime startup path,
command-store host/version binding, lifecycle Journal/Persist, ZFS claim writers
and VM execution bindings. The incoming image-template fixture additions are
reviewed separately below. No deployed resources were changed by this review.

The source adds a retained-state migration and startup mutation. That has
persistence and recovery impact despite unchanged address octets and tool policy.
ADR-0147 expressly accepts fresh installations only. Proposed
[ADR-0151](../decisions/0151-existing-state-standard-profile-migration.md) records
the extension without rewriting that accepted rationale or activating supersession.
The authorized independent-observability work includes repairing its conflicting
archive/publication behavior; broader migration acceptance remains unresolved.

## Findings

1. **High — raw lifecycle claim rewrite violates archive/publication custody.**
   ProfileRename (`lilly/lib/lilly/control/profile_rename.ex` at kittens revision `9fe1e493`, repository deleted) initially
   applies `PrivateFiles.write` directly to `claim.json`, recursively changing its
   profile while leaving `_lifecycle` revision unchanged.
   [ZFSDataset](../../../lilly/lib/lilly/host/zfs_dataset.ex) normally publishes that
   file through `Lifecycle.Journal.write(Dataset, ...)` under the pool storage lock.
   `local-machine-locked-publication`, `local-state-publication-atomic` and
   `legacy-diagnostics-have-no-state-authority` require validated journal load,
   coherent Ash publication and exact archival of original v1 bytes first.
   A legacy claim rewritten before archive loses the exact original custody; an
   archive-before-v2 interruption can subsequently fail on conflicting bytes.
   Recommendation: use the pool's normal storage lock, validate/archive/publish v2
   through Journal.load, then publish the intentional same-state profile update
   through Ash without rewriting any immutable archive.

2. **Medium — startup rewrite precedes persistent host identity validation.**
   The incoming runtime calls migration after host lock acquisition but before
   `Store.open` validates the store's retained host/version identity. A configured
   host-ID mismatch can therefore mutate private commands before startup refuses
   the foreign store. Move migration after validated binding and before Store.all;
   failures must retain closed diagnostic reasons and release both startup locks.
   The added `vm.json` path in `76c6ce42` is a plain execution identity marker, not
   a lifecycle journal. Its exact physical binding and matching deletion tombstone
   require separate review; a generic transformation does not prove adoption safety.

3. **Medium — deployed-state policy and handbook claims drift.**
   ADR-0147 and HLDD13 state that existing-state upgrade is excluded, while the
   incoming source automatically migrates retained profiles. Its blanket
   `no-impact` review receipts do not document the new refusal/recovery behavior.
   Preserve ADR-0147 and propose the extension separately; reconcile deployment,
   recovery and scenario documentation with the actual implementation and remaining
   native gaps. A structural receipt cannot establish upgrade acceptance.

4. **Verification gap — the incoming property covers only pure transformation.**
   The property checks nested exact-name substitution, unrelated fields and
   idempotence. It never calls filesystem migration, acquires a native storage
   lock, validates host binding or interrupts archive publication. Add isolated
   filesystem tests for exact legacy bytes, corrupt/conflicting archives, unlocked
   refusal, foreign host refusal and idempotent reopens. A packaged retained-state
   upgrade with real running guests remains necessary before rollout claims.

## Correction boundary and current evidence

Independent review of the frozen correction finds no remaining archive/publication
blocker in the inspected path. Its implemented boundary uses `Storage.locked` on
`.lilly-storage` for Dataset claims, loads and
archives exact legacy bytes before live transformation, and applies the profile
change as a same-state Ash update retaining ID/state and advancing revision once.
Plain command/execution/disk markers use PrivateFiles separately; immutable
`.lifecycle-v1` bytes remain untouched. Runtime validates host/version binding
before migration and explicitly releases startup locks on closed failure. Plain
records reject unexpected lifecycle envelopes; execution `vm.json` and matching
`deleted.json` migrate together without touching native execution journals.

The combined focused Lilly selection passes 31 checks (five properties and 26
tests) in 3.5 seconds, seed 957907, with exit 0, recorded at
`/tmp/kittens-profile-migration-custody-focused.log`. It covers exact whitespace and
accepted v1 diagnostic bytes, one same-state revision increment, existing exact
archive recovery, conflicting archive/schema refusals, missing host lock, foreign
Store binding, pool contention, v2 deleted-state poisoned-archive independence,
execution binding/tombstone migration and native-journal byte preservation.
Loading the original incoming `76c6ce42` importer in a disposable VM fails the
exact-v1 regression: exit 2, zero of one passing and nine excluded, 0.4 seconds,
seed 414888. The original archive is absent, as recorded in
`/tmp/kittens-profile-migration-raw-baseline-witness.log`. This falsifies the raw
rewrite against the corrected fixture without modifying the production source.

The actual Marshall migration test (`marshall/test/marshall/profile_rename_migration_test.exs` at kittens revision `9fe1e493`, repository deleted)
passes one check in 0.3 seconds, seed 551224 (`seed551224` ledger reference), at
`/tmp/kittens-observability-profile-marshall-focused-fixed.log`. It uses populated
disposable PostgreSQL tables, runs the real migration twice under distinct fixture
versions, preserves historical/unrelated values and checks the final address
constraint and down refusal. This is an actual SQL migration check on its minimal
fixture, not a full retained-schema/physical-host deployment test.

Journal.load validates lifecycle envelope/resource/state/legacy event shape; it
does not validate the complete ZFSDataset native ownership binding. The current
16,384 limit bounds candidate count after full wildcard traversal.
These are explicit remaining limits. Prepared archive-interruption fixtures do
not establish abrupt migrating-host recovery. The frozen complete Lilly precommit
passes with exit 0: 541 checks (104 properties and 437 tests) in 75.3 seconds, seed
95084, and forced Dialyzer with zero errors, skips and unnecessary skips in
14.82 seconds. The complete shell is 149.526942544 seconds, recorded at
`/tmp/kittens-lilly-profile-custody-final-precommit.log`; runtime, 149-ADR,
contracts, logging, compiler and formatting gates also pass. No source/assertion
changes occur during that gate. The frozen current Marshall precommit exits 0:
1387 passing checks (235 properties and 1152 tests), two excluded, seed 922173,
in 1510.0 seconds (40.1 asynchronous and 1469.9 synchronous). Its 32
terminal/accessibility checks, four dashboard checks and workspace TypeScript
gate pass. Forced Dialyzer has zero errors, skips and unnecessary skips in
61.94 seconds, after PLT preparation of 13.38 and 324.95 seconds. The raw log is
`/tmp/kittens-observability-profile-marshall-final-precommit.log`.
These component checks do not establish a legacy native upgrade or physical
isolation.

The incoming image-template fixture adds a delayed native ZFS property change
and a process kill after actual unmount but before property mutation. It requires
accounting refusal while ownership is incomplete, sweep recovery of the retained
standby GUID, exact claimed GUID reuse and final owned cleanup. It changes no
production command format, diagnostic channel or archive authority. Its added
native journeys are present and unrun in this review; isolated profile tests do
not establish them. Earlier completed native captures precede this profile
migration and incoming guest source. The corrected full relocation gate now exits
0 with all 19 subtests against the incoming profile implementation and guest
source, at
`/nix/store/11ibfwp2xv1jdf53vn3gr3q22mhdc3hg-vm-test-run-kittens-relocation-fleet`.
The VM-run footer is 3,643.75 seconds, the following script footer 3,643.99 seconds
and the Bash wrapper 3,654.445 seconds, recorded at
`/tmp/kittens-relocation-trust-native-final.log`. Its exact derivation, unchanged
physical/audit/fault/deadline oracles and preserved earlier failure are documented
in [ADR-0149](../decisions/0149-independent-observability.md). Later description,
fleet-comment, separate image-template-fixture and decision-status edits change
no relevant tested runtime values. This records actual running-guest relocation
evidence. Packaged retained-state profile upgrade, native Starship prompt
rendering and the incoming standalone standby fixture remain unverified.

## Remaining work

Verify a packaged retained-state database/host upgrade with physical guests and
interrupted-migration recovery before deployment. Keep ADR-0149 production sizing,
physical power-loss and independent
notification-receipt gaps separate. ADR-0147 remains accepted/partial and
ADR-0151 remains proposed/partial until the wider policy is resolved.
