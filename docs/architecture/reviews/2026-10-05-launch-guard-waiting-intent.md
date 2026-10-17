# Launch-guard waiting intent review

## Scope and architecture impact

Base3a8748b2; verification-only change. ADR-0017 retains generation custody and
native intent fences. Reviewed root/Lilly/native contracts, guard CLI/current/
acquire_fd/run and current deterministic shared-lock test. No production source,
wire schema, ownership or deadline changes. Self-review only.

## Coverage gap and property

Existing frame/refusal properties and deterministic lock-across-exec checks do
not change a valid intent while the guard waits behind a coordinator. A premature
intent read can therefore validate the old generation and execute after revocation.
No implementation defect is claimed: current run acquires shared custody first.

`waiting_guard_refuses_revoked_intent_after_exclusive_release` requires an
independent kernel blocked-FLOCK record for the exact guard PID/lock inode before
changing intent. Nine fixed variants per draw cover stopped, invalid state,
foreign placement, newer epoch/generation, short payload, unsafe permissions,
hardlinked payload and unchanged control. Generated cases add variant and
counter boundaries1/ordinary/signed-max-minus-one. The target marker independently
witnesses exec; exact stale75/custody74 refusals never create it. The unchanged
control must execute. A subsequent exclusive flock checks custody retirement.
Owned-child guards kill/reap fixtures on assertion failure.

Native baseline, targeted ordering mutation, component and publication gates are
pending. Local locking cannot establish native journal/systemd/Firecracker
composition, cgroup fencing or packaged daemon recovery. Accepted contracts and
ADR statuses remain unchanged; broader source/research review remains active.

## Recorded native baseline

Full native package passed exit0,99seconds, archive
`1791224011241-817796-0.jsonl`, log
`/tmp/overalls-launch-guard-waiting-intent-package1.log`. Three library properties
and six integration checks passed; two executable fixtures were ignored.
Integration completed2.33seconds. Rustfmt and all-target Clippy passed.
All nine fixed post-wait variants and the unchanged exec control ran in each
case; generated boundary selections are not claimed exhaustive. The observed
kernel barrier worked in the actual Nix sandbox. Ordering mutation and final
gates remain pending; no systemd/Firecracker acceptance is inferred.

## Ordering mutation falsification

Moving only the intent read before shared acquisition was falsified by the
unchanged property: the first Stopped case returned0 instead of stale75 after
the independently observed lock wait and coordinator update. Targeted property
failed14.68seconds; package exit1,100seconds, archive
`1791224482099-1115709-0.jsonl`, log
`/tmp/overalls-launch-guard-prelock-intent-mutant.log`. Patch SHA256
`9a2f98905dc38ef1f6fa1aa384a8116c6ae69e4729c474eeb936864208fba533`.
This is the predicted stale pre-lock-read failure; later variants are not credited.
Source/tests were restored byte-for-byte and the fork retained at
`/tmp/overalls-launch-prelock-intent-restored-vcc97d6f`. User tree carries no
mutation. Final handbook receipts/hooks and publication remain pending.

## Recorded publication and verified export/audit integration

Reviewed handbook receipts, all-file hooks and evaluated HLDD passed; evaluated
check exited0 in28seconds, archive `1791224757598-1258479-0.jsonl`. Normal commit
hooks passed for2ae0cad5. Export failure and audit fairness integration brings
01779fe6 into this worktree. Native launch source/tests remain byte-identical to
the99-second package and ordering mutant workload. Export native source/tests
remain byte-identical to its126-second package. Elixir production/tests, shared
protocol and governance tooling match the verified505-check source tree; the
existing result is reused with that scope, not claimed as fresh combined execution.
The source-export review records119.9seconds,seed300233 and forced Dialyzer12.45seconds.
Merge audit rows retain both properties and89unique candidates. Architecture
impact remains verification of ADR-0017 custody and retained ADR-0037/0072 export
requirements. Final merge structural gates and newer-main integration remain
pending; no packaged VM/storage or hosted claim is added. Self-review only.

## Main29ad6228 integration checkpoint (2026-10-06)

Preserved source/tests are byte-identical to the waiting-intent tree0662d4f8.
The recorded native packages and mutants above retain their historical scope.
Fresh combined package/consumer gates, current handbook receipt review and
publication remain pending; no full merged execution is claimed.

### Fresh integrated package execution

Forced rebuild on main29ad6228 integration passed exit0,127seconds,archive
`1791249752091-3869524-0.jsonl`, log `/tmp/overalls-integrated-launch-guard-rebuild2.log`.
Three library properties and six integration checks passed; two executable
fixtures ignored. Waiting property passed; integration2.32seconds, rustfmt and
all-target Clippy passed. Package `/nix/store/44jmjfp7xcxf8j36fc5pj7pyxbl5dq9c-lilly-launch-guard-0.1.0`.
A preceding evaluation failed copying a stale whole-worktree test FIFO before
compilation. Using the pinned launcher Nixpkgs input with the absolute integrated
native package source preserved toolchain/source scope. Consumer, handbook and
publication gates remain pending; no systemd or native VM acceptance is inferred.
