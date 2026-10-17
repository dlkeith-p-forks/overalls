# Control first-envelope property review

## Scope and architecture impact

Base edee0815. Verification draft for ADR-0142's identity-binding first hello.
Reviewed Control.Socket callbacks, Control.Envelope decode/encode, Galileo bind,
Control.Close, existing handler tests and terminal fixture ownership. Root,
Marshall and test contracts require current durable authority and isolated
fixtures. No production change or new decision is introduced. Self-review only.

## Source-backed gap

The control-hello-binds-identity contract requires every other first envelope to
close. Existing tests cover requests before hello but not heartbeat envelopes.
Socket.message accepts ping/pong regardless of whether identity is nil. This
is a source-backed mismatch, not yet a recorded runtime counterexample; no
unauthorized domain request or hint delivery is claimed.

## Generated property

The property sends every valid non-hello envelope kind before binding, including
ping/pong, requests, both response results, hint, resync and welcome. Fixed
counter boundaries0/1/9007199254740991 accompany ten generated draws across the
closed counter domain. Decode checks distinguish valid unexpected envelopes
from malformed input. Exact close4005 must retain nil identity and empty tasks.
A valid hello control must permit the same ping/pong counters with bound identity
and no spawned tasks. Fixture credentials remain private and are never printed.

The property is present and unexecuted. Native upgrade, TLS and fleet evidence
remain separate from callback coverage. Production repair is deferred until the
baseline demonstrates the mismatch. Full gates, catalog and handbook integration
remain pending; this draft does not claim plan completion.

## Related client timer review remains open

Source review of Control.Client found that every successful connect schedules an
untagged heartbeat, and each heartbeat reschedules itself. lost/retry neither
cancels nor distinguishes a previous connection's heartbeat. A timer delivered
after reconnection can therefore service the replacement connection and create
an additional recurring loop. Existing client tests cover one reconnect and
request non-redelivery but do not observe heartbeat ownership over repeated
reconnects. This is a source-backed candidate, not a reproduced rate failure.
The next useful history should use actual peer-observed heartbeat frames and
connection boundaries, with an independent timer-ownership oracle; elapsed quiet
time alone must not establish retirement. This remains separate from the
first-envelope property and is not credited as its coverage.

The repository's native contract checker and its19regression checks passed for
the draft. Upstream cc-check rejects Elixir source as unsupported; native note
discovery and manual caller review provide the applicable Elixir workflow.
Neither structural check establishes callback runtime behavior or type checking.

The satellite version-refusal evidence was also reconciled against ADR-0142.
The current Galileo gate passed31checks (11properties,20tests),seed734392,
96.0seconds and forced Dialyzer. That local classifier evidence does not prove
terminal retry retirement: Client.retry translates the Close :stop reaction to
a60000ms reconnect timer. The existing50ms no-domain-request observation cannot
exclude that later upgrade. This source-backed policy mismatch requires its own
generated history and repair; no timed counterexample is yet credited.

## Protocol contract reconciliation before client property implementation

Protocol CONTRACTS, test CONTRACTS and AGENTS still prohibited all host I/O,
contradicting the accepted ADR-0142 Connection and Client implementation. The
architecture overview and handbook reference chapter also retained blanket
purity claims. This is guidance drift against the explicit existing decision,
not authorization to move domain or host mutation into Protocol.

The correction retains codec/state/View/Cadence purity and confines outbound
socket transport to the two named ADR-0142 modules, using application-owned
credential callbacks and TLS trust. Ash, database access, host mutation and
durable credential storage remain prohibited. Transport tests may use owned
nonprivileged loopback/TLS fixtures; codec tests remain free of host I/O.
ADR-0142 remains accepted/partial, with original migration and native acceptance
gaps retained; ADR-0012's historical rationale remains intact. CONTRACTS IDs are
preserved and the overview, decision index and handbook01/02/17 are reconciled.
The change creates no domain/resource, deployed service or new authority.
Source discovery found socket operations in Connection and its Client wrapper;
the existing View GenServer remains a volatile state primitive. Structural,
consumer and final handbook gates remain required before publication.

## Generated pending-batch property awaiting runtime evidence

The real loopback peer and shared client now have generated answered/dropped
batch histories with fixed1/7/8 counts plus sampled count/mode. Independent
peer ID/ordinal inventory, unknown-ID barriers, reverse valid/wrong duplicate
responses, ninth-request refusal, complete unproven drop settlement and fresh
replacement sentinel completion cover the existing client contract. The retained
200ms observation is bounded no-replay evidence, not universal absence of delayed
work. Client/task supervision and closed header-observation metadata keep owned
fixture cleanup and diagnostics explicit. Formatting and native contract/ADR
checks are structural; runtime, typing and full consumer gates remain pending.
The extension adds actual five-second timeout histories and old late responses
before/during fresh sentinel work, with a120-second test budget for fixed waits.
Reconnect timer ownership still needs a separate history.
No production client behavior is changed by this property.

## Recorded client batch and first-envelope results

Client file passed exit0,seed0,44.8seconds: four checks (one property,three
tests), log `/tmp/kittens-control-pending-batches-original-baseline.log`.
Every generated case ran all fixed1/7/8 answered/dropped/timed-out histories.
Five-second production request deadlines were retained; loopback socket and
bounded no-replay scope remain explicit. Full gates and targeted mutation are
pending; no verified-TLS or fleet claim follows from this property.

The original first-envelope property failed exit2,seed0,0.8seconds before a
successful generated case: counter0 ping produced :push before identity binding,
log `/tmp/kittens-control-first-envelope-original-baseline.log`. Closed kind/tag
diagnostics exposed no principal or credential. The repair adds a nil-identity
message refusal after the specific hello clause and before all other envelopes.
It retains foreign/invalid hello classifications and valid bound heartbeats.
The compiler identified an unreachable diagnostic fallback; it was removed
while retaining the three observed closed result tags.

The repaired control file passed exit0,seed0,2.1seconds: seven checks (one
property,six tests), including existing verified-TLS end-to-end request,
log `/tmp/kittens-control-first-envelope-repaired-focused.log`. No warnings
remained. This is recorded focused evidence; full component/type/publication
gates and targeted fence mutation remain pending. Architecture impact implements
existing ADR-0142 first-hello requirements, with no new authority or wire version.

## Recorded first-envelope mutation

The isolated guard-removal mutant failed exit2,seed0,0.9seconds: counter0 ping
returned push before binding, exactly the targeted violation. Six other checks
were excluded. Source and test were restored and compared byte for byte; the
inert fork was retained. See the local-control-first-envelope mutation ledger.
This closes the targeted callback mutation gap only. Full component/type gates,
native fleet acceptance and the separately reviewed client source gaps remain
open. The final evidence does not change ADR-0142's authority or wire contracts.

## Recorded pending-correlation mutation

The isolated unknown-ID fallback mutant failed exit2,seed0,0.5seconds: the first
fixed one-caller answered history settled with ack -1 after the processing
barrier, before its valid response. Three checks were excluded. Source/test were
restored byte for byte. The local-control-pending-correlation ledger records the
patch and retained inert fork. Only unknown-ID correlation receives mutation
credit; timeout/drop/duplicate collateral and full gates remain separate.

## Terminal version-refusal history

A new shared-client property varies pending batch count1/7/8, observes each
request at the real loopback peer, and closes with unsupported_version. Every
caller must settle as unproven, new requests must remain disconnected, and no
replacement upgrade may occur during61000ms, beyond the actual60000ms retry.
Two generated histories retain real production timing, with shrinking disabled
to avoid repeated minute-long failures; the test timeout is150000ms. This is
bounded transport evidence, not arbitrary future absence or verified TLS.
The history implements ADR-0142's existing terminal-stop requirement, without
new wire fields, domains or authority. Execution and repair evidence are pending.

The original history failed exit2,seed0,60.3seconds at count7: a replacement
upgrade was observed after unsupported_version despite all pending callers
settling as unproven. Four other checks were excluded. Log:
`/tmp/kittens-control-version-terminal-original.log`. This is a recorded actual
retry violation, replacing the earlier source-only diagnosis for this path.
The repair removes the stop backoff, retains phase stopped with the refusal,
ignores queued connect messages while stopped, and stops frame reduction on
terminal closure. Public status remains disconnected with unsupported_version;
request refusal and all pending retirement are retained. Full client execution
is running; HTTP426, queued-message histories, mutation, typing and consumer
gates remain pending. No new architectural decision is introduced.

The repaired client file passed exit0,seed0,167.3seconds: five checks (two
properties,three tests), log `/tmp/kittens-control-version-terminal-repaired.log`.
Both generated WebSocket refusal histories retained the real61000ms observation;
the existing pending-batch property also passed against the changed client.
This result predates the queued-connect and HTTP426 extension and is not evidence
for those added cases. The extension sends one through eight queued connect
messages with a synchronous status barrier after each, adds an explicit HTTP426
loopback refusal mode, and retains61000ms observation for each HTTP history.
The expanded full client file is running; mutation, typing, consumer gates,
heartbeat ownership and native fleet acceptance remain open.

The expanded client file passed exit0,seed0,288.0seconds: six checks (three
properties,three tests), log `/tmp/kittens-control-version-terminal-expanded.log`.
The HTTP426 and WebSocket refusal properties each ran two generated histories
with actual61000ms observations and queued-connect status barriers. All pending
batch correlation/timeout/drop checks passed against the repaired client.
Only sampled counts are claimed; arbitrary future absence, verified TLS and
fleet rollout remain outside this scope. Targeted terminal-stop mutation,
heartbeat ownership and full consumer/type/publication gates remain open.

## Terminal-stop mutation and oracle refinement

The isolated stop-to-disconnected plus60000ms-retry mutant was caught by the
HTTP426 property, exit2,seed0,0.3seconds,count8, observing another upgrade after
queued connects. The WebSocket property initially failed on a status-call
timeout, which is not credited as a direct retry counterexample. Its queued
loop now checks peer upgrade absence for2000ms before each status barrier;
the test budget rises to200000ms with production deadlines intact. The correctly
copied refined mutant failed exit2,seed0,0.3seconds,count7 with an actual peer
upgrade; five checks excluded in both targeted runs. Only queued-connect
sensitivity is claimed, not execution of the mutant's sixty-second timer.
Source/test were restored byte-for-byte. The refined unmutated full client
baseline is running and must pass before finalizing this refinement. See the
local-control-terminal-stop ledger for exact patch, logs and the uncredited
wrong-directory copy attempt. Full gates and heartbeat ownership remain open.

## Reproduced heartbeat ownership

While the refined baseline was frozen, a separate copy added real loopback
reconnect histories with fixed0/1/3 reconnects plus generated0..3. An independent
peer ping/pong barrier precedes a4900ms no-heartbeat observation, allowing100ms
for welcome/barrier transit before the connection's own five-second heartbeat.
Its own heartbeat must subsequently arrive and preserve ready state. No fake
clock or production deadline compression is used. The original property failed
exit2,seed0,10.4seconds with an early ping1, drawn3, zero successful generated
cases; six checks excluded. Log `/tmp/kittens-control-heartbeat-original.log`.
The fixed loop fails before later histories; no exhaustive reconnect claim follows.

The separate repair stores an Erlang timer reference, cancels it on retirement
and rearming, and accepts heartbeat delivery only for the current reference.
Welcome rearms with its negotiated interval. This implements ADR-0142's existing
one-client heartbeat ownership, with no wire/domain/authority change. The focused
repaired property completed successfully; integration into the frozen worktree,
exact passing runtime record, mutation and full type/consumer gates follow.
The4900ms observation assumes welcome/barrier transit within100ms in this healthy
loopback fixture; it is not a production latency bound or arbitrary scheduler
guarantee. Self-review only.

The heartbeat-focused repair passed exit0,seed0,47.8seconds: one property,
six checks excluded, log `/tmp/kittens-control-heartbeat-repaired.log`. The
refined terminal baseline completed separately with six checks (three properties,
three tests),exit0,seed0,318.9seconds in
`/tmp/kittens-control-terminal-refined-baseline.log`. That result predates the
heartbeat repair and closes the refined queued-connect baseline requirement.
After it completed, the heartbeat source and test were copied into this worktree.
Combined full Protocol/consumer/type gates and heartbeat mutation remain open.

The separate stale-reference extension passed exit0,seed0,47.9seconds, one
property and six excluded checks. It captures real timer refs before reconnect,
redelivers retired refs twice after replacement readiness, and includes legacy
untagged delivery. Only the timer ref is read; private callback state is never
printed. Peer barriers and observed ping traffic remain the independent oracle.
Removing only ref matching then failed exit2,seed0,6.2seconds with early ping1,
drawn3, before any successful generated case; six checks excluded. The zero-
reconnect control preceded the violating history; later histories are not
mutation-credited. Source/test restored byte-for-byte to the green baseline copy.
See the local-control-heartbeat-ownership ledger. Extension integration waits
for the frozen Protocol gate, and its combined type/consumer gates remain open.

## Recorded Protocol gate and extension integration

Protocol precommit passed exit0:249checks (97properties,152tests),seed219746,
367.5seconds, plus forced compilation, formatting, contract checks and zero-error
Dialyzer (zero skipped/unnecessary skips),3.84seconds. Log:
`/tmp/kittens-control-heartbeat-integrated-protocol-precommit.log`. This gate
includes all production repairs and the original heartbeat property, before
the retired-reference extension. After completion, the extension test was copied
into this worktree; production Client source remained byte-identical. Focused
extension compilation/formatting/runtime checks are running. Full consumer,
handbook publication and latest-main integration remain required. The production
gate result is reused only for its unchanged source, not claimed as execution
of the subsequently extended test.

The integrated extension then passed exit0,seed0,45.9seconds: one property,
six checks excluded, with warnings-as-errors compilation and formatting checks.
Log `/tmp/kittens-control-heartbeat-extension-integrated-checks.log`. Production
source is unchanged from the249-check gate and the extension is unchanged from
its separate green baseline and killed ref-matching mutant. Lilly's full consumer
gate is running; Marshall/Galileo gates, final handbook checks and upstream
integration remain open. No native fleet acceptance follows from these results.

## Captured upstream integration review

Captured origin98aff42a adds Audi/Lilly control services and negotiated Client
in-flight limits. Client accepts advertised integer limits1..256 and falls back
to eight otherwise; its added example covers limit2 and fallback0. Our default
welcome pending-batch property still tests eight, but its prose must distinguish
the default from negotiated capacity after integration. Valuable follow-up:
generated boundary1/8/256 and invalid-limit histories with independent peer
inventory, exact one-over-limit refusal, complete settlement and renegotiation.
These are source-backed incoming coverage gaps, not current runtime failures.
The current249-check gate predates this captured upstream tree and does not
validate Audi migration, Lilly server dispatch or negotiated capacity.
Preserve both repairs and incoming functionality when merging; do not replace
the Client wholesale or claim the fixed-eight property covers256 admission.

Lilly precommit subsequently passed exit0:503checks (92properties,411tests),
83.8seconds, with forced Dialyzer reporting zero errors/skips/unnecessary skips.
Log `/tmp/kittens-control-repairs-lilly-precommit.log`. This validates the current
consumer tree, not the captured incoming Lilly-server migration. Reviewed HLDD
receipt/reference, coverage, options, domain/topology and ADR checks passed.
Evaluated Nix HLDD passed exit0 in16seconds, archive
`1791231041196-796110-0.jsonl`; this precedes this result/upstream-review prose.
Marshall/Galileo, all-file publication and incoming-main integration remain open.

## Recorded Marshall consumer gate

Marshall precommit completed with exit0 in the repaired control worktree:
1466 checks (240 properties,1226 tests), two exclusions, seed936963,
1676.2seconds. UI checks passed (four checks), and forced Dialyzer passed
with zero errors, skips or unnecessary skips in53.8seconds after its PLT
update. Log `/tmp/kittens-control-repairs-marshall-precommit2.log`.
This validates the current consumer and shared governance tree; it does not
validate incoming98aff42a, the isolated capacity prototype or the unexecuted
post-ACK mail draft. The first receipt-failing invocation remains uncredited.
Galileo's full consumer gate is now running. Final receipt/all-file checks,
upstream integration and native/hosted acceptance remain open. Architecture
impact continues to implement ADR-0142's existing first-hello, terminal-refusal
and heartbeat ownership requirements without changing domains or wire formats.

## Recorded Galileo and publication gates

Galileo's full precommit passed exit0:31checks (11properties,20tests),
seed137303,121.5seconds, with forced Dialyzer reporting zero errors, skips or
unnecessary skips in5.99seconds. Log
`/tmp/kittens-control-repairs-galileo-precommit2.log`. The first invocation
stopped before compilation because this worktree lacked Hex dependencies;
locked dependencies were fetched without changing Galileo's lockfile.

All-file prek passed conflict markers, each application logging catalog,
HLDD review, Ruff, Ruff formatting and ty. Log
`/tmp/kittens-control-final-allfile-prek.log`. Reviewed HLDD receipt/reference,
coverage, domain/topology, generated options and ADR checks passed in
`/tmp/kittens-control-final-research-review.log`. Evaluated Nix HLDD passed
exit0 in25seconds, archive `1791233524161-2377205-0.jsonl`, log
`/tmp/kittens-control-final-evaluated-hldd2.log`. Its first attempt rejected a
stale system receipt after the heartbeat research evidence was reconciled;
that failed attempt is uncredited. This result predates this final result prose;
receipt checks must be reconciled before commit. Latest-main integration and
native/hosted acceptance remain open. No mail-draft execution follows from
these control gates.

## Local main reconciliation

Merged local main5acff905 into a110760f. Both first-hello and Client production
repairs remain byte-identical to the verified batch; no production source change
comes from this merge. Main contributes two audit properties, their mutation
ledgers and ADR-0074 evidence, plus the independently recorded Protocol transport
boundary correction. The imported Lilly test files are byte-identical to main.
Their recorded505-check main gate and the current503-check consumer gate retain
their own revisions; no new combined full-suite execution is claimed.

Resolved the review index by retaining all three reviews, the verification
reference by retaining the repaired-client results, and the receipt file by
reviewing the merged source and chapter scopes afresh. Scenario coverage retains
both audit traversal fairness and control transport properties. Architecture
impact preserves ADR-0074, ADR-0012/0140 and ADR-0142 decisions; no domain,
storage, protocol or deployment authority changes. Structural, generated and
evaluated handbook checks must pass before the merge commit. Incoming origin
capacity/Audi/Lilly migration and native/hosted acceptance remain open.

## Incoming origin and capacity integration

Fetched origin main98aff42a and merged its Audi client/Lilly server phase into
501a38cb. Client conflict resolution retains both `heartbeat_timer` and
`in_flight`; welcome both rearms its current heartbeat and validates negotiated
capacity. The nil-identity Socket fence precedes the new limit/fault-gate request
dispatch. No prototype source patch replaces upstream implementation. Applied
the retained test/fixture patch, scoped the default-eight contract, and added
the production Audi/Lilly64 limit to fixed1/8/256 witnesses.

The integrated original capacity property passed26.8seconds,seed0,one property
and eight exclusions. The service64 extension passed27.7seconds,seed0 with
the same counts; both had compiler warnings-as-errors and format checks. Logs
`/tmp/kittens-control-capacity-integrated-baseline.log` and
`/tmp/kittens-control-capacity-service64-baseline.log`. Prototype mutation credit
does not claim execution of fixed64. Full integrated Protocol gate is running;
Audi, Lilly, Marshall/Galileo, native migration and publication remain open.

Reviewed Service limits, FaultGate, ControlAPI upgrade, Socket dispatch,
Audi Link/client request and reply paths, shared Ingress ControlRequests,
ProvisionerRequests and both service adapters. Fixed route maps call the
existing closed decoders/domain actions; credentials remain bound at hello and
reauthenticated by domain exchanges. Configured fault rejection precedes dispatch
and is inert without its file. Diagnostics preserve catalogued closed reasons.
Architecture impact implements existing ADR-0142 migration, not new domain or
storage authority; ADR-0105 wildcard custody and prior fencing remain applicable.
This is a focused source review, not exhaustive consumer/native verification.

Source-backed follow-up: migrated Audi fixture translates owner-supplied426 into
a request error and discards its synthetic body. Historical HTTPS426/body-size
property names/comments therefore overstate the current exercised seam. Actual
upgrade426 and close4001 while work is pending need Audi cadence histories.
Client maps `:disconnected` via terminal status, but `:unproven` falls through to
transport_error; whether pending close4001 loses the permanent class needs an
actual-wire regression before a repair or completion claim. No runtime failure
is claimed from this source observation.

The full integrated Protocol precommit subsequently passed exit0:251checks
(98properties,153tests),seed212242,390.4seconds, with zero errors/skips/
unnecessary skips in forced Dialyzer,3.97seconds. Log
`/tmp/kittens-control-origin-integrated-protocol-precommit.log`. This includes
the integrated capacity/service64 property and retired heartbeat extension.
Protocol source/tests remain unchanged after this result. Audi's actual pending
close4001 regression then reproduced and was repaired in its consumer adapter;
the [Audi review](2026-10-05-audi-pending-version-close.md) separates that focused
evidence from native migration acceptance. Full merged Audi precommit subsequently
passed 182 checks (51 properties, 131 tests), seed 718971, in 164.4 seconds, with
forced Dialyzer reporting zero errors/skips/unnecessary skips in 5.53 seconds.
Lilly, Galileo and Marshall merged consumer gates and native migration remain open.

## Merged Lilly gate: readiness timing failure

The merged Lilly precommit exited 2: 504/505 checks passed (94/94 properties,
410/411 tests), seed 5371, 197.1 seconds. The existing unresponsive-guest
readiness test failed its combined elapsed >=90 and <500ms assertion; that
assertion did not expose which bound failed. Forced Dialyzer nevertheless ran
and passed in 15.51 seconds with zero errors, skips or unnecessary skips.
Log: `/tmp/kittens-control-origin-integrated-lilly-precommit.log`.
The test now checks each unchanged bound separately to report elapsed on failure.
This diagnostic edit has no architecture impact: it preserves the deadline,
request and expected outcome. The isolated readiness file passed all seven tests,
seed 5371, in 2.4 seconds with warnings-as-errors; log
`/tmp/kittens-control-readiness-isolated.log`. This does not establish the cause
of the full-suite failure. The full Lilly rerun subsequently passed: 505 checks
(94 properties, 411 tests), seed484267, 202.3 seconds; forced Dialyzer passed
in17.14 seconds with zero errors, skips or unnecessary skips. The precommit
process exited0. Log `/tmp/kittens-control-origin-integrated-lilly-precommit2.log`.
Both readiness timing bounds remain unchanged. The earlier failure and its
unproven cause are retained; this is not a claim that timing flakiness is repaired.

## Imported dispatch and limits contract review

Reviewed ControlAPI's HTTPS/GET/version/service/bearer admission, Service's closed
module registry and optional limit callbacks, Socket's bound-identity request
guard and task admission, Audi/Lilly bind and dispatch adapters, FaultGate and
the shared request modules. The merged request guard still precedes limit and
fault-gate dispatch: an unbound request cannot reach either domain adapter.
Audi binds exactly role/host and Lilly exactly host; each adapter passes the
credential to the shared request module rather than treating hello as renewed
domain authority. Service limits remain trusted static module declarations;
peer-advertised capacity is independently bounded by the shared Client.
FaultGate returns only a fixed transient refusal for exact listed op lines,
before task creation, and is inert without its configured file. Busy admission
takes precedence when the server already holds its full task inventory.
These observations preserve ADR-0142's authority boundaries; they are source
review evidence, not new native execution or comprehensive service-test credit.

## Merged Galileo gate

Full Galileo precommit passed31 checks (11 properties,20 tests),seed841285,
97.0 seconds, with zero errors/skips/unnecessary skips in forced Dialyzer,
5.17 seconds. The process exited0; log
`/tmp/kittens-control-origin-integrated-galileo-precommit.log`. Marshall's merged
gate is now running. No packaged migration or independent-host acceptance is
inferred from these local consumer results.

## Final merged Marshall and governance gates

The first merged Marshall precommit exited1 at stale HLDD review receipts before
compilation or tests; log `/tmp/kittens-control-origin-integrated-marshall-precommit.log`.
After individual source/chapter reviews, the second full gate exited0:
1474 checks (242 properties,1232 tests),two exclusions,seed471856,1743.9seconds.
Forced Dialyzer passed47.18seconds with zero errors, skips or unnecessary skips.
Log `/tmp/kittens-control-origin-integrated-marshall-precommit2.log`.
Production and test source stayed fixed throughout this execution.

All-file prek passed conflict markers, every application logging catalog gate,
HLDD receipts, Ruff lint/format and ty; log
`/tmp/kittens-control-origin-allfile-prek.log`. Structural receipt/reference,
view, option and coverage checks passed; log
`/tmp/kittens-control-origin-hldd-structural.log`. Evaluated Nix HLDD passed in18
seconds, archive `1791239193754-1576972-0.jsonl`, log
`/tmp/kittens-control-origin-evaluated-hldd.log`. These results precede this final
evidence paragraph; affected receipts need review before publication. Local
Protocol251, Audi182, Lilly505, Galileo31 and Marshall1474 gates do not establish
the migrated native fixture, deployment rollout or full Antithesis plan completion.

## Integration of origin b6496b73 with mail repairs

A separate integration worktree merges latest origin (Lilly client, Ziggy/Porsche
server side and four-second reconnect cap) into verified255a2346. Protocol merge
resolution retains the permanent stop and owned heartbeat/capacity repairs while
applying the new recoverable four-second bound. Incoming one/four-second prose
is reconciled with actual full jitter from1ms through the doubling ceiling;
terminal version refusals remain stopped, draining caps jitter at500ms.

The fixture now supports both unsupported-version mode and an explicit listen
port. The incoming fixed-sleep reconnect regression becomes a generated4..8
actual-failed-dial history with nonce-like owned callback observations and
:sys synchronization. Focused execution passed exit0,seed0,20.8seconds:
one property,nine exclusions; warnings-as-errors compilation and formatting
passed (`/tmp/kittens-integrated-reconnect-property.log`). This adds the92nd
research candidate; the91existing candidates remain in scope. Mutation, full
consumer gates, receipt reconciliation, evaluated handbook and merge commit are
pending. Existing255a execution records remain historical and do not cover
these imported changes. Mail properties/repair are also present in this tree
with their separate pre-integration evidence.

The thirty-second-cap mutant failed at the observed8000ms ceiling (exit2,seed0,
3.3seconds,one failing property,nine exclusions), independently of later socket
recovery. Restored source cmp passed; restored property passed exit0,seed0,
33.0seconds,one property,nine exclusions. See the
local cap mutation ledger (`antithesis/scratchbook/mutation-testing/local-control-reconnect-cap.md` at kittens revision `9fe1e493`, repository deleted).
No later recovery assertion after mutant failure receives mutation credit.

## Imported consumer review: Lilly pending terminal classification

Reviewed Lilly's imported Link supervision, request response boundary, Runtime
and transfer refusal consumers, Marshall's shared Ziggy/Porsche request adapters
and API extraction, gateway identity transaction, catalogued events and native
fault-gate migration. The shared domain dispatch still passes credentials into
the existing transaction authority; codec, principal binding and domain
authorization remain distinct. Native fault gating writes only closed op names
on every Marshall replica and cannot create receipt/domain mutations.

A concrete source finding remains in Lilly's response adapter: its version-close
contract covers pending work, but :unproven does not inspect the stopped owner's
reason. Runtime fences unsupported_version and backs off transport_error.
The new actual-TLS pending session/audit property is present, with4008 and
transient-service controls. Runtime execution and any repair are pending; no
counterexample is inferred from Audi's separate recorded history. This adds
the93rd audit candidate, preserving all prior candidates.

## Origin-integrated Protocol execution

Full Protocol tests on the origin-integrated/mail integration worktree passed
exit0,seed0,431.1seconds (428.5async,2.5sync):252checks,99properties,153tests.
Compiler warnings-as-errors and format --check-formatted passed before the
run. Log `/tmp/kittens-mail-origin-integrated-protocol-runtime.log`. The
following standalone Dialyzer command defaults to the development environment
and remains live; it is not credited as the required test-environment forced
precommit gate. Full consumer/governance/native publication remains open.
The new Lilly close property was added in its separate project while Protocol
source/tests remained fixed; its execution is not part of this Protocol count.

## Lilly pending close counterexample and repair

Original imported adapter failed the actual verified-TLS pending session/audit
property exit2,seed0,0.7seconds:zero successful draws,prefix0. Both operation
kinds were independently observed before actual close4001; the first result
was transport_error rather than unsupported_version. The4008 control passed;
later version/final assertions after failure are not credited. Log
`/tmp/kittens-lilly-pending-close-original.log`.

The response adapter now checks stopped-owner status for unproven and
disconnected, with an explicit response typespec and contract. Existing
ADR-0142 refusal classes and Runtime/transfer recovery policies remain intact;
no resend, new domain authority, wire change or diagnostic event is introduced.
The oracle now collects both pending results and observes the actual close
reason before comparison. Repaired execution passed exit0,seed0,1.1seconds:
one property, formatting and warnings-as-errors compilation. Log
`/tmp/kittens-lilly-pending-close-repaired.log`. Reversion mutant, restored
execution, forced test typing, full consumers and native Runtime/transfer
fencing remain required. This is independent Lilly evidence, not Audi credit.

The Lilly guard-reversion mutant failed the refined oracle with both adapter
results transport_error after the independently observed4001 close:exit2,seed0,
0.7seconds,prefix0,one failing property. Later terminal assertions are not
mutation-credited. Production cmp restoration passed; restored execution
passed exit0,seed0,1.1seconds,one property, warnings-as-errors compilation.
See the local Lilly mutation ledger (`antithesis/scratchbook/mutation-testing/local-lilly-pending-version-class.md` at kittens revision `9fe1e493`, repository deleted).

The earlier standalone Protocol development-environment forced Dialyzer
completed exit0,4.75seconds with zero errors, skips or unnecessary skips.
This is development-library typing evidence, not the test-environment forced
gate; that and full consumer/governance/native publication remain required.

## Native custody batch integration

Both queued Rust native source/test patches apply cleanly to this origin tree
and were applied after the focused Lilly mutation/restoration runs finished.
Host-lock lib.rs/protocol.rs and transfer lib.rs/stream.rs compare byte-for-byte
with their respective previously passing native-source archives. Those archives
are native project roots; initial repository-relative comparisons failed to
locate files and were corrected before any source identity claim.

Their two owned research candidates, reviews, mutation ledgers and patch files
are now integrated, bringing the catalog/audit to95unique candidates. Existing
93candidates remain. The earlier252-check Protocol result predates only these
Lilly-native source changes and the Lilly adapter repair; Protocol itself is
unchanged. Full Lilly must use the exact verified host-lock and transfer
executables, with current documentation and all forced consumer gates.

## Full Lilly integration attempt and fixture reconciliation

The exact-helper-PATH full precommit attempt stopped at test compilation:
retained audit fairness still called the removed HTTP server/2 fixture after
the incoming migration deleted it. Log
`/tmp/kittens-mail-native-origin-integrated-lilly-precommit.log`. This run is
not credited as a passing full suite or forced Dialyzer result. The remaining
caller now uses the same WebSocket audit handler and owned connected link as
the migrated recovery history. All fairness/pending/readiness assertions and
generated cases remain; the per-draw link is explicitly stopped after its
sender. Full execution remains required.

## Integrated Lilly runtime result, typing pending

After migrating the retained fairness caller, full Lilly tests passed
506checks (95properties,411tests),seed712576,130.8seconds (75.0async,55.8sync).
The full mix precommit command uses MIX_ENV=test and places the exact previously
verified host-lock and transfer-stream executables first on PATH. Compiler,
format, ADR, contract/regression and logging gates preceding the tests passed.
Forced Dialyzer is still live; no full precommit/typing success is claimed yet.
Log `/tmp/kittens-mail-native-origin-integrated-lilly-precommit2.log`.

Both complete native project directories additionally compare with their
passing native-source archives, excluding target and .gitignore (the latter is
absent from the archived cleanSource input). Cargo manifests/locks, contracts,
all source and all tests match. This strengthens source identity and retains
the distinction from newly executed native-package or physical/fleet acceptance.

## Completed origin-integrated Lilly gate

Full MIX_ENV=test mix precommit completed exit0 with the exact verified native
helpers first on PATH. Tests:506checks (95properties,411tests),seed712576,
130.8seconds. Forced Dialyzer:15.06seconds,zero errors,skips or unnecessary
skips; PLT rebuild79.18seconds. Log
`/tmp/kittens-mail-native-origin-integrated-lilly-precommit2.log`.
The earlier pending statements describe their checkpoints. Other consumers,
current handbook receipts, evaluated publication and physical/hosted acceptance
remain open. This component gate does not establish native fleet isolation.
## Porsche session adapter review checkpoint

The imported `ZiggyPorscheServiceTest` success branch compared map keys only.
That assertion could accept altered authenticated status or user values. Two
independent session creations legitimately issue distinct session IDs, tokens
and expiry timestamps, so whole creation-document equality is inappropriate.
The revised generated property compares stable status/user fields, checks the
fixture user, requires distinct IDs/tokens, and reads each issued session through
both adapters. Each status response must match the originating document after
removing its issuance-only token. Refusal documents retain exact equality.

Focused execution passed exit0,seed0,0.7seconds:3checks (1property,2tests).
Log: `/tmp/kittens-porsche-strengthened-baseline.log`.

This is an adapter/domain property using sandboxed PostgreSQL and the HTTPS
controller helper; it does not open a WebSocket or establish TLS, authenticated
upgrade, credential rotation or native gateway acceptance. Execution of these
new assertions passed at this checkpoint; mutation and full integrated gates
remain pending. Existing historical gate results do not verify this
revision. Architecture impact: no domain, protocol or persistence change;
ADR-0142 transport-equivalence evidence is strengthened without changing its
accepted rationale.

## Integrated Protocol required-gate checkpoint

The integrated Protocol precommit ran with `MIX_ENV=test`, seed426800.
All252checks passed (99properties,153tests) in403.9seconds; contract-checker
regressions passed19checks. Its forced test Dialyzer reported zero errors,
zero skips and zero unnecessary skips in3.6seconds. Evidence log:
`/tmp/kittens-mail-native-origin-protocol-precommit.log`. The command's explicit
second forced Dialyzer check also passed, reporting zero errors/skips and zero
unnecessary skips in4.6seconds after18.32seconds of PLT work. The complete
command exited0. This supersedes the earlier dev-environment-only typing gap for
Protocol; it does not verify Marshall's revised Porsche assertions or native
consumer/fleet acceptance.

## Porsche refined-oracle mutation checkpoint

The isolated pending-status overwrite preserves response keys. It failed
exit2,seed0,0.7seconds after17successful generated draws at the stable status/user
comparison: pending versus authenticated. Two unit tests passed; later
cross-adapter assertions are not mutation-credited. Restored fork execution
passed exit0,seed0,0.8seconds:3checks (1property,2tests). Source restoration was
copied from the integrated service; the retained fork contains no Git metadata.
Logs: `/tmp/kittens-porsche-session-status-mutant.log` and
`/tmp/kittens-porsche-session-status-restored.log`. Exact patch/provenance is in
the local ledger (`antithesis/scratchbook/mutation-testing/local-porsche-session-status.md` at kittens revision `9fe1e493`, repository deleted).
This is local falsification after oracle refinement, not a hosted result.
Full integrated Marshall and actual socket credential-rotation histories remain
open. The research audit now tracks96candidates,89partial and7bounded-local.

## Integrated Marshall terminal precommit result

The full integrated Marshall precommit exited0 with `MIX_ENV=test`, seed755639.
All1479checks passed (245properties,1234tests),2excluded, in1598.9seconds.
The required compiler, contracts, logging, formatting, distributed tests and
terminal/dashboard/workspace gates completed before forced test Dialyzer.
PLT work took155.84seconds; analysis took42.65seconds with zero errors, zero
skips and zero unnecessary skips. Log:
`/tmp/kittens-integrated-marshall-full-precommit.log`. Tested staged tree:
`e384913d7fb1dcc9f113893b2b77223eeb328505`, HEAD255a2346/MERGE_HEADb6496b73.
Documentation reconciliation follows this execution without changing runtime
source. Evaluated HLDD passed exit0 in26seconds, log
`/tmp/kittens-integrated-evaluated-hldd.log`.

Origin/main advanced to29ad6228 during verification. This result does not cover
its44-file terminal/client/telemetry migration. Normal pending-merge publication,
newer-main merge and affected revalidation remain required. Queued launch-guard/
source-export integration and new bound-rotation/delayed-admission drafts remain
separate unintegrated work. The full all-source/research objective is unfinished.

## Integrated Audi consumer result

Audi's full precommit exited0 with `MIX_ENV=test`, seed298574. All182checks
passed (51properties,131tests) in153.2seconds; forced test Dialyzer reported zero
errors/skips and zero unnecessary skips in4.89seconds after21.2seconds PLT work.
Log: `/tmp/kittens-integrated-audi-precommit.log`. This verifies the current
b6496b73 integration consumer, including retained pending-version refusal
histories. It does not execute the separate delayed-admission draft or verify
incoming origin29ad6228. Galileo's current consumer gate remains pending.

## Integrated Galileo and final contract review

Galileo's full precommit exited0 with `MIX_ENV=test`, seed18638. All31checks
passed (11properties,20tests) in106.3seconds. Forced test Dialyzer reported zero
errors/skips and zero unnecessary skips in4.96seconds after21.22seconds PLT work.
Log: `/tmp/kittens-integrated-galileo-precommit.log`. This supersedes the pending
consumer checkpoint above for the b6496b73 integration only.

Final contract review clarified bounded-reconnect prose to name unsupported
version as the permanently stopped refusal; other Close reactions retain their
existing semantics. This changes a comment only, preserving the tested runtime
and accepted ADR-0142 policy. No new architecture impact is introduced. Contract
structure, updated receipts and normal commit hooks still require the final
checkpoint; incoming origin29ad6228 and the wider property audit remain open.

## Main29ad6228 asynchronous opening and bound rotation checkpoint

The integration retains main's off-process opening/passive socket handoff and
our stopped-client guard, negotiated capacity, four-second reconnect ceiling and
owned heartbeat timer. Opening success arms the tracked timer rather than an
unowned legacy heartbeat. Hanging-handshake fixtures are supervised and close
the owned listener. Async opening exposed two test timing assumptions, corrected
without changing production refusal semantics: initial failed dials do not emit
an owner disconnect event, and peer HTTP426 writes precede client result handling.
The revised reconnect oracle gates each owned worker, awaits opening-reference
retirement, and measures returning-listener readiness within4500ms.

Full merged Protocol execution passed253checks (99properties,154tests),seed0,
424.9seconds,exit0 (`/tmp/kittens-async-merged-protocol-tests-typing.log`). Forced
development Dialyzer passed3.9seconds; forced test Dialyzer passed4.06seconds;
both reported zero errors, skips and unnecessary skips. Contract structure passed
119CONTRACTS files,2501native notes,205parsed files and2597maintained sources.
These structural counts do not establish semantic review of every source file.
Required precommit and consumer gates remain open after this merge.

Bound TLS credential rotation baseline passed2properties,seed0,2.3seconds,exit0
(`/tmp/kittens-bound-rotation-first-baseline.log`). The Ziggy property rotates
host credentials after0..3healthy prefixes, repeatedly refuses fresh identity
requests on the already-bound old socket, and admits a newly bound replacement.
The Porsche property preserves gateway ID/increments generation, refuses old
socket reads/creation, independently checks the unchanged session inventory,
refuses an old-generation session under the replacement credential and serves a
new session. Listener/client processes are supervised; disposable CA fixtures
and SQL sandbox ownership define the exact scope. No production behavior changed.

ADR-0142 and inherited ADR-0046/0100 authority decisions remain unchanged.
Credential revocation and gateway-generation oracle mutations are pending.
Independent committed-replica rotation, native gateway rollout, complete consumer
precommit and hosted exploration remain unverified. HLDD receipts remain stale
until individual review of the combined migration, property and handbook diff.

### Delayed SSH admission composition

Audi delayed admission transport baseline passed18checks (1property,17tests),
seed0,11.1seconds,exit0 (`/tmp/kittens-audi-delayed-admission-owned-baseline.log`).
An explicit backend entered/release gate holds authorization beyond generated
TTL25/75/150ms, with a measured elapsed witness. The supervised exec task retains
SSH message ownership until exact channel closure. Independent notifications
require no connector call and no guest connection. A healthy admission then
connects and forwards exactly16bytes. The initial parent-owned close observation
failed because exec transfers message ownership; it is not passing evidence.
This property covers real loopback SSH with scripted authority, not actual TLS
Marshall control-backend composition, guest isolation or native rollout.
Forced Audi typing/full gate and a request-start-reset mutant remain pending.

Audi forced test Dialyzer passed4.93seconds with zero errors, skips and unnecessary
skips,exit0. Log `/tmp/kittens-audi-delayed-evidence-typing.log`; scenario generation
and checks and ADR structure also passed. Full Audi precommit remains pending.

### Local oracle falsification after main integration

The retained no-Git fork `/tmp/kittens-control-property-mutants.8KP6eR` uses
separate builds and matching source/test baselines. Ziggy revoked-at omission
failed0.9seconds at the old bound socket unauthorized assertion; Porsche gateway
session-generation omission failed1.2seconds at replacement-credential refusal
of an old session. Restored rotation executions passed2properties in2.0seconds
and1.7seconds. Audi initial guard receipt-clock mutant failed0.7seconds at exact
unexpected connector_called despite later channel closure; restored full transport
suite passed18checks in10.0seconds. Async reconnect30-second-cap mutant failed
2.8seconds at observed8000ms; restored selection passed1property in32.5seconds.
All used seed0. Mutants exited2; restored runs exited0. All four source files
restored byte-for-byte; no mutation entered integration. Later assertions and
other generated trigger variants receive no mutation credit. See the
authority ledger (`antithesis/scratchbook/mutation-testing/local-bound-control-authority.md` at kittens revision `9fe1e493`, repository deleted)
and async cap ledger (`antithesis/scratchbook/mutation-testing/local-async-control-reconnect-cap.md` at kittens revision `9fe1e493`, repository deleted).
These are local oracle results, not hosted or fleet acceptance.

## Ziggy and Porsche pending version refusal after migration

Source review found both imported adapters consulted stopped-owner status only
for disconnected calls; pending unproven calls fell through to outage classes.
That contradicted retained close4001 semantics. New generated properties use a
shared test-only verified-TLS peer, healthy correlated reply and sampled1..3
peer-observed pending IDs before close4001 or draining4008. The peer does not
implement Marshall domain authentication; this is adapter/transport evidence.

Original Ziggy reproduced2pending authority_unavailable results instead of
unsupported_version,exit2,seed0,0.3seconds. Original Porsche reproduced2pending
transport_error results instead of unsupported_version,exit2,seed0,0.3seconds.
Logs `/tmp/kittens-ziggy-pending-version-first-baseline2.log` and
`/tmp/kittens-porsche-pending-version-first-baseline.log`. Production guards now
consult stopped-owner status for disconnected and unproven calls. Other errors
retain their classes and no request is queued or replayed.

Repaired focused Ziggy passed3checks (2properties,1test),seed0,1.0seconds.
Repaired focused Porsche passed9checks (2properties,7tests),seed0,6.9seconds.
Log `/tmp/kittens-satellite-pending-version-repaired-baseline.log`. Transient4008
controls passed. New helper is test-only under protocol/test/support; production
codecs/transports and wire schemas did not change. Porsche directory contracts
now reflect accepted ADR-0142 control transport while retaining domain authority,
verified peer, no redirects and no implicit redelivery. ADR-0046/0100/0142 rationale
and statuses remain unchanged. Full consumer gates and forced typing remain
pending. Actual Marshall domain authorization,
provider activity, native gateway rollout and hosted mixed-version behavior remain
separate acceptance gaps. Shared-client terminal stops await owner replacement or
auto-update; response-level version probes cannot revive a stopped socket.

Separate isolated guard reversions were caught at the predicted close4001
assertion: Ziggy returned two authority_unavailable errors, 0.4 seconds;
Porsche returned two transport_error errors, 0.3 seconds. Both exited 2, seed 0,
after zero successful draws. Later close4008 controls are not mutation-credited.
Both files were restored and compared byte-for-byte with integration source.
Restored Ziggy and Porsche each passed one property, seed 0, 1.0 seconds,
exit 0, in `/tmp/kittens-satellite-pending-version-restored.log`.
The local ledger (`antithesis/scratchbook/mutation-testing/local-bound-control-authority.md` at kittens revision `9fe1e493`, repository deleted)
records matching baselines, mutant logs and retained patch hashes. This is local
adapter oracle evidence; native and hosted acceptance remain open.

## Terminal opening worker retirement

Review of the incoming Lilly shared-transport migration found an unmonitored
opening worker. Its death retained an occupied opening reference indefinitely,
violating the existing reconnect contract. The new generated real loopback
property failed at the missing second worker after a peer-observed request and
worker death: seed 0, generated two deaths, exit 2, 2.1 seconds, zero successful
draws. Log `/tmp/kittens-terminal-opening-worker-original.log`.

The repair owns a worker monitor per attempt, clears only matching deaths and
schedules existing backoff recovery. Completion flushes the monitor; stale
successful sockets close. Termination retires the opening worker without guest
effects. Three focused checks (two properties, one test) passed seed 0, exit 0,
0.1 seconds in `/tmp/kittens-terminal-opening-worker-repaired.log`. The property
observes fresh real requests and shutdown socket closure; it does not authenticate
the recovered hello or establish native/TLS deployment acceptance. ADR-0083/0142
and independent guest lifetime remain unchanged. Full Lilly gates, forced typing
and isolated mutation are pending. The initial attempt is internally gated solely
to install process tracing before the real dial.

Strengthened terminal recovery execution passed three checks (two properties, one test), seed 0, 3.2 seconds, exit 0.
Log `/tmp/kittens-terminal-opening-worker-authenticated.log`. The successor's
decoded hello matches the original host/session/epoch exactly; readiness remains
false until the scripted hello_response. Closing that socket reports readiness
loss, then the next stalled opening is stopped with observed worker death and
socket closure. This supersedes the earlier missing-hello gap for this local
scripted peer only. Test backoff is reduced to one millisecond; production
backoff timing, TLS/domain authentication and native guest acceptance remain open.

## Satellite complete component gates

The integrated Ziggy precommit exited 0: 66 checks (16 properties, 50 tests),
seed 245101, 59.4 seconds; forced test Dialyzer 4.94 seconds, zero errors,
skips or unnecessary skips. Log
`/tmp/kittens-satellite-ziggy-integrated-precommit.log`.
Integrated Porsche precommit exited 0: 94 checks (16 properties, 78 tests),
seed 690807, 148.7 seconds; forced test Dialyzer 4.58 seconds, zero errors,
skips or unnecessary skips. Log
`/tmp/kittens-satellite-porsche-integrated-precommit.log`.
These supersede earlier pending consumer-gate checkpoints for the current
satellite adapter fix. Native deployment, provider effects and hosted exploration
remain separate; source/architecture structure checks are not runtime acceptance.

The terminal opening-worker property also falsified a separate retained-reference
mutant in the isolated fork: the matching DOWN handler returns unchanged state
instead of clearing the attempt and scheduling recovery. Matching baseline and
restored property passed 3.2 seconds each, seed 0, exit 0; mutant failed the
predicted missing successor worker assertion, 2.2 seconds, seed 0, exit 2,
after zero successful draws. Later hello/shutdown assertions were not reached.
Restored source was compared byte-for-byte; logs and patch hash are in the
local ledger (`antithesis/scratchbook/mutation-testing/local-bound-control-authority.md` at kittens revision `9fe1e493`, repository deleted).

## Abrupt terminal owner loss

The initial monitored-worker revision completed Lilly precommit: 501 checks
(95 properties, 406 tests), seed 853883, 125.1 seconds; forced test Dialyzer
13.37 seconds with zero errors, skips or unnecessary skips, exit 0. Log
`/tmp/kittens-terminal-worker-lilly-integrated-precommit.log`. This result predates
the following owner-loss repair and is not its complete gate evidence.

The isolated fork's owner-kill extension failed at the worker DOWN assertion:
seed 0, exit 2, 2.2 seconds, after zero successful draws. Log
`/tmp/kittens-terminal-opening-owner-kill-original.log`. The unlinked worker
survived abrupt owner death because terminate was bypassed. Linking the monitored
worker to the trapping stream passed the isolated extension, seed 0, exit 0,
3.4 seconds in `/tmp/kittens-terminal-opening-owner-kill-linked2.log`.
An initial fork compile attempt used an unqualified spawn_opt; it failed compilation
and is not behavioral evidence (`/tmp/kittens-terminal-opening-owner-kill-linked.log`).

The integration repair uses linked/monitored spawning. The stream already traps
exits, so worker death retains the matching-monitor recovery path; owner death
retires the worker. Every generated history now exercises orderly and abrupt
shutdown after observed stalled handshakes, alongside exact successor hello and
readiness. Integrated focused execution passed eight checks (seven properties,
one test), seed 0, 7.6 seconds, exit 0, in
`/tmp/kittens-terminal-opening-owner-both-repaired.log`. Updated full gate and
typing remain pending. Independent guest lifetime, ADR-0083/0142 rationale,
wire schemas and durable authority are unchanged. Native/TLS/domain acceptance
and production backoff timing remain open.

The final linked-owner Lilly precommit subsequently passed 501 checks (95
properties, 406 tests), seed 125240, 263.2 seconds, exit 0; forced test Dialyzer
11.89 seconds with zero errors, skips or unnecessary skips. Log
`/tmp/kittens-terminal-owner-linked-lilly-precommit.log`. This predates the later
shared Protocol worker-ownership repair and does not verify that dependency
change in the consumer.

## Shared control opening worker ownership

Review found the imported shared Control.Client also retained an opening
reference after unmonitored worker death. A generated fork property observes a
real loopback upgrade request, kills the credential-reported worker, and awaits
a successor under the four-second backoff ceiling. It failed after zero successful
draws, generated two deaths, seed 0, 4.6 seconds, exit 2, in
`/tmp/kittens-control-opening-worker-original.log`.

Linked/monitored workers, matching-DOWN attempt retirement and existing lost
backoff repair that history. Completion demonitor-flushes; client termination
retires its opening worker/socket. The client traps worker exits without changing
codec, credential storage, domain authorization or terminal close reactions.
Initial repaired fork property passed 4.7 seconds, seed 0, exit 0. Integrated
focused execution passed 12 checks (seven properties, five tests), seed 0,
428.7 seconds, exit 0, in
`/tmp/kittens-control-opening-worker-integrated-focused.log`.

The strengthened fork property also checks exact version1/service/generation
hello, readiness only after welcome, transport loss, and both orderly/abrupt
client-owner shutdown. It passed one property, seed 0, 11.8 seconds, exit 0:
`/tmp/kittens-control-opening-owner-hello-fork2.log`. Its first attempt omitted
version1 from the expected decoded map and failed that test assertion; it is not
a production counterexample (`/tmp/kittens-control-opening-owner-hello-fork.log`).
The stronger property is integrated; the final Protocol gate passed as recorded
below.
ADR-0142/0140 rationale/status remain unchanged; production backoff remains in
force. Plain loopback/scripted welcome does not establish TLS/domain/native
acceptance. All consumers must reverify the shared dependency change.

Final matching fork baseline passed one property, seed 0, 13.6 seconds, exit 0.
Log `/tmp/kittens-control-opening-final-fork-baseline.log`. The separate mutant
changes only the matching-DOWN handler to retain state. It failed the predicted
missing successor assertion, seed 0, 4.6 seconds, exit 2, generated two deaths,
after zero successful draws. Later hello and shutdown assertions were not reached
and are not mutation-credited. Log
`/tmp/kittens-control-opening-retained-attempt-mutant.log`. Source restored and
compared byte-for-byte; restored execution passed one property, seed 0,
15.9 seconds, exit 0, in `/tmp/kittens-control-opening-final-restored.log`.

Final Protocol precommit with the exact support-file discovery setting passed
254 checks (100 properties, 154 tests), seed 465553, 440.2 seconds, exit 0.
Explicit forced test Dialyzer passed 4.22 seconds with zero errors, skips or
unnecessary skips. Log
`/tmp/kittens-control-owner-protocol-precommit-discovery-fixed.log`.
The preceding gate passed all 254 checks and typing but exited 1 because the new
test helper was unmatched by Mix's discovery filters; it is not a passing gate
(`/tmp/kittens-control-owner-final-protocol-precommit.log`). The fix ignores
exactly `test/support/control_close_peer.ex` during test discovery; consumers
still explicitly load it, and other files retain normal discovery warnings.
This metadata change preserves production architecture. Current consumer gates
and native/hosted acceptance remain pending.

## Audi asynchronous upgrade-refusal barrier

The first consumer gate against the final shared worker change exited 2:
182/183 checks passed (51/52 properties, 131/131 tests), seed 486531,
155.7 seconds. Forced test Dialyzer was clean, 4.62 seconds. Log
`/tmp/kittens-shared-worker-audi-precommit.log`. The DNS version/payload property
called immediately after asynchronous startup, before the actual HTTP426 was
received, and observed the expected not-yet-connected transport class. That is a
test synchronization failure, not evidence of a production version classifier
defect.

The corrected property first observes the TLS server's upgrade refusal and awaits
the real shared client's stopped unsupported-version status within five seconds.
It then checks DNS/identity calls and absence of domain request dispatch over the
same generated malformed/oversized body corpus. No production classifier changed.
Corrected fork DNS file passed nine checks (five properties, four tests), seed 0,
56.6 seconds, exit 0 in `/tmp/kittens-audi-dns-version-stop-fork.log`. The inspected
test-only diff is integrated. Full Audi precommit passed 183 checks (52 properties,
131 tests), seed 368095, 142.0 seconds, exit 0. Forced test Dialyzer passed
5.63 seconds with zero errors, skips or unnecessary skips. Log
`/tmp/kittens-shared-worker-audi-stopped-barrier-precommit.log`. Other consumer
gates and native/hosted acceptance remain pending. Accepted ADR-0142 semantics
and runtime startup behavior remain unchanged.

## Galileo pending version refusal

Current-source review found Galileo still classified every pending `:unproven`
reply as an authority outage, unlike the repaired Audi, Lilly, Ziggy and Porsche
adapters. Its existing version property covers HTTP426 during upgrade rather
than close4001 with dispatched work. The new
`galileo/test/pending_version_refusal_property_test.exs` permutes all three
routes and generates one to three pending calls. Each route first completes a
healthy correlated response; the peer observes distinct pending IDs before
sending actual4001 or the transient4008 control over verified loopback TLS.

Original source failed with two pending renewal results classified as
authority_unavailable instead of unsupported_version, zero successful draws,
seed0, 0.3 seconds, exit2. Log
`/tmp/kittens-galileo-pending-version-original2.log`. The earlier launcher
attempt lacked fork dependencies and did not execute the test; it is not a
behavioral result. The repair inspects the stopped-owner reason for both
disconnected and unproven replies. No automatic redelivery, durable authority,
transport schema or accepted decision changes. Applicable repository/Galileo
contracts and the shared client retirement/status paths were reviewed.

Repaired focused Galileo passed3checks (2properties,1test), seed0, 3.4seconds,
exit0 in `/tmp/kittens-galileo-pending-version-repaired.log`. A separate guard
reversion failed the same predicted4001 assertion after zero successful draws,
two pending renewal calls, seed0, 0.3seconds, exit2:
`/tmp/kittens-galileo-pending-version-guard-mutant.log`. Later routes and4008
controls were not reached and are not mutation-credited. Restored source
passed one property, seed0, 2.7seconds, exit0 in
`/tmp/kittens-galileo-pending-version-restored.log` and was copied byte-for-byte
into integration. The shared scripted helper's finite service/operation
allowlists now include Galileo; existing Ziggy/Porsche cases remain available.

Architecture impact: this restores ADR-0142's existing permanent refusal
contract while retaining ADR-0140 ownership and Galileo's current Marshall
authorization boundary. Integrated full Galileo precommit passed32checks
(12properties,20tests), seed512221,100.3seconds,exit0. Gate Dialyzer passed
4.78seconds; explicit forced test Dialyzer passed5.15seconds, both with zero
errors, skips or unnecessary skips. Log
`/tmp/kittens-shared-worker-galileo-pending-precommit.log`. These
local scripted-peer results do not establish Marshall domain authentication,
upstream provider fencing, packaged service rollout or hosted mixed-version
exploration. The brief no-dispatch observation is not arbitrary future silence.

## Current shared-dependency consumer results

Ziggy precommit against the linked/monitored shared worker and expanded finite
TLS helper passed66checks (16properties,50tests),seed895967,63.5seconds,exit0.
Gate Dialyzer passed6.3seconds and explicit forced test Dialyzer passed5.68seconds,
both with zero errors, skips or unnecessary skips. Log
`/tmp/kittens-shared-worker-ziggy-current-precommit.log`.
Porsche current precommit passed94checks (16properties,78tests),seed214624,
143.4seconds,exit0. Gate Dialyzer passed3.95seconds and explicit forced test
Dialyzer passed4.42seconds, both with zero errors, skips or unnecessary skips.
Log `/tmp/kittens-shared-worker-porsche-current-precommit.log`.
Audi183 and Galileo32 current gates passed as recorded above. Lilly and Marshall
current gates remain pending; native/hosted acceptance remains separate.

## Socket custody superseding checkpoint

The [2026-10-06 custody review](2026-10-06-opening-socket-custody.md) records a
subsequent Protocol/Lilly repair after reproducing worker death between socket
handoff and completion reporting. The Protocol254, Audi183, Galileo32, Ziggy66
and Porsche94 gates above predate that repair. They retain exact earlier scope;
current complete Protocol and consumer verification must recheck provisional
socket registration/retirement. The broader source/research audit is incomplete.

## Native Ziggy fixture typed input

Reviewed the migrated standalone Python TLS fixture against repository and
Nix/test contracts and the backup schema's object-narrowing pattern. Its provider
POST path assigned the decoder result directly to a typed dictionary, and its
socket dispatcher passed a merely dictionary-shaped body to the typed control
function. Explicit object validation now checks string keys before typed dispatch;
JSON is decoded through an object boundary. Invalid provider objects receive400,
and invalid socket objects leave the fixture's receive path.

This is a fixture typing/refusal correction with no production domain, deployed
configuration, transport version, provider-origin or credential-custody change.
Synthetic control remains distinct from real Marshall authorization. The fixture
does not claim complete WebSocket codec validation.

Prepared source passed Ruff formatting/linting and explicit `ty check --project`
against the repository's Python3.13 target. A deliberately invalid assignment in
a disposable copy produced the expected type diagnostic, confirming explicit-file
coverage; it is not behavioral mutation evidence. Local contract syntax and
discoverability passed in an isolated Git copy with the real root/Nix/test
ancestor contracts. A prior direct `/tmp` parser attempt lacked a repository root
and did not validate contracts.

The inspected prepared file was copied byte-for-byte into integration. Required
all-file Python hooks passed: ruff,ruff-format,ty, followed by explicit standalone
fixture typing. Log `/tmp/kittens-opening-custody-python-static.log`.
Native machine execution against this narrowed fixture remains pending; earlier
native results retain their historical source scope. No generated property is
credited for this small schema guard.
