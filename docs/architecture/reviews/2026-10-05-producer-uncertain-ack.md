# Producer acknowledgment uncertainty and recovery histories

## Scope and architecture impact

Baseline `6688935f6564ab1f3720eedb61d2339c1ebfe049`. Production client,
marker, RPC and Rust recorder remain unchanged. ADR-0136 retains source-local
numeric measurement with no application/guest authority. Accepted rationale
and partial implementation status remain unchanged. This extends local boundary
verification; native durable checkpoint and per-source journeys remain separate.

The captured baseline called the producer project `slo_client/` and exposed
`OverallsSLOClient.Client`. The current breaking rename is
`elixir/request_accounting/` with `Overalls.RequestAccounting.Producer`,
`QualityMarker` and `RecorderRPC`; the histories and execution scope below
remain evidence for the same boundary.

Reviewed the complete Client admission/finish/gap/recovery paths, Marker custody
and RPC's bounded closed replies, plus their repository and SLO-client contracts.
The existing worker histories do not exercise acknowledgment uncertainty.

## Generated histories

`uncertain_ack_history_test.exs` uses the production Client, private real marker
files and packet4 Unix sockets. Its controlled peer records received commands
before dropping, refusing or sending a malformed acknowledgment. This is an
attempt witness, not proof of a Rust durable commit.

The first property varies admission versus finish uncertainty, three response
faults, one to four failed gap handshakes, success/failure/exclusion, configured
zero/one/maximum duration boundaries and repeated completion. Unknown admission
returns unrecorded without a pending ticket; an uncertain finish removes its
ticket and duplicates emit no second terminal. Both retain a private gap marker.
Failed recovery handshakes must emit no new admission; successful recovery must
emit exactly gap then admit, publish running, and permit a new exact completion.

The second property varies the same uncertainty boundary/fault and eligible
work return, error, throw or exit. Exact numeric-tagged semantics and one work
invocation survive measurement failure; pending accounting empties and the gap
remains. Work errors settle failure only when an admission was acknowledged.
Fixture resources have nested cleanup and actual server-death observation.

## Verification and limits

Initial acknowledgment property passed seed244091 in0.8seconds. The combined
two-property file passed seed211549 in1.1seconds, exit0, warnings-as-errors;
log `/tmp/overalls-producer-uncertain-ack-focused2.log`. Pinned formatter passed.
Component precommit, forced Dialyzer, governance, integration and mutation
validation remain pending. No standalone test-module type result is claimed.

The controlled peer does not authenticate native SO_PEERCRED, fsync checkpoints,
explore power loss or deliver collector telemetry. Delayed acknowledgments after
RPC timeout and native commit/reply ambiguity remain valuable separate histories.
Fresh-agent review remains unavailable under the existing thread-capacity limit;
final source self-review is still required.

## Component gate and single-mutant sensitivity

Full SLO-client precommit passed11checks (8properties,3tests), seed759065,
1.7seconds, exit0. Forced project Dialyzer passed3.2seconds with zero errors,
skips or unnecessary skips; PLT update51.9seconds. Toolchain,138-ADR structural
check, contract gate, compiler and formatter passed. Log
`/tmp/overalls-producer-uncertain-ack-precommit.log`. Project Dialyzer analyzes
the three production client modules; dedicated test-module analysis is separate.

An isolated single mutant changes the uncertainty handler's state from gaptrue
to gapfalse. Patch SHA256
`2852b807562e2b1d733fd4419e62f912dfd9c55fc6341dc2eff17868f1e95ad7`.
At the same seed211549, both generated properties fail on dropped admission
acknowledgment because the Client no longer retains its gap. Run exited2 in
0.3seconds, log `/tmp/overalls-producer-uncertain-ack-mutant.log`. The mutant
production file was restored; the same two properties then passed1.2seconds,
exit0, same seed, log `/tmp/overalls-producer-uncertain-ack-restored.log`. This
is bounded local sensitivity, not a hosted sweep or native durable-commit test.

Dedicated test-module typing initially hit a missing Elixir debug backend, then
external ExUnit/IEx dependency warnings. The production gate is unaffected.
A separate copied dependency PLT is being completed before crediting any
test-module type result; no diagnostics have identified a test-source mismatch
at this stage. Final receipts, hooks and evaluated HLDD are still pending.

## Dedicated test typing and final source self-review

The compiled new test module and all three production client modules passed
dedicated Dialyzer analysis in0.41seconds, exit0, with no diagnostics. Log
`/tmp/overalls-producer-uncertain-ack-own-test-types.log`. Its copied project PLT
includes ExUnit, Logger, IEx and Mix metadata. Dependency construction reports
unknown optional Mix/OTP/EEx/Hex calls; those are outside the analyzed source
scope and are not credited as warning-free dependency verification. The source
analysis does not suppress unknown-function or type warnings. This adds test
module evidence beyond the production-only forced component gate.

Final self-review inspected both properties, fault selection and closed peer
values, production Client/Marker/RPC callees and contracts, private resource
acquisition/cleanup, command attempt ordering, issuer custody, duplicate terminal
refusal, numeric boundaries, failed recovery prefixes and work return/error/throw/
exit preservation. No source/contract mismatch was found in the inspected
scope. No production consumer or wire implementation changed, so consumer
application acceptance is not claimed from these library tests. Fresh-agent
review remains unavailable under the existing thread-capacity limitation.
Final reviewed receipts, hooks and evaluated HLDD results are recorded below.

## Publication gates

All-file hooks passed, including reviewed HLDD receipts, Ruff and ty. Evaluated
Nix HLDD passed38seconds, exit0, archive `1791206411200-2444339-0.jsonl`, log
`/tmp/overalls-producer-uncertain-ack-final-hooks2.log`. Source-derived views,
generated options and ADR138 structural validation passed. The first Nix HLDD
snapshot omitted the newly added test/review before staging and failed references;
it is retained in `/tmp/overalls-producer-uncertain-ack-final-hooks.log`, archive
`1791206221871-2291961-0.jsonl`. Reviewing and staging the complete file set and
refreshing only the affected receipts resolved that snapshot failure. No hook
was bypassed. Existing library/marker/RPC implementations are unchanged.
