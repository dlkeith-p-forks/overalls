---
sut_path: /home/ghuntley/src/kittens-antithesis-reset
commit: c835eb1017d24a001215c319373fa4204d64269b
updated: 2026-10-13
external_references: []
scope_answer: "Repository only (Recommended)"
research_started_at_commit: 9fe1e493b2090d44bacd16089049cd12b316d58a
---
# BEAM Antithesis SDK fallback feasibility

Research date: 2026-10-13. Repository inspected:
`/home/ghuntley/src/kittens-antithesis-reset`. This is a design note, not an
implemented SDK, executed harness, or hosted acceptance result. No repository
source was changed. No retired `antithesis/` source or Git history was read.

## Finding and recommended boundary

The documented fallback SDK can supply Elixir/Erlang assertions and lifecycle
signals without an official BEAM SDK or a `libvoidstar.so` dependency. The current
[SDK index](https://antithesis.com/docs/reference/sdk/) lists Go, Java, C, C++,
JavaScript, Python, Rust and .NET; it does not list Erlang or Elixir. This establishes
absence from the documented supported list, not proof that no unofficial or future
BEAM integration exists. The [fallback API](https://antithesis.com/docs/reference/sdk/fallback/)
explicitly covers unsupported languages.

Use a small, typed, harness-only Mix application for property definitions,
independent observations and JSONL generation. Prefer observing real application
interfaces from this application over introducing production control hooks. Keep
its transport outside `protocol/`, outside application Events catalogs and outside
the production release dependency closure. If an internal invariant later needs a
small read-only probe, make its compile/runtime scope explicit, separately review
the governing contracts, and never grant the probe mutation authority.

The fallback is assertion/lifecycle feedback. It does not establish BEAM basic-block
coverage, thread pausing or BEAM symbolization. The official
[coverage page](https://antithesis.com/docs/product/writing_tests/instrumentation/coverage_instrumentation/)
does not list Erlang/Elixir, while the fallback page only mentions additional LLVM
languages. Instrumenting a Rust helper or C runtime does not prove Elixir function
coverage. Hosted validation must name the actual instrumented modules.

## Authoritative transport contract

The [fallback overview](https://antithesis.com/docs/reference/sdk/fallback/) requires
each message to be written **atomically** to
`$ANTITHESIS_OUTPUT_DIR/sdk.jsonl` as one JSON object on one line, followed by a
newline. It is insufficient to emit JSON on stdout, use a different filename,
pretty-print the object, or write the object and newline separately.

The [environment documentation](https://antithesis.com/docs/configuration/the_antithesis_environment/#capturing-output)
says Antithesis injects `ANTITHESIS_OUTPUT_DIR`. Its directory is an output sink:
writes vanish immediately and cannot be read back. Antithesis captures the output
and distinguishes container name and full path. Setting the same environment
variable to an ordinary local directory is explicitly supported for local tests.

Consequences for implementation:

- Construct and validate the complete encoded binary, including its final newline,
  before writing. Reject embedded physical line breaks and oversized records.
- Use append rather than truncation locally. Never rotate, rewrite, truncate,
  reread or attempt atomic-rename publication of `sdk.jsonl`.
- A successful local file append is not an ingestion acknowledgement from
  Antithesis. Neither `fsync` nor a local reread can establish hosted ingestion.
- Container-local files are distinct capture streams. Do not arrange multiple
  containers to share or mount over the injected output directory, or assume an
  assertion emitted by an unprivileged account will have usable permissions.
- The documentation does not specify a byte limit, an acknowledgement protocol,
  precise sink syscall semantics, or atomicity guarantees for a particular OTP
  file function. Those are implementation/hosted-validation questions.

## Exact assertion format

Read together the
[fallback assertion documentation](https://antithesis.com/docs/reference/sdk/fallback/assert/)
and [complete published JSON schema](https://antithesis.com/docs/reference/sdk/fallback/schema/).
The body has the top-level key `antithesis_assert` and these fields:

| Field | Documented wire type | Repository adapter restriction |
|---|---|---|
| `hit` | boolean | `false` for declaration, `true` for evaluation |
| `must_hit` | boolean | Derived solely from a closed assertion kind |
| `assert_type` | string enum | `always`, `sometimes`, `reachability` |
| `display_type` | string | Exact default corresponding to assertion kind |
| `message` | string | Unique reviewed compile-time literal |
| `condition` | boolean | `false` at declaration; actual boolean at evaluation |
| `id` | **string** | Same literal as `message`, stable across source moves |
| `location.class` | string | Fixed module name, or empty string if inapplicable |
| `location.function` | string | Fixed oracle function identity, or empty string |
| `location.file` | string | Actual harness source path, consistent within build |
| `location.begin_line` | integer in prose; number in published schema | Positive integer from the actual assertion call |
| `location.begin_column` | integer in prose; number in published schema | Nonnegative integer, `0` when unavailable |
| `details` | optional JSON object | Omitted for declaration; closed reviewed struct for evaluation |

**A numeric assertion `id` is invalid.** The numeric fields are the source
coordinates; the identifier is a string. The published schema is permissive in
other ways: it does not declare required fields or enforce startup/evaluation
semantics and pair equality. Schema validation alone therefore cannot prove the
full protocol. Supplement it with checks from the assertion prose.

Every declaration has `hit:false`, `condition:false`, no `details`, and the
remaining fields identical to its later evaluations. The complete kind table is:

| Kind | `must_hit` | `assert_type` | `display_type` | Evaluation `condition` |
|---|---:|---|---|---|
| Always | true | `always` | `Always` | Observed boolean |
| AlwaysOrUnreachable | false | `always` | `AlwaysOrUnreachable` | Observed boolean |
| Sometimes | true | `sometimes` | `Sometimes` | Observed boolean |
| Reachable | true | `reachability` | `Reachable` | Always true when reached |
| Unreachable | false | `reachability` | `Unreachable` | Always false when reached |

Illustrative declaration, serialized exactly as one line plus final newline:

```json
{"antithesis_assert":{"hit":false,"must_hit":true,"assert_type":"always","display_type":"Always","message":"Overalls: missing capacity never becomes schedulable capacity","condition":false,"id":"Overalls: missing capacity never becomes schedulable capacity","location":{"class":"OverallsAntithesis.CapacityOracle","function":"check/1","file":"/src/antithesis/workload/lib/capacity_oracle.ex","begin_line":120,"begin_column":0}}}
```

Illustrative evaluation from that same oracle call, also one line plus newline:

```json
{"antithesis_assert":{"hit":true,"must_hit":true,"assert_type":"always","display_type":"Always","message":"Overalls: missing capacity never becomes schedulable capacity","condition":true,"id":"Overalls: missing capacity never becomes schedulable capacity","location":{"class":"OverallsAntithesis.CapacityOracle","function":"check/1","file":"/src/antithesis/workload/lib/capacity_oracle.ex","begin_line":120,"begin_column":0},"details":{"observed_count":3,"unknown_count":1,"schedulable_unknown_count":0}}}
```

The sample file and line are explanatory proposed locations, not existing source
evidence. Implementation must derive real coordinates; do not ship these numbers.
Do not serialize `condition:null` from the pseudocode intermediate object in the
docs. The final condition is always boolean.

## Catalog ownership and generation

The [assertion catalog documentation](https://antithesis.com/docs/reference/sdk/assertion_cataloging/)
requires all assertions to be known at startup so that never-reached assertions can
fail. The fallback page says undeclared evaluations may still be attempted, but
that is not a reason to omit catalog generation.

Proposed contract: one static manifest per harness build enumerates every property
descriptor and its assertion call location. Every property-bearing process loads
the manifest and emits its declaration set before evaluation. The readiness
coordinator can declare the full union before setup, including properties in test
commands that have not yet run; command processes may redeclare their own stable
descriptors at startup. This is deliberate aggregation by identical ID, not a new
property per process lifetime. Generate one immutable union manifest for the entire
run and copy that same fingerprinted artifact into every property-bearing image.
A container's local subset alone must not substitute for the coordinator's full
union catalog.

Create the manifest from a narrow property-definition DSL or explicit declaration
module with compile-time literals. Reject duplicate literal messages across the
entire harness catalog, unknown kinds, dynamic IDs/messages and missing locations.
The runtime evaluation must retrieve its descriptor from this manifest rather
than reconstructing fields independently. Source relocation changes the location
in both records of the new build while preserving the same literal ID/message.
An intentional meaning change gets a new reviewed identity.

Do not derive assertion identities from job IDs, node names, sequence numbers,
timestamps, user data, random inputs or transaction tokens. Do not infer assertions
by translating every existing diagnostic event into an `Always(true)` evaluation:
an event saying work finished is not an independent oracle proving the result.

The fallback docs say only the first true and first false evaluations are useful.
Deduplicate by `{property_id, condition}` **after confirmed full transport write**.
Never mark a false evaluation delivered just because it was queued. A previous
true evaluation must never suppress a later false evaluation. Restart may resend
both declaration and evaluations; identical duplicates have no additional property
benefit, and local exactly-once emission is not necessary for aggregation.

## Proposed typed interfaces

These are interface sketches, not code installed or type-checked in this research.
The production absence and oracle restrictions are design decisions; the wire
mapping above is the documented protocol.

```elixir
defmodule OverallsAntithesis.Property do
  @type key :: :missing_capacity | :stale_outcome | :authorized_request_progress
  @type kind :: :always | :always_or_unreachable | :sometimes | :reachable | :unreachable
  @type t :: %__MODULE__{
    key: key(), kind: kind(), message: binary(), location: OverallsAntithesis.Location.t()
  }
  @enforce_keys [:key, :kind, :message, :location]
  defstruct [:key, :kind, :message, :location]
end

defmodule OverallsAntithesis.Location do
  @type t :: %__MODULE__{
    class: binary(), function: binary(), file: binary(),
    begin_line: pos_integer(), begin_column: non_neg_integer()
  }
  @enforce_keys [:class, :function, :file, :begin_line, :begin_column]
  defstruct [:class, :function, :file, :begin_line, :begin_column]
end

defmodule OverallsAntithesis.CapacityDetails do
  @type t :: %__MODULE__{
    observed_count: non_neg_integer(), unknown_count: non_neg_integer(),
    schedulable_unknown_count: non_neg_integer()
  }
  @enforce_keys [:observed_count, :unknown_count, :schedulable_unknown_count]
  defstruct [:observed_count, :unknown_count, :schedulable_unknown_count]
end

defmodule OverallsAntithesis.SDK do
  @type failure :: :invalid | :oversized | :unavailable | :refused | :timeout | :uncertain
  @type delivery :: :written | :disabled | :duplicate | {:error, failure()}
  @type details :: OverallsAntithesis.CapacityDetails.t() | OtherReviewedDetails.t() | nil

  @spec declare_catalog() :: :written | :disabled | {:error, failure()}
  @spec evaluate(OverallsAntithesis.Property.key(), boolean(), details()) :: delivery()
  @spec setup_complete() :: :written | :disabled | {:error, failure()}
end
```

Replace the example key union and `OtherReviewedDetails` with the actual finite
catalog and individual approved structs. The external-data boundary is validation,
not a broad `map()`/`term()` cast. Validate finite keys, booleans, bounded integers,
string lengths for fixed descriptors, UTF-8, total encoded size and exact per-kind
conditions before constructing a wire record. No arbitrary nested JSON or arbitrary
caller-provided string details are accepted even though Antithesis itself allows
them. Property-specific helpers should narrow which details each key accepts.

The public evaluator receives an already-computed boolean, not a closure with
effects hidden inside it. Assertions may describe observations, but must not own
application work. Production removal or disabled output must never remove a
necessary side effect; the official SDK runtime-mode page explicitly warns that
arguments still evaluate outside Antithesis.

Each oracle needs its own typed observation result, for example
`{:ok, CapacityObservation.t()} | {:error, :unavailable | :invalid | :timeout}`.
An unavailable read is not an observed invariant violation or proof of safety.
Define the property's trigger and treatment of unknown evidence explicitly; never
replace a failed query with empty rows, fabricated zero capacity or `condition:true`.
A separate reachability/progress property can expose an oracle that never acquired
enough valid evidence to evaluate its safety condition.

## Atomic append and concurrency design

Preferred design for the first implementation: a single writer per container,
reached through a bounded harness-local interface. A small typed native helper
(Rust or C) gives a reviewable single-system-call write boundary without installing
a NIF in application BEAM schedulers. A port may use bounded length-prefixed frames;
the helper reconstructs a full frame before touching the sink, rejects malformed
frames and writes the complete newline-terminated record in one append call.
Many BEAM clients and concurrently launched composer commands use that writer;
multiple application/container writers must not share one file.
If separate OS command processes share a container, use one private bounded local
writer endpoint rather than spawning one helper per command. Keep the endpoint
owned by the harness runtime UID with no guest/public listener access. Cross-process
framing, permissions and admission are explicit parts of the transport test scope.

Proposed graph:

```text
Harness property/oracle modules
    -> Harness SDK validator/catalog/encoder
        -> Existing pinned Jason package in harness closure
        -> Bounded container-local writer interface
            -> Small pinned native append helper
                -> Kernel append write to ANTITHESIS_OUTPUT_DIR/sdk.jsonl
    -> Direct /dev/urandom reader for harness choices

Production application releases -> no harness SDK/helper dependency
protocol/ -> no assertion transport or file I/O
Application Events -> existing reviewed diagnostics path only
```

This helper is repository transport code, **not an official Antithesis SDK**.
It does not need the Rust Antithesis SDK merely to write documented fallback
records. Any native ABI/syscall crate must be pinned explicitly; helper-only code
does not establish LLVM/Rust instrumentation. The native helper is optional if a
pure OTP writer is proven to preserve the required atomic boundary in the pinned
OTP build and hosted sink. Calling `File.write/3`, `:file.write/2` or `IO.write/2`
once is not by itself proof that one kernel write occurs.

Set a conservative, explicit record cap (for example 4 KiB) and a fixed admission
cap; these are proposed repository limits, not Antithesis guarantees. A 4 KiB
record must not be justified by `PIPE_BUF` when the final destination is a file or
the special sink. A bare GenServer cast mailbox is unbounded. Admit into a bounded
queue before sending, or use bounded synchronous requests from harness observers.
Synchronous request deadlines alone do not bound a GenServer mailbox. Either path
requires admission before sending and a cap on simultaneous OS clients; reserve
and release slots across sender death, rejection and transport uncertainty.
Keep all assertion writes outside PostgreSQL transactions, ownership locks,
pre-exec regions, signal callbacks, disk streams and terminal-byte critical regions.

The helper reports `:written` only for a full record write. A short write is
`:uncertain` and contaminates the local validation stream; do not append the suffix
and pretend the record was atomic. A known short write poisons that writer/run and
prohibits subsequent SDK output: another record could concatenate with the
unterminated prefix. Report failure through an independent harness status path,
not a new record in the damaged sink. Do not attempt a whole-record retry after a
known short write. Process death after write and before reply also
leaves uncertainty. Retrying the entire assertion can create a duplicate, while
partial output cannot be repaired in the hosted sink. Escalate malformed/uncertain
transport as a harness failure or an explicit incomplete-evidence result, without
changing any SUT result. Do not silently skip safety observations and report green.

There is no documented exactly-once transport ACK. The failure window from observing
an invariant to writing it cannot be eliminated by an in-memory queue. Use direct
harness observations and mutation witnesses to measure this gap; do not claim that
all transient SUT violations are captured. Avoid depending only on an observer
inside the process whose crash the property studies.

## Lifecycle and setup ordering

The exact minimal ready signal from the
[fallback lifecycle page](https://antithesis.com/docs/reference/sdk/fallback/lifecycle/)
is this line followed by a newline:

```json
{"antithesis_setup":{"status":"complete"}}
```

Optional `details` is an object; omit it initially. `{"setupcomplete":true}`,
`{"setup_complete":true}`, a normal log message, an Events catalog event, and
an assertion named setup complete are not the documented lifecycle protocol.

The [Compose setup guide](https://antithesis.com/docs/setup/docker_compose/#add-a-ready-signal-for-fuzzing)
says emit it once the system is up. The
[FAQ](https://antithesis.com/docs/faq/customer_faq/) says Antithesis expects exactly
one setup signal from the system. Assign a single non-restarting harness readiness
coordinator as its owner. Ordinary application `start/2`, every test command and
every container health check must not emit their own signal.

Required preconditions for that owner: all intended containers are healthy,
database migrations/readiness are verified, offline substitutes are reachable,
required initial fixture identities and trust are present, the full property
catalog has been written, and workload execution can begin. These readiness checks
are harness-owned observations, not a bypass of real application readiness. On
failed/missing checks the coordinator withholds setup and returns an explicit
setup error.

The [test command reference](https://antithesis.com/docs/product/writing_tests/test_templates/test_composer_reference/)
states `first_` runs **after** setup, before other commands, with faults stopped.
It expressly forbids emitting setup from `first_`. Bootstrap necessary to make
the system healthy belongs before setup; per-timeline seeding belongs in `first_`
only if the system is already ready without it. `parallel_driver_` and `anytime_`
may run concurrently, which is another reason one writer must accept all command
processes in a container.

Do not retry setup automatically after an ambiguous write or transfer ownership
to another application. With no documented ingestion ACK/idempotency protocol,
an initializer death must produce failed/incomplete setup rather than competing
emitters. A one-shot coordinator with a deployment policy that does not restart
its container or replay its entrypoint after finishing avoids emitting a second
setup signal. An exited BEAM process alone does not establish this guarantee: a
container restart could run the entrypoint again. Verify the actual orchestration
policy and owner lifetime, including independent restarts of other application
containers.

## Randomness

The official fallback and
[random-device documentation](https://antithesis.com/docs/configuration/the_antithesis_environment/#random-devices)
allow direct reads from `/dev/random` or `/dev/urandom`; Antithesis replaces both
with its entropy source and documents identical quality/performance inside the
environment. The [randomness page](https://antithesis.com/docs/reference/sdk/generate_randomness/)
says never use SDK randomness to seed a private PRNG or retain it for a later
decision. Apply the same immediate-decision discipline to fallback device reads.

The harness can expose typed `choose(nonempty_finite_choices)` and
`integer(low, high)` helpers with validated bounds, exact-length device reads,
bounded handling of errors, and an unbiased mapping algorithm. Consume fresh
device entropy when making each choice. Do not call `:rand.seed` once and then use
`:rand.uniform` for an entire workload. Do not assume `:crypto.strong_rand_bytes`
hits the documented devices directly: its OpenSSL/backend caching needs separate
proof, so direct device reads are the clearer fallback interface.

A direct device choice lacks the native SDK's structured-choice feedback. For a
workload that would materially benefit, an observer container using an official
Python/Rust SDK is a legitimate alternative; pin and bake that SDK and its runtime
at image-build time. It supplies assertions from that observer, not a native BEAM
SDK or BEAM coverage. Do not fetch dependencies during hosted execution.

## Existing repository contracts and architecture impact

Read root `AGENTS.md`/`CONTRACTS`, component guidance, architecture overview/index,
ADR-0002, ADR-0017, ADR-0028 and ADR-0149. Relevant current boundaries:

- Root `repository-secret-diagnostics` prohibits credentials, tokens, token URLs,
  encryption keys and terminal contents; test credentials are confined to fixtures.
- Root `repository-test-claim-boundary` requires actual scope; mocks/unit tests do
  not establish VM isolation or physical failure domains.
- `protocol/CONTRACTS` keeps codecs/state/value primitives free of filesystem I/O,
  with narrowly named existing socket exceptions. It is not the SDK home.
- `lilly/CONTRACTS` preserves independent guest lifetime, native execution fencing,
  fixed argv host utilities and secret-free diagnostics.
- `elixir/diagnostics/CONTRACTS` forbids observability acquiring application, DB, VM,
  guest or control authority; exporter failure cannot alter results/locks/receipts/
  recovery. It requires bounded fail-open routine emission and no I/O in native
  critical regions.
- `Overalls.Diagnostics.Events.Catalog` has no string metadata field type. Its
  `emit/2` accepts literal reviewed event names and keys; strict dynamic validation
  rejects unknown/duplicate keys and invalid values. Existing application Events
  catalogs remain the sole path for application diagnostics.
- Marshall/Lilly already use Jason through their dependencies/shared diagnostics,
  while `protocol/` does not depend on JSON encoding or a testing SDK. An existing
  package is not evidence that an SDK assertion integration works.

The all-application review found these existing catalog/dependency boundaries:

| Application | Events catalog | Production diagnostics dependency |
|---|---|---|
| Marshall | `marshall/lib/marshall/events.ex:22` | `marshall/mix.exs:51` |
| Lilly | `lilly/lib/lilly/events.ex:19` | `lilly/mix.exs:38` |
| Audi | `audi/lib/audi/events.ex:19` | `audi/mix.exs:37` |
| Brady | `brady/lib/brady/events.ex:20` | `brady/mix.exs:23` |
| Ziggy | `ziggy/lib/ziggy/events.ex:19` | `ziggy/mix.exs:35` |
| Porsche | `porsche/lib/porsche/events.ex:19` | `porsche/mix.exs:31` |
| Enrico | `enrico/lib/enrico/events.ex:3` | `enrico/mix.exs:33` |
| Galileo | `galileo/lib/galileo/events.ex:19` | `galileo/mix.exs:34` |

No Antithesis dependency appears in these eight current manifests. The schema
generator scans these eight apps only (`elixir/diagnostics/generate_schema.exs:3`,
`:15`); the service type is also finite (`elixir/diagnostics/lib/overalls/diagnostics.ex:9`).
The native spool refuses a service outside its reviewed schema
(`elixir/diagnostics/native/spool/src/main.rs:380`). A new harness assertion service
therefore does not automatically participate in production diagnostics.

Any later event-based probe must use **catalog/service plus event name** as its
identity. For example, `enrico.refresh_succeeded` exists in Marshall's catalog
(`marshall/lib/marshall/events.ex:30`) and Enrico's
(`enrico/lib/enrico/events.ex:10`) with different messages/metadata. Prefix-only
dispatch would select the wrong schema. Similarly, Lilly's committed transition
event uses custody (`lilly/lib/lilly/events.ex:558`), whereas Marshall's similarly
named event uses routine delivery (`marshall/lib/marshall/events.ex:380`). Neither
diagnostic delivery mode is an assertion result or authorizes domain progress.

Any future adapter-local application diagnostic must first add an appropriate
`defevent` entry with safe numeric/finite metadata, then emit through the owning
Events catalog. Do not enlarge that shared catalog to unrestricted string payloads
to carry Antithesis `details`. The harness's separate property catalog owns reviewed
assertion literals and property-specific numeric details; application credentials,
terminal bytes, command arguments, request bodies, exception messages and user
payloads never cross this boundary. Assertions follow committed observations when
claiming committed outcomes.

Before implementation, use `node scripts/check_contracts.mjs list` for each target,
manually resolve adjacent/enclosing notes (native Elixir discovery is lexical),
read called-library contracts, and add a narrow harness `CONTRACTS` scope. Suggested
new obligations: static property identity/catalog completeness; exact per-kind
wire semantics; one complete atomic record per successful write; bounded producer
admission; no SUT authority; no output when disabled; closed details schemas;
exactly one readiness owner; random choices read entropy at the decision boundary.
Owner is `ghuntley`, already verified in `docs/code-contracts.md`; do not add notify
metadata without instruction.

This read-only research changes no architecture or implementation status. A future
harness-only implementation should preserve ADR-0002/0017/0028/0149, but introduces
verification/deployment behavior and a testing dependency boundary. Review its
final graph with architecture-review and maintain the HLDD/scenario gaps in the
same change. Source hooks that change authority, persistence, recovery or protocol
semantics need substantive review rather than being labeled instrumentation.

## Verification plan and open acceptance gaps

1. Validate the generated catalog against the retrieved official schema **and**
   stricter semantic tests: every required field, string ID, kind mapping, exact
   declaration/evaluation identity/location equality, booleans, omitted startup
   details, and full newline-terminated one-line records. Negative tests include
   numeric ID, null condition, duplicate literals, unknown details and wrong setup
   signal. A passing schema validator alone is insufficient.
2. Exercise no-output mode with `ANTITHESIS_OUTPUT_DIR` absent: no SDK file, no
   native helper launch, no stdout surrogate, no application mutation. Empty or
   invalid configured paths must be classified separately as misconfiguration,
   without exposing their contents. Production releases exclude the dependency.
3. Run concurrent producer tests across BEAM processes and separate command OS
   processes against one local sink. Check exact expected complete-line counts,
   parseability, full writes and first-true/first-false behavior. Test unavailable
   writer, full bounded admission, invalid record, delayed response, short write,
   producer death, helper death and helper restart. Measure evidence-loss windows.
4. Inspect actual write syscall traces on the pinned OTP/helper build, including
   max-size records and failure injection. Do not infer atomic writes from one
   high-level function call. This proves only the observed local transport scope.
5. Verify readiness withholding on every missing prerequisite, complete catalog
   before the signal, exactly one minimal lifecycle record, no setup emission from
   `first_`, and no duplicate after application restarts. Classify ambiguous setup
   writes as failed/incomplete, without automatic duplicate emitters.
6. Test direct entropy reads and choice mapping: bounds/refusals, short reads,
   device unavailability and no private PRNG continuation. Harness unit tests can
   inject a typed entropy source; hosted exploration still needs real devices.
7. Build offline amd64 images and confirm permissions and private container-local
   writer endpoints with the final runtime UID. Locally run all composer commands,
   including their concurrency combinations, without network access to the world.
8. Enter the pinned `devenv shell`; run compilation with warnings as errors,
   formatting, meaningful generated/concurrency tests and forced Dialyzer for the
   new harness project and changed consumers. Run contract syntax/discovery and
   semantic review, reviewed logging gates, ADR checker, HLDD/generated-reference
   gates and the Nix `hldd` check. All changed projects run their `mix precommit`;
   protocol changes, if any, require both consumers as well as the library.
9. A small hosted baseline must demonstrate catalog presence (including an
   intentionally unhit required property), true/false evaluation attribution,
   the single setup transition, final-UID writes and the real sink's behavior.
   Identify source/config/image fingerprints. Confirm actual module coverage
   separately; do not claim BEAM coverage from JSONL or a helper's instrumentation.
10. Mutation testing must confirm a real independent oracle fires for a realistic
    targeted SUT defect. Pure encoder tests and deliberate SDK `false` calls prove
    transport, not that the oracle detects the system bug. Preserve native KVM,
    ZFS, guest isolation and physical multi-host evidence as separate requirements.

Completed here: repository/contract review and official-document retrieval.
The supporting review ran the repository read-only `checkFiles` adapter over root,
all eight application contracts/catalog sources and the shared catalog, tracing,
custody and privacy sources; selected contract syntax validation passed. It also
ran source-note/ancestor discovery for `events/catalog.ex`. These are scoped
structural/discovery checks plus manual semantic review, not application gates.
Not
completed: implementation, static typing execution, local concurrency/syscall
verification, images, readiness execution, hosted ingestion or mutation witnesses.
The feasibility conclusion is therefore conditional on these specific acceptance
checks; no launch or approval is implied by this note.

## Retrieved sources

All Antithesis sources above were retrieved using `snouty docs` on 2026-10-13.
Copies for the research handoff live under
`/home/ghuntley/src/kittens-antithesis-reset/antithesis/scratchbook/sdk-docs/`. Documentation uncertainties
are preserved explicitly rather than filled with assumptions.

- [SDK index and runtime modes](https://antithesis.com/docs/reference/sdk/)
- [Fallback SDK transport](https://antithesis.com/docs/reference/sdk/fallback/)
- [Fallback assertions and catalog semantics](https://antithesis.com/docs/reference/sdk/fallback/assert/)
- [Published assertion JSON schema](https://antithesis.com/docs/reference/sdk/fallback/schema/)
- [Fallback lifecycle](https://antithesis.com/docs/reference/sdk/fallback/lifecycle/)
- [Assertion catalog](https://antithesis.com/docs/reference/sdk/assertion_cataloging/)
- [Randomness](https://antithesis.com/docs/reference/sdk/generate_randomness/)
- [Environment, output sink and random devices](https://antithesis.com/docs/configuration/the_antithesis_environment/)
- [Coverage instrumentation](https://antithesis.com/docs/product/writing_tests/instrumentation/coverage_instrumentation/)
- [Test-command scheduling](https://antithesis.com/docs/product/writing_tests/test_templates/test_composer_reference/)
- [Exactly one setup signal FAQ](https://antithesis.com/docs/faq/customer_faq/)
- [Compose ready signal](https://antithesis.com/docs/setup/docker_compose/)
