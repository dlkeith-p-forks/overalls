# Executor loss and explicit user retry verification

## Scope and architecture impact

Campaign improvement 030 adds verification for ADR-0100 and ADR-0101 in a
dedicated branch/worktree. Application execution captured published
`4bd7d237cdf2831a441ad3b721845deab11fd09f`; subsequent native preparation
integrates published `ddf1d05a`, retaining external `186a1ea4` Lilly receive-staging
repair and improvement029 scoped fixture cleanup. Neither changes the030 property. Their accepted decisions and partial
implementation status remain unchanged. There is no production implementation,
schema, protocol, permission or timeout change. No production action or new
Inception testing/validation is included.

The existing [executor tests](../../../marshall/test/marshall/agents/executor_session_test.exs)
already cover one started-command replacement, increasing fence, stale result
refusal and no reclaim. The existing [model tests](../../../marshall/test/marshall/agents/model_calls_test.exs)
cover repeated claim uniqueness, a fixed model/tool round trip and claimed model
timeout without provider retry. The [CLI review](2026-09-25-agent-cli-verification.md)
retains its earlier native attempt two's unexplained executor interruption.
This improvement does not assign that historical failure a cause.

## Composed application histories

[The new property](../../../marshall/test/marshall/agents/executor_loss_history_test.exs)
uses actual CLI HTTP authorization, prompt admission, Loop, ModelCalls and
ExecutorSession over PostgreSQL. Every generated order includes all eight
claimed/started, replacement/expiry and allowed/revoked combinations. Three
orders and generated polling counts exercise 24 histories per property run.
Expected command state comes from the generated start boundary, not a SUT
transition or scheduling predicate. Every refused late status, expired lease,
terminal poll and identical request replay preserves complete public-table row
hashes, including all prior fixtures with multiplicity.

The initial VM running receipt and executor expiry are synthetic SQL sandbox
fixtures. Claimed cancellation enters the ordinary tool-result continuation;
the isolated provider then returns a final answer. Started uncertainty fails
the turn as `tool_uncertain` without another model call. No real tool effect,
native timing or TLS claim follows from these application transitions.
Expiry alone refuses the old executor but does not retire its command; the
subsequent actual registration performs retirement and advances the fence.

An unchanged request identity retains its terminal turn. A new identity under
current permission admits a new turn and command. Withdrawal through the normal
sharing action refuses both new and replayed requests and result reads despite
the existing CLI session; regrant precedes explicit retry. Original work rows
remain retained and later polling cannot dispatch a third command.

## Native started-loss fixture

The new [driver](../../../nix/verification/tests/machines/executor-loss/driver.py) and
[browser](../../../nix/verification/tests/machines/executor-loss/browser.py) compose ordinary
browser sharing/approval with the packaged CLI, actual Marshall/Ziggy/Audi/Lilly,
source-built Standard NixOS guest and isolated provider. Only the explicit
`executor-loss` provider mode admits the two fixed effect prompts. The retry
answer requires the exact successful tool output.

[The typed observer](../../../nix/verification/tests/machines/executor-loss/observer.py) is
installed only in this disposable guest. The actual guest tool appends and
fsyncs an effect, signals a FIFO and blocks. An independently running observer
outside the target cgroup freezes the executor service and its twenty-second
timeout child. It records exact PID/start identities after verifying the real
supervisor/executor relationship and descendant tree. Unsupported freezing or
unexpected processes fail closed; bounded emergency cleanup kills and thaws
only the fixture cgroup.

The driver requires that actual marker and a durable `started` command bound to
the current VM placement, epoch, executor fence and packaged binary digest
before requesting a targeted kill. The helper kills the captured executor and
tool descendants, preserves its supervisor, thaws and proves killed identities
absent. These are explicit process interruption and child cleanup, not a natural
tool timeout. Database time continues while the cgroup is frozen; the driver
records whether the old lease is still live and does not claim immediate
replacement-before-expiry causality.

The native assertions require uncertain old work, old-executor invalidation,
real new registration with a larger live fence, twelve seconds of unchanged
work inventory and one actual effect. A fresh browser-approved CLI invocation
then produces exactly one second effect and a completed result. Owner UI
withdrawal refuses a further mounted approval without work; ordinary owner
deletion removes the disposable guest and placement storage.

## Execution record

Initial focused application execution passed one property in 29.0 seconds,
seed `30001`, before the additional post-retry retained-row/no-third-dispatch
assertions. This initial run is not final-source execution evidence. The first shell ty invocation returned success while repository source filters
excluded these machine helpers; it did not establish their types. Strict Nix
build one failed in 102 seconds on actual isolated observer/provider dictionary
narrowing (`1790400162138-1935405-0.jsonl`). No native runtime ran. Explicit
validated string-key object and object-list boundaries fix those errors; actual
standalone copied-artifact Ruff/ty passes outside repository filtering.

Full Marshall precommit passes on frozen tree
`e93cd2df9228f0aea2dd44cca735d27bda2a3a01`, base `4bd7d237`: **1,171 checks
(133 properties, 1,038 tests)**, two exclusions, seed `536772`, 836.0 seconds.
Browser state, dashboard and workspace checks pass. Forced Dialyzer reports zero
errors, skipped and unnecessary exclusions in 77.94 seconds after rebuilding
its copied PLT. Source hashes remain identical through the complete execution.

The complete public-table inventory preserves all 139 baseline bootstrap and
migration rows. It retains 1,163 additional full-suite rows: 320 across five
agent history tables, 193 job events, 185 job snapshots and 465 lifecycle events.
These are not attributed to improvement 030 and are not deleted. The final
inventory SHA-256 is
`a21dcd0b7bb3ebb6f0e0b6ce755ad922f3bc3582d9c7da7d71b41b811f3fc140`.
`/tmp/verify030-full-gate2.log` and `/tmp/verify030-full-audit-summary.json` retain
execution and exact inventory evidence. Earlier preparation failures for missing
local contract tooling and an absent optional npm manifest ran no application
suite and changed no tracked source.

Native-only typing corrections and external Lilly integration follow that frozen
application execution; they do not extend its revision scope. Exact standalone
FleetTerminal/FleetGalileoGuest compilation and direct Dialyzer with actual Lilly
dependencies pass before integration, and both were re-run against the current
staged tree after the Lilly helper-context type updates: fresh helper beams
compile from the current `galileo-guest.exs`/`terminal.exs` and Dialyzer
succ-typings over the helper plus compiled Lilly beams report zero findings
(`/tmp/verify030-final-helper-types.log`).

The strict native fixture then ran. Staged source tree
`c25da191fe0abb8551cad372ddb1be062b878655` on base `ddf1d05a` evaluates to test
driver derivation `1qvr1b46zfqkk7z8lg0mif52ia438add` and runtime derivation
`787xdlyiqwca4iwlkp81rn475a6iaszq`; the run wrapper pinned that exact runtime
derivation. `vm-test-run-kittens-executor-loss` passed in 675 seconds, exit 0,
producing store output
`/nix/store/myjbx6dv74k87xy21r67agz9bmll0w6r-vm-test-run-kittens-executor-loss`
(build log `1790402343794-2452316-0.jsonl`, driver log
`/tmp/verify030-native1.log`). Its typed installed artifacts match current source
hashes for the driver, browser, observer, provider catalog and Galileo guest
helper. The journey recorded a durable `started` effect under a live lease with
the packaged-binary digest, targeted executor/child loss with the supervisor
preserved, a `tool_uncertain` turn without another model call, old-executor
invalidation, a real re-registration with a larger live fence, twelve seconds of
unchanged work inventory, exactly one retried effect under a fresh
browser-approved invocation, and refusal of another mounted approval after owner
withdrawal, followed by ordinary guest deletion. All sixteen owned
wrapper/driver/switch/QEMU process identities were absent after the run and were
independently re-verified absent after the session interruption
(`/tmp/verify030-final-drain-and-identity.log`). Rebuilding the strict driver
derivation from the current staged worktree afterwards is content-reused and
prints the identical output path, so the 675-second success applies to the
current staged sources. The native boundary remains nine virtual machines on one
physical host.

Final focused application execution on the staged tree passed 26 checks
(2 properties, 24 tests), seed `799844`, in 21.4 seconds on fresh partition
`verify030fin`: the new executor-loss property plus the existing
executor-session and model-call suites (`/tmp/verify030-final-focused.log`).
Scoped result records:

- Full Marshall gate 1,171 checks (133 properties, 1,038 tests), seed 536772; final focused suite 26 checks (2 properties, 24 tests), seed 799844
- vm-test-run-kittens-executor-loss passed in 675 seconds at output myjbx6dv74k87xy21r67agz9bmll0w6r; staged-tree strict rebuild reuses the identical output path

Final ADR, HLDD receipt, generated coverage/options/views, Nix HLDD and all-file
prek governance gates pass on the same staged tree; exact commands are retained
in the campaign ledger and `/tmp/verify030-final-*` logs.

## Contract review and remaining gaps

Reviewed root, Marshall/test/agents and Nix/test contracts with ExecutorSession
registration, claim/transition/lease and retirement; Loop cancellation versus
uncertainty; ModelCalls claim/context; Prompt identity; CLIAccess and controller
fresh permission; Conversation result; Lyra's started-before-effect, twenty-second
tool timeout and supervisor restart. No accepted decision changes or current
production defect are established. Contract syntax is separate from semantic
review and runtime execution.

Native pre-start interruption has no established observation seam and remains
uncovered. The SQL property covers its durable policy. Native expiry histories,
independent physical hosts, Ubuntu, live providers, arbitrary long no-replay
observation and production load remain separate. The earlier unexplained native
failure remains preserved, regardless of this fixture's eventual outcome.
