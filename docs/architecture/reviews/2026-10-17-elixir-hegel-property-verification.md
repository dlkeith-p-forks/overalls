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
