# Independent HLDD reviews

## Scope and architecture impact

ADR-0250 replaces only the aggregate receipt invalidation inherited by ADR-0122.
There is no product API, database, authorization, guest isolation or handbook
delivery change. Source and chapter reviews become independent; scenario and
topology metadata are partitioned into YAML files without upgrading evidence.

The host-retirement Codex session reported conflicts in the receipt manifest and
topology snapshot followed by stale receipts across all groups. The Android relay
session reported no repository edits or conflicts. The validation session was
contacted for overlap coordination. Work is isolated in `overalls-hldd-merges`.

## Findings and resolution

- The one-line manifest serialized unrelated reviews into one conflict location.
  Per-source and per-chapter files remove that shared write point.
- Overlapping chapter digests forced repeated unrelated source review. Independent
  chapter currency preserves mandatory documentation review without that cascade.
- Automatic migration could accidentally bless current unreviewed bytes. The
  migration validates baseline group hashes before writing and preserves their
  rationale, digest provenance and exact source/chapter bytes.
- YAML interpretation must not silently overwrite evidence. The adapter rejects
  duplicate keys, aliases, unsupported tags and unsupported scalar values.

## Validation and limits

The standalone ExUnit run loaded the repository's compiled test dependencies and
executed both HLDD architecture test files: **33 passed**, seed `733119`, 110.1
seconds, using pinned Elixir 1.20.4/OTP 29.0.6 and Hegel `b0dec2a`. The source
mutation property retains all 100 generated cases with a finite 180-second
budget. An earlier 60-second run passed 29 of 30 tests and timed out that property;
redundant reads were removed and the budget was adjusted for measured filesystem
and YAML overhead. No case-count reduction or alternate property engine was used.
The tests include a real Git merge, unchanged receipt preservation, scoped review,
rename/restoration, mapping drift, malformed YAML, migration refusal and already
reviewed chapter reuse, and deletion of a chapter after its last mapping is removed.

All **21 contract-checker regression tests** passed, including an inventory above
Node's default one-MiB subprocess output limit. That regression caught an integration
failure introduced by the larger receipt inventory; discovery now spools Git output
to a private temporary file without truncation. Contract discovery finds the changed
`inventory-includes-untracked` obligation. Schema and contract checks remain
structural, not semantic proofs.

The following checks passed in the isolated clone:

- `elixir scripts/check_hldd.exs` and `elixir scripts/check_adrs.exs`.
- Option, scenario and visual generated-reference checks.
- `nix build --no-link .#checks.x86_64-linux.hldd`, including packaged-source
  inventory and evaluated deployment placement.
- `prek run --all-files`: conflict markers, all application logging gates, HLDD,
  Dart formatting, Python ruff formatting/lint and ty.
- Direct migration comparison: every scenario and topology data field equals the
  validated legacy baseline; scenario chapter ordering is now stable by ID.

Marshall's complete `mix precommit` was attempted. After fixing the inventory
buffer failure, it stops at existing native Mila contract syntax errors in
`mila-crypto`, `mila-ffi`, `mila-model`, `mila-protocol` and `mila-runtime`. An earlier normal
Mix test invocation separately stopped at duplicate migration version
`20261020120000` (SCIM retirement and message boards), and compilation reports the
existing missing `require Marshall.Events` in message-board cleanup. The owning
Codex sessions were notified. These are not passing full-suite or Dialyzer results.

The Nix option reference required regeneration of existing control-character bytes;
option declarations and defaults were not changed. No browser presentation or
handbook delivery mechanism changes in this work. Existing scenario and security
gaps remain unchanged; these checks establish neither native isolation nor
production deployment health.

## Trunk integration

The cutover commit `cdb7a23c` was merged with upstream `7d25fbc7`. All upstream
legacy group digests were validated against an unchanged archive before transferring
34 existing reviews whose target identity, content and mapping exactly matched the
merged tree. The combined architecture review index received its own explicit
review. The removed aggregate manifest was not restored, and unrelated current
receipts were not rewritten. This transfers existing evidence without claiming
new execution of the upstream redaction or native-client features.

A second upstream merge, `eab8baf0`, added three source changes. Its legacy system
receipt was stale, so the migration correctly refused to transfer any evidence.
Those three diffs were reviewed explicitly instead: two files correct Ash update
argument shapes without changing documented redaction authority; the NixOS guest
package list adds `gh`, now documented as a declaration in chapter 07. No claim
of rebuilt or deployed guest images was added. Unrelated receipts stayed current.

The subsequent `283dfe85` integration was reviewed by path: Android removes an
obsolete Kotlin DSL block, the Linux test imports its existing route helper, the
Rust lock property guarantees its generated attempt is actually stale, and the
Underclass pin advances with its generated chapter-18 package version. These
reviews do not claim new native-client execution. The HLDD implementation and its
33-test result are unchanged by these incoming source fixes.

Upstream `1d231757` subsequently fixes that duplicate migration number and repairs
Redaction domain registration, generated run IDs and declared shard transition
actions. The five changed source paths (including both sides of the migration
rename) were reviewed explicitly; the declared workflow and authority remain the
same. This records the migration-order correction without claiming a passing
Marshall full-suite run.
