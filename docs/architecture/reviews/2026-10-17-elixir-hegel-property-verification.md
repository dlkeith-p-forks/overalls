# Elixir Hegel property verification review

## Scope and impact

This review covers migrating the Elixir property suite from StreamData to the
pinned Hegel binding and adding model/history and controlled-concurrency APIs.
The change is confined to test dependencies and test support. It adds no Ash
domain, resource, protocol, persistence, authorization, host, or deployment
boundary. ADR-0191 records the accepted verification policy.

## Required evidence

Every migrated property must have bounded generators, a stable seed, replayable
case data, and redacted failure output. Fixture-backed properties must perform
per-case setup and teardown, including process, SQL sandbox, socket, and
supervision cleanup. Stateful properties must name the model and oracle; pooled
or concurrent properties must record the schedule boundary and must not claim
linearizability without a model check.

The normal application gates remain authoritative: compiler, ExUnit, Dialyzer,
contracts, logging, ADR and HLDD checks. Protocol changes require both Marshall
and Lilly consumer gates. Native Hegel smoke tests verify load, replay, shrink,
redaction, task cleanup, and state-machine behavior before migration results are
recorded.

## Limits and gaps

BEAM Hegel execution cannot establish native isolation, KVM behavior, physical
recovery, or production deployment. Those claims remain covered by NixOS and
native suites. A dependency declaration or unexecuted property is not evidence
of passing verification. Inception failures remain out of scope under the root
repository guidance.

## Protocol migration repair

The initial protocol repair retained the reviewed `6a62795` dependency pin and changed
test code, test support and test-file discovery only. Production codecs, native
admission, wire versions, application dependencies and deployment authority are
unchanged. ADR-0191 remains accepted and partially implemented.

The AST-assisted conversion replaced 85 nested `property`/`check all` runners
with a single Hegel runner, explicit original case counts, labelled draws, fixed
seeds, disabled databases and suppressed replay blobs. Terminal, envelope and
WebSocket properties use the same form. Filter clauses become explicit
assumptions. Native `list(..., min: ..., max: ...)` and `tuple([...])` generators
retain collection bounds and exact IPv4 widths. Typed helpers preserve string
alphabets and lengths, bounded Unicode/compound peer terms, and the complete
unsigned 64-bit GUID/refusal ranges using bounded 32-bit halves.

The local draw boundary records literal labels and redaction markers through
the native test-case API, then draws silently. A failure/replay regression
verifies that the synthetic payload stays out of the native printer and the
original exception is preserved. Control transport properties register cleanup
for their listeners, supervised children and queued fixture messages. A second
negative control intentionally fails a real socket fixture and verifies at
least two native executions, restored supervision/process links, and no queued
protocol events after replay. These properties use the shipped `ci` profile so
their existing bounded 61-second transport observations retain their assertions
without triggering the engine's 30-second input-generation health check.

Recorded focused executions with the pinned native engine:

- Terminal and native terminal smoke: **17 passed**.
- Terminal, envelope, WebSocket and redaction regression: **26 passed**.
- Generator compatibility across eight pure test files: **46 passed**.
- Failure/replay fixture-cleanup negative control: **1 passed**.

The pre-merge protocol `mix precommit` at frontend `6a62795` passed on
2026-10-17: **299 passed** (6
StreamData properties and 293 tests, including the Hegel properties) in 408.3
seconds; Covenant reported **14/14** obligations covered; Dialyzer reported **0
errors, 0 skipped and 0 unnecessary skips**. The shared contract validator's
**19 tests passed**, and compiler and formatting checks passed. Its command ran
inside the repository's pinned `devenv shell`, with `ERL_FLAGS="+S 4:4"` and
`HEGEL_NIF_PATH=/tmp/overalls-native-hegel-nif-6a62795/release/libhegel_nif`.
The local native library SHA-256 is
`a15b9b5f96c0aa804cf8f4a153bcb2fe913006d7e97b85c0e47ff55c83a3a684`.
The protocol source aggregate SHA-256 (`rg --files protocol | sort | xargs
sha256sum | sha256sum`) stayed
`152256c29de5f1b47568c3fa1ae379f69ff770961b69634111b73e6710efe607`
throughout the final gate.
The execution log is `/tmp/overalls-native-protocol-hegel-precommit-final.log`;
it is local execution evidence, not a retained native-guest acceptance artifact.

The upstream merge advances the frontend to
`2c9f7a4a9f2cf156de063bbc8058bcf297be5cf0`. The reviewed upstream delta changes
only the Elixir binding's context handling and generator compatibility; the
native engine and the native library above are unchanged. The merge preserves
the seeded single runners, redacted draws, complete unsigned GUID generation
and original out-of-range refusal fixtures. It retains the six StreamData View
and workspace-source properties with their broad generators and assertions:
the upstream mechanical migration instead narrowed generated sources and
integer boundaries, so it did not provide equivalent coverage. The complete
merged-pin protocol gate passed on 2026-10-17: **299 passed** (6 StreamData
properties and 293 tests, including Hegel properties) in **410.8 seconds**,
with Covenant **14/14**, Dialyzer **0 errors, 0 skipped and 0 unnecessary
skips**, the shared contract validator's **19 tests passed**, and compiler and
format checks passed. Its execution log is
`/tmp/overalls-native-protocol-hegel-merged-precommit.log`, against source
aggregate `c17753a49b4ef02f6243ece724b32ef5aaf87aa8ab129e133754d46b9f9d7987`,
which stayed unchanged throughout the gate.
The historical 299-test result and its exact source hash above apply only to the
pre-merge frontend pin.

Protocol's workspace-source and View properties still use StreamData. The
pinned binding does not implement every accepted stateful/concurrent API.
Consumer gates and native-engine smoke/replay obligations keep their separate
scope and records; this checkpoint does not claim migration completion or any
new guest, TLS, isolation, storage-recovery or fleet acceptance.

## 2026-10-18 consumer checkpoint

The [current matrix review](2026-10-18-guest-os-matrix.md) retains later count,
fixture, generator and health-check repairs and their failed/focused runs.
On frontend `02cd8bd5bf07a7ca1bfaf7d599456fff5badbfa2`, the complete protocol
gate passed 302 tests with Covenant 14/14 and zero-error forced Dialyzer;
Lilly passed 610 tests with Covenant 15/15 and zero-error forced Dialyzer.
The final repaired Marshall gate passed 1,694 tests with four exclusions in
1,540.6 seconds, seed 156566, Covenant 24/24 and forced Dialyzer with zero
errors/skips in 59.03 seconds. Its log is
`/tmp/overalls-os-matrix-marshall-confirmation2.log`; the final repair sources
were committed as `b84ac6277`.

Upstream `0ed3c8151` then advanced every frontend to
`f1ad336e4be1f0b3e18e429f8bc826d538b40601` and refreshed Mix dependency
hashes. Its native engine is unchanged, but its context/options macro still
failed a bounded actual-compilation probe while a plain-property control
passed. Existing ordinary ExUnit workarounds remain required. Focused new-pin
protocol and Marshall checks passed; complete new-pin gates retain separate
records and cannot inherit the prior pin's results. The matrix review records
the exact probe and execution scope. ADR-0191 remains partial.

The complete `f1ad336` Marshall run subsequently failed only the shared-lock
property's native TooSlow heuristic: 1,693/1,694 passed, four excluded,
1,526.1 seconds, seed 770435. Covenant 24/24, both JavaScript suites, Monospace
and forced zero-error Dialyzer passed. The next frontend `08cd428`, resolved
as `08cd4289b8b268ae14176e3391c791647e8affae`, preserves the native engine and
corrects context macro traversal/metadata. Its bounded three-form context
compilation/runtime probe passed; the scoped CI-profile lock property passed
without reducing its two cases or three rotations. Actual resolution normalized
all eleven source locks, and all eight refreshed fixed-output snapshots and
independently computed recursive NAR hashes now match. These focused and
dependency-custody results do not replace complete consumer execution. The
matrix review records exact failed and focused scopes and receipt identities.

The complete `08cd428` Marshall gate then passed **1,694 tests**, with four
exclusions, in **1,382.3 seconds**, seed **325708**. Covenant passed **24/24**,
terminal JavaScript **36/36**, presentation JavaScript **9/9**, Monospace and
forced Dialyzer with **0 errors, 0 skipped and 0 unnecessary skips** in
**49.65 seconds**. The command exited zero under a 6 GiB, zero-swap scope.
Its frozen runtime source ledger remained unchanged through `439a71e96`;
this pre-machine-pin execution does not verify the later `132bc28b5`
integration. The matrix review records the exact log and ledger digests;
complete merged-source consumer gates remain separate. ADR-0191 remains partial.

The final `132bc28b5` protocol gate passed **303 tests** in **420.6 seconds**,
seed **476754**, with Covenant **14/14**, shared contract tests **19/19**, and
Dialyzer **0 errors, 0 skipped and 0 unnecessary skips** in **2.77 seconds**.
The frozen runtime source ledger checked unchanged after the command exited
zero. The matrix review records exact log and ledger digests.

Final frozen `132bc28b5` Marshall execution subsequently exited zero with
**1,712 passed, four excluded**, seed **576982**, in **1,413.8 seconds**.
Covenant passed **27/27**, terminal/presentation JavaScript **36/36** and
**9/9**, Monospace, and forced Dialyzer with **0 errors, 0 skipped and
0 unnecessary skips** in **51.78 seconds**. The runtime ledger checked
unchanged; this includes machine-pin integration and excludes subsequent
fixture-script/CSS corrections. Final Lilly and Porsche gates subsequently
passed 610/100 tests, Covenant15/15 and4/4 and zero-error forced Dialyzer;
the frozen runtime ledger remained unchanged after all four consumer gates.
The matrix review retains the exact log and ledger digests. Migration and
native guarantees remain partial under ADR-0191.

The subsequent integration of upstream `d18a6f11e` imports three Enrico test
files with eleven property declarations explicitly selecting one generated CI
case. Assertions and fixed restart/saturation/refresh loops remain intact;
inner compatibility `max_runs` values do not preserve the former generated
counts. This reduces randomized exploration and carries no new passing Enrico
execution record. Enrico is outside the unchanged four-consumer runtime ledger
and cannot inherit its passing results. The import changes verification scope
only; ADR-0191 remains accepted/partial with unchanged production contracts.
