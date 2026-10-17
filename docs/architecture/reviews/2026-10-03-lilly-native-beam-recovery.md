# Native completed effect across worker BEAM loss

## Architecture and scope

Baseline `ecfb2ba343d56ba3bdc28b5903a3455f0a397984`. Verification extension
under ADR-0017, carrying ADR-0004, ADR-0016 and ADR-0031. Production Actor,
Executor, Store, Journal, Driver and host ownership behavior is unchanged.
The existing native actor-only completion and contention histories remain.

This extension kills the entire source-built release-eval worker BEAM. The
storage fixture disables the production Lilly systemd daemon and uses isolated
API workers; this does not establish a production daemon crash or authenticated
Marshall exchange. The distinction is part of the test's scope.

## Schedule and oracles

The production Executor performs the actual Firecracker effect. The wrapper
holds its completed result, the coordinator suspends the actor, releases the
executor task and witnesses normal task completion and the exact running result
in the actor mailbox. The typed journal and persisted journal must remain
attempt-only. The real launch marker binds placement, epoch and generation, and
the independent process helper requires actual Firecracker identity.

Before abrupt `erlang:halt(137)`, a private fixture witness records the journal
digest, launch marker and native process identity. Python requires exit status
137, then invokes fresh source-built workers to reopen the Store and native
locks. First recovery requires the journal digest to match the pre-crash bytes.
Recovery records running with sequence one and the original command identity.
Later independent worker processes compare a digest of the complete typed
outcome, including its stable ID. Every recovery requires identical native PID,
kernel start time, executable device/inode and launch marker. No acknowledgment
is sent; local actor replacement additionally checks retained outcome replay.

Each fresh worker exit is followed by actual guest console write/read and
unchanged process identity. Production deletion must remove the real dataset
and guest disk. Inputs use the established generation menu (1, 2 and the largest
fixture generation permitting subsequent deletion) and one to three fresh
worker reopens. Fixed witnesses retain the smallest case and repeated reopen at
the large generation; one generated example complements them.

## Contracts and review

Reviewed root, Nix, Nix test and Lilly/control contracts, with production Actor,
Executor, Journal, Store, Lock and PrivateFiles callsites. Store is reopened only
under the native lock. Private fixture witnesses contain hashes, fixed physical
identity and launch metadata, without guest bytes or credentials. Host operations
continue through fixed fixture entry points and validated generated integers.
Fresh read-only source/contract review found no concrete blocker; this is not
runtime or type evidence.

## Execution

Formatting passed. The changed Elixir fixture modules compiled in the pinned
test runtime and Dialyzer returned zero warnings, terminal exit zero, against
the parent's existing dependency PLT. This analyzes the fixture modules; it
does not repeat PLT validation or the full component gate. Log:
`/tmp/kittens-native-beam-types.log`.

The source-built NixOS native check passed with terminal exit zero in 1,037
seconds, archive `1791028366849-1610010-0.jsonl`. The complete machine script
finished in 985.17 seconds. Existing actor-only histories finished in 478.92
seconds; the new worker-BEAM histories finished in 487.12 seconds. New
(generation, independent worker reopen count) pairs were `(1, 1)`,
`(9223372036854775805, 3)` and `(1, 1)` at placements105–107. All required exit137,
fresh Store/lock reopens, identical Firecracker identity/launch marker, stable
outcome, actual guest write/read and final deletion. Composed driver lint/type
checks passed within this source-built NixOS check. Logs:
`/tmp/kittens-native-beam-format.log` and
`/tmp/kittens-native-beam-recovery.log`. The evaluated Nix HLDD gate separately
passed in 17 seconds, archive `1791028725728-1872211-0.jsonl`; that handbook
execution predates recording this machine result.

The parent actor-only combined contention/completion check passed in 671 seconds;
its exact scope and revision remain in the earlier native actor recovery review.
That execution does not include this process-wide extension.

The ordinary Lilly precommit reported one failing property among 475 checks:
the existing dirty-sender property counted all actors rather than only journals
with remaining events after partial acknowledgment. Seed267831, 69.4 seconds,
474 passes, terminal exit two. Its subsequent forced Dialyzer passed in 13.34
seconds with zero errors or skips; the gate remains failed. A separate
`antithesis-audit-roster-oracle` worktree corrects the pending-journal target and
adds the discovered boundary as a fixed witness. The correction is now integrated
at `52cd07f1`, after final Lilly precommit passed475 checks (85 properties and
390 tests), seed279043, in98.0 seconds and forced Dialyzer passed12.83 seconds
with zero errors or skips. Its standalone test-module analysis also passed
without warnings. These results apply to the corrected oracle; final merged
component Lilly gate for this extension passed475 checks (85 properties and
390 tests), seed147745, in79.1 seconds. Its forced Dialyzer passed12.18 seconds
with zero errors or skips. The wrapper then stopped before Marshall compilation
because that worktree had no dependency checkout. Pinned verified dependencies
and build cache were copied from the passing mail worktree; Marshall will be
rerun separately. Log: `/tmp/kittens-native-beam-final-merged-gates.log`. Log:
`/tmp/kittens-native-beam-lilly-precommit.log`.

Main was merged through `52cd07f1`, preserving private SLO delivery and committed
waiting-token verification. The first merged Marshall wrapper stopped at stale
HLDD receipts before compiling or running tests. Log:
`/tmp/kittens-native-beam-marshall-merged-precommit.log`. No failed prerequisite
is counted as a passing runtime gate.

## Updated main verification

The pre-merge Marshall gate passed 1,434 checks (233 properties and 1,201 tests),
with two exclusions, seed750658, in1,770.3 seconds. Forced Dialyzer passed49.91
seconds with zero errors or skips. Log:
`/tmp/kittens-native-beam-marshall-final-precommit.log`.

Origin/main was subsequently merged through `a5b6c891`. ADR-0140 changes the
actor task result to carry liveness evidence. The fixture now requires the
wrapped running result and the wrapper's absent optional watcher target in the
suspended actor mailbox. It still obtains physical process/marker evidence from
the real executor and independent native helpers. Earlier runtime results are
historical evidence for the pre-merge implementation; merged native and component
verification is pending. Log: `/tmp/kittens-native-beam-a5b6-native.log`.

The merged component gates passed: Lilly503 checks (92 properties and411 tests),
seed444218, in91.9 seconds; Marshall1451 checks (237 properties and1214 tests),
two exclusions, seed122646, in1379.6 seconds. Both forced Dialyzer gates passed
with zero errors or skips. Log: `/tmp/kittens-native-beam-a5b6-components.log`.
Static hooks including ruff, format and ty passed. Evaluated HLDD passed43seconds,
archive `1791184825751-3062895-0.jsonl`.

The first merged native rerun failed in500seconds, archive
`1791184638716-2915826-0.jsonl`, during replacement-actor cleanup. Source review
found that the isolated worker lacked ADR-0140's real execution View process:
running-result publication now calls that process. The fixture now starts and
owns the real View for each worker invocation, stops it on ordinary completion,
and retains whole-BEAM loss on the crash path. It publishes no connected runtime
or durable intent rows, so this setup grants no authenticated execution authority.
Kill diagnostics distinguish prior actor exit without disclosing exit payloads.
The corrected native rerun is pending:
`/tmp/kittens-native-beam-a5b6-view-native.log`.

## Remaining gaps

Production daemon supervision and fixed global host ownership, authenticated
activation and Marshall command exchange, interruption after attempt marker but
before systemd submission, native start/restart windows, host power loss,
multi-host isolation and hosted Antithesis faults remain separate requirements.
Worker BEAM loss cannot establish any of those boundaries by itself.

## Corrected integrated execution

The corrected merged native check passed with terminal exit zero in1,040 seconds
at the a5b6c891 integration with the real isolated View and wrapped result oracle.
Archive `1791188153386-972013-0.jsonl`; actor-only histories460.04seconds and
whole-worker histories506.95seconds. All required native identity, stable outcome,
guest write/read and deletion checks completed. Log:
`/tmp/kittens-native-beam-a5b6-view-native.log`.

Main subsequently advanced through7e2b20df with only telemetry freshness changes;
Lilly Actor/Executor, the protocol View and this fixture are unchanged by that
advance. The passing native record remains explicitly scoped to its a5b6c891
integration. Final receipts and evaluated handbook verification follow the merge.

Final fixture modules compiled in the pinned test runtime and standalone Dialyzer
passed0.90seconds with no warnings, terminal exit0. This reused the validated
Lilly dependency PLT and did not repeat PLT validation. The first direct CLI
invocation lacked Elixir debug-info code on its path and could not analyze;
the corrected invocation supplied that code path. Log:
`/tmp/kittens-native-beam-final-fixture-types2.log`.
