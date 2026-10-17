# Transfer-stream adopted-child custody review

## Scope and architecture impact

Base9a71e12aef237d0ef474945d1b3bcecf94a616f6. ADR-0037 is superseded and
partial; its retained relocation custody requirements and ADR-0072's accepted,
partial single-dataset transfer remain applicable. The fix preserves trusted
argv, existing blocking cleanup, process-group signaling, NOWAIT leader custody,
stream ABI and status classes. It adds no new deadline, protocol or authority.
Self-review only. Component and publication gates remain pending.

## Finding and repair

Rustix1.1.5 `waitpid(None, …)` selects children in the calling process group.
A setsid descendant is adopted by the helper but falls outside that selector.
The original real helper reported success0 while an independently observed child
was still alive. Production `finish` now uses all-child `wait`; checked PID
conversions and wait uncertainty return the existing I/O failure class rather
than success. Both direct leaders remain unreaped until cleanup signaling.

Reviewed root, Lilly and native transfer CONTRACTS plus polling/finish/run and
fixture callers. Custody cannot be confirmed by leader completion alone.
The all-child wait remains blocking: escaping descendants are not automatically
killed by private-group signals, and uninterruptible I/O remains a separate gap.
This fixes premature confirmation; it does not establish bounded escape cleanup.

## Property and evidence

The new `escaped_stream_children_are_reaped_before_owner_exit` property tests
both producer/consumer escape roles, fixed1/3descendants plus two generated draws
from1/2/3. Both direct-side PIDs, their actual retirement, independent descendant
groups/sessions and liveness are observed. Helper completion must remain withheld
until guarded explicit child death; exact success and complete reaping follow.
Safe self-exec fixtures use Rustix setsid and private PID files. No real transfer
payloads or credentials appear in diagnostics.

Original producer-side baseline failed0.06seconds, helper success0/child alive;
package exit1,67seconds, archive `1791220728655-2864070-0.jsonl`.
Expanded two-role package passed exit0,95seconds, archive
`1791221894853-3668113-0.jsonl`: three library properties and eight integration
checks passed in1.01seconds, eight ignored executable fixtures; rustfmt/all-target
Clippy passed. Log `/tmp/overalls-transfer-stream-escaped-package3.log`.
Targeted selector reversion was falsified with unchanged property source in
0.07seconds: roleProducer/count1, helper success0 and escaped_alive=true.
The selected package exited1 in81seconds, archive
`1791222047033-3794061-0.jsonl`, log
`/tmp/overalls-transfer-stream-selector-mutant.log`. Patch SHA256
`4c2965ef0f5585ded30702ab2e0ceb14ed0caccb6ab0e24abbfa1707c6cec4db`.
The first failing producer case stops the mutant property; this is not a separately
observed consumer mutant counterexample. Both roles passed the unmutated baseline.
Temporary source/tests were restored and compared byte-for-byte, then retained
at `/tmp/overalls-transfer-selector-restored-xfmwjm5o`. No mutant is in the user tree.

## Remaining verification

Full Lilly, handbook/scenario reconciliation, ADR validation and publication
checks are pending. Local native completion evidence does not establish escaped
EOF/deadline/failure histories, automatic cgroup containment, actual ZFS,
authenticated SSH, physical transfer-slot release or hosted SDK exploration.
The broader research and source review remains incomplete.

## Escaped failure-path extension awaiting native verification

`escaped_stream_failure_retains_lock_until_actual_reaping` adds fixed producer/
consumer × callerEOF/deadline/sideFailure × counts1/3 plus generated combinations
from both sides, all three triggers and counts1/2/3. Escaped fixtures publish
independent PID/session/group witnesses before holding their direct side.
Caller EOF or the existing deadline kills both direct sides; explicit side
failure preserves exact producer5/consumer6 classification. Both direct PIDs
must retire while descendants remain live, helper completion remains withheld,
and a separate open-file-description nonblocking flock must refuse admission.
After explicit descendant death, every adopted PID must be absent, exact
trigger status4/2/5/6 must remain and the same contender must acquire the lock.
The deadline fixture uses5000ms; existing production and test deadlines are
unchanged. Formatting and contract syntax passed; native execution is pending.
This new extension has no recorded passing or mutation result yet.

The first extension package exited1 in140seconds, archive
`1791223614503-545282-0.jsonl`. Hegel's TooSlow health check rejected two valid
cases taking45.7468seconds against its30second input-speed threshold; the
fixed real five-second deadline histories account for this runtime. No custody
assertion failure was reported. Only this property's TooSlow check is exempted;
all other health checks, every original assertion and all deadlines remain.
Failed native source patch is retained at
`/tmp/overalls-transfer-stream-escaped-failures-package4-failed.patch`.
A corrected package execution remains required; this red run is not a pass.

### Corrected failure extension native result

Corrected extension package passed exit0,138seconds, archive
`1791224119862-888167-0.jsonl`, log
`/tmp/overalls-transfer-stream-escaped-failures-package5.log`. Three library
properties and nine integration checks passed; eight executable fixtures were
ignored. Integration took45.73seconds. Rustfmt/all-target Clippy passed.
Both completion and failure properties ran; all fixed both-side EOF/deadline/
sideFailure × counts1/3 histories executed in each case. Only the expected
TooSlow health check is exempted; deadlines and custody assertions remain.
Failure-oracle mutation and full component/publication gates remain pending.
The first red native source patch SHA256 is
`69ee3a3977b07eca31d52013b2eaf76a827eb3cb5a4ee629035673cb7d7968db`.

### Failure-oracle selector mutation

The unchanged failure workload falsified process-group-only waiting on
Producer/CallerEof/count1 after both direct sides retired with escaped children
independently live. Helper retirement was observed before their death. Target
failed3.64seconds; package exited1 in83seconds, archive
`1791228049561-3146991-0.jsonl`. Patch SHA256 remains
`4c2965ef0f5585ded30702ab2e0ceb14ed0caccb6ab0e24abbfa1707c6cec4db`.
Source/tests were restored and compared byte-for-byte, then the inert fork was
retained at `/tmp/overalls-transfer-failure-selector-restored-c7Z2p35m`.
Only this first producer/EOF history is credited. The failure property now has
local targeted attribution; consumer/final gates, newer-main integration and
physical storage/SSH/hosted boundaries remain open. Self-review only.

### Current integration preflight

The owned native source/test diff passes `git apply --check` against the
origin98aff42a-merged control worktree. Temporary patch
`/tmp/overalls-transfer-custody-integration.patch` has SHA256
`641e0a9c1e795f16c187a0ee287bd79b72c34809fccb2d170f7163dea6cd130f`.
No native source was applied during the merged Marshall gate. Patch compatibility
does not establish exact-helper-PATH Lilly execution or merged native acceptance;
those gates, final evidence reconciliation and publication remain required.

The native lib.rs and stream.rs files were compared byte-for-byte with the
passing package's archived input `/nix/store/yv9z90lm94jipfxpwv4c1xn931k1bj57-source`.
The executable exists at
`/nix/store/gfw5wrq3s55h6x6kb9libz8kxqc6xxhr-lilly-transfer-stream-0.1.0/bin/lilly-transfer-stream`.
Lilly resolves exactly `lilly-transfer-stream` from PATH. This identifies the
queued consumer gate's helper without claiming that gate has executed.

Final source review traced subreaper setup, Side's checked-PID/NOWAIT peek and
finish's two-group signaling, direct-child waits and all-child drain. Interrupted
drain waits retry; only ECHILD retires adopted-child custody, and accumulated
direct-wait uncertainty maps to EXIT_IO rather than confirming the requested
outcome. The owned lock stays live across the drain. No new violation of
transfer-reap-before-ownership-release was found in these paths; escaped-child
lifetime, physical ZFS/SSH behavior and merged consumers remain separate scope.

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
`/tmp/overalls-mail-native-origin-integrated-lilly-precommit2.log`.
The earlier pending statements describe their checkpoints. Other consumers,
current handbook receipts, evaluated publication and physical/hosted acceptance
remain open. This component gate does not establish native fleet isolation.
