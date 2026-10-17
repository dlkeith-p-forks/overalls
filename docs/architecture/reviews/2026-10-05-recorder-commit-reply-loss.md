# Native recorder commit/reply loss design

## Scope and architecture impact

Baseline `b5c9c1339f7b12d914114e31288d9062e1effc40`. ADR-0136 requires durable
admission and settlement before acknowledgment, permanent identity, and gap
recovery after ambiguous communication. Production behavior and defaults remain
unchanged. A separate native fixture substitutes a test-only expression at the
production `authenticate → read_frame → Runtime.apply → write_frame` boundary.

The checkpoint stops the real recorder after an accepted production apply and
before its reply, preserving the kernel Unix peer identity and actual Store
persistence. Only the variant installs it, for the SDK instance. The ordinary
native check retains its production package. A proxy would authenticate a
different process and cannot establish this Client boundary.

## Generated property and witnesses

Admission and success/failure finish losses vary one/two recorder reopens.
Observe the exact recorder's kernel stopped state, real Client timeout and
private gap marker, then kill that recorder before its reply. The producer stays
alive at this cut. Lost admission must coexist with Client refusal and durable
pending state. Reopens retain its ID, producer, admission time and deadline;
actual whole-producer death settles one failure without duration. Lost finish
retains its committed outcome and duration exactly once. Further reopens preserve
terminal history and source identity; fresh Client work must recover.

Coverage metadata may advance through gaps and is excluded from equality
projections. Fixture-map duplicate refusal is not direct recorder-RPC refusal.
Gap-command acknowledgment loss, delayed ACK after timeout, collector visibility,
full application adapters, storage failure and physical power loss remain gaps.

## Current evidence

Source is present; native execution, composed driver typing, instrumented Rust
compiler/Clippy verification, mutation sensitivity and governance remain pending.
Pinned Ruff formatting and lint passed in
`/tmp/kittens-recorder-commit-reply-static.log`; they prove no Rust/native behavior.
The Rust expression compiles inside the substituted production module, not as a
standalone module. Repository/Nix contracts, Client/RPC and production recorder
persistence/authentication boundaries were reviewed. No runtime acceptance is
claimed. ADR-0136 remains partial.

## First build failure

Driver build exited1 after52seconds, archive `1791208072409-3306514-0.jsonl`,
log `/tmp/kittens-recorder-commit-reply-driver.log`. The instrumented production
Rust package compiled and its ordinary tests ran, but its added Clippy command
failed because the build environment had no `cargo-clippy`. Composed driver and
native execution were not reached. Add pinned `pkgs.clippy` explicitly to the
fixture's build inputs; rerun required. This is fixture tooling failure, not an
accounting counterexample or completed typing gate.

## Instrumented source and composed-driver verification

The refined driver build passed, exit0,82seconds, archive
`1791208513368-3475822-0.jsonl`, log
`/tmp/kittens-recorder-commit-reply-driver2.log`. The substituted production
Rust package compiled, passed40library tests and3recorder-binary tests, and
all-target Clippy with warnings as errors completed in11.22seconds. Composed
driver lint and type checks passed. No native history ran in a driver build.

Subsequent source review strengthened exact duration sum and eight-bucket checks:
unknown-duration producer loss preserves them; committed finish and fresh work
each add exactly the fixture's100microsecond sample in bucket0. Final composed
typing for those additions and native execution remain pending. Latency input
boundaries beyond this fixed fixture duration remain separate.

The strengthened composed driver passed lint and typing in24seconds, exit0,
archive `1791208659531-3568282-0.jsonl`, log
`/tmp/kittens-recorder-commit-reply-driver3.log`. The unchanged instrumented Rust
package result was reused. Native execution and mutation sensitivity remain
pending; the next native run will use these exact sum/bucket assertions.

## Added delayed reply and gap acknowledgment histories

The admission/finish property now also resumes the same stopped recorder after
the real Client timed out and closed its stream. Production writes the actual
late reply; the test requires unchanged recorder PID, durable admission/terminal
conservation, reopens and fresh recovery. No fabricated or proxy reply is used.

A second generated history creates a real communication gap by stopping the
recorder. Its Client heartbeat attempts actual gap recovery after recorder start;
the checkpoint stops after durable gap commit but before acknowledgment. While
stopped, a real Client admission must refuse, with unchanged allocation sequence,
totals and identity. Killing or releasing that recorder, acknowledged recovery
and repeated reopens must preserve history before exactly one fresh admission.
The root control helper's read timeout is eight seconds in this variant only,
to observe the production Client's bounded recovery attempts; production RPC
and GenServer timeouts are unchanged. No direct recorder-RPC duplicate claim is
made. These additions need new composed typing and native execution; collector,
application adapter, storage and physical power boundaries remain open.

The expanded driver build passed, exit0,111seconds, archive
`1791209060382-3729599-0.jsonl`, log
`/tmp/kittens-recorder-commit-reply-driver4.log`. The variant's eight-second
root-helper compiled and the composed driver lint/type checks passed. The actual
instrumented recorder remained unchanged. A subsequent Nix guard requires the
exact corruption-subtest insertion boundary before composition; it prevents
silent omission after an upstream rename. Native execution remains pending.

## Reviewed pre-native governance

Applicable directory contracts now explicitly cover real commit/peer identity
and required history insertion. Contract format checks passed for the directory,
Python property and Rust expression; semantic review traced the production apply/
reply boundary and both generated callers. Insertion-guard evaluation passed in
`/tmp/kittens-recorder-commit-reply-insertion-check.log`. Reviewed HLDD receipts,
ADR links, generated options and domain/deployment views passed in
`/tmp/kittens-recorder-commit-reply-reviewed-hldd.log`.
All-file hooks, including Ruff and ty, passed, followed by evaluated HLDD in
20seconds, exit0, archive `1791209605764-4023383-0.jsonl`, log
`/tmp/kittens-recorder-commit-reply-pre-native-hooks.log`. These are static and
documentation results, not native history execution. Full Marshall, native
baseline, mutation sensitivity and final publication remain pending. Fresh-agent
review is unavailable due to the thread limit; self-review is the recorded scope.

## First native history failure and control readiness repair

Native build exited1 after58seconds, archive `1791209772348-4138487-0.jsonl`,
log `/tmp/kittens-recorder-commit-reply-native.log`. The first admission-loss
history reached its final fresh-work stage after terminal conservation/reopens.
It then started the killed SDK producer and read the retained running marker
before the new BEAM control listener was ready. The control helper returned no
reply; bare `.id` extraction failed with exit4. This is not a recorded passing
property or an established recorder accounting defect. Failed source patch:
`/tmp/kittens-recorder-commit-reply-native1-failed.patch`, SHA256
`258846b1b1de98a20cad9cce8f6468203817e9bf5163b6fe72a044dc5c80eaeb`.

Startup now requires an actual control hello before marker readiness and work.
Accepted admission IDs additionally validate the closed reply and expose closed
refusal reasons. A retained marker/socket alone is not new-incarnation proof.
Production Client and recorder semantics remain unchanged. Refined composed
typing and native rerun remain required.

The repaired driver build completed with exit0 after31seconds, archive
`1791210072828-127328-0.jsonl`, log
`/tmp/kittens-recorder-commit-reply-driver5.log`. This verifies driver construction
after the control-readiness repair; it does not establish a passing native
commit/reply-loss history. Native rerun remains pending and will follow the
currently running initial-submission fleet test.

## Repaired native baseline

The repaired native check completed exit0 in189seconds, archive
`1791211362195-890858-0.jsonl`, log
`/tmp/kittens-recorder-commit-reply-native2.log`. The actual recorder commit/reply
cut and authenticated BEAM producer ran through the composed native script.
This is the baseline execution for the new histories, before mutation validation;
mutation sensitivity, full Marshall gates, final reviewed receipts and publication
remain pending. The previous failed execution remains part of the evidence.

The archive records both new native subtests passing: durable commits with lost
replies52.61seconds, committed gaps without acknowledgments48.34seconds. These
results cover the fixed and generated histories in the native script, not a
hosted Antithesis run or production seven-day source acceptance.

Native durable_commit_reply_loss passed52.61seconds; durable_gap_ack_loss passed48.34seconds.

## Local mutation validation in progress

Baseline staged tree fingerprint `db750456e40ba7900c86d23288cf7c4955168619`
was reproduced in a detached disposable worktree before mutation. The first
mutant changes `Client.recover/1` to disregard a failed gap acknowledgment before
clearing the gap, a realistic missed result guard. Its private fixed marker
records only that the erroneous branch executed; a diagnostic probe reads it
without altering the generated workload or assertions. The mutation exists only
in `/home/ghuntley/src/kittens-antithesis-recorder-commit-reply-mutant-gap-ack`;
the real source tree retains the original `:ok` guard.

Native session74533 is live, log `/tmp/kittens-recorder-gap-ack-mutant-native.log`;
mutation patch `/tmp/kittens-recorder-gap-ack-mutant.patch`. No falsification is
credited before the exact target assertion and divergence evidence are inspected.
This applies local mutation attribution principles, not the hosted SDK catalog
sweep; that broader catalog remains unfinished.

The first mutant run exited1 after70seconds, archive
`1791211732702-1150086-0.jsonl`, before the new histories. Existing communication
gap coverage refused the erroneous clean marker at composed script line245.
No targeted falsification or collateral credit is assigned: the new target was
not reached and its divergence probe was not observed. The client mutation was
removed from the disposable fork.

The refined realistic mutant instead treats only `:gen_tcp.recv` timeout on a
gap RPC as success, mistaking a sent command for acknowledgment. Connection
failure remains unavailable and all other command/results remain unchanged.
Native session63032 is live, log
`/tmp/kittens-recorder-gap-timeout-mutant-native.log`, patch
`/tmp/kittens-recorder-gap-timeout-mutant.patch`. Original RPC and client guards
remain intact in the real source tree. Verdict remains pending.

The timeout mutant run exited1 after204seconds, archive
`1791211859739-1226649-0.jsonl`. Earlier communication-gap and commit/reply-loss
subtests passed; `durable_gap_ack_loss(fault='delay', reopens=2)` failed at
composed line633, exact stable identity/sequence/totals comparison after releasing
the late gap reply. The marker was not read at this target in that run, so
falsification attribution remains provisional. A diagnostic-only marker read
now precedes that unchanged assertion in the disposable fork. Session39248
reruns the full workload, log `/tmp/kittens-recorder-gap-timeout-mutant-native2.log`.
No production source or target assertion was changed.

The diagnostic rerun exited1 after146seconds, archive
`1791212146007-1397866-0.jsonl`, at the same delay/two-reopen target. The driver
captured the marker read's return value without printing it into the archive;
therefore marker attribution remains incomplete. A printed fixed diagnostic
replaces that read in the fork; session56711 reruns the unchanged full history,
log `/tmp/kittens-recorder-gap-timeout-mutant-native3.log`.

A separate disposable fork reproduces the same baseline fingerprint at
`/home/ghuntley/src/kittens-antithesis-recorder-commit-reply-mutant-retract-admit`.
Its realistic mutant incorrectly retracts a durable admission after an actual
reply write error, removing pending authority and incrementing exclusions while
preserving checkpoint shape. A private admission-ID witness records the wrong
branch. The lost/delayed admission history retains its original pending-authority
assertions. Pinned Rust formatting and diff checks passed; driver compilation
session77230 is live, log `/tmp/kittens-recorder-retract-admit-mutant-driver.log`.
Patch `/tmp/kittens-recorder-retract-admit-mutant.patch`; native verdict pending.
Neither mutation exists in the real source worktree.

Retraction-mutant driver build completed exit0 in88seconds, archive
`1791212300388-1493853-0.jsonl`. This captures the changed Rust reply-write branch
and unchanged assertion workload before its diagnostic output refinement; native
execution remains pending. The scoped
local mutation ledger (`antithesis/scratchbook/mutation-testing/native-recorder-commit-reply-loss.md` at kittens revision `9fe1e493`, repository deleted)
records outstanding verdicts and all prior executions without claiming the
broader hosted sweep is complete.

The printed timeout-mutant rerun exited1 after156seconds, archive
`1791212345552-1524966-0.jsonl`. The native history prints `gap_ack_ignored`
before the unchanged delayed/two-reopen stable-accounting assertion fails after
reply release. Local `durable_gap_ack_loss` falsification is credited at the
recorded baseline fingerprint; no unrelated property is credited. The admission
retraction mutant now runs natively as session73013, log
`/tmp/kittens-recorder-retract-admit-mutant-native.log`; its verdict remains pending.

Retraction native execution exited1 after81seconds, archive
`1791212532083-1659473-0.jsonl`. The native witness names retracted admission22
immediately before `durable_commit_reply_loss` fails its unchanged pending-ID22,
nextID23 assertion. Local falsification is credited for this second scoped
property. Final mutation patches and SHA256 identities are retained in the local
ledger; real client and recorder source have no diff against main. Both native
mutation targets are falsified. Full Marshall, all-file/evaluated HLDD gates and
disposable-fork cleanup remain required before publication.

Both disposable mutant worktrees were removed after terminal executions and
archival patch capture. Final source/contract review confirms the SDK-only fault
variant retains production authentication, accounting, bounds and defaults;
fixed/generated histories observe real kernel stop/death, refusal/gap, durable
identity/accounting and acknowledged recovery. Fixture duplicate-control refusal
remains distinct from direct recorder duplicate-RPC refusal. ADR-0136's accepted
decision and partial status are unchanged. No production-domain/topology or
runtime permission change is introduced; archived mutation patches are inert
evidence. Remaining broad source/collector, overload/storage and hosted gaps are
retained. Full Marshall and final evaluated/documentation gates remain pending.

## Final component verification

The full pinned Marshall `mix precommit` completed exit 0. It passed 1,452 checks
(238 properties and 1,214 tests), with two exclusions, in 1,789.5 seconds.
Forced Dialyzer passed in 45.6 seconds with zero errors, skips or unnecessary
skips after the independent copied PLT was rebuilt. Log:
`/tmp/kittens-recorder-commit-reply-marshall-precommit.log`. The source tree
remained frozen throughout this gate. Caches supplied no verification credit.

All-file hooks and evaluated HLDD already passed on the reviewed draft before
the component gate; evaluated archive `1791213001217-1914245-0.jsonl`, 30 seconds.
The final evidence-only report update requires a fresh governance receipt and
static/evaluated checks before commit. Native baseline and both targeted local
mutants remain scoped evidence; no hosted sweep, per-source collector interruption,
overload or storage acceptance is claimed. ADR-0136 remains accepted and partial.
