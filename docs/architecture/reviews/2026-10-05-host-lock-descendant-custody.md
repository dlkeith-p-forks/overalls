# Host-lock descendant custody candidate review

## Scope and architecture impact

Base3a8748b2. Adds a local Linux property and repairs descendant retirement for
existing mutation custody under ADR-0015 and ADR-0017. Review read root/Lilly
and host-lock contracts, execute/serve_child/terminate, the existing direct-child
caller-EOF fixture and protocol caller sequencing. Self-review only.

## Source-backed candidate, not yet reproduced

serve_child reaps its direct child with try_wait before signaling its process
group, then sends a result without descendant retirement proof. terminate waits
only the direct child. An inherited lock can still protect external helpers,
but the existing serving helper can accept another command after its reply.
The source note excludes live utility descendants after their parent returns.
This needs an actual process counterexample before production changes.

## New property awaiting execution

`escaped_utility_writers_withhold_reply_and_successor_work` uses fixed1/3 plus
generated1/2/3 descendants. Positive PID publication and proc group/session/state
witnesses independently confirm direct retirement and escaped writer liveness.
A separate open-file-description flock must refuse admission while the helper's
result is withheld. Explicit writer death then requires reaping before exact
success, same-helper successor execution and external lock after orderly exit.
The test process adopts orphans solely for fixture cleanup on a failing original
helper; no all-child wait in the oracle is used as SUT completion evidence.
No payload, credentials or actual enrolled-host operations are involved.

Native baseline, mutation, full component and publication gates are pending.
No confirmed bug or passing scenario is claimed. PID-reuse, same-group threads,
EOF/deadline/overflow and physical ZFS/VM composition need separate coverage.
No architectural decision or inherited deadline is changed by this draft.

## First native baseline

Targeted native baseline exited1, archive `1791223904445-747886-0.jsonl`, log
`/tmp/kittens-host-lock-descendant-baseline1.log`. The property failed0.07seconds
on count1: its reply-channel observation occurred while the independently
witnessed escaped descendant remained live. This first oracle did not distinguish
reply bytes from EOF/other channel errors; refinement now retries EINTR and
reports closed byte-count/status or error-kind witnesses separately. It also
requires an independent exact inherited-lock device/inode descriptor witness.
Production remains unchanged. A refined baseline is required before repair.
Failed source patch retained at `/tmp/kittens-host-lock-descendant-baseline1-failed.patch`.

## Refined baseline and repair draft

Refined baseline failed0.07seconds on count1, archive
`1791224373241-1048950-0.jsonl`: bytes1/status0 arrived while the independently
witnessed escaped descendant remained live and retained the exact inherited
lock device/inode descriptor. EINTR and EOF are now separate observations.
This confirms premature success, not merely a channel error.
Failed source patch retained at `/tmp/kittens-host-lock-descendant-baseline2-failed.patch`.

The repair draft makes the helper a subreaper before spawn, polls leaders with
waitid NOWAIT, signals while their PID identity remains pinned, and reaps all
adopted groups/sessions before replying. Unknown wait errors become fatal rather
than confirmed results. PID conversion is checked. Existing status classes,
trusted argv, inherited stable lock and blocking cleanup policy remain intact;
no new deadline is added. Escaped children are not automatically group-killed,
so completion remains withheld until actual descendant death. Full native
verification and consumer/final gates remain pending. ADR-0015/0017 retain their
custody requirements; native cgroup/storage and failure-path coverage remain open.

## Recorded repaired native package

Repaired full native package passed exit0,92seconds, archive
`1791224597697-1187032-0.jsonl`, log
`/tmp/kittens-host-lock-descendant-repair-package3.log`. Three library checks
and13integration checks passed, six executable fixtures ignored; integration
1.75seconds. Rustfmt and all-target Clippy passed. The strengthened property
observed inherited lock identity, withheld success during actual descendant
liveness, complete reaping and same-helper/external successor admission.
Fixed counts1/3 and generated draws ran; no artificial shutdown deadline was
introduced. Targeted selector mutation, full Lilly and final gates remain pending.
Caller-failure escaped histories and physical storage/cgroup scope remain open.

## Targeted mutation result

The process-group-only reaping mutant retained subreaper setup and NOWAIT leader
polling, changing only `wait(EMPTY)` to `waitpid(None)`. Native package exited1
after91seconds, archive `1791225462728-1377077-0.jsonl`. The targeted property
failed0.06seconds on count1 with bytes1/status0 before descendant death, directly
attributing the failure to premature confirmation. Patch SHA256 is
`0f3fcae7003e584dc6cdb0a543e2a47650d56166fd213d5b19ccdc932f86e75a`.
Fork source/tests were restored and compared byte-for-byte, then retained at
`/tmp/kittens-host-lock-selector-restored-cqv6b1dp`. No mutation remains in the
working source. This is local native evidence, not a hosted Antithesis result.
Full Lilly, final publication gates and escaped caller-failure histories remain
pending. Architecture impact remains implementation of existing ADR-0015/0017
custody; no replacement decision or cleanup deadline is introduced.

## Escaped failure histories added

The separate failure property now drives caller EOF, five-second command deadline
and output overflow against a live direct utility with independently witnessed
escaped descendants. Fixed1/3 and generated1/2/3 counts cover every trigger.
Exact fatal exit or empty status2/3 follows complete reaping; same-helper marker
and external flock independently establish successor admission. It preserves
the production cleanup policy and adds no production change. Native execution
and targeted failure-property mutation remain pending. The sole TooSlow health
exemption reflects three real five-second histories per generated case; deadlines
and assertions remain intact. Rustfmt and contract syntax/discovery passed,
but those structural results do not establish runtime correctness. Self-review
and native process scope remain explicit limitations.

## Recorded escaped failure package

The expanded full native package passed exit0 in108seconds, archive
`1791227940300-3071556-0.jsonl`, log
`/tmp/kittens-host-lock-escaped-failures-package4.log`. Three library checks
and14integration checks passed, seven executable fixtures ignored; integration
35.07seconds. Both completion and failure custody properties passed. Rustfmt
and all-target locked/offline Clippy passed. Every case includes caller EOF,
actual five-second deadline and output overflow with fixed counts1/3 plus a
draw from1/2/3; no claim that every generated count was selected.
Exact original outcomes, complete reaping and successor admission were observed.
Only TooSlow input-speed accounting is suppressed for the fixed production
deadlines. Targeted failure-property mutation, full consumer/publication gates,
newer-main integration and physical storage/cgroup/hosted scope remain pending.

## Recorded failure-property mutation

The process-group-only selector mutant failed exit1 in104seconds, archive
`1791229360752-4001029-0.jsonl`. The selected failure property failed0.06seconds
at protocol.rs:399: CallerEof,count1, helper retired while an independently
witnessed escaped descendant remained live. Twenty other tests were filtered
out. Only that targeted EOF violation is credited; deadline/overflow collateral
is not established. Source/test were restored byte-for-byte and the inert fork
retained. The local mutation ledger records the identical selector patch.
This verifies sensitivity within existing ADR-0015 cleanup custody, without
new cleanup deadlines or automatic escaped-session killing. Consumer/type,
publication, newer-main and physical/hosted acceptance remain open. Self-review.

## Current integration preflight

The owned native source/test diff passes `git apply --check` against the
origin98aff42a-merged control worktree. Temporary patch
`/tmp/kittens-host-lock-custody-integration.patch` has SHA256
`a61c9f250f854fc2ab039deb7794b8f067ef58f44e5540122cde2ed9162cb588`.
No native source was applied during the merged Marshall gate. This establishes
patch compatibility only; exact-helper-PATH Lilly execution, final documentation
receipts and publication still require verification. Native/storage/cgroup and
hosted gaps retain their recorded scope.

The native lib.rs and protocol.rs files were compared byte-for-byte with the
passing package's archived input `/nix/store/nm5bvj378n3h9qa89b45ki55f8gagm7n-source`.
The executable exists at
`/nix/store/0mha82fbkzfn349p0kfk61gbfxg6pfh7-lilly-host-lock-0.1.0/bin/lilly-host-lock`.
Lilly resolves exactly `lilly-host-lock` from PATH. This identifies the queued
consumer gate's helper; no consumer execution is credited from its existence.

Final source review traced execute's subreaper setup, checked child PID,
NOWAIT exit observation and terminate's signal/direct-wait/all-child-wait order.
Interrupted adopted-child waits retry; ECHILD is the completion witness, and
other wait errors return Fatal rather than a successful command result.
The inode remains owned by the helper during that drain. This agrees with
utility-descendants-retire-before-reply for the inspected paths and does not
establish physical storage recovery or a bound on an escaped child's lifetime.

## Integration into origin b6496b73 tree

The owned native source/test patch was applied to the origin-integrated control
and mail worktree. Both source and integration test files compare byte-for-byte
with the previously passing package's native-source archive. The initial
comparison incorrectly treated that archive as a repository root; the corrected
comparison uses its src/ and tests/ directories and passed. This is source
identity evidence, not a newly executed native build or consumer gate. Exact
verified helper binaries exist; full Lilly with those helpers, current handbook
receipts, evaluated publication and latest-source component checks remain open.

Full origin-integrated Lilly tests passed506checks (95properties,411tests),
seed712576,130.8seconds with this exact verified helper first on PATH alongside
the other custody helper. Forced Dialyzer remains live, so this is not yet a
passing full precommit claim. Complete native project comparison also passes
after excluding target and .gitignore, preserving exact Cargo/contract/source/
test identity with the archived cleanSource input. Current receipts, evaluated
publication, other consumers and physical/hosted scope remain open.

## Completed origin-integrated Lilly gate

Full MIX_ENV=test mix precommit completed exit0 with the exact verified native
helpers first on PATH. Tests:506checks (95properties,411tests),seed712576,
130.8seconds. Forced Dialyzer:15.06seconds,zero errors,skips or unnecessary
skips; PLT rebuild79.18seconds. Log
`/tmp/kittens-mail-native-origin-integrated-lilly-precommit2.log`.
The earlier pending statements describe their checkpoints. Other consumers,
current handbook receipts, evaluated publication and physical/hosted acceptance
remain open. This component gate does not establish native fleet isolation.
