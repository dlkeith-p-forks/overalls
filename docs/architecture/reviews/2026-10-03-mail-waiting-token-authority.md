# Mail authority changes while delivery waits

## Scope and architecture

Verification extension under ADR-0024 and ADR-0040. Production delivery and
stored-token authority are unchanged. Baseline `ecfb2ba3` integrates the committed
mail helpers and their passing full precommit. The waiting properties extend those
helpers without changing production delivery, token or deployment decisions.

## Properties and value menu

Two separate generated properties remove or expire the exact stored magic-link
token while another worker is waiting on the outbox row. Three independently
started Marshall BEAMs use separate real PostgreSQL pools; the coordinator is not
a peer. The workload rotates the holder, waiter and observer and selects one,
two or three terminal replays. One is the smallest observed terminal refusal;
repeated replays check idempotence. These are direct Ash actions, not Oban's
eight-attempt scheduler or duplicate-job creation.

The first verified implicit-TLS attempt reaches complete DATA before its
acknowledgment is gated. The second peer must visibly wait on that peer's outbox
FOR UPDATE through pg_blocking_pids and distinct PostgreSQL application names.
The third independently sees committed pending state, changes stored token
authority and confirms absent/expired authority while the outbox's own deadline
is still in the future. Invalidation refuses an enclosing transaction so its
return is a committed write before SMTP release.

The gate releases a controlled 451 refusal, with a fixture receipt only after
successful SSL transmission. Closure and gate-timeout receipts are refused, and
the first action must finish within nine seconds of coordinator dispatch,
excluding the unchanged ten-second owner timeout as the cause. The first action must fail; the
waiting action must reread current token authority and commit expired with nil
payload. Exactly one connection and one complete DATA receipt are permitted.
Every peer must see erased terminal state and repeat refusal without another
connection. Independent full-table inventory checks exact fixture restoration.

## Contracts and diagnostics

Reviewed root, Marshall, test, Accounts, Mailer, committed cleanup and delivery
contracts. Token invalidation uses only the captured JTI and magic-link purpose,
with bound parameters and disabled query logging. Observations contain statuses,
time-validity booleans and identity digests; SMTP MIME/token bytes do not enter
coordinator messages. Fixtures remain supervised, and peer retirement precedes
exact-ID cleanup with separate reporting of body and teardown failures.

The concurrent SMTP gate gains an optional first reply; its default remains
250. Existing successful contention and crash/retry histories must be rerun
alongside these properties to verify that helper change.

Fresh review identified that a generic first-action error alone could let an
owner timeout masquerade as the controlled rejection. Reply-transmission,
premature-closure refusal and pre-deadline completion now distinguish that
schedule. The serialized combined execution below verifies those witnesses.

## Execution

Source is written and formatted. The pinned-runtime test-environment compiler
passed with warnings treated as errors. Forced test-environment Dialyzer passed
in 46.58 seconds with zero errors, skipped warnings or unnecessary skips, after
169.45 seconds of PLT reconciliation. The test module also compiled without
executing tests; that separate wrapper emitted deprecation warnings for setting
the compiler's warnings-as-errors option programmatically. It is not runtime
evidence. Logs: `/tmp/kittens-mail-waiting-static-types.log` and
`/tmp/kittens-mail-waiting-test-compile.log`.

The combined focused file run passed all four properties in 80.8 seconds,
seed63342, with warnings treated as errors. It ran both committed-worker
properties and both waiting-token properties, checking default SMTP success/crash
behavior alongside explicit rejection. Log:
`/tmp/kittens-mail-waiting-focused-serialized.log`.

An earlier combined run passed three of four properties but failed peer startup
after exhausting the private PostgreSQL connection limit. It overlapped the
previous Mix process's retained connections during final Dialyzer; this was an
orchestration mistake, not passing evidence. That process exited before the
serialized rerun. Full waiting-extension precommit passed with terminal exit
zero: 1,434 checks (233 properties and 1,201 tests), two exclusions, seed559168,
in 1,724.4 seconds. Its final forced Dialyzer passed in 60.57 seconds with zero
errors, skipped warnings or unnecessary skips. Log:
`/tmp/kittens-mail-waiting-precommit-installed.log`.

The first wrapper passed all repository hooks and evaluated Nix HLDD in 19
seconds (archive `1791028044599-1479518-0.jsonl`) but stopped before runtime
because the pinned contract checker was not installed in this worktree.
Installing it from the existing package lock supplied that prerequisite; no
gate was bypassed. The passing full gate above is the subsequent run.

An isolated local negative control removed only the stored-token lookup from
delivery, retaining JWT signature/claim validation. Both properties failed at
the intended waiter-result assertion: actual `{:ok, :delivered}` versus required
`{:ok, :expired}`. Each shrank to one replay and ordering `[0, 1, 2]`, with zero
successful draws. The run completed in 34.0 seconds, seed63342, exit two; no
fixture-inventory cleanup failure was reported. Log:
`/tmp/kittens-mail-waiting-mutant.log`. Mutation patch SHA256:
`b27230914221c3cb1b540e6e5fd58642e3e78830f15c0f17608b26d59185269f`.
The tests/helpers matched the passing local baseline. The mutation exists only
in the isolated disposable fork. This establishes sensitivity to this local
stored-authority regression; it is not a hosted mutation sweep.

Main was merged at `f2e748a1`, preserving the private SLO delivery changes and
both review entries. Historical full-suite execution above predates this merge;
merged governance and generated evidence require fresh validation.

## Remaining gaps

Removing the stored row tests absent authority, not the complete sign-in action
or session issuance that normally consumes it. Natural expiry at the precise
deadline edge, token changes after a worker's validation but before DATA,
Oban scheduling, host relay, real inbox/provider, native and hosted faults remain
separate. The first message was already submitted before invalidation; the
property governs the waiting worker's subsequent refusal.
