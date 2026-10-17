# Lilly native submission and daemon recovery composition

## Scope and architecture impact

Integrated main `34daa6b3`; green native run baseline `31f133d8`; initial native run baseline
`e3598d11be20498968fc21da993a5459f4b96890`.
ADR-0017 retains attempt-before-effect and at-most-once launch authority;
ADR-0016/0031 retain independent native VM lifetime and storage custody.
This fixture preserves the production Driver, Unit, Runtime, Journal and
authenticated command/outcome exchange. No accepted decision changes.

## Source-backed boundaries

`Lilly.VM.Driver.launch/5` writes the exact placement/epoch/generation marker
before `Unit.start/5`. `not_attempted/3` refuses resubmission of that authority
when its native unit is stopped. A running unit follows physical adoption.
`Lilly.VM.Unit.start/5` calls the native launcher with a ten-second command
deadline. Its independent `lilly.slice` tree owns the VMM and boot-log writer.
Disconnection alone cannot establish daemon death or VMM survival.

The existing native readiness scenario restarts daemons during database outage
and independently checks original VMM identities. The existing actor-recovery
scenario checks completed effects and isolated worker BEAM loss. Neither proves
full daemon death at launch submission followed by authenticated settlement.

## Fixture implementation

`submission-barrier.py` interposes only in the disposable runtime-readiness
variant. An explicitly armed canonical placement and closed before/after phase
select the exact unit. Unarmed invocations exec the pinned launcher unchanged.
The before checkpoint precedes submission; the after checkpoint requires native
success. An exclusive runtime checkpoint prevents duplicate witness replacement.
It persists across process death in the disposable VM; it is not power-loss
storage evidence.
No arguments, credentials, guest data or outcomes are recorded or fabricated.

The scenario must observe the checkpoint and actual daemon exit before recovery.
Because the command deadline is ten seconds, pause the daemon promptly at the
checkpoint before collecting independent physical evidence; then kill and
observe its old MainPID. Final review strengthened this to suspend the entire
daemon service tree, including the native command owner. Suspending only BEAM
cannot pause the external command deadline. The atomic checkpoint publishes the
barrier worker PID and kernel start time; its suspended state and unchanged
identity must still hold immediately before whole-tree kill, and its process
must disappear afterwards. The independently supervised VM unit remains separate. A timeout must fail, never count as the intended fault.
Source review shows that a generation without matching prior running history
must settle as `execution_failed`; it cannot consume automatic crash recovery.
The before history requires that failed settlement, then uses a distinct public
start request to restore the guest. Same-generation relaunch is forbidden. After-submission recovery must preserve the exact VMM
identity and original launch authority through authenticated settlement.

## Verification and remaining work

Pinned Ruff formatting, lint and ty checks passed for the typed barrier helper;
log `/tmp/kittens-lilly-submission-barrier-static.log`. This establishes static
checks only. Native derivation evaluation passed, exit0; log
`/tmp/kittens-lilly-submission-eval.log`. The generated scenario now runs both
before/after phases for each selected host and one/two subsequent daemon reopens,
with fixed first-host/one-reopen and second-host/two-reopen witnesses. It checks
actual old PID disappearance, exact native process identities, unchanged launch
marker, completed original operation, exact state/reason and immutable outcome
IDs/sequences through authenticated exchange. Pinned scenario formatting and lint
passed after a loop-capture correction; helper ty passed. Log
`/tmp/kittens-lilly-submission-scenario-static2.log`. Fragment type checking was pending at that stage; the refined composed
driver passed as recorded below.
An atomic link now publishes a fully written checkpoint rather than exposing a
partially written file. The positive worker/suspension refinement passed pinned
formatting, lint and helper ty; log `/tmp/kittens-lilly-submission-tree-stop-static.log`.
The initial native execution predates this refinement and failed, archive
`1791197341395-2049832-0.jsonl`, log `/tmp/kittens-lilly-submission-native.log`.
Its exact initial fixture patch is retained at
`/tmp/kittens-lilly-submission-initial-native-source.patch`, SHA256
`d2cebbdb9b63f14ee41a3ffa5c4b10e1dd2d9cca0541440cf089267d739960d9`.
The initial Nix-composed driver passed its static checks (archive lines4643
and4646) and booted the fleet; its runtime assertions remain pending. This
initial driver predates the final worker/suspension checks, so final fragment
typing and runtime execution still require the refined source.
At that stage, refined native execution, evaluated handbook gates and mutation
sensitivity remained required; refined native success is recorded below. Repository hooks and structural handbook checks
passed before this final source refinement; their refresh is pending. That draft established no new native recovery
claim; the recorded refined result below has its explicit bounded scope. Fresh agent review remains unavailable due
to the session thread limit; final self-review is also pending.

## Initial native failure and oracle repair

The initial command exited1 after reaching the submission scenario. The
before-submission history progressed through failed settlement and daemon
reopen; its distinct public restart then failed the generic `await_running`
fixture immediately because the VM still retained its old failed observation.
Source review confirms `Lifecycle` advances desired intent/generation while
`Outcomes` changes the physical observation only after matching authenticated
evidence. The retry wait now follows the new generation and its completed
operation/running outcome, and refuses a genuine failure of that generation.
The host0/reopens1 explicit case reported `Real guest launch failed` at this
old-observation wait. A subsequent host1/reopens2 example could not snapshot
that already failed guest; this is collateral fixture-state failure, not an
independent application counterexample. The initial profile matrix passed
492.50seconds and the composed driver type/lint gates passed. That initial native
composition was not green.

The destructive history now disables shrinking and multiple-bug aggregation
to preserve the first actual fault after shared machine state changes. Fixed
host/reopen witnesses and generated draws remain enabled on success. Final
whole-tree suspension, positive worker identity and generation-bound restoration
source passed pinned scenario format/lint; log
`/tmp/kittens-lilly-submission-failure-preservation-static.log`. At that stage native
execution, refreshed receipts and gates remained pending. No production defect
is established by these initial fixture failures.

## Recorded refined native execution

The integrated `31f133d8` refined source passed the complete source-built NixOS
check: 1544seconds, exit0, archive `1791199858236-3527244-0.jsonl`, log
`/tmp/kittens-lilly-submission-refined-native.log`. The composed driver lint and
type gates passed (archive events4342 and4345). The profile matrix passed in
325.69seconds and existing Runtime-readiness recovery passed in217.64seconds.
The new submission/whole-daemon-loss subtest passed in337.69seconds; the complete
machine script passed in1036.30seconds. Fixed host/reopen witnesses and generated
draws exercised both submission phases with full-tree suspension, positive
worker identity, observed old-process retirement and generation-bound recovery.

The pending and failed execution descriptions above are historical. This result
establishes the bounded retained-start/authenticated-settlement composition.
It does not establish initial provisioning, guest data usability, power loss or
hosted execution. Mutation sensitivity and final publication evidence are recorded below.

## Native mutation sensitivity

An isolated single production mutant changes the Driver launch-marker revision
comparison from `<` to `<=`, permitting same-authority resubmission. Fixture
source is identical to the green retained-start baseline. Patch SHA256 is
`4871cadd4fc08257be48e97708421235c15648604d96b63f1769f3d7a2391cfa`.
The native run exited1 in1264seconds, archive
`1791201540948-16345-0.jsonl`, log
`/tmp/kittens-lilly-submission-equal-authority-mutant.log`.

The exact before checkpoint, suspended original daemon/worker, inactive native
unit and marker precede whole-tree kill. Old-daemon retirement and fresh MainPID
were observed by event71330. The same placement
`13826b1f-00db-4523-a8b1-fa85d653ee37` launched at epoch1/generation3 at event71786
and became provisioning_ready at event72870. Repeated running outcomes and
timeout headroom at event85072 cover that same authority. Required
failed-generation settlement timed out at event85111 (host0/reopens1). This
connects the targeted failure to same-authority relaunch rather than unrelated
readiness polling. The mutant Driver has been restored; no mutant is published.
This establishes bounded native sensitivity, not a hosted SDK mutation sweep.

## Integrated application gate and final source review

The full Marshall gate on main34 plus this fixture passed, exit0:1452 checks
(238 properties,1214 tests),2 excluded, seed366224,1772.5seconds. PLT update
completed in5m5.4seconds; forced Dialyzer completed in46.73seconds with zero
errors, skips or unnecessary skips. Log
`/tmp/kittens-lilly-submission-main34-precommit3.log`. Setup failures from missing
contract-tool/dependency installations preceded this run and are not test defects.

Final in-context source review inspected the complete wrapper and generated
scenario, exact selector/delegation, exclusive witnesses, positive kernel worker
identity, whole-tree suspension/death, operation authority, authenticated
settlement, generation-bound restoration and every unrelated VMM through
reopens. No code/contract mismatch was found in this scope. A fresh-agent review
was unavailable because the thread agent capacity was exhausted. Marker hash
continuity does not independently decode its exact authority. Initial provision,
guest data usability, exact dataset cleanup, power loss and hosted exploration
remain separate gaps. All-file publication hooks passed, including Ruff and ty; the evaluated Nix
HLDD check passed40seconds, exit0, archive `1791204659507-1449994-0.jsonl`.
Log `/tmp/kittens-lilly-submission-final-hooks.log`. Source-derived views,
generated option reference, ADR138 structural checks and reviewed receipts
passed in `/tmp/kittens-lilly-submission-final-evidence-check2.log`.
