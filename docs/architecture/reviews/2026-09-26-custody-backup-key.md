# Custody: backup key ceremony, restore-decrypt composition, recipient turnover

## Scope and architecture impact

Improvement 107 implements transitions (a), (b) and (c) of discovery 045a on
base `c14ae27d`: the Restic backup-password key ceremony documentation and the
executable check of its exact wedge label, the synthetic restore→decrypt
composition end to end, and full recovery-recipient turnover histories
(two-generation ceremonies plus the direct-turnover refusal pair). Transition
(d), updater recovery after manual rotation, is delegated to the sibling
improvement and untouched (no `nix/modules/auto-update/` change).

No production runtime, protocol, authority, option or persistence change is
made. Production-facing deltas are documentation only: the key ceremony, the
documented wedge label/status and recovery, turnover planning and the
retention-window stranding hazard in `docs/backups.md`, `secrets/README.md` and
`docs/fleet-users.md`. ADR-0070 gains evidence wording only; its accepted
rationale (SOPS-sealed per-host password, recipients never rotating repository
keys) is preserved. ADR-0041/0044/0067/0086 remain in force; no new decision is
needed because reconciliation, custody and refusal semantics are unchanged.

## Evidence

All checks are exported Nix evaluation derivations using real Restic, SOPS,
age and OpenSSH binaries with synthetic disposable identities; no systemd, S3,
ZFS, PostgreSQL or native claim is made.

- Exported `checks.x86_64-linux.secret-reconciliation`, derivation
  `/nix/store/l2vs2rmr4kzkaynggc8jf028l6l6x0h9-kittens-secret-reconciliation.drv`,
  output `/nix/store/2j9j8xfimav8zqv32rf4gc0q073aqsyh-kittens-secret-reconciliation`:
  the unchanged 14 fixed secrets tests (Ran 14 tests in 3.271s; OK),
  Recipient histories passed: 12 generated examples,
  Interruption histories passed: 8 generated examples and 2 explicit boundaries,
  Ceremony histories passed: 6 generated examples and 3 explicit pairs.
  Direct turnover refusals passed: 4 generated examples and 1 explicit pair.
- Exported `checks.x86_64-linux.backup-custody`, derivation
  `/nix/store/i5w4xbgzmvhvx17zgz5z79fzljkvc8nq-kittens-backup-custody.drv`,
  output `/nix/store/hwvl1206cfahadbag67fm41dqyllc0vb-kittens-backup-custody`:
  Ran 3 tests in 73.605s; OK — `test_ceremony_overlap_never_wedges_scheduled_operations`,
  `test_restored_ciphertext_decryption_recovers_repository_access` and
  `test_rotation_without_ceremony_wedges_with_repository_failure_label`.
- Standalone Ruff format/lint and ty (3.13) pass for
  `nix/tests/evaluation/backup-custody.py` (run with the isolated backups
  module copies, mirroring the derivation) and the modified
  `secret_recipient_histories.py`; the repository-wide `python-static` gate is
  rerun with the final tree (results below).
- Neither check emits passwords, keys, tokens or private paths in observed
  output; failures print only the documented generic labels, enforced by
  byte-level leak assertions inside each fixture.

## Composition details

(a) Key ceremony and wedge. The ceremony test performs `restic key add` with a
new password before the document value is replaced, observes healthy managed
`check`/`backup` runs at every step, retires the old key with `key remove`
selected from `key list --json`, and verifies the retired password is refused
while scheduled operations never observed a failure status. The wedge test
rotates the document value without the ceremony: managed `backup`, `check` and
`list` fail with exit 1, stderr exactly `Backup operation failed; inspect backup
status and recovery guidance.`, status `state: failed`/`failure: repository`,
an untouched snapshot inventory, preserved `last_success_at` and a terminal
journal with `phase: failed`, `failures: ["repository"]`, no components.
Recovery decrypts the preserved previous-generation ciphertext through the real
secrets CLI and adopts the published password via `restic key passwd`; the next
`check` and `backup` succeed and the previous password is retired.

(b) Restore→decrypt composition. A managed backup materializes the sealed
hostname-backup document through the `materialize` configuration path, the
managed restore reproduces it byte-identically in a numbered directory located
via the captured `paths.json` mapping, the public secrets CLI decrypts it with
a recovery-only synthetic identity, and the recovered `RESTIC_PASSWORD` opens
the repository and lists the captured points. The failure leg performs a real
two-generation CLI turnover (two `rekey` invocations) and then refuses the new
identity on the preserved pre-turnover ciphertext with the documented decrypt
refusal, publishing no output file, while the retired incumbent still opens it.

(c) Turnover histories. `Policy.recovery_keys()` no longer pins the operator
identity into every generation; membership derives from the generated bitmask
(bits 1/2/4 with the alpha-overlap key rule) and a zero-recovery policy stays
ungeneratable because the CLI refuses it. Generated histories chain
transitions through a sampled retained anchor, mirroring the documented
two-generation ceremony; unretained identities keep failing with the
retained-recovery label and leaving exact inventories. The ceremony property
runs all three replacement pairs, asserting per-step drift, data-key rotation
and decryptor equality plus the post-turnover historical-envelope refusal and
the currently silent working-tree `check`. The direct-turnover property asserts
both refusal legs — retention for the removed identity, decrypt failure for
the new identity — with unchanged ciphertext and immediate reconvergence after
restoring the previous policy.

## Mutants

| Mutant | Intended oracle | Observed | Reverted |
| --- | --- | --- | --- |
| `restic.py` `ensure()` raises `BackupError("credentials")` instead of `repository` | wedge label/status assertions | `backup-custody` fails: `Lists differ: ['credentials'] != ['repository']`; ceremony leg still passed | yes; identical derivation rerun passes |
| `recovery_keys()` re-seeds the operator identity (`keys = {0}`) | generated decryptor/anchor oracle | `secret-reconciliation` fails with AssertionError inside recipient histories | yes; identical derivation rerun passes |

## Defect verdicts

- (a) Repository password rotation without a documented key ceremony wedging
  all scheduled backups under `failure: repository`: **reproduced and fixed**.
  The wedge is the intended fail-closed behavior; the defect was the missing
  documented ceremony, label and recovery path. Fixed in `docs/backups.md` with
  executable coverage in `backup-custody`. No production source change.
- (b) Restore drill never composing materialized ciphertext, restore,
  recovery-only decrypt and repository access: **evidence gap closed**; no
  behavioral defect found.
- (c) `{0}` hard-pin blocking full-turnover histories: **reproduced and fixed**
  in the generator; the two-generation ceremony and direct-turnover refusal
  pair are now covered. The retention-window stranding hazard is **documented
  only**: `check` and Restic retention keep their current silent behavior by
  design here; warning redesign is delegated territory (055).

## Remaining gaps

No native run: systemd service/timer activation, TLS S3, native ZFS,
PostgreSQL and physical custody acceptance retain their previously recorded
scopes; the native backup fixtures continue to inject the password file
directly, so the custody leg is evaluation-level only. Updater recovery after
manual rotation (045b) is separate. The stranding warning is documentation and
planning guidance, not an implemented check alert. Generated histories run with
`derandomize=True` (fixed deterministic generation), so no external seed is
recorded.

## Gates

- Focused suites above: both exported derivations pass; the mutant table records
  detection and reverts, with post-revert trees resolving to the identical
  recorded derivations.
- Repository governance on the final tree: `elixir scripts/check_adrs.exs`
  passed; `scripts/check_hldd.exs` passed with reviewed receipts (deployment
  and governance `updated` records describing this change's chapter and source
  deltas; marshall/lilly/services `no-impact` records for the regenerated
  coverage chapter digest; a final governance `no-impact` record for the
  docs-only example clarification); `scripts/hldd_coverage.exs --check`,
  `scripts/hldd_options.exs --check` and `scripts/hldd_views.exs --check`
  passed; contract format/coverage (`scripts/check_contracts.mjs format`)
  passed with 102 CONTRACTS files, 1814 native notes and 126 parsed source
  files across 2137 maintained files.
- Full `prek run --all-files` passed on the final tree, including the Ruff,
  Ruff-format, ty, per-application logging and hldd-review hooks.
- `nix build .#checks.x86_64-linux.hldd` passed on the final receipt tree;
  executed output `/nix/store/dhqp59gv81vy02sdwcd2a4n21vm7khld-kittens-hldd-check`
  (an earlier completed run produced
  `/nix/store/1f4am4hk79v3hy753jc0p5cyrxxvbism-kittens-hldd-check`; the gate's
  inputs are the chapters, scenario ledger and receipts, not this review).
- `nix build .#checks.x86_64-linux.python-static` passed (Ruff/ty across the
  repository, including both Python files changed here); output
  `/nix/store/z87nqwx021720p46w9b6l80fzsvn3xi7-kittens-python-static`.
- No Elixir application source changed (handbook chapters, scenario ledger and
  docs only), so the Marshall/Lilly/protocol `mix precommit` suites are outside
  this improvement per the campaign precedent for documentation-only changes;
  the shared governance gates above still run.
