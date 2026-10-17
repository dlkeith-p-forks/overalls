# Browser-approved agent CLI verification

## Scope and architecture assessment

Improvement 023 starts at published `d8f054795fbd652dd54114e3ac2c9f202ddb924b`
in `verify/023-agent-cli`. The user authorized independent worktrees and
incremental verification improvements. Source, contracts, HLDD11 and
ADR-0099/0100/0101/0103/0107/0108 were reviewed before implementation.

The planned change adds verification within ADR-0101's accepted per-invocation
authority. It introduces no new domain, resource, lock, schema, provider,
protocol or production permission. Browser sign-out revokes the browser login;
an already approved CLI secret independently retains its one-hour window while
the approving account and VM write access remain current. Retirement, access
withdrawal, expiry and VM deletion deny later API requests. No independent
three-BEAM contention schedule is inferred from this sequential-history gap.

Existing [HTTP/LiveView tests](../../../marshall/test/marshall_web/agent_cli_test.exs)
already check explicit approval, digest-only persistence, wrong VM/thread,
withdrawal, deletion and expiry. The
[packaged CLI fixture](../../../nix/verification/tests/machines/agent-cli/default.nix)
already exercises verified HTTPS against a synthetic control. The
[native agent scenario](../../../nix/verification/tests/machines/fleet/scenarios/agent.py)
already exercises real guest execution using a private prompt helper. This
improvement joins the ordinary browser and packaged user CLI to that real stack.

## Added verification

The [generated histories](../../../marshall/test/marshall_web/agent_cli_history_test.exs)
model direct web/viewer/operator/manager/revoked roles and current team membership
independently of Cedar. Each step tests an existing approved secret and a fresh
explicit browser approval. Refusals compare UUID-indexed full persisted-row
digests for both machines' turns, threads, sessions, audits, VM rows and lifecycle
operations. GET is read-only. Wrong machine, foreign thread, digest bearer,
unapproved fresh secret and changed replay payload refuse; exact retries retain
the original turn and wake/audit inventory, including through another approved
invocation. Real DELETE sign-out rejects a mounted stale browser approval while
the independent CLI invocation remains usable. Real VM deletion and account
retirement, and explicitly synthetic session expiry, then refuse CLI use.

The [dedicated native driver](../../../nix/verification/tests/machines/agent-cli-journey/driver.py)
and [browser helper](../../../nix/verification/tests/machines/agent-cli-journey/browser.py)
compose the existing source-built fleet modules with a current NixOS guest.
An ordinary owner shares a stopped Standard VM through the UI. An ordinary
member signs in through the magic-link form, compares the packaged CLI's digest
and explicitly approves. Intended acceptance checks real wake, two completed
model calls, one guest `read_file`, the final CLI answer and its durable receipts.
A fresh invocation retains the profile's child-agent refusal. A third approval
form is mounted before the owner removes access through the UI; the stale form
must refuse with unchanged full agent/lifecycle inventory. No fixture writes
approved sessions, prompts or results. The CLI owns its secret; only the digest
URL enters the browser. Output and login material remain in private files.

The helper has its own pinned Python/Playwright type gate and the complete
dedicated driver retains NixOS composed-driver type checking. The fixture uses
an isolated deterministic HTTPS provider; it cannot establish live-provider
availability, production capacity, physical-host isolation or Ubuntu acceptance.

## Findings and execution record

No production defect is established. ADR-0101's historical curl standard-input
description is stale: `lyra/src/agent_cli.rs` calls the native bounded verified
HTTPS client in `lyra/src/http.rs`. The client disables proxies and redirects,
uses the bearer as an in-memory header, bounds response bytes/time, and maps
request/status errors to fixed messages. The CLI emits the digest approval URL
to the user's terminal and emits only closed error text; no bearer, browser
cookie, prompt or response body enters process arguments or persistent logs.
The evidence wording is corrected without changing accepted custody intent.

Initial source test run, seed `23001`: two properties passed; the lifetime
property incorrectly used GET `/sign-out`, which returns the confirmation page.
The fixture now uses the real DELETE route. Second run, seed `23002`: seven of
eight checks passed; the synthetic expiry injection violated the schema's
expiry-after-insertion constraint. The third run, seed `23003`, also exposed the
fixture's greater-than-one-hour synthetic duration. The fixture now moves both
timestamps into the past, preserving exactly one hour between them. These are failed fixture attempts,
not product failures or passing coverage of the final source.

The final focused run passed **8 checks (3 properties, 5 tests)**, seed `23004`,
32.3 seconds, on base `d8f05479` with history-test Git blob
`6d52b2ff580f3750e91266d982d1468f13fecac8`. Every lifetime history now includes
all three boundaries in a generated order, with a generated past expiry age.
The sharing history checks session, threads and original-turn reads in addition
to mutations. The test shell completed successfully and its owner session was
drained. Log: `/tmp/verify023-properties4.log`.

Initial driver build stopped at the standalone helper's external JSON type
narrowing. It now explicitly validates string keys into `dict[str, object]`
before selecting required strings. Subsequent build and execution results follow.

The complete Marshall `mix precommit` passed on frozen staged tree
`4a343602d9cbd6d6e14c8e88d5a4b4f137acc4ab`, base `d8f05479`:
**1,106 checks (118 properties, 988 tests)**, two excluded, seed `473022`,
489.1 seconds. Terminal/browser checks passed 28 tests, dashboard checks four,
and workspace TypeScript passed. Forced test Dialyzer reported zero errors,
skipped findings or unnecessary skips, 51.03 seconds after isolated PLT rebuild.
The owner shell drained successfully. Log: `/tmp/verify023-full1.log`.
ADR/HLDD/options/coverage/views/contracts, all-file `prek`, Nix `hldd` and
`python-static` passed on that frozen scope. Driver build two passed its
standalone browser and complete composed-driver type checks in 290 seconds;
it did not boot native machines.

After the gate drained, published `e3072688` was integrated. Its administrative
actor/target serialization is inherited; this improvement changes no Agents
production code. Campaign rows and review receipts preserve both improvements.
Pre-runtime source review corrected the browser's sharing path to
`/machines/:id/access`, and strengthened the native positive control to require
exact `read_file` arguments for `/etc/hostname`, its source-configured
`lilly-guest` newline result, and the current placement/execution/fence executor
binding. Queries emit only counts. These fixture corrections postdate the
passing driver above and require a new captured driver before execution.

ADR-0100's historical ordinary-member read-only wording conflicts with the
accepted member-use policy in ADR-0077. Its Decision now explicitly retains the
historical wording and references campaign 012's prior permission repair and
owner/admin-only management boundary. This documents the inherited resolution;
023 does not introduce a permission change.

The integrated focused gate passed **31 checks (9 properties, 22 tests)**,
seed `23005`, 57.4 seconds, followed by forced test Dialyzer with zero errors,
skipped findings or unnecessary skips, 63.8 seconds. This covers the CLI,
account lifecycle, administrative account histories and HLDD tests on tree
`a5b0a41559f852c2aca2016affb1d8f6ea1963b5`, base `e3072688`; it does not
relabel the earlier complete-suite scope. Log: `/tmp/verify023-integrated1.log`.
Driver build three passed standalone browser typing, composed-driver typing and
lint, Nix `hldd` and `python-static` in 311 seconds. The built driver and browser
were compared byte-for-byte with the source before the captured native run.

Native attempt one used
`/nix/store/98dkbwxq1vwq5nla2yail9kcankpy33v-vm-test-run-overalls-agent-cli-journey.drv`
on that same frozen tree. It failed after 55 seconds during Marshall startup,
before any CLI journey, because the dedicated fixture omitted the existing
agent-enabled fleet's `serper.key` transfer. The isolated key now follows the
same private transfer path as the original fleet bootstrap. This is a fixture
failure, not a production defect. The owner exited unsuccessfully and was
drained; all captured driver, QEMU and switch PIDs were absent afterward.
Log: `/tmp/verify023-native1.log`; archive:
`/home/ghuntley/.local/state/nix/build-logs/1790374996670-499011-0.jsonl`.

Driver build four passed composed typing/lint, Nix `hldd` and `python-static`
in 47 seconds. Native attempt two used
`/nix/store/5avxm90qy0xwvavmbqwj74mhm29g5gim-vm-test-run-overalls-agent-cli-journey.drv`
on frozen tree `9592f6c9a9b2be2d118db3d6cefc5f563fe58593`.
Boot (65.22 seconds), authenticated capacity/service enrollment (167.15 seconds),
and ordinary browser sharing of the stopped real guest (60.05 seconds) passed.
The approval GET preserved the recorded inventory. The explicit approval stage
then failed its CLI result assertion: the first model exchange completed and
the second reported `upstream_error`. An executor re-registration occurred
between them; no command-finished event was recorded. The capture does not
establish whether the cause is a provider fixture refusal, executor failure or
another product boundary. Its private database/client files were not retained.
The failed run lasted 326 seconds, cleanup 5.02 seconds, with the owner drained
and all captured native processes absent afterward. Log:
`/tmp/verify023-native2.log`; archive:
`/home/ghuntley/.local/state/nix/build-logs/1790375331139-670910-0.jsonl`.
The next capture adds finite provider-rejection codes, separate browser exit and
result stages, and failure-only schema-constrained status/count diagnostics.
These do not change provider acceptance or relax the exact tool/result oracle.

The full-suite disposable database retained 63 initial agent roots, threads,
registration audits and each resource's versions, created during the original
full gate. Existing committed fixture teardown paths in
`distributed_admission_test.exs`, `GalileoPeerFixture` and
`GuestIdentityFixture` omit these agent tables; assigning all original rows to
individual helpers remains follow-up work. No rows were deleted or partition
reset. A rerun of only the new CLI history file passed all three properties,
seed `23006`, 32.3 seconds. The exact 315 retained row digests were byte-identical
before/after; users, VMs, CLI sessions, turns, commands, model calls, lifecycle
operations, sharing, jobs, other connections and advisory locks remained zero.
This establishes this new property's cleanup scope separately from inherited
suite residue. Log: `/tmp/verify023-cleanup-scope2.log`.

## Remaining gaps and final review

Driver build five passed standalone browser typing, composed-driver typing/lint,
Nix `hldd` and `python-static` in 58 seconds. **Native attempt three passed all
six stages in 337.46 seconds**, with 3.98-second cleanup (Nix build 346 seconds):

- Fleet boot: 81.43 seconds; authenticated native capacity/services: 140.36 seconds.
- Ordinary browser sharing of a stopped real guest: 65.20 seconds.
- Read-only approval GET, explicit consent and complete packaged CLI/guest round
  trip: 30.07 seconds. Two model calls and one exact `/etc/hostname` result
  (`lilly-guest` plus newline) passed, bound to the current native executor.
- Fresh Standard invocation child-agent refusal: 9.81 seconds.
- Mounted approval refusal after ordinary owner UI sharing withdrawal, with
  unchanged agent/lifecycle inventory: 10.59 seconds.

This captured frozen tree `c071d5d3ac10cf6ea48de04f938f7520f02c451c` on
`e3072688`, exact derivation
`/nix/store/hbm4iyy60lvazllk1gkg6l9ss4scvr7h-vm-test-run-overalls-agent-cli-journey.drv`.
The built driver and helper matched source byte-for-byte; complete test-script
SHA-256 was `136d8ccf8b9ecfa74f00ca4e55fe2d93157d3bd763c5273bfb067e5f50af3d7e`.
The owner drained with exit zero. All captured Nix, builder, driver, nine QEMU
and switch processes were absent afterward, independently confirmed by the
coordinator. Log: `/tmp/verify023-native3.log`; archive:
`/home/ghuntley/.local/state/nix/build-logs/1790389779142-2614111-0.jsonl`.
An unrelated native job was active on the shared runner during the final
independent process scan. These durations record the execution and cleanup;
they do not establish performance acceptance or exclusive runner use.

Attempt two's executor interruption remains unexplained: attempt three changed
diagnostics only and reproduced no failure. No production repair or cause is
claimed. Its recurrence needs the retained closed diagnostics. This is a
remaining reliability investigation, not grounds to relabel the failed run.

After this capture, upstream `73a3a96c` was integrated. Its registry allowlist and
Underclass package pin/documentation are inherited. The passing capture predates
that pin; this result does not establish Underclass token recovery or acceptance
of the new package. The upstream token-recovery scenario gap and generated
options remain intact. Inception verification is excluded by user direction;
this native journey uses only Standard, and the earlier full-suite evidence
retains its historical scope.

The final integrated gate on `73a3a96c`, frozen tree
`68419a6674902b1f7ba4131c71a1e0c74816b3c4`, passed **31 checks (9 properties,
22 tests)**, seed `23007`, 63.3 seconds. Forced test Dialyzer reported zero errors,
skipped findings and unnecessary skips, 71.63 seconds. The owner drained with
exit zero. Exact 315 retained row digests matched before/after, SHA-256
`7066bba672718a12801c2feb40d986bf9a6a2bdd1d35c30d8910b75862c8abaa`;
all other audited fixture tables, connections and advisory locks remained empty.
No retained rows were deleted or partition reset. Log: `/tmp/verify023-integrated2.log`.
The complete earlier Marshall suite is not relabeled as a run of this newer
source. ADR/HLDD/generated references, contract format/discovery/coverage and
all-file `prek` passed on the final integrated scope. All eight new contract IDs
are discoverable; semantic review found no violation in the changed test paths.

The final integrated driver, Nix `hldd` and `python-static` build passed in
379 seconds and its owner drained with exit zero. The strict composed driver
passed typing and lint. Its transfer/driver suffix and typed browser match
source exactly. The complete script differs from native attempt three only in
the evaluated `storage_images` store binding; integrated script SHA-256 is
`3c08ef69891c3232e2582e673d7394fe9d91cbfdaa9a0e812abaae7b9ae36981`.
Driver: `/nix/store/w42izvkvwpfhf87falh4qzxffsbf6wi2-nixos-test-driver-overalls-agent-cli-journey`.
This built the integrated source packages but did not boot another fleet or
extend native acceptance to the Underclass pin. Log:
`/tmp/verify023-final-driver-build.log`; archive:
`/home/ghuntley/.local/state/nix/build-logs/1790390503800-3047459-0.jsonl`.

Final diff review preserves ADR-0077/0099/0100/0101/0103/0107/0108 boundaries:
no production code, permission, protocol, schema or topology change. The ADR
wording reconciles existing implementation/provenance and adds scoped evidence.
Independent physical hosts, live providers, production rollout/load, Ubuntu CLI
approval and hostile-tool/profile permutations remain separate. Hardware
authenticators are outside this ordinary member-login journey. ADR-0101 remains
accepted/partial given the unexplained failed capture and these acceptance
limits; no accepted rationale is replaced. Publication remains pending.

### Bounded follow-up 030 plan

Use one dedicated agent and new worktree for execution-lifetime verification.
Keep the fixture isolated, the profile Standard, and the actual source-built
guest executor, provider and control services. No Inception validation is planned.

Existing [executor session coverage](../../../marshall/test/marshall/agents/executor_session_test.exs)
already tests replacement fencing, uncertain started commands, late-result
refusal and no reclaim. [Model-call coverage](../../../marshall/test/marshall/agents/model_calls_test.exs)
already includes generated repeated-claim uniqueness and fixed server-tick
round-trip and expired-claim uncertainty without provider retry. These are
existing application assertions, not native executor-loss acceptance. Inspect
their exact scope first and extend only uncovered composed loss/retry histories.

1. Add missing generated state histories with independent command/fence/result inventory
   expectations for loss after claim and after the durable `started` receipt.
   Include expired/replaced leases, late result refusal and current-user retry.
2. In a typed NixOS journey, stop the actual guest executor at observable
   pre-start and post-start boundaries. Hold only fixture-controlled tool work;
   never inject production locks, terminal results or approval authority. Use an
   independently observed guest-side effect counter to detect duplicate execution.
3. Prove the old fence cannot commit after replacement. Loss after a `started`
   receipt must preserve uncertain effects and must not automatically replay the
   command. The browser/CLI must expose the actual terminal failure outcome.
4. Exercise an explicit retry by a still-authorized ordinary user under a new
   request identity. Verify its new turn and exactly one deliberate new effect;
   revoked users and old request identities must not gain execution authority.
5. Retain closed route/status/phase diagnostics and both successful and failed
   captures. Attribute any reproduced defect before changing production code.
   Update ADR-0100/0101 evidence without weakening the no-automatic-replay
   recovery contract. Keep native2's unexplained failure until evidence resolves it.
