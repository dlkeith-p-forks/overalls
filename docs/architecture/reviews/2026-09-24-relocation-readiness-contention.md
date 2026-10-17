# Relocation readiness contention — 2026-09-24

## Scope and architecture impact

Reproduce a Porsche-created customer's relocation from Overalls to Dungarees,
correlate both hosts' logs, and fix destination readiness under ordinary
reconciliation contention. This preserves ADR-0092's physical relocation and
ADR-0115's scoped roster bootstrap. There is no protocol, persistence, access,
capacity or placement-authority change. Source reclamation still requires the
exact committed destination boot receipt.

## Production reproduction

Both hosts ran `ce450164` before the experiment. Background journal capture
started before creation and covered Porsche/Marshall on Overalls and Lilly,
transfer SSH, Audi private and Ziggy on both hosts. Porsche authenticated with
the existing registered key and a pinned management host key.

- `new --name relocation-check-0924`, request `relocation-check-0924-create`,
  created VM `2a9b217a-11e3-4281-b529-608d6e1473a4` at 13:32:49 UTC.
  Its provision outcome completed running at 13:33:01 on Overalls; the source
  VMM unit was physically running before relocation was requested.
- `relocate` with request `relocation-check-0924-move` accepted relocation
  `2d9d9850-73c6-4063-8e5b-f5cb707ab2dd` at 13:33:19. Baseline and final
  incremental receive completed; destination adoption completed at 13:34:24.
- Handoff committed at 13:35:00, retaining the same VM identity and moving from
  placement `f9d31cf6-64e0-45fc-81a8-0fb364226a77` to
  `e9593a8a-7668-4736-8f47-38140e27d097`, execution epoch 2, generation 3.
- Activation `50a295b8-974f-4b05-9fd8-6e20944a76ef` completed running at
  13:35:08.709. Lilly rejected its first readiness effect at 13:35:08.751 with
  `readiness_unconfirmed`, immediately before reconciliation reported adoption
  at 13:35:08.761. Marshall's unchanged 120-second deadline expired at
  13:37:08.840, leaving the move in `readiness_failed`.
- The confined VMM remained running. The guest's boot service statuses included
  sshd and multi-user. Isolated read-only probes verified host private services,
  every activation/workload binding, and real boot-bound guest readiness.
  Repeated probes also observed `execution_unavailable` during reconciliation.

Evidence is retained outside Git under the private operator directory
`~/.local/state/kittens/porsche-relocation-20260924-recheck/`. No direct database
lifecycle writes or production service restarts were used for reproduction.

## Findings and resolution

**High — readiness can starve on the placement lock.**
[Driver.ready_boot](../../../lilly/lib/lilly/vm/driver.ex) used a single
nonblocking lock attempt for both authority checks. The ordinary running actor
reconciles every second; relocation effects retry at fixed five-second intervals.
Repeated collisions can consume the entire readiness window while a healthy
guest remains running. The old
[ReadinessProbe](../../../lilly/lib/lilly/transfer/readiness_probe.ex) erased the
underlying lock error, leaving only `readiness_unconfirmed` in the effect log.

The driver now uses the existing native lock helper's bounded, jittered retry
for definite contention: at most two seconds per authority check, capped by the
original readiness deadline. It acquires and rechecks current ownership,
confinement, intent and boot identity on each side of the guest exchange. The
lock remains released during that exchange. Success after the original deadline
is rejected. Lock contention and guest timeout retain their closed reason atoms
through the existing deduplicated Events diagnostic.

## Validation

The same real Dungarees guest was probed in an isolated release process with its
placement lock deliberately held for 250 ms. The deployed driver returned
`execution_unavailable`; loading the changed driver into that isolated process
made the identical probe succeed. Five subsequent probes also succeeded. This
did not load code into or restart the serving Lilly process, publish readiness,
or modify the failed relocation receipt.

The [native regression](../../../nix/tests/machines/zfs-guest/readiness.exs)
adds a real lock holder, checks success with the same guest boot ID, rejects a
lock hold that exceeds the probe budget, and retains the existing stale-identity
and stopped-execution negative cases. The source-built `zfs-guest` driver ran
this focused fixture successfully in 73.6 seconds on nested KVM, including
confirmed fixture dataset deletion. The broader storage suite was stopped
before completion when verification was narrowed to this regression; it is not
claimed as a full-suite pass. The temporary focused driver passed Ruff format,
Ruff checks and ty with the Nix test-driver package supplied as an import path.

Lilly's final `mix precommit` passed: 406 checks (48 properties and 358 tests),
compiler, formatting, contracts, catalogued logging, and forced Dialyzer with
zero errors or unused skips. The effect diagnostic property now covers the
preserved readiness reasons and still rejects payload-bearing errors. The ADR
structure/link checker passed separately. Both production system closures built
successfully.

## Deployment and recovery

Fix `1e118a2defad296d824b9f29b64c210e1ec6efe4` was merged to main and pushed.
Both hosts activated it through the normal updater and reported it healthy.
The original source and `test` VMM units retained PIDs 3429998 and 3430572 on
Overalls; the reproduction VM retained PID 1725853 on Dungarees throughout
deployment. The later explicit recovery action restarted only that destination.

Porsche accepted `request retry relocation-check-0924-move` with stable request
ID `relocation-check-0924-retry`, retry identity
`bc0c5d4d-c5a3-49b6-823d-4c476f22af9b`. Its destination stop completed at
generation 4, followed by activation `ed9d9b03-c635-48fd-9b45-305ea840ac95`
at generation 5. Lilly logged the boot-bound readiness proof at 13:58:31.832,
Marshall recorded ready at 13:58:32.748, and the relocation completed at
13:58:37.450 UTC. Porsche's retry receipt reports succeeded, complete, inactive;
the machine projection reports running on Dungarees with no failure.

The source dataset is absent and both source reservation holds are false.
The destination keeps compute/disk holds and dataset GUID
`2055696440346263441`, unchanged from before the retry. Its new VMM is running.
The failed generation-3 readiness row still records the original timeout;
Porsche's original request preserves its failed snapshot while the new retry
receipt records recovery. No receipt was rewritten or database state fabricated.
The two original customer machines remain running at their recovered generations.

This establishes one real Porsche create/running/relocate reproduction and
authorized recovery across both hosts, plus the focused contention regression.
The reproduction machine remains available for inspection.

## Contract review and limits

Reviewed Driver's physical claim checks, the native lock handshake/deadline,
transfer command correlation, and diagnostic allowlist. Waiting does not create
authority, reset Marshall's deadline, release capacity, revive a failed receipt,
or bypass guest readiness. ADR-0092 remains partial for its existing unrelated
acceptance obligations. Guest user SSH login is outside this reproduction.
