# Terminald shared ring capacity histories

## Scope and architecture impact

Baseline `52cd07f1`. Reviewed ADR-0082, root/native/package contracts and actual
session admission, ring growth, pump and retirement code. Production behavior,
protocol, authentication, deployment and accepted rationale remain unchanged.
The new test module is compiled only under `cfg(test)`. ADR-0082 remains accepted
and partial; this evidence covers local session admission and retirement.

## Discovery and oracle

The existing concurrent reservation example checks an abstract eight-unit atomic
counter. It does not establish that real PTY creation and asynchronous retirement
respect the configured 64 MiB aggregate reservation. The new property exercises
production `Daemon.create`/`kill`, actual Linux PTYs and pumps, independently
retained session IDs and arithmetic capacity expectations.

Each draw includes fixed 1 MiB default and 8 MiB maximum-capacity families plus
one generated 2/4/8 MiB family. The session-count limit is above the memory limit.
After creating all but one reservation, three barrier-synchronized contenders
must yield exactly one success and two `ERR_LIMIT` refusals. The complete live
inventory and reservation counter must match the independent expectation.

One to three generated retirements, with generated survivor order, must release
exactly their reservations. Contending replacements admit only that number and
preserve every survivor. Final retirement requires no registered sessions and a
zero reservation counter. All contenders join before assertions. A cleanup guard
kills owned fixture sessions on early failure and waits for retirement.

Capacity is held at each family's initial value to isolate admission from dynamic
growth. A local admission refusal is not proof of authenticated guest authority.
The test does not infer physical isolation or full browser delivery.

## Verification

Contract format and declaration/ancestor discovery passed. Backfilled the
callee `create-shared-ring-reservation` contract for positive configured initial
capacity; fresh review traced control dispatch, create-once and fixture consumers
without finding a semantic blocker. Source review traces
the memory reservation before PTY spawn, rollback on failed spawn and release
by completed session retirement. The oracle does not invoke `reserve` directly
or calculate expectations from production counter values.

The sandboxed native check passed all 47 tests in 6.10 seconds and Clippy with
warnings as errors. Compilation succeeded for all targets with the pinned Rust
toolchain. Nix completed in 41 seconds, exit zero; archive
`1791031017747-3327908-0.jsonl`. Log:
`/tmp/kittens-terminald-budget-native.log`.
After the callee contract addition, the final native check passed all 47 tests in
6.13 seconds and Clippy with warnings as errors. Nix completed in 41 seconds, exit
zero; archive `1791031383685-3579421-0.jsonl`. Log:
`/tmp/kittens-terminald-budget-final-contract-native.log`.
The earlier handbook/static hooks and evaluated HLDD passed in 28 seconds, archive
`1791031272996-3456625-0.jsonl`; source/comment evidence updates require refreshed
review receipts. Marshall integration remains pending behind the active native
recovery suite.

An isolated local negative control replaces only create's aggregate limit with
`usize::MAX`, retaining the same test/helper source. Mutation-only patch SHA256:
`a9df2a4da576caf6ff11b6aa1a7fe03ddd9fca9f48b1a6f116c5eeb97e53951e`.
Run log: `/tmp/kittens-terminald-budget-mutant.log`. The intended final-slot
assertion failed with three successes instead of one. The counterexample shrank
to generated2MiB, one retirement and normal survivor order; failure occurs in
the fixed default1MiB witness before retirement. The other46tests passed.
Test phase179.74seconds, Nix214seconds, terminal exit one (builder101), archive
`1791031297572-3508954-0.jsonl`. No cleanup failure was reported; exit diagnostics
show owned sessions retiring. This proves sensitivity to the local quota
regression and is not a hosted mutation sweep.

Fresh source and documentation review found no blocker after correcting the
new catalog row to match its five-column header. Final reviewed repository hooks and evaluated HLDD passed in22seconds,
archive `1791031603616-3775530-0.jsonl`; log:
`/tmp/kittens-terminald-budget-final-reviewed-hooks.log`. The combined budget/neighbor native suite passed all48tests in5.94seconds
and Clippy with warnings as errors. Nix completed in40seconds, exit zero;
archive `1791032206546-18334-0.jsonl`. Log:
`/tmp/kittens-terminald-budget-neighbor-combined-native.log`.
Fresh combined source/documentation review found no blocker; both modules remain
under independent `cfg(test)` declarations with separate fixture daemons.
Combined handbook/reference/view/coverage checks and repository hooks passed,
with evaluated HLDD25seconds, archive `1791032486182-211198-0.jsonl`. Log:
`/tmp/kittens-terminald-budget-neighbor-combined-hldd.log`.
Marshall integrated gate and publication remain pending.

## Remaining gaps

Interleaved creation/retirement, child-exit/idle release, simultaneous dynamic
ring growth combined with neighboring viewer stalls, authenticated
vsock/Firecracker/browser composition, production memory-pressure acceptance,
escaped descendants, power loss and hosted Antithesis faults remain separate.
The native sandbox is not a NixOS machine integration test; that preferred
coverage must exercise real guest authority and accounting under load.

## Final main integration

Main67de1f74 was merged, preserving corrected native Lilly recovery and main
telemetry changes. These advances leave terminald runtime and this property
unchanged. The complete merged Marshall gate passed1451 checks (237 properties
and1214 tests), two exclusions, seed26636, in1666.1seconds. Forced Dialyzer
passed48.09seconds with zero errors or skips. Log:
`/tmp/kittens-terminald-a5b6-marshall.log`.

The a5b6c891 terminald check succeeded through cache reuse in7seconds, archive
`1791184669364-2936262-0.jsonl`; the authoritative executed combined48-test
result remains the earlier5.94-second run. Post-merge evaluated HLDD passed
29seconds, archive `1791184848551-3078514-0.jsonl`. Reference, options, views,
coverage, ADR and all static hooks passed. Fresh source/contract review found
no blocker and confirmed main boot-adoption scenarios were preserved.
Final recorded-receipt verification and commit hooks follow the67de1f74 merge.
