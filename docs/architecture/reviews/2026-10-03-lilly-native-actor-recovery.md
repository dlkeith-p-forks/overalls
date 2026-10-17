# Native Lilly completed effect recovery

## Architecture impact

Verification of ADR-0017's existing attempt-before-effect, independent VMM
lifetime and stable outcome replay requirements. Production Actor, Executor,
Journal, Store, Driver and native helper behavior is unchanged. ADR-0004,
ADR-0016 and ADR-0031 retain their execution and storage boundaries. No new
architecture decision is introduced; implementation status remains partial.

## Native scenario and oracle

The `lilly-native-actor-recovery` NixOS check reuses the source-built Lilly,
verified guest image, systemd/cgroup and real mirrored ZFS fixture. A generated
generation and replay count select a fresh placement. Its real actor opens a
real protocol-v3 Store and journal and invokes the production Executor.

Before launch, a separate task holds the actual Driver placement lock. The
production Executor must return `{:retry, :execution_unavailable}` while the
typed and persisted journal contain the exact attempt and no outcome, the
actual unit is stopped and no launch marker exists. The native lock helper
must confirm release before completion testing proceeds. This proves the
Executor retry boundary; it does not independently assert that the actor has
already consumed that result and entered its deferred state.

The fixture executor wrapper delegates physical work unchanged. It waits only
after the production executor returns a running observation. The fixture then
suspends the actor, releases that result and requires normal task completion
and the matching successful result in the actor's mailbox. The attempt-only
journal must remain byte-identical before and after the actor's `:kill` exit.

The replacement uses the production Executor directly. Recovery must record
running for the original epoch/generation with sequence one. Repeated actor
replacement must replay the exact unacknowledged outcome before reconciliation
and preserve it afterwards. Actual cgroup process PIDs, kernel start times and
executable device/inode identity must remain equal, as must the real driver's
launch-attempt marker. The shared snapshot helper independently requires a
Firecracker process. Unit activity alone cannot satisfy survival.

After the fixture BEAM exits, the Python driver verifies actual guest console
write/read and unchanged VMM identity, then production deletion and absence of
the dataset and guest disk. Generated inputs vary the generation and one to
three recovered replays; fixed witnesses retain first and repeated replay.

## Execution

The completion-window fixture passed the source-built NixOS check, exit 0,
in 779 seconds; archive `1791011037338-535511-0.jsonl`, log
`/tmp/overalls-native-actor-recovery-networked.log`. The native script took
732.10 seconds and the four histories took 715.88 seconds. Executed
(generation, replay) pairs were `(1, 1)`, `(9223372036854775805, 3)`, `(1, 1)`
and `(2, 2)`. Each included subsequent real guest write/read and native deletion.
This pass predates the placement-lock contention extension.

The combined contention/completion native check passed, exit 0, in 671 seconds;
archive `1791011957778-1096679-0.jsonl`, log
`/tmp/overalls-native-actor-recovery-combined.log`. The native script took
605.88 seconds and all four histories took 584.93 seconds. The same four
(generation, replay) pairs passed real contention, completion recovery, guest
write/read and native deletion. Composed driver lint/type checks passed within
the source-built Nix check. Existing dormant CloneMatrix module diagnostics do
not establish runtime failures in this scenario.

The combined fixture modules and existing Lilly/protocol consumer program were
compiled with debug information and freshly analyzed against the existing
pinned test dependency PLT. Dialyzer returned zero warnings, exit 0; log
`/tmp/overalls-native-actor-dialyzer-combined.log`. This analyzes the changed fixture
but does not repeat PLT validation or the component precommit suite. An initial
raw Dialyzer invocation lacked Elixir's debug-info backend and failed before
analysis; invoking it within the pinned Mix runtime corrected the tool setup.
Fresh evidence/source/contract review found no blocker. All-file Ruff, formatting,
ty, logging and handbook review passed; ADR structure (136 decisions) and
generated options/coverage/views passed. Evaluated Nix handbook validation
passed, exit 0, in 32 seconds; archive `1791012868668-1646033-0.jsonl`.
Its first invocation omitted this then-untracked execution report from the Nix
source, so its recorded-evidence check refused. Staging the reviewed report
supplied the intended source input; no validation rule was changed. Repository
contract discovery/parser checks also passed (117 CONTRACTS, 2335 native notes,
187 parsed and 2490 maintained source files); these are structural checks,
separate from the source and native oracle reviews.

The first native draft failed before any guest launch with
`unsafe_state_directory`: the fixture had not created its private parent
directory. Archive `1791009674582-4066208-0.jsonl` retains that failure.
The parent directory and Store ownership lock were corrected. Fresh review also
removed a second unlocked Journal open and strengthened outcome/marker binding
and replay bounds. These are fixture repairs, not production defect evidence.
The next draft reached native disk/jail materialization but failed before launch
because its new action omitted the ordinary fixture's `Lilly.Network.setup/1`
prerequisite. Archive `1791010447965-320490-0.jsonl` retains that failure. The
action now performs the same real network setup as the established start action;
terminal non-running executor results fail the barrier immediately; transient
retry results retain their production classification unchanged.

## Remaining gaps

This isolates the native completion-before-recording window. It does not run
Marshall command exchange, authenticated actor activation, a full Lilly daemon
crash at that exact boundary, host power loss or hosted Antithesis faults.
Attempt-marker-before-systemd-submission and start/restart completion histories
retain separate test requirements. No physical isolation or availability claim
follows from a single disposable native test host.
