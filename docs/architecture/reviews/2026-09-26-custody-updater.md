# Updater custody recovery histories

## Scope and architecture impact

Improvement 108 (branch `verify/108-custody-updater`, discovery 045b) verifies the
scheduled updater's behavior around custody transitions of encrypted documents:
legitimate coordinated value rotation, recipient-only rekey, and a host removed
from a document its configuration still selects. There is no production runtime,
release-policy or decision change; ADR-0036 (through its supersession chain) and
ADR-0070 record evidence-only additions. Root-owned generated configuration
remains the trust boundary. Pre-switch compatible migration, candidate identity,
health verification before `lastHealthy` and the ban on automatic database
rollback remain in force.

## Transition map

The histories cover discovery 045b's four legs:

1. Coordinated value rotation is refused by the real `compatible`/preflight
   path as exactly `coordinated_secret_change` (`runtime.py:455-456`). The same
   immutable candidate keeps refusing with deterministic backoff
   `min(900, 30*2**(failures-1))`, failures capped at 16 (`runtime.py:964-974`),
   with no expiry: refusals are re-staged and re-refused indefinitely.
2. After the documented operator cutover (manual switch to the exact refused
   closure plus re-prepared bundles), the first timer run after the persisted
   `retryAt` finds the already-active candidate and takes the verify-only path
   (`runtime.py:936-947`): no staging, resolution, migration or switch runs;
   `record_healthy` clears the backoff and retains `failedPhase` as evidence.
3. A recipient-only rekey flows through real `stage()` → prepare `resolve()` →
   `descriptor_id` handoff (`runtime.py:341-388`, `secrets/prepare.py:260-292`):
   activation publishes the staged bytes even when the repository document is
   re-encrypted concurrently at switch time, an abandoned handoff is retired at
   staging entry, and the handoff key set matches the descriptor digests.
4. Removing the host recipient from a still-selected document wedges staging:
   `resolve()` fails closed ("resolver failed"), which crosses the generic
   handler as failure `operation_failed` with `failedPhase`/`phase` `stage`,
   with the same capped backoff, untouched live bundle and uninterrupted
   consumers. Post-fix recovery converges in one tick for both documented
   repairs (config stops selecting the bundle; custody re-adds the host).

## Independent oracles and seams

Expected durable state, exit statuses and the exact `update.phase`/`failed`/
`healthy` event streams come from an operation-log model (`Model.expect_tick`)
parameterized only by published revisions, clock steps and per-revision outcome
intent — never from updater results. Every timer firing compares the complete
`status.json` (restricted key universe, exact backoff sequence), the published
bundle bytes parsed independently, the serving-environment inventory, and the
command/preparation logs. Secret material and age/host private keys are asserted
absent from updater output and durable state. Fixture-side `require` failures
raise `BaseException` so harness bugs cannot masquerade as production wedges.

Executed for real: the full production `main()` lock/state path, `stage()`
(safe-directory and source validation, snapshotting), prepare.py `resolve()`
against the pinned SecretSpec/SOPS/ssh-to-age/age toolchain with a synthetic
generated host identity, `publish()`, `staged_contents()`/`descriptor_id()`
handoff consumption by a real `prepare.py` subprocess per activated unit,
`verify()`/health polling and `record_healthy` cleanup, and the public
`overalls-secrets` CLI policy refusal matrix. World-model seams (systemd,
Git refs, Nix builds, clocks, EnvironmentFile parsing, serving-process
discovery) are explicit and fail closed on unexpected commands.

## Execution evidence

The exported `auto-update-custody` check passed in **13 seconds** on
2026-09-26 (test phase properly measured). It runs standalone Ruff format and
lint plus `ty` against the copied production runtime, prepare.py, CLI and the
history file, then executes **5 tests: 26 generated histories and 2 fixed
boundaries** inside a disposable uid-0 user namespace (bwrap) with confined
`/run/overalls-auto-update`, `/var/lib/overalls-auto-update`, `/run/current-system`
and `/run/overalls-secrets` paths:

- Rotation recovery: 9 histories over refusal counts 1..22 (forced examples at
  1/16/17/22 across all three authority fields), optional in-window fetch tick.
- Recipient-only rekey: 8 histories over recipient position, stale-handoff
  retirement and an optional second bundle.
- Custody wedge: 9 histories over wedge durations 1..20 and both fix flavors
  (forced examples include 16-failure cap boundary and 17-failure plateau).
- Fixed: 18-refusal cap assertion converging after recovery, and the four-case
  CLI custody-policy refusal matrix via the real CLI.

All hypothesis histories run `derandomize=True, database=None, deadline=None`,
so the corpus is pinned. Tool versions are pinned by the flake (sops 3.13.3
during this build; secretspec/age/ssh-to-age from the same package set).

- Base: `c14ae27d` (published `origin/main` at branch creation).
- Derivation: `/nix/store/695yq92pcqffk3vbbmlh0j1w66kzvccv-overalls-auto-update-custody.drv`.
- Result: `/nix/store/k2x0kr392vv5rpr1mf37amczpla1q26v-overalls-auto-update-custody`.
- Production runtime SHA256: `06adee90c7c11638...`; prepare SHA256: `7097249f09f22464...`;
  CLI SHA256: `0cb7d3514cdae3f8...` (all unchanged from base).
- Histories SHA256: `937968622d772ea2...`; check SHA256: `e5caf3e7ba08d865...`.

## Mutation evidence

Five mutants against the production runtime copy (each run of the identical
history suite, ~10–16 s, then reverted; the final clean rerun passed):

| Mutant | Detection |
| --- | --- |
| M1: verify-only path reruns migration (`run()` already-active branch) | rotation history event-stream mismatch; unexpected `migrate` phase; zero-migration oracle fires |
| M2: failure count cap removed (`failed()`) | cap pin `failures: 17 != 16` and exact wedge delay sequence fire |
| M3: `record_healthy` retains backoff (`failures`/`retryAt` not cleared) | post-recovery `failures: 16 != 0` oracle mismatch |
| M4: handoff keyed by bundle name instead of descriptor digest (`stage()`) | activation falls back to re-resolution and publishes the concurrently mutated document: "publication must equal staged handoff bytes" |
| M5: compatibility refusal removed (`preflight`) | rotated candidate activates: `exit 0 != model 1` |

No survivors. Each detection fired from the operation-log/bookkeeping oracles
without reference to the mutated implementation.

## Defect verdicts

- (d) "candidate refuses coordinated_secret_change forever" — verified behavior,
  now generated evidence.
- (d) verify-only recovery and deterministic 16/900-second backoff cap —
  verified; retained `failedPhase` after recovery is intentional evidence
  preservation and is pinned as such.
- (d) stale window after manual rotation — verified current behavior (no
  detection before the persisted retry time; bounded at fifteen minutes at the
  cap) and now documented in the NixOS runbook and the operations chapter. A
  shorter stale window would be a new decision and is not pursued.
- (d) recipient-only stage→resolve→descriptor handoff — verified end-to-end,
  including the concurrent-delivery race.
- (d) config/custody wedge label — **documented boundary**: the discovery
  anticipated `stage_failed`; the actual durable record is failure
  `operation_failed` with `failedPhase` `stage`, because resolver errors are
  `ValueError`s crossing the generic `main()` handler rather than the fixed
  `UpdateError` reason-code path. The operator-side custody tool does refuse
  the last-host-removal manifest shape (`Invalid document inventory; ...`,
  cli.py policy), so the wedge requires mixed custody/config edits as scoped.
  The current label is pinned by the histories and documented; renaming it to a
  dedicated reason code is a user-delegated decision, out of scope.

## Remaining gaps

systemd unit execution, `/proc`-discovered serving environments, real Git/Nix
fetches and builds, migration execution, consumer stop/activate ordering, guest
survival and physical rollout are outside these seams; the existing
`auto-update` machine check and the historical native rotation reviews retain
their scopes. No Inception validation. The `045a` restic/recipient items are a
sibling improvement and untouched here.
