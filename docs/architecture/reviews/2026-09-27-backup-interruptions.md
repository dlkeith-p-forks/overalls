# Backup interruptions, custody symmetry and publication-window pinning

## Scope and architecture impact

Campaign improvement 109 extends discovery 046 into delivery under
[ADR-0070](../decisions/0070-host-recovery-backups.md). One production source
line changed: `Repository.command()` validates private credential custody
immediately before every repository-touching invocation, closing a refusal
asymmetry where only the capture path gated credentials. Every other change is
verification: generated interruption histories, a real concurrent
prune-vs-restore probe, mid-restore credential swap refusal, restored-authority
refusal properties, a native kill/unlock/lock/custody extension, handbook
custody/interruption paragraphs, scenarios ledger coverage and ADR-0070
evidence wording. No architecture decision changed; restic repository
semantics, retention policy, the journal state machine, status publishing and
systemd layout are unchanged.

Contracts reviewed: root/Nix/test/module `CONTRACTS` plus declaration notes on
`retention-validates-all-references-first`, `backup-terminal-after-cleanup`,
`backup-command-bounded-readers` and `backup-state-durable-publication`. The
fix adds `repository-commands-require-custody` at the enforcing boundary and
keeps every existing contract intact, including custody-free cleanup (cleanup
never routes through `Repository.command`).
`nix tests must use real packages` and `fixtures stay isolated` hold: the
extended derivation runs the real runtime in subprocesses against real local
encrypted Restic repositories; the native run exercises the packaged units.

Reviewed the runtime dispatch, journal transitions, custody gate, retention
walk, shim discipline and Lilly claim/journal authority layers. The new fixture
methods launch the real runtime, wait for an in-flight marker, signal it and
drain the recorded reader process groups before assertions run.

## Defect 1: credential-gate asymmetry — reproduced, fixed

Reproduced before repair: with a mode-0644 password file the operator `list`,
`inspect` and `restore` commands succeeded (exit 0), `init` materialised a
fresh repository, `prune`/`check`/`read-check` ran, and with absent S3 keys the
same operations reported a generic `repository` failure instead of a closed
`credentials` refusal: 43 failing subtests (8 custody corruptions × 7
operations + S3 distinctions). What capture already refused is now uniform.

Fix ([restic.py](../../../nix/modules/backups/restic.py)): `command()` runs
`self.credentials()` before spawning Restic. One line plus its contract.

`test_generated_credential_custody_refusal_symmetry` then passed in 88.371s
standalone (and inside the shared derivation): group/world-readable, symlinked,
multi-linked, empty, whitespace-only, oversized and missing password files plus
absent-S3-keys all refuse on `list`/`inspect`/`restore`/`init`/`prune`/`check`/
`read-check` with unchanged repository/source inventories and empty fresh
targets. Read operations never republish status; the scheduled prune/check/
read-check publish `failed/credentials` with the prior success retained;
`backup` is the unchanged control. A valid-custody probe against an
unreachable S3 endpoint still reports `repository`, distinguishing the closed
custody refusal from repository failures. Two other defects from discovery 046
(mid-restore swap, publication window) showed no divergence after pinning; the
stale-writer-lock pin records intended restic semantics, no defect.

## Interruption and concurrency histories

All through the real runtime and local encrypted Restic
([backup-operators.py](../../../nix/tests/evaluation/backup-operators.py)):

| Test family | Independent assertion |
| --- | --- |
| Custody symmetry (generated cases, seed 26005) | Every corrupt-custody or missing-S3 combination refuses every repository operation closed as `credentials` before repository access; zero inventory or status drift; capture control unchanged. |
| Restore component interruptions (generated indexes/permutations, seed 26006) | SIGTERM, SIGKILL and a real command timeout at generated component indices abort publication: verified partial prefixes stay byte-exact and inspectable, no `manifest.json`, status bytes unchanged (SIGKILL/SIGTERM), reader sessions reaped; fresh-target retry is byte-exact. |
| Kill during real upload (SIGTERM and SIGKILL) | The upload leg completed inside the shim while the runtime still believed it in flight: SIGTERM reconciles through the runtime handler, SIGKILL defers to the cleanup operation; both record `failed(interrupted)` exactly once with idempotent cleanup retry; the uploaded component snapshot (run tag not in any manifest) survives retention within its one-day grace and the next run completes healthy with the orphan still retained. |
| Publication-window kill pinning | Killing between manifest upload and journal completion leaves the host-manifest point tag-visible: it lists, inspects and restores byte-exact and counts in retention, while the journal records `failed(interrupted)` with `manifest_id = null`. A later complete backup displaces the older recorded point but not the published unrecorded one (keep_last=2). Semantics pinned as accepted under ADR-0070 — no divergence defect. |
| Real concurrent prune-vs-restore | A live blocked restore holds `owner.lock`: real prune/check/read-check/cleanup processes skip with zero and empty output, list/inspect/restore refuse nonzero; repository, source and `status.json` bytes are unchanged; release restores normal operation. |
| Mid-restore credential swap (generated component orders, seed 26007) | Swapping the private password between components fails the remaining components closed as `repository`, retains the verified partial prefix, writes no manifest and mutates no status or repository; after custody is restored, the same target refuses again (occupancy) and a fresh target recovers byte-exact. |

Lilly generated stale-authority property
([restored_authority_test.exs](../../../lilly/test/host/restored_authority_test.exs)):
all fifteen divergent combinations of `zpool_guid`, dataset GUID, host and pool
identity between restored `.lilly-zfs` owner/claim/backup journals and the live
pool refuse at the claim-read, backup-journal and capacity-expectation layers
with byte-identical on-disk records; the matching control accepts. The
`Pool.new`/`ZFSDataset.bind` live-pool comparison behind ADR-0070 reactivation
remains the recorded native follow-up (KVM probe, out of scope here).

## Native evidence

`nix build .#checks.x86_64-linux.backup-recovery` under the medium native lock,
captured tree, logs and store paths in the execution record below. On top of the
existing ZFS/TLS-S3/PostgreSQL/keyring/restore/retention journey:

- An operator SIGKILL during the real host upload (48 MiB at the configured
  8 MiB/s limit) leaves the journal `capturing` and status `running`; the
  cleanup unit records `failed(interrupted)` exactly once, destroys the owned
  native snapshot/mount, retains the unreferenced PostgreSQL orphan snapshot
  while the last-good point stays current, and an idempotent retry is a no-op.
- The killed writer's non-exclusive Restic repository lock is observed by
  `restic list locks`; `prune` then refuses closed with `failed/retention` and
  `check` refuses closed with `failed/repository` while the published point
  lists unchanged; after the documented `restic unlock` remediation both
  succeed. This pins actual restic 0.18 locking semantics — retention does not
  silently delete anything on interruption evidence.
- A held host lock (real `flock` through systemd-run) refuses operator
  list/inspect/restore nonzero while all four scheduled units start and skip
  with zero; `status.json` bytes are unchanged throughout.
- A world-readable password and a missing S3 EnvironmentFile each close the
  packaged service and the transient operator CLI with `failed/credentials`,
  with retained last success; custody restoration resumes normal operation; the
  final cleanup-without-credentials subtest is unchanged.

## Execution record

Pinned assertion text for the scenarios.json review pointers (verbatim):

- "native backup-recovery run with interruption, lock and custody refusals" — the
  325s run whose subtest seconds are listed above.
- "shared extended backup-operators run" — the six focused standalone runs above
  (custody symmetry 88s after the 43-failure reproduction; restore-component
  interruptions 48s; kill-during-upload 36s; publication pinning 83s;
  concurrency and mid-restore swap 113s) and the extended 12-test suite at
  1097s, with derivations as listed.
- "lilly focused restored-authority suite" — 2 tests in 0.7s
  (MIX_TEST_PARTITION=verify109).

## Execution record

Focused standalone runs on the worktree (Python 3.13.15, Restic 0.18.1):
custody symmetry 88.371s after reproduction (43 pre-fix subtest failures);
restore-component interruptions 48.112s; kill-during-upload 36.792s;
publication pinning 83.072s; concurrency + mid-restore swap 113.092s. The full
extended suite passed 12 tests in 1097.042s. The strict derivation
`kittens-backup-operator-histories` (ruff format+check, ty, then the twelve
tests) built at `/nix/store/0abkirxjvs49019xqv8hdrm5w6rjihv9-kittens-backup-operator-histories`
in 1155s. The backup-types derivation passed at
`/nix/store/i2gk01gn2gsx3wai47jlzcmhily2k28z-kittens-backup-types`
(ruff/ty plus its existing 8 state, 11 workflow and status suites). The Lilly
focused restored-authority suite passed 2 tests in 0.7s
(`MIX_TEST_PARTITION=verify109`, `ERL_FLAGS='+S 6:6'`).

Native `backup-recovery`: passed in 325s at
`/nix/store/c6is7prqpmhng1pyvws7mlicc77ygkf0-vm-test-run-kittens-backup-recovery`
(captured under flock `/tmp/opencode/verify-native-medium.lock`). Subtest
seconds: wild-card custody 6.49, timer wiring 0.03, first complete point 11.62,
SIGKILL-during-upload reconciliation 6.31, stale-lock refusal and unlock 9.70,
database outage preservation 4.28, isolated restore 9.83, retention 33.84,
held-lock refusal/skip matrix 3.19, EnvironmentFile custody refusals 2.50,
credential-free cleanup 0.18. Earlier attempts in this change:
(1) a `pgrep -x restic` wait never observed the live reader in 60s while the
upload completed — replaced by ZFS-snapshot presence plus a `/proc` comm probe;
(2) the interrupted writer left a real repository lock and retention's first
exclusive `forget` failed `retention` — root-caused against restic 0.18.1
source (`forget`, `prune` and `check` all take exclusive locks; stale locks
are never auto-removed) and pinned with the documented `restic unlock`
remediation, with the driver diagnostic retained for future failures; (3) the
held-lock holder lost its unit PATH (`touch`/`sleep` resolve only via absolute
store paths); (4) the packaged CLI's refusal stderr reaches the guest journal
but not the driver's captured output channel, so the native side pins nonzero
exit and zero status mutation while the exact 75/TEMPFAIL message stays pinned
by the evaluation histories.

Mutants (copied module trees, real source untouched, fixtures removed):

| Mutant | Intended detector | Result |
| --- | --- | --- |
| Remove the `command()` custody gate (the original defect) | custody symmetry family | Detected — the operation matrix succeeds instead of refusing |
| `recover()` skips `journal.failed("interrupted")` | kill-during-upload and publication-window histories | Detected — cleanup reconcile fails without the marked failure |
| Orphan grace boundary replaced by immediate expiry | kill-during-upload grace assertions | Detected — the fresh orphan is forgotten instead of retained |

## Existing acceptance and remaining gaps

The [original recovery review](2026-09-18-host-recovery-backups.md) and the
[operator verification review](2026-09-26-backup-operator-verification.md)
retain their scopes; this change adds custody uniformity, interruption,
concurrency and stale-authority evidence on top. Never weakened: failed runs
still do not displace good points, published points remain complete-only, and
the custody gate reads credentials through the private envelope every time.

Remaining, unchanged: production S3 deployment, physical power-loss,
independent off-host key recovery and historical-authority reconciliation
(ADR-0070 open question), plus the optional native KVM probe that a restored
`.lilly-zfs` tree binds against a real replacement pool — tracked as the
follow-up to this improvement. The systemd `Persistent` calendar catch-up of
the five backup timers remains configuration-level (timers are deliberately
deactivated inside the machine fixture).
