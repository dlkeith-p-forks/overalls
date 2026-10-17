# Antithesis property test audit

## Scope and architecture impact

The working audit (`antithesis/scratchbook/property-test-audit.md` at kittens revision `9fe1e493`, repository deleted)
tracks all 63 research candidates against current source and tests. This batch
adds generated local checks for the Lilly journal attempt ordering and
superseded executor results, Marshall host report ordering, CLI approval and
expiry, terminal peer budget reclamation, and Ziggy receipt retention through
restart. That generated-test batch changes no production protocol, persistence
format, authorization rule, Ash resource or deployment topology. A subsequent
property exposed one production error-class defect: malformed clone JSON used a
different decoder and returned transient 503. The clone route now uses the
bounded protocol decoder shared by every other v3 action and returns permanent
400 `invalid_message`. This restores the
[ADR-0012](../decisions/0012-provisioner-control-transport.md) bounded
validation contract carried forward by
[ADR-0035](../decisions/0035-zfs-only-provisioning.md); no wire schema or
accepted decision changes. It adds verification evidence for the existing actor
recovery decision in [ADR-0017](../decisions/0017-durable-vm-actors-and-host-ownership.md)
and the capacity freshness and reservation boundary in
[ADR-0006](../decisions/0006-capacity-accounting.md), plus the bounded Ziggy
accounting rule in
[ADR-0063](../decisions/0063-private-services-and-ziggy.md). Their accepted rationale
and implementation statuses are unchanged. The new audit-stream tests add
evidence for [ADR-0074](../decisions/0074-durable-lifecycle-state-machines.md),
the CLI histories for [ADR-0101](../decisions/0101-browser-approved-agent-cli.md),
and peer-budget reclamation for
[ADR-0083](../decisions/0083-terminal-host-stream-and-registry.md).
The added listener property exercises the existing public/fleet route boundary
under [ADR-0091](../decisions/0091-fleet-perimeter-public-listeners.md); it does
not change listener placement or authenticated transport. The generated version
refusal property checks the ADR-0012/0035 fail-closed control boundary before a
durable host transaction.
Ziggy's completion reply mapping now preserves Marshall's existing
`completion_conflict` class and exposes it in its catalogued retry event while
retaining the disputed spool receipt. This stays within ADR-0063's bounded,
idempotent accounting decision and changes no wire payload or usage totals.
The generated ingress history exposed a mismatch with
[ADR-0105](../decisions/0105-public-audi-wildcard-custody.md): after the same
gateway service rotated its credential, the old installation row prevented a
fresh acknowledgement of the still-active wildcard. The repair permits only a
newer generation of that same authenticated service and exact fingerprint to
rebind the single Ash installation row. The internal action is explicitly
allowed for the trusted coordinator and PaperTrail retains the update. Old
credentials, other service identities and conflicting fingerprints remain
refused. This changes recovery and authorization behavior within the accepted
decision, with no new storage table or wire payload.

## Test evidence

The generated Lilly actor tests block the executor after invocation, inspect
the persisted journal before allowing any result, then exercise supersession
with newer generation or epoch and start or stop intent. A stale executor
result must publish no outcome; the new result must retain its exact revision
and survive actor restart. On 2026-09-29,
`mix test test/vm/actor_test.exs` passed **19 tests (3 properties, 16 tests)**
inside the pinned `devenv shell`.

The durable Antithesis fake now refuses stop and delete evidence for an unseen
incarnation. A generated command history exercises replay, stop, delete,
generation advance and unseen commands, verifying that physical observations
always have a matching persisted launch marker and that refused commands do
not alter state. The oracle is an independent command model and alternating
commands execute in short-lived processes. On 2026-09-29,
`mix test test/vm/fake_executor_property_test.exs` passed **1 property** in
`devenv shell`. The fake still does not model native
storage, guest crashes or the full executor retry classes.

The generated Marshall report property applies histories of accepted,
duplicate, older, old-epoch, partial and reconnect actions to real Ash and
PostgreSQL resources. Every rejected report must leave the host and pool
capacity snapshots identical, while accepted reports publish their exact host
capacity and pool storage values. Reconnect increases the epoch and clears
host freshness. On 2026-09-29,
`mix test test/marshall/compute/host_reports_test.exs` passed
**7 tests (1 property, 6 tests)** inside `devenv shell`. These are database fixture checks;
they do not prove native host telemetry or fleet transport behavior.

The generated lifecycle audit histories apply accepted events, lost-ACK
reoffers, sequence gaps, conflicting bytes and stale sessions to the real
PostgreSQL ingestion path. After every prefix the event inventory must equal
the durable cursor with no gap or duplicate. On 2026-09-29,
`mix test test/marshall/compute/lifecycle_audit_test.exs` passed
**10 tests (1 property, 9 tests)** in `devenv shell`. This does not exercise
Lilly's outbox, a real Marshall restart or audit expiry in the same generated
history.

The generated Lilly outbox property offers a bounded journal batch, appends
new events after the offer, acknowledges an arbitrary subset twice and compares
the exact remaining event maps with the reloaded journal and next offer. On
2026-09-29, `mix test test/lifecycle/journal_test.exs` passed
**7 tests (3 properties, 4 tests)** in `devenv shell`. The third generated
property fills the 64-event journal, checks byte-identical refusal, then
acknowledges a generated prefix and verifies exact resumed publication. This checks the local
producer half of the audit stream; it does not exercise cross-service delivery.

The generated Ziggy spool property fills a bounded set of slots with completed
receipts, acknowledges an arbitrary subset, restarts the spool, and verifies
that every unacknowledged receipt remains byte-identical on disk while exactly the freed slots
can be reused. On 2026-09-29, `mix test test/spool_test.exs` passed
**5 tests (1 property, 4 tests)** inside `devenv shell`. It does not exercise a real
Marshall acknowledgement outage or reporter timing.

Ziggy's full `mix precommit` then passed **44 tests (4 properties, 40 tests)**
with zero Dialyzer errors. The gate first exposed a pre-existing unformatted
line in `ziggy/test/update_artifact_test.exs`; that line was formatted without
changing its assertion or behavior before the successful rerun.

The generated Marshall CLI approval histories compare accepted and refused
digests with exact session and audit inventories, including member withdrawal
while owner approval remains possible. The expiry property checks retained live
sessions, removed expired sessions and idempotent receipts. On 2026-09-29,
`mix test test/marshall/agents/agent_revocation_history_test.exs` passed
**9 tests (3 properties, 6 tests)** in `devenv shell` with four BEAM schedulers.
This is database-backed authorization evidence, not browser or native CLI
transport acceptance.

The terminal peer budget property saturates generated limits of two to eight
slots, kills an arbitrary nonzero set of owners and checks exact reclamation,
replacement admission, renewed saturation and full reuse. On 2026-09-29,
`mix test test/marshall/terminal/peer_budget_test.exs` passed
**3 tests (1 property, 2 tests)** in `devenv shell`. Its process-level scope
does not establish distributed socket behavior under a partition.

The Lilly guest identity property derives the expected MAC, gateway and reserved
UID from the protocol's address octet across all four profiles and generated
slots. It catches a permutation of Lilly's local profile mapping that would
preserve uniqueness while silently mixing profile identities. The network
guard's MAC rule is checked too. On 2026-09-29,
`mix test test/network/identity_test.exs` passed **7 tests (5 properties, 2 tests)**
in `devenv shell`. This verifies local derivation, not the bytes
observed inside a native guest.

Lilly's full `mix precommit` passed **441 tests (63 properties, 378 tests)**
with zero Dialyzer errors after this addition.

Marshall's full `mix precommit` completed **1342/1343 tests (168/168
properties, 1174/1175 tests)** with zero Dialyzer errors. The one failure was
the unchanged `Marshall.Access.CustomerIsolationTest` fixture receiving
`:machine_identity_mismatch` when it opened an OSS terminal fixture. A focused
rerun of that file in the same test partition passed **5 tests (2 properties,
3 tests)**. The full suite result remains a failure; the focused pass limits
the evidence to a suite interaction rather than proving the gate green.

`snouty validate antithesis/config --timeout 120`, `elixir scripts/check_adrs.exs`,
the HLDD receipt, coverage, option and view checks, and
`nix build .#checks.x86_64-linux.hldd` passed for this worktree. The validation
establishes harness setup completion, not a hosted fault-injection result.

The provisioner API property generates malformed JSON forms and posts each to
all 18 v3 actions, including clone. Every response must be the permanent 400
`invalid_message` class and the authenticated host row must remain unchanged.
Before the decoder fix, the clone case entered the opaque 503 internal-error
arm. A second property generates retired URL and wrong body versions for session
and exchange requests. Each refusal must preserve the exact host and operation
rows, and the next valid session must advance exactly one epoch. On 2026-09-29,
`mix test test/marshall_web/provisioner_api_test.exs` passed
**8 passed (2 properties, 6 tests)** in an isolated test partition. These check
the Marshall HTTP boundary; a real Lilly retry loop and concurrent malformed
traffic remain untested.

The generated listener property permutes machine API paths, methods and host
headers against the public ingress plug, then browser paths against the fleet
plug. Cross-listener traffic receives uncached 404 with no cookies or redirect,
and the public ingress has not read the supplied body. On 2026-09-29,
`mix test test/marshall_web/fleet_endpoint_test.exs` passed
**5 passed (1 property, 4 tests)**. This tests the plug chains locally; live TLS
listeners, purpose credentials and injected faults remain untested.

The generated Ziggy reply-class property varies route, HTTP status and returned
error name. Only a 409 `completion_conflict` on the completion route receives a
distinct durable-conflict class; malformed or unrelated responses retain their
other classifications. On 2026-09-29,
`mix test test/control_response_test.exs` passed **2 passed (1 property, 1 test)**.
The reporter now emits `ziggy.accounting_retry` with reason
`:completion_conflict` and keeps the receipt. This is local mapping evidence;
lost-response replay through Marshall and live reporter drain remain untested.
Generated Marshall completion histories then alternate identical replay and
conflicting bytes after one committed completion. Every prefix preserves the
exact request row and one daily usage increment. On 2026-09-29,
`mix test test/marshall/inference/requests_test.exs` passed
**7 passed (1 property, 6 tests)** in an isolated PostgreSQL test partition.
The two local properties do not yet compose the client and server over HTTP.
Ziggy's full `mix precommit` passed **46 tests (5 properties, 41 tests)** with
zero Dialyzer errors after this change.

Marshall's next full `mix precommit` reached **1314/1315 tests (169/170
properties, 1145/1145 tests)** with 30 invalid distributed cases and zero
Dialyzer errors. The property failure was a reproducible gateway rotation
history: acknowledgement of the same active wildcard returned
`:invalid_binding` after the service generation advanced. A focused rerun with
seed `375698` reproduced it. The 30 invalid cases failed during remote BEAM
startup with `Marshall.Accounts` reported as not a Spark DSL module; they do
not validate or invalidate their assertions. The same worktree was recompiled
by focused tests while this gate ran, a plausible cause of the peer startup
failure; that cause is not yet proven. After the guarded rebind change,
`mix test test/marshall/ingress/history_test.exs
test/marshall/ingress/fleet_certificate_test.exs --seed 375698` passed
**8 passed (1 property, 7 tests)**. A fresh full Marshall gate is required
for this corrected tree.

An uninterrupted full Marshall `mix precommit` on the corrected tree reached
**1346/1347 passed (172/172 properties, 1174/1175 tests)** with two excluded,
no invalid cases and zero Dialyzer errors. Its sole failure was the recurring
Customer isolation test fixture: a second synthetic host could lose admission
to the first host, then the helper tried to open the first host with the second
host's machine identity. The same failure reproduced alone. The test now
provisions the OSS comparison VM on an eligible host directly, preserving its
authorization and lifecycle assertions without a second host session.
The focused `customer_isolation_test.exs` rerun passed **5/5 (2 properties,
3 tests)**. This fixture correction has no architecture impact and changes no
production behavior. The full merged Marshall `mix precommit` then reached
**1356/1357 passed (175/176 properties, 1181/1181 tests)** with two excluded,
zero Dialyzer errors and one unrelated MFA login history property timeout at
its 120-second limit. A focused rerun in an isolated test partition also timed
out at 120 seconds while exercising real LiveViews and Ash reads. With only its
module timeout raised to 240 seconds, the unchanged generated property passed
in **109.6 seconds (1/1)**; the higher limit leaves headroom for loaded CI
hosts. The original full gate cannot be described as passing.

The existing Lilly journal property also checks delayed acknowledgements
across reopen, and the prior generated actor properties cover completed replay
and a seeded attempted marker. Their narrower scopes are retained in the
working audit. The audit does not treat candidate prose copied from an older
tree as current proof; source and tests must be reconciled per row.

## Terminal output sequence gap follow-up

The generated HostStream history exposed a terminal recovery defect: a future
output sequence was silently discarded while its viewer channel stayed open.
Subsequent output then remained behind the missing sequence. HostStream now
closes only that viewer channel, tells its viewer the attachment ended and
returns a `channel_close` control to Lilly. Replayed older sequences still have
no effect. This applies ADR-0083's bounded reconnect and scrollback design to
the output-gap path; it changes no wire frame, Ash authority or deployment
topology. The local property drives actual frame decoding and viewer messages;
Lilly interruption and browser reattachment still require composed and native
evidence. The focused `mix test test/marshall/terminal/host_stream_test.exs`
passed **8/8 (1 property, 7 tests)** with generated gaps from sequence 3
through 64. The follow-up Marshall `mix precommit` passed
**1358/1358 (177 properties, 1181 tests)** with two excluded and zero Dialyzer
errors before the MFA timeout setting changed. The timeout-only edit has a
separate passing focused run; the full gate result applies to the earlier
120-second setting.

## Audi DNS publication history follow-up

The local Audi DNS property generates accepted route and proof publications,
withdrawals, stale and conflicting revisions, expired publication attempts,
independently expired routes and malformed snapshots. After each prefix it
compares real UDP and TCP A/TXT payloads, response codes and authority flags
with the latest accepted publication.
`mix test test/dns_replica_test.exs` passed **5/5 (1 property, 4 tests)**.
Audi's full `mix precommit` passed **161/161 (38 properties, 123 tests)** with
zero Dialyzer errors.
Marshall's `mix precommit` also passed **1358/1358 (177 properties, 1181 tests)**
with zero Dialyzer errors. This adds local wire evidence for the existing Audi authoritative DNS boundary
under ADR-0085 and ADR-0090. It changes no production behavior, protocol,
deployment placement or accepted decision. Live snapshot expiry, cross-host refresh
and public delegation remain unverified by this property.

## Audi stream guard lifetime follow-up

The generated Audi StreamGuard property shuffles seven independent local lease
and guard cases. Each case first echoes bytes over a real TCP socket,
then checks owner death and socket closure after expiry, delayed expired
renewal, changed binding, revocation, guard loss or suspension. Stale renewal
is refused while the owner remains live, followed by explicit revocation.
`mix test test/stream_guard_test.exs` passed **8/8 (1 property, 7 tests)**.
Audi's full `mix precommit` passed **162/162 (39 properties, 123 tests)** with
zero Dialyzer errors. This adds local enforcement evidence for the existing
Audi lease boundary inherited by ADR-0105 from ADR-0047. No production code,
protocol, deployment placement or accepted decision changed. The SSH channel's
frame gates, multi-action timing on one stream, real Marshall renewal under
faults and cross-role satellite lifetimes remain unverified by this property.
The existing HLDD network chapter
now records the local guard scope; no user-facing scenario claim changes because
the property does not drive a complete gateway journey.
Marshall's `mix precommit` passed **1358/1358 (177 properties, 1181 tests)**
with zero Dialyzer errors. An earlier full run failed only in the existing
Galileo audit-order assertion: sorting `DateTime` structs by Erlang term order
can put a later second before an earlier one. The test now sorts by Unix
microseconds. Its focused file passed **12/12**, and the full Marshall rerun
passed. This is a test-oracle correction with no production or architecture
impact.

### Same-stream renewal history

A second generated StreamGuard property reorders stale renewal, an obsolete
expiry message and a later accepted renewal after first accepting a renewal on
one TCP owner. It checks continued echo and deadline stability, then checks
owner death and socket closure after revocation, an expired reply or changed
binding. The focused suite passed **9/9 (2 properties, 7 tests)**. This extends
local Audi lease evidence under ADR-0105 and ADR-0047 without changing an
accepted decision or production behavior. It does not establish SSH frame
fencing, owner survival past the former deadline after renewal, a partitioned
Marshall renewal, or a cross-role satellite lifetime.
Audi's final `mix precommit` passed **163/163 (40 properties, 123 tests)**
with zero Dialyzer errors. Marshall's full gate passed **1361/1361
(177 properties, 1184 tests)** with zero Dialyzer errors after the handbook
update.

The current Lyra supervisor test also contains generated format,
missing-interpreter and early-exit candidate histories for staged and
interrupted activation, plus generated active-work drain histories. The audit
now credits their inode, digest, rejection and later retry assertions under
ADR-0104. It remains partial because the tests do not present a
schema-incompatible Marshall registration response or deployed version skew.

## ACME propagation classification follow-up

The existing Boolean propagation check hid transport, absent proof, malformed
DNS, expired TTL and proof mismatch behind one retry result. Its new typed
`check/3` keeps these classes distinct, with `invalid_request` and
`local_defect` for local failures. The certificate coordinator emits only the
closed cause atom and certificate identity after its proof transaction, then
keeps the accepted retry behavior. A generated loopback DNS-over-TCP property
checks success and five negative response classes over one and two configured
replicas. The focused run passed **3 checks (2 properties, 1 test)**. This
extends ADR-0105's stalled-generation observability without changing custody,
proof acceptance, activation or deployment topology. Hosted faults, production
delegation, issuer tick timing and escalation remain open.

## Lilly launch-attempt interruption follow-up

The fake executor now has a test pause immediately after its durable attempt
marker. A generated property kills the real Lilly actor at that pause, checks
that its journal has the attempt but no outcome, then starts a replacement.
The replacement fences the generation as failed; exact replay retains that
outcome and the fake attempt count remains one. The focused file passed
**3 properties**. This extends local ADR-0017 recovery evidence without
changing production behavior or the accepted decision. Full Lilly death,
systemd launch, launch guard, Firecracker and native storage remain outside
the fake executor's scope.

## Admission atomicity follow-up

The generated Marshall property shuffles twelve database insert-failure stages
for both CPU request shapes, compares the complete committed public-table
inventory after each refusal, then verifies linked VM, placement, reservation,
address, agent, ingress, provision operation, create audit version and dispatch
job rows after a later success. Exact replay and changed-shape conflict leave
the inventory unchanged. The focused run reported **1 passed, 41 excluded**.
This extends local transaction evidence under ADR-0010, ADR-0014 and ADR-0050
without changing production behavior or an accepted decision. Process death
around commit, cross-node retries, optional
workspace source and Inception environment writes, and native job execution
remain unverified by this property.

## Galileo single-attempt upload follow-up

The generated Galileo property varies TLS upload chunk sizes around 16 KiB
boundaries and source pull failure after different produced chunk counts, plus
successful completion. A unique guest path identifies each local TLS origin
handler dispatch; the test counts dispatches through a 200 ms quiet window
after the synchronous call returns, requiring at most one on failure and
exactly one on completion. It checks source pull progression, not origin
receipt of partial bytes. `mix test test/upstream_test.exs` passed
**12/12 (2 properties, 10 tests)**. Galileo's full `mix precommit` passed
**21/21 (4 properties, 17 tests)** with zero Dialyzer errors. This adds local
verification for the existing single-attempt integration boundary under
ADR-0063. It changes no production behavior, protocol, persistence, authority
or accepted decision. Physical TLS dials before handler dispatch, late
asynchronous retries, connect/response fault permutations, the complete
private frontend and external origins remain unverified by this property.
Marshall's `mix precommit` passed **1361/1361 (177 properties, 1184 tests)**
with zero Dialyzer errors after the handbook scenario update.

## Remaining work

All 63 research candidates now have a source-backed local test decision in the
working audit. Fifty-two retain narrower local, transport, interruption or
native gaps and six remain without a related generated property. The actor
tests do not kill Lilly during journal publication or
physical launch. The report property uses fixture observations and does not
exercise authenticated exchange transport or independent host clocks. No
hosted Antithesis run, mutation sweep or native acceptance was performed for
this batch.

## Delayed certificate activation (2026-10-02)

The focused certificate file passed **7 checks (1 property, 6 tests)**, seed
`632388`, in `devenv shell`. Generated histories call production activation with
shuffled stale jobs, newer pending/failed/issued rows and repeated active jobs.
Refused and replayed jobs preserve encrypted chains, row timestamps and audit
versions. The latest issued row alone activates and retires the incumbent.

Architecture impact: verification evidence only; ADR-0105 and production
authority contracts are preserved. Sequential sandbox execution does not prove
independent-worker races, ACME faults, native gateway installation or hosted
timing. Failed-newer recovery remains unresolved.

Before integration with the concurrent SLO changes, the complete Marshall
`mix precommit` passed **1384 checks (196 properties, 1188 tests)** with two
excluded; forced Dialyzer reported zero errors, skips or unnecessary skips.
HLDD receipts, generated references, views, ADR structure and the Nix HLDD
check also passed. Final integration validation is recorded separately below.

After integration with `cef0d0a6`, the certificate and SLO focused suites passed
**17 checks (5 properties, 12 tests)**, seed `213858`; contracts (including 19
tooling regression tests), HLDD references/options/coverage/views, ADR structure
and the Nix HLDD gate passed. The complete Marshall gate above ran before this
integration; it was not rerun on the combined revision.

## Fresh invalid Lilly boots (2026-10-02)

The focused startup suite passed **2 checks (1 property, 1 test)**, seed
`648829`. Four generated histories shuffle thirteen invalid configuration
classes and vary synthetic credentials and invalid transfer rates. All 52
fresh BEAM processes invoke actual OTP `Application.ensure_all_started(:lilly)`
and require the exact fixed startup error, no supervisor/Runtime/status sockets,
no started event, unchanged fixture files and no synthetic credential in output.
The valid loader precheck prevents unrelated invalid fixtures from counting as
coverage. The unset-config control confirms the deliberate no-runtime boot.

Architecture impact: verification evidence only. The configuration custody
and supervision obligations carried forward from ADR-0013 through ADR-0031 and
ADR-0035 remain unchanged. This does not establish successful configured boot,
packaged systemd startup, other applications, native isolation or hosted config
faults. No production code or startup policy changes.

The final probe traces all processes and spawned descendants during startup.
A trace-delivery barrier precedes collection; rejected boots make no call to
the named Lilly supervisor, Runtime or StatusServer startup entry points. The
unset control calls the supervisor and confirms detection. This observes those
production entry points, not arbitrary alternative listener implementations.
The independent skill review found no remaining issues in the final probe.

The first full Lilly attempt passed all checks but failed the warnings-as-errors
policy on the probe's fixture filename and an existing intentional peer-module
replacement warning. The probe now runs from `lilly/scripts` only under explicit
Mix test opt-in; the generated process test runs serially to avoid competing
with short-deadline socket fixtures. The disk fixture suppresses only its
intentional module-conflict warning inside the disposable peer while compiling
the synthetic boundary, restoring compiler options afterward. Production Disk
and Storage bytecode and the runner's warning policy remain unchanged. A second
attempt hit the existing socket fixture timeout before serial scheduling.

Final complete pinned gates passed on the source based on `cf9abbad`: Lilly
**468 checks (78 properties, 390 tests)**, seed `713222`, and Marshall
**1387 checks (197 properties, 1190 tests)** with two excluded, seed `690967`.
Both forced Dialyzer runs reported zero errors, skips or unnecessary skips.
Runtime, contract, logging, compiler/formatting, ADR, handbook and generated
reference/view checks passed; the Nix HLDD gate passed before the fixture-only
placement/scheduling correction and passed again after integrating the
documentation-only upstream `c1c2a434`. Final HLDD references, generated
options/coverage/views and ADR structure checks also passed. Tested application
and test code was unchanged by that integration.

## Fresh invalid Audi role boots (2026-10-02)

The focused suite passed **2 checks (1 property, 1 test)**, seed `618316`. Three
shuffled histories cover 42 gateway/DNS/private-role case pairs through 126
fresh `Application.ensure_all_started(:audi)` calls. Each baseline passes the
real loader before one file/schema/custody defect is introduced. Rejection
requires the exact error and catalogued event, no named supervisor or reviewed
SSH/HTTP/DNS/private/status listener start call, and no surviving supervisor,
proof registry or status socket. The oracle retains fixture hashes, modes and
link counts and refuses diagnostics containing synthetic credentials, private
keys, PEM markers or configured fixture paths. Unset configuration starts only
the deliberately unconfigured supervisor/proof registry.

An independent skill review identified omitted external certificate/CA paths;
those and gateway host-key bytes are now checked. Gateway host-key custody
variants were added. The final review found no remaining issues. Traces and
logger payloads stay inside the explicitly opted-in Mix test probe; only closed
labels and booleans leave it. Audi's formatter now includes the script directory.

Architecture impact: verification evidence only; production startup, private
custody, role separation and the accepted ADR-0090/ADR-0091/ADR-0105/ADR-0124
boundaries remain unchanged. This does not prove packaged startup, successful
configured serving, native networking/isolation, concurrent file replacement,
hosted faults or other components' boot validation.

Audi's full pinned `mix precommit` passed **165 checks (41 properties, 124
tests)** with seed `34939`; forced Dialyzer completed with zero errors. ADR,
contract and logging structure checks passed. The focused property result above
and this full-suite result establish only the documented local scope.

The shared-governance Marshall `mix precommit` also passed **1,387 checks
(197 properties, 1,190 tests), two excluded**, seed `965054`, and forced
Dialyzer with zero errors. The HLDD reference, generated options/coverage/views,
ADR structure and Nix HLDD gates passed before the subsequent Ziggy additions;
those additions require their own final receipt and structural reconciliation.

## Fresh invalid Ziggy boots (2026-10-02)

The focused suite passed **2 checks (1 property, 1 test)**, seed `159952`.
Three shuffled histories drive 30 invalid file/schema/origin/path/provider/
credential cases through 90 fresh OTP starts. Each baseline passes the real
loader. The oracle requires exact startup rejection, the catalogued event,
no named supervisor or reviewed Bandit/spool/catalog/reporter/agent worker
start calls, no surviving supervisor/spool/catalog/socket/spool directory,
unchanged fixture hashes/modes/link counts and credential/path-safe output.
The separate unset-config control observes an empty supervisor and no serving
start call. Trace/logger payloads stay inside the opted-in Mix test process;
only a validated closed projection leaves it.

The fresh reviewer identified relative and fixed overlong socket paths outside
fixture ownership. The probe now changes directory to the private fixture and
the long socket remains underneath it; the final review found no remaining
issues. The property preserves Ziggy's reviewed regular private-file contract
without imposing Audi's additional hardlink prohibition. Its formatter includes
the test probe directory.

Architecture impact: verification evidence only. ADR-0063's remaining private
service boundaries and ADR-0064/ADR-0099's authority/provider decisions are
unchanged. No production code, protocol, resource, configuration default or
deployment placement changes. Packaged startup, successful configured serving,
native isolation, file-replacement races, hosted faults and remaining components
are not established by these tests.

Ziggy's full pinned `mix precommit` passed **54 checks (11 properties, 43
tests)**, seed `120256`; forced Dialyzer completed with zero errors. Its
compiler, formatter, ADR, contract and logging gates passed. Marshall's
passing shared-governance suite above covers unchanged governance tooling;
the final combined receipts and generated scenario chapter are checked
separately after these evidence additions.

The combined final HLDD receipts/references, generated options/coverage/views,
ADR structure, contract format/discovery and Nix `hldd` checks passed. The
independent reviewer verified the Ziggy documentation against source and exact
focused/full-suite logs, with no remaining actionable finding. These results
retain the bounded local startup scope and the catalog's partial status.

Integration preserves upstream `0f28c70d`'s observational SLO reader, burn
arithmetic and Control room route. The only merge conflict was the shared
receipt file; reconciliation starts from upstream receipts and explicitly
reviews the combined network/scenario evidence. Audi/Ziggy test and probe code,
their dependencies and the disposable TLS fixture are unchanged by integration.
Application gate results above therefore retain their original revision scope;
combined documentation, ADR and Nix HLDD checks are rerun after integration.

The integrated HLDD references, generated options/coverage/views, ADR structure,
contract format and Nix `hldd` checks passed against the combined tree. Comparing
the tested local commit with the integrated tree confirms unchanged Audi/Ziggy
sources, shared protocol and disposable TLS fixtures. No new application or
native execution claim is inferred from the documentation merge.

## Fresh invalid Galileo boots (2026-10-02)

The focused suite passed **3 checks (2 properties, 1 test)**, seed `759236`.
Three shuffled histories cover 30 file/schema/origin/path/credential cases
through 90 fresh OTP starts after real-loader baseline prechecks. Refusal
requires the exact error, catalogued event, no named supervisor or reviewed
Galileo Finch/Bandit/SLO start, no surviving supervisor/Finch/SLO/socket,
unchanged fixture hashes/modes/link counts and credential/path-safe output.
The separate unset control starts an empty supervisor without serving calls.
Twenty generated immutable socket paths are tested through the read-only
loader without attempting startup outside the disposable fixture.

The initial gate failed because Req's dependency Finch was counted as Galileo
serving. The unset control and fresh reviewer exposed the false positive;
the probe now checks `name: Galileo.Finch`. The reviewer also identified the
immutable socket case's fixture escape; it now exercises only the read-only
loader. The final source review found no remaining findings. Traces/logger
payloads stay inside the explicitly opted-in Mix test probe, and only validated
closed labels/booleans leave it. Galileo's own IPv6 origin and private regular
hardlink acceptance is preserved. Its formatter includes the probe directory.

The same review finding prompted moving Ziggy's immutable spool case from a
fresh boot to a separate read-only loader property. Its earlier 90-boot record
belongs to `acb9f7db`; the revised property has 29 boot cases plus the new loader
check and requires a new execution record.

Architecture impact: verification evidence only. ADR-0080's Galileo authority,
routing and renewable lease boundaries and ADR-0063/ADR-0064/ADR-0099's Ziggy
boundaries remain unchanged. No production code, protocol, resource or placement
changes. Packaged startup, configured serving, native isolation, concurrent file
replacement, hosted faults and remaining component boots are still unverified.

Galileo's full pinned `mix precommit` passed **27 checks (9 properties, 18
tests)**, seed `970232`; forced Dialyzer completed with zero errors. Its
runtime, ADR, contract, logging, compiler and formatter gates passed. These
checks preserve the local scope above and do not establish packaged serving.

Ziggy's revised focused suite passed **3 checks (2 properties, 1 test)**, seed
`212292`. It records 87 fresh refusals across 29 cases and 20 immutable-spool
loader checks without outside-fixture startup. The earlier 90-boot result retains
its `acb9f7db` scope. The independent reviewer checked both the custody correction
and Galileo's documentation/logs and found no remaining issues in that scope.

The first revised Ziggy full gate passed 54 of 55 checks and failed the existing
spool property at capacity six with all receipts acknowledged. Its replacement
ID 106 contained uppercase `6A`, violating the protocol's canonical lowercase
UUID precondition. The SUT correctly refused it as `:invalid_event`. The fixture
helper now lowercases its bounded 1..106 menu and validates generated IDs before
admission; no production code or capacity/ACK oracle was weakened. The focused
spool rerun passed **6 checks (1 property, 5 tests)**, seed `96170`. The aborted
full gate's passing Dialyzer result does not make that gate successful; the full
Ziggy and shared Marshall gates are rerun separately after the fixture fix.

The revised Ziggy full pinned `mix precommit` passed **55 checks (12 properties,
43 tests)**, seed `313027`, with zero forced Dialyzer errors. The fresh fixture
review found no remaining issue: original, saturation and replacement IDs remain
within the guarded menu, unique and canonical, while the receipt/capacity oracle
is unchanged. The shared Marshall gate follows in the same pinned process.

That first shared Marshall invocation stopped before testing because the latest
evidence edits had made HLDD receipts and the generated coverage chapter stale.
After reviewing the source/chapter changes, regenerating coverage and explicitly
reconciling affected receipts, the shared pinned `mix precommit` passed **1,392
checks (200 properties, 1,192 tests), two excluded**, seed `165899`. Browser
checks passed, and forced Dialyzer completed with zero errors. HLDD references,
generated options/coverage/views, ADR structure, contract format and Nix `hldd`
passed before the successful suite. Neither the stale-receipt stop nor the
earlier spool-fixture failure is counted as a passing gate.

Integration onto captured upstream `51f4cf5e126a6317888ed9e8ce25c28270356ba1`
preserves the UI wording, guest diagnostics and durable Ziggy SLO changes.
Only the HLDD receipt file conflicted; reconciliation began from upstream
receipts and reviewed the combined chapters and scenario ledger. Galileo,
Audi, shared protocol and shared validator/test sources are unchanged from
the tested local tree, so their results retain the scoped revisions above.
Upstream extends the spool property with aggregate/lifetime recovery checks;
the canonical UUID repair preserves those assertions. The merged spool suite
passed **10 checks (1 property, 9 tests)** with the original failing seed `96170`.
The combined Ziggy pinned `mix precommit` passed **62 checks (14 properties,
48 tests)**, seed `403388`, with zero forced Dialyzer errors. A fresh contract
review inspected all five UUID-helper caller sites and found no issues or
weakened receipt, capacity or SLO assertions. Upstream's native execution records
retain their own scope; this rerun establishes local integration only.

## Enrico bind validation and fresh invalid boots (2026-10-02)

Pinned-runtime reproduction before the fix supplied JSON null, boolean, number,
list and object bind values. All five raised rather than returning the loader's
declared `{:error, :invalid_configuration}`. `String.to_charlist/1` ran before
type validation. The narrow fix checks `is_binary(bind)` before conversion,
preserving the IPv4 policy, port/token limits, absolute-path policy and valid
loader state-directory creation. No extra-field, version, file-mode, hardlink
or canonical-path restriction is imported from another component.

The corrected focused suite passed **3 checks (2 properties, 1 test)**, seed
`400251`. Three shuffled histories cover 32 invalid file/required-field/type,
IPv4/port/path/token/certificate-reference/state cases through **96 fresh OTP
refusals**. Baselines pass the real loader. Refusal requires the exact error,
catalogued event, no named supervisor or reviewed Tasks/Manager/Bandit start,
no surviving supervisor/tasks/manager/socket and unchanged recursive fixture
type/mode/link-count/UID/GID/hash snapshots including the root. Original and
mutated credentials and fixture paths must remain absent from output. The
unset control starts an empty supervisor. **40 non-string-bind loader checks**
also preserve snapshots with the configured state directory initially absent.
Synthetic certificate/key bytes establish only the loader's regular-file
precheck, not successful TLS serving.

The first focused attempt stopped before execution because Enrico's locked
dependencies were absent in this worktree. Installing them changed no lockfile.
The initial property draft then passed three checks, seed `754208`, but fresh
review found a one-byte-token privacy false-positive risk and omitted ownership
and root metadata. The final menu uses 31/257/512-byte invalid tokens; the empty
case is separate. Snapshots now include those custody fields. The follow-up
review found no remaining findings. The test-only opted-in probe keeps captured
arguments/logger payloads inside its disposable BEAM and exports validated
closed labels and booleans after a trace-delivery barrier.

Architecture impact: corrective validation and local verification within
ADR-0097, with no change to accepted authority, protocol, listener topology,
mirror persistence or capacity policy. Its evidence is updated without changing
decision or implementation status. Packaged invalid startup, configured serving,
native isolation, replacement races, hosted faults and Brady/Porsche/Marshall
fresh-boot properties remain open; catalog counts are unchanged.

The final pinned Enrico `mix precommit` passed **6 checks (3 properties,
3 tests)**, seed `411171`, with zero forced Dialyzer errors and skips. Runtime,
ADR, contract, logging, compiler and formatter gates passed. The dependency PLT
was built for this worktree; dependency setup is not counted as runtime evidence.

## Fresh Brady schema and signer boots (2026-10-02)

The focused suite passed **4 checks (3 properties, 1 test)**, seed `46210`.
Three shuffled histories generate **120 schema refusals across 40 cases**,
requiring real-loader baseline acceptance followed by exact schema refusal and
catalogued event before the named supervisor or reviewed signer/cache/listener/
metrics starts. Separate histories generate **51 signer-child refusals across
17 cases** after real loader and anonymous signer baseline acceptance. Supervisor
and signer attempts are expected for this later failure; exact failed-first-child
refusal, no cache/listener/metrics starts and no surviving state are required.
No schema rejection event is expected after signer-child refusal. Twenty
immutable-store issuer-key paths use only the loader; unset starts only Metrics.

Root and recursive fixture snapshots preserve type/mode/link-count/UID/GID/hash
and symlink targets. Original and mutated signer bytes, PEM markers and fixture
paths are excluded from output. The child disables inherited fleet-monitor/SLO
export/invocation settings, checks the actual runtime config path, traces startup
through a delivery barrier and exports closed labels/booleans only. The schema
loader's config-symlink acceptance is preserved; private single-link signer
custody is checked at the actual child boundary, not misattributed to the loader.

Two initial attempts stopped before property execution because module-attribute
`for` do-blocks bound to the attribute; final explicit Enum menus preserve all
40 schema and 17 signer cases. Fresh read-only review found no semantic issues
in the final source, and did not claim compilation of the failed drafts.
Installing locked dependencies changed no lockfile.

Architecture impact: verification only under ADR-0069 and the ADR-0109 custody
retained by ADR-0113. No production source, protocol, network isolation, trust
delivery, cache policy or capacity changes. ADR-0069 receives scoped evidence;
accepted statuses and historical native executions remain unchanged. Packaged
invalid startup, configured serving, native interception/trust/ZFS/isolation,
file replacement, hosted faults and Porsche/Marshall boots remain open.

Brady's final pinned `mix precommit` passed **66 checks (17 properties,
49 tests)**, seed `232233`, with zero forced Dialyzer errors and skips. Runtime,
ADR, contract, logging, compiler and formatter gates passed. These results retain
the local test-build scope above and do not upgrade historical native evidence.

The first push was rejected after upstream advanced to
`4f2f71865a285c9399de4a6c285bac2a6380305c` with Ziggy durable-SLO producer
rollout. Integration preserves its runtime, deployment, tests and handbook
changes. Only HLDD receipts conflicted; reconciliation starts from upstream
receipts and explicitly reviews the combined chapters. Comparing the tested
local tree confirms unchanged Brady, shared protocol, other tested satellite
sources and shared HLDD validator code. Their application results retain the
original scope above; combined structural/generated/Nix documentation checks
are rerun after integration. Upstream rollout and native records retain their
own revisions and are not inferred from Brady's local gate.

## Fresh Porsche configuration boots (2026-10-02)

The corrected focused suite passed **2 checks (1 property, 1 test)**, seed
`898716`. Three shuffled histories cover **171 fresh OTP refusals across 57
cases**. Real loader baselines include generated canonical gateway credentials,
accepted optional trailing newlines, private synthetic host-key bytes and a
validated disposable PEM CA. Refusal requires its exact fixed error before the
named supervisor or reviewed listener/status/observability starts, no surviving
base infrastructure/listener/socket, unchanged root/recursive fixture hashes,
types, modes, link counts, UID/GID and symlink targets, and no original/mutated
credential, host-key/CA bytes or fixture paths in output. Unset separately
requires exactly five live named direct base children and no serving calls.
Inherited SLO export paths are cleared. The opted-in test probe changes to its
owned fixture and exports closed labels/booleans after a trace-delivery barrier.

The first draft passed two checks, seed `445594`, but self-review found that
writable-CA refusal also depended on malformed bytes. Final missing/malformed/
writable CA cases each mutate one valid PEM baseline condition; captured OpenSSL
generation output is never emitted. Inline credential input now uses the same
generated token checked for privacy, and CA bytes join the original/mutated
material set. Fresh follow-up review found no remaining issues. Synthetic host
keys establish loader file custody only, not valid SSH/host-certificate serving.
Required fields and optional defaults remain separate. Configuration/CA public
readability is accepted when not other-writable; credential/host-key single-link
service ownership and modes 0400/0600 are preserved.

The first full gate stopped before its suite on formatting; a default-format
retry also failed its preliminary check. Explicit formatting of the two new
files followed by whole-project format checking allowed the final full gate
to proceed. Failed formatting attempts are not counted as passing gates.
Installing locked dependencies changed no lockfile.

Architecture impact: local verification only under ADR-0046. No production
source, command/API/domain authority, protocol, listener topology or custody
policy changes. ADR evidence is updated without changing decision or
implementation status. Packaged invalid startup, configured SSH/host-certificate
serving, native isolation, concurrent file replacement, hosted faults and
Marshall fresh boots remain open; catalog counts remain unchanged.

Porsche’s final pinned `mix precommit` passed **88 checks (13 properties,
75 tests)**, seed `197244`, with zero forced Dialyzer errors and skips. Runtime,
ADR, contract, logging, compiler and formatter gates passed. The unset Porsche
configuration starts base infrastructure without listeners. These local test-build
results do not establish configured SSH or native isolation acceptance.

## Early Marshall common runtime boots (2026-10-02)

The new probe starts before runtime configuration, loads the actual Mix project
and compile configuration, then runs real `app.start --no-compile
--no-deps-check` with existing test-build beams. Three shuffled histories cover
117 refusals across 39 cases: inference retention, ingress port, relocation
readiness timeout, default/Inception image identities and bounded parent JSON.
Each case requires its own exact fixed-error family before reviewed application,
Repo, endpoint or Bandit startup, no surviving Marshall application or named
serving processes, and no supplied private image/parent marker or project path
in output. Each entry's trace installation must match one function; a harmless
probe-local call positively calibrates delivery before runtime evaluation.
The trace collector exports closed labels and booleans after a delivery barrier.
Valid default and boundary/null-parent reader controls use real `app.config`
without starting Marshall. They establish reader acceptance only.

Early draft focused executions failed. Review corrected the invalid menu: JSON
`null` is accepted parent absence under the shared protocol contract. A private
unknown-field parent object now checks metadata privacy. Family-specific refusal
labels replace broad rejection matching, projection data is validated, initial
Mix configuration is loaded explicitly, and the tracer gains positive
calibration. Empty strings travel through validated test-only JSON and are
installed inside the child; environment overrides are normalized and inherited
Marshall serving/export settings are cleared. No caught exception, environment
contents or trace arguments are emitted by the final probe.

Architecture impact: verification only. Existing common runtime guards,
production deployment/mail/signing validation, domain authority, PostgreSQL
recovery, protocols and listener topology are unchanged. ADR-0037's inherited
readiness-timeout guard receives bounded evidence without changing its historical
status or replacing native acceptance. Production-built release startup, required
production secrets/TLS/mail/budget faults, other common optional integrations,
packaged startup, configured serving, concurrent file replacement and hosted
faults remain open. Counts remain 54 partial, eight bounded local properties
and one native fault gap.

The corrected focused suite passed **2 checks (1 property, 1 test)**, seed
`303463`. Invalid common Marshall runtime settings refuse before application
startup in 117 fresh Mix attempts. Valid common Marshall runtime settings load
without starting the application. These results retain the test-build scope above.

Marshall's final pinned `mix precommit` passed **1,394 checks (201 properties,
1,193 tests), two excluded**, seed `632473`, with zero forced Dialyzer errors,
skips or unnecessary skips. Runtime, ADR, HLDD, contract, logging, compiler,
formatter, distributed tests, terminal/browser/dashboard and workspace TypeScript
gates passed. Shared governance tests are included. This full result preserves
the local test-build scope and does not upgrade native or production acceptance.

## Porsche host-certificate first-child boots (2026-10-02)

The corrected focused suite passed **2 checks (1 property, 1 test)**, seed
`364023`. Three shuffled histories cover **54 fresh OTP refusals across 18
certificate/key cases**. Every fixture first passes real Config and default Proof
acceptance with disposable OpenSSH Ed25519 private keys and a signed host
certificate. Mutations keep Config acceptance and exercise absent/empty/malformed/
invalid-base64/truncated certificate input, signature and signed-nonce damage,
foreign leaf or private key, malformed private bytes, expired/future validity,
multiple/no principals, a correctly re-signed user-certificate type, trailing
blob bytes, and correctly re-signed critical options/extensions. The latter
semantic mutations preserve cryptographic signatures so unrelated bad-signature
refusal cannot satisfy their intended test.

Each refusal requires the exact first-listener-child `invalid_configuration`
startup result, expected named supervisor/listener attempts, no `ssh.daemon`,
status or observability starts, no surviving Porsche base/supervisor/listener
state or status socket, unchanged root/recursive type/mode/link/UID/GID/hash
snapshots, and no original/mutated private material, CA seed, credential or
fixture path in captured output. Trace installation must match every reviewed
function. A separate real default-callback configured startup control requires
seven live direct children, ready listener, private status socket and actual
loopback TCP SSH banner, positively calibrating daemon/status/observability
traces. It stops its application and removes only its owned socket before the
fixture preservation comparison. Inherited SLO snapshot export is cleared;
closed labels/booleans leave the opted-in disposable child after a delivery
barrier. No control-plane request is needed for this startup/banner check.

The first draft failed compilation because its `string/1` helper collided with
ExUnitProperties; it now uses `ssh_string/1`. Self-review fixed a user-type
mutation that had dropped the leaf field, so it now retains the original
encoding and changes/re-signs only the type. The second draft executed both
checks, seed `555147`, but its warnings-as-errors gate failed on an unpinned
bitstring size. The final focused run pins that size and passed. Type inspection
found `File.Stat` exposes only `t/0`; snapshot metadata now uses an explicit
regular/directory/symlink union instead of a nonexistent remote alias. Key
parsing must return its validated success before the helper returns. A fresh
read-only review found no remaining substantive oracle or contract findings.

Architecture impact: verification and a contract documenting the existing
default-Proof pre-daemon guard under ADR-0046. No production branch, API,
authority, domain, protocol, listener placement or file-custody policy changes.
The server verifies the embedded CA signature; client authority to trust that
CA is separate. This local configured startup and banner control establishes
neither certificate negotiation/client CA trust nor account authentication,
Marshall HTTPS management, production release/systemd acceptance or native
isolation. Concurrent file replacement and hosted faults remain open.
Catalog counts remain 54 partial, eight bounded local properties and one native
fault gap.

Porsche's final pinned `mix precommit` passed **90 checks (14 properties,
76 tests)**, seed `755960`, with zero forced Dialyzer errors, skips or
unnecessary skips. Runtime, ADR, structural contract, logging, compiler and
formatter checks passed. The test runner exercises the probe/test code and
validated external projections; application Dialyzer success is not a separate
claim that every test-script typespec has been statically checked. These results
retain the local startup scope and client/native gaps above.

Publication integrated upstream `3ef521c57df0bf1fffd1f625eeb98f484fd3b663`,
which adds durable Underclass proxy SLOs and source-health guards. Only review
receipts conflicted; reconciliation starts from upstream receipts and reviews
the combined handbook/scenario/topology changes. Comparing the tested local
commit confirms unchanged Porsche and shared protocol source/dependencies. Its
90-check gate retains the same scope after integration. The upstream
[Underclass review](2026-10-02-underclass-proxy-slo.md) records its separate full
Marshall, merged startup/reader, forced Dialyzer, rule and machine/browser
results; their revisions, limits and native gaps remain intact. Shared Elixir
HLDD validator code is unchanged; the new evaluated topology role is rechecked
with combined generated and Nix gates. No full combined native acceptance is
inferred from either local suite.

## Porsche strict certificate negotiation (2026-10-02)

The focused property passed **1 property**, seed `986167`. It runs **12 real
OpenSSH connections across three shuffled four-case histories** against a real
loopback Listener with the default Proof callback. A disposable OpenSSH Ed25519
CA signs the real host key for `management.test`; the server's real certificate
validation passes before the listener starts. The trusted matching client
completes certificate negotiation and signed user-key proof, submits exactly one
scripted pending session with the canonical user key, exits 3 with approval
required, and never submits a command. Close acknowledgement precedes the next
history entry so late cleanup cannot pollute a refusal's backend-call oracle.

A foreign CA, an alias outside the signed principal (with that alias trusted by
the real CA), and absent CA trust each exit 255 with no backend request. Strict
host checking, explicit empty global trust, the per-fixture authority file and
certificate-only algorithms prevent ambient trust or a plain-key fallback.
OpenSSH sometimes reports its blocked certificate-to-plain-key fallback rather
than the generic host-verification refusal; both observed closed messages are
accepted, together with exit 255 and zero requests. The first fixture attempt
used a placeholder pending fingerprint and was correctly refused by Connection's
real response validator; the fixture now derives the actual proven fingerprint.
The second attempt exposed that OpenSSH message distinction and failed before
the corrected focused run. No production defect was identified.

Architecture impact: evidence only under ADR-0046; unchanged authority, protocol,
configuration, deployment and host-certificate policy. Server embedded-CA
validation remains distinct from client CA trust. This property establishes real
local certificate negotiation and user-key proof, while the pending backend is
scripted. It establishes neither Marshall account authorization/approval nor
HTTPS management, release/systemd/native isolation, production rotation or hosted
fault acceptance. Catalog counts remain 54 partial, eight bounded local
properties and one native fault gap.

A fresh read-only reviewer inspected the real Listener/Proof/Connection/Channel
paths, hostname isolation, close sequencing and applicable contracts. No
substantive findings remained; its review did not rerun the focused property.

Porsche's full pinned `mix precommit` passed **91 checks (15 properties,
76 tests)**, seed `518079`, in 146.4 seconds, with zero forced Dialyzer errors,
skips or unnecessary skips. Runtime, compiler, formatting, ADR, structural
contracts and logging checks passed. This application Dialyzer result does not
claim independent static checking of every test-script typespec.

After narrowing the test reply interface to string-keyed/string-valued data,
the focused property passed again. HLDD review receipts, generated options and
scenario coverage, Ash/deployment views, ADR structure/links, repository contract
checks and `nix build .#checks.x86_64-linux.hldd` passed. No shared validator or
Marshall application code changed, so the preceding scoped Marshall execution
record is retained without claiming a new full combined application run.

## Fleet version and malformed-envelope histories (2026-10-02)

The focused combined suite passed **8 checks (4 properties, 4 tests)**, seed
`777640`. New histories cover **65 current control routes** across provisioner,
SSH, Ziggy, Galileo, Audi and monitor samples. Three shuffled histories include
11 explicit version variants per route (negative/zero/retired/future/bigint,
string/null/boolean/list/object and a numeric-equality float alias), five
malformed or absent envelopes per route, unknown-path/method families, every
recognized retired provisioner action and both local stream-refusal surfaces.
These new corpora make **3,465 refused local endpoint requests** in total. Each
surface body corpus and each path history preserves independently enumerated
whole-row hashes for every public PostgreSQL table, including empty tables and
row multiplicity, plus the exact fleet cache state with timers disabled. This
is after-corpus preservation; it does not observe every intermediate transaction.

Every purpose credential is actually issued for the fixture host/service.
Setup opens a current provisioner session; current identity/readiness controls
reach all remaining service dispatchers. A valid monitor sample changes the
real cache without changing durable inventory, then its real flush changes
the durable inventory. This positively calibrates both preservation oracles.
Some wrong-version route baselines deliberately test envelope classification
without claiming a complete valid business operation. Clone/lifecycle/egress
envelopes retain current session bindings and empty collections, monitor input
retains a fully valid sample, and SSH certificate input retains a valid leaf
public key. Tokens and rows are not projected into inventory diagnostics.

The first corpus exposed a deterministic production defect: authenticated
`/api/fleet/v1/samples` with malformed JSON `{` returned **503 unavailable**,
because the nested `with` preserved a `Jason.DecodeError` struct and the outer
response classifier treated it as unknown. FleetAPI now maps that parser error
to its existing **400 invalid_samples** class before cache admission. Invalid
syntax and scalar/array/null/missing envelopes no longer satisfy the outage arm
in this corpus. No logging, credential, cache, transaction or retry policy
changes. The unpatched source omitted this mapping and failed the property; no hosted
mutant falsification is claimed.

The matrix also records existing differences rather than inventing a universal
426 promise: SSH host-certificate bodies and provisioner clone/inception/audit/
egress-owner bodies use 400; monitor samples use 400. Most other explicit wrong
versions use 426. Numeric-equality floats still produce differing permanent
classes. Unknown provisioner versions reach endpoint 404, but a recognized
retired prefix with an unknown action returns 400; recognized retired actions
return 426 even with invalid JSON. SSH/Audi unknown versions use 426 and
Ziggy/Galileo/monitor paths use 400. In-version stream denials remain blank 404
with Plug's inherited private/max-age-zero/revalidation header, while unmatched
peer paths use the fixed no-store 404. The path draft initially assumed all
unknown provisioner actions escaped routing and blank stream replies had no
cache header; source inspection corrected both expectations.

A fresh read-only review found no parser/oracle/typing correctness issues, and
identified a broad unknown-route contract phrase. It now names only paths
unmatched by all API plugs. Architecture impact: a malformed-monitor refusal
repair within ADR-0060's separate bounded monitoring transport, with verification
of existing control boundaries under ADR-0037/0046/0047. No new universal status
policy, authority, schema, deployment or observation-to-execution capability is
introduced; ADR statuses remain unchanged. Current application/sandbox endpoint
evidence does not establish wire TLS, independent-process races, packaged
mixed-version rollout, WebSocket upgrades, native isolation, overload fairness
or hosted Antithesis faults. Catalog counts remain 54 partial, eight bounded
local properties and one native fault gap.

The first full Marshall gate stopped at the stale mandatory HLDD receipt before
compilation/tests. After reviewing the control/monitoring/scenario changes and
recording receipts, the full pinned `mix precommit` passed **1,398 checks (204
properties, 1,194 tests), two excluded**, seed `129895`, in 1,201.0 seconds.
Forced Dialyzer reported zero errors, skips or unnecessary skips. Runtime,
compiler, formatting, ADR, structural contract and logging checks passed. The
final source includes the narrowed session-reply projection and corrected
contract wording. Application Dialyzer success is not a separate claim that
every property-test typespec was independently checked. No protocol library
or other application source changed.

Before publishing, origin advanced to
`5f5225f3391cf6e3dbba85788c789913e280b32d` with SLO deployment evidence and an
isolated handbook browser-fixture repair that revokes both login and remembered
credentials under ADR-0131. The upstream deployment/reader records retain their
original revisions and scopes. Rebase reconciled only the receipt JSON conflict;
monitoring chapters and scenario coverage preserve both changes. Comparison to
the tested local commit `8057ffd717c62b611c7c83662a7588d882ff7013` confirms
Marshall library/test/configuration/dependency source, protocol and shared
validator scripts unchanged. Full application evidence remains scoped to that
tested source; the integrated handbook/native browser gates are separate.

Integrated HLDD receipts, generated option/coverage references, Ash/deployment
views, ADR structure/links and repository contract gates passed. The evaluated
Nix `hldd` check passed. The clean integrated `0f26b85da8d6f35e3f9abd451b46000e3358a921`
tree's packaged native `hldd-browser` check passed in a **382-second Nix build**,
including every section, both maintained diagram views, navigation teardown,
history/theme/mobile checks and refusal after revoking both reader credentials.
Execution archive:
`/home/ghuntley/.local/state/nix/build-logs/1790953165738-2060688-0.jsonl`.
This adds single-machine packaged handbook/TLS browser evidence, not a native
fleet API version-skew, independent-host authorization or physical isolation
claim. The final amendment changes only this execution record and its reviewed
receipt; application/test and reader-visible handbook source remain unchanged.

## Live host-session takeover histories (2026-10-02)

Architecture impact: evidence-only extension of ADR-0083's accepted stream and
nonce renewal mechanism. No production code, protocol, authority or timer changes;
accepted rationale and implementation status remain intact. Ancestor and local
HostStream/Directory/Relay contracts were reviewed. No semantic contract mismatch
was found in this scoped change. Hosted SDK assertions remain absent, and both
catalog candidates stay partial.

The new `marshall/test/marshall/terminal/host_takeover_history_test.exs` uses
`marshall/test/support/terminal_host_socket.ex` to run the production provisioner
credential/identity upgrade and HostStream inside real Bandit WebSock processes.
Only HTTPS is supplied synthetically. Real isolated credentials and PostgreSQL
host sessions rotate while actual local channels carry synthetic attached/output
frames. Three generated histories each include both renewal-first and
successor-first ordering: six takeovers. Guest identities draw from codec lower
boundary one, its next value two and signed-64-bit maximum.

Each old process exits. A connection upgraded before rotation delays its matching
old hello until after successor registration; the stale hello cannot publish or
change the successor PID/nonce. Old directory nonces cannot renew or identify a
local stream, and stale attempts preserve the current directory row. The
successor renews and sends usable channel output. Closing the final process
removes its local relay binding; a durable directory lease may remain until
expiry, so this is not an assertion of immediate row deletion.

Host connection session/epoch is distinct from VM execution generation. The
fixture uses real loopback WebSocket framing and process shutdown, not native
Lilly/guest or actual remote peer transport. Explicit renewal messages establish
the renewal decision, not the five-second wall-clock bound. Per-frame database
fencing, partition convergence, database outage, hosted faults and the unresolved
window design question remain open. No mutation-falsification claim is made.

Draft corrections: hello_response has interval_ms, not an ok field; rejected
hellos close directly. Ash wraps transaction rollback's :replaced into an unknown
error, so the stale renewal oracle checks refusal plus exact preserved successor
row, rather than asserting an incidental error representation. The fresh-context
reviewer caught a delayed hello upgraded after rotation; moving its upgrade before
rotation now exercises the database freshness arm. No remaining substantive
source-review finding was reported.

Host takeover focused checks: 10 passed (3 properties, 7 tests), in 5.9 seconds.
Focused seed: `794298`. Full gate results are recorded below after execution.
Log: `/tmp/kittens-host-takeover-focused.log`.

Upstream integration: origin advanced to
`e1cb9e4f2b11ea21d1a3f39590c794dc8cf380e8` with Galileo/Porsche management
repairs while the first full gate ran. That gate was intentionally stopped
before completion; it is not passing evidence. The local property commit
`cf8fce38` was rebased onto the captured upstream SHA. The only conflict was the
HLDD receipt file; upstream receipts were retained, then the combined source and
handbook were explicitly re-reviewed. Interactive and scenario additions merged
without source conflicts. New native browser execution begun before integration
retains its pre-integration scope and cannot establish the combined tree.

Upstream changes include SSH list result objects and pagination, team-show member
objects and the catalogued boolean --peer parser flag, with existing Galileo and
protocol regression properties. ADR0046/0080 retain their upstream evidence and
stated personal-VM eligibility discrepancy. They do not change HostStream,
Relay, Directory, provisioner upgrade or fixture session authority. Combined
verification nevertheless includes protocol and both consumers because upstream
changed shared wire parsing; passing upstream gates are not substituted for this
combined execution. No local production source fix was required.

Combined gates on the `e1cb9e4f` integration:

- Protocol pinned `mix precommit`: 222 passed (83 properties, 139 tests),
  seed `483070`; forced Dialyzer zero errors/skips/unnecessary skips.
- Lilly pinned `mix precommit`: 468 passed (78 properties, 390 tests),
  seed `543753`, 44.9 seconds; forced Dialyzer zero errors/skips/unnecessary skips.
- Marshall pinned `mix precommit`: 1,402 passed (207 properties, 1,195 tests),
  two excluded, seed `559594`, 1,100.5 seconds; forced Dialyzer zero
  errors/skips/unnecessary skips. Distributed tests included; host/capacity excluded.
- Combined ADR, HLDD receipt/reference/coverage/view and contract checks passed.
  Integrated Nix `hldd` passed in eight seconds.
- Integrated `hldd-browser` passed in a 296-second Nix build, on
  `3ba29bb119945c4f8321cc1dc50a22643a348009` plus the staged catalog provenance,
  integration execution notes and reviewed receipt. Application/test and
  reader-visible chapter/scenario sources match that captured commit.
  It visits individual sections, renders/tears down diagrams, exercises navigation,
  history, theme and mobile layouts, and refuses mounted/fresh readers after both
  login credentials are revoked. This is packaged single-machine handbook/TLS
  evidence, not native host-stream takeover, remote peer or physical isolation.
  Archive: `/home/ghuntley/.local/state/nix/build-logs/1790954726093-3134120-0.jsonl`.

The first protocol gate attempt stopped before tests because this worktree lacked
locked test dependencies stream_data/dialyxir. `mix deps.get` restored pinned
protocol and Lilly dependencies without lockfile changes; the sequential
reexecution above passed. Application Dialyzer results do not establish independent
static analysis of every test typespec.

A second origin advance to `95b5470987b85a9b75088b52927d06ef691988c8` landed during
Marshall's gate. It changes Galileo validation failures from exception matches to
closed transaction rollback, adds domain/LiveView refusal properties, corrects
native team refusal expectations and preserves those verification scopes in the
handbook. This changes Marshall application source, so the final integration needs
its own Marshall gate rather than treating the e1-based execution as final.
Protocol and Lilly sources/tests are unchanged by this second advance.
Logs: `/tmp/kittens-host-takeover-integrated-full.log`,
`/tmp/kittens-host-takeover-integrated-doc-gates.log`,
`/tmp/kittens-host-takeover-integrated-nix-hldd.log`,
`/tmp/kittens-host-takeover-integrated-native-hldd.log`.

Second integration captured as `319ee00e434d232a5f73594eee5fc4ddd5d7fb0f` before
final provenance/receipt review. Again only the receipt JSON conflicted; upstream
receipts were retained and combined chapter/scenario facts reviewed. The new
validation helper has one configure caller and three protocol-value callsites;
all remain inside the same Ledger transaction before integration/header writes.
Closed protocol refusals roll back instead of reaching exception matches. No
accepted authorization or target requirement is relaxed. The existing outcome
event follows transaction success. Terminal production and property/helper
sources compare unchanged to the first integration; protocol and Lilly complete
source/test/configuration comparisons are empty, retaining their passing gates
at the captured e1-based revision. Combined Marshall and handbook verification
are rerun because Marshall behavior and reader-visible evidence changed.

Second integration gates passed:

- Marshall pinned `mix precommit`: 1,404 passed (209 properties, 1,195 tests),
  two excluded, seed `869126`, 1,213.3 seconds. Distributed checks included;
  host/capacity excluded. Forced Dialyzer zero errors/skips/unnecessary skips.
- Reviewed HLDD/reference/coverage/views, ADR and contracts passed.
- Final Nix `hldd` and `hldd-browser` passed together in a 341-second build on
  `319ee00e434d232a5f73594eee5fc4ddd5d7fb0f` plus staged provenance, second
  integration audit and reviewed receipts. Application/tests and reader-visible
  chapters/scenarios match that captured commit. Browser scope remains packaged
  single-machine sections/navigation/diagrams/theme/mobile and both-credential
  reader revocation, not native host-stream takeover or partition convergence.
  Archive: `/home/ghuntley/.local/state/nix/build-logs/1790956063403-4133161-0.jsonl`.
Logs: `/tmp/kittens-host-takeover-final-full.log`,
`/tmp/kittens-host-takeover-final-doc-gates.log`,
`/tmp/kittens-host-takeover-final-native-hldd.log`.

Origin then advanced to `33b76a25aab03ecc3a9356c6fe6cf8aea45becec` during this gate.
The only new Marshall application file is IntegrationsLive: every submission
advances password-input DOM identities so browser-local values cannot survive
server patches with already-empty form values. Its existing property now checks
replacement identities. The upstream record explicitly reports its own full
Marshall gate (1,403 checks, 208 properties, 1,195 tests, two excluded, forced
Dialyzer zero errors) separately from our captured 95-based full execution.
No terminal/provisioner/protocol/Lilly path changes. Remaining changes are Brady
HTTPS acceptance fixtures and scoped architecture/handbook evidence, including
expected Customer network refusals excluding TLS errors and exact response
comparison after native cache recovery. These are inherited evidence, not new
production acceptance executed by this local host-stream workload.

For this independent leaf UI change, the final combination uses the two captured
full-gate records plus fresh combined affected tests, compiler, forced Dialyzer
and handbook gates. It does not claim a new full-suite execution on the final
combination. The source comparison and exact combined results follow below.

Third integration verification on `1dd95d23696b09edafe4f8bac8eb5ed5a16dedfc`
plus staged provenance/receipt review passed 26 affected checks (six properties,
20 tests), seed `948670`, 8.9 seconds: host takeover, existing HostStream,
Galileo domain and integration LiveView. Compiler warnings-as-errors, format,
runtime/ADR/HLDD/contracts/catalogued logging and terminal/dashboard/workspace
checks passed. The standalone default-dev Dialyzer command began constructing
a new dependency PLT and was intentionally stopped, not counted as passing.
Explicit `MIX_ENV=test mix dialyzer --force-check` then passed with zero errors,
skips or unnecessary skips, in 73.3 seconds. No test/helper or protocol/Lilly
changes occurred across the merge; the only application and application-test
changes were the independently full-tested IntegrationsLive password IDs and
its existing refusal property.

Combined Nix `hldd` and `hldd-browser` passed in a 466-second build. Reader-visible
chapters/scenarios and application/test sources match the captured third
integration. The later research-only correction resolves the uncached SQL query
question without changing those sources or accepting a deadline/window design.
Browser scope remains single-machine packaged handbook/TLS/navigation/diagrams
and reader revocation, not native host takeover. Archive:
`/home/ghuntley/.local/state/nix/build-logs/1790957603222-1034490-0.jsonl`.
Logs: `/tmp/kittens-host-takeover-combined-focused-static.log`,
`/tmp/kittens-host-takeover-combined-dialyzer.log`,
`/tmp/kittens-host-takeover-combined-doc-gates.log`,
`/tmp/kittens-host-takeover-combined-native-hldd.log`.

A further origin advance to `f8dd5632a71b06e9424c7fedf25a7eb5f88f4d99` adds
ADR0133's partial durable physical service-level accounting, new Ash resources
and migrations, transactional operation/SSH admission and a publication worker.
This affects compute fixtures and complete-table preservation oracles, unlike the
independent leaf DOM change. The publisher schedules work only when its directory
is configured; ordinary unconfigured test startup does not schedule publication.
New attempts are admitted in the operation transaction, and migration-initialized
source totals remain durable authority. This integration requires fresh Marshall
full-suite validation and handbook inventory/evaluated topology checks. No passing
pre-SLO execution is presented as evidence of this combined tree. The inherited
SLO review retains its own full, affected-path and native captures; no production
activation or seven-day compliance is inferred by this terminal workload.

Fourth integration gates passed on
`f6408e050ddb9b7203cc9701cfb7c80ff9ad6b64` plus staged provenance and reviewed
receipts. Marshall pinned `mix precommit` recorded **1,409 passed (211 properties,
1,198 tests), two excluded**, seed `815508`, 1,237.6 seconds. Distributed checks
included; host/capacity excluded. Forced Dialyzer passed in 43.43 seconds with
zero errors, skipped warnings or unnecessary skips. Compiler, format, runtime,
ADR, HLDD, contracts, catalogued logging and terminal/dashboard/workspace gates
passed. This validates the local takeover and complete-table refusal histories
with the new migration-initialized measurement resources; the oracle did not
exclude those tables. No local production or test correction was needed.

The fresh-context review confirmed that terminal fixture provisioning admits
lilly_physical and marshall_ready attempts inside its sandbox transaction, while
session takeovers admit no operations or SSH receipts. Missing initialized totals
correctly refuse fixture provisioning. The publication worker schedules nothing
without a directory, and the fleet oracle dynamically discovers the new tables.
No source/evidence mismatch was found in this scoped integration. Protocol and
Lilly complete comparisons remain empty relative to their recorded passing gates.
ADR0083's accepted decision/status remain unchanged. ADR0133 remains inherited
accepted/partial; this workload does not add native physical SLA acceptance.

Nix `hldd` and `hldd-browser` passed together in a 393-second build, including
new Ash inventories and evaluated topology, individual sections, diagrams and
teardown/navigation/history/theme/mobile, and both-credential reader revocation.
The captured application/test and chapter/scenario sources match f6408e05;
only provenance/review receipts were staged. This remains single-machine packaged
handbook/TLS evidence, not native host takeover or partition convergence.
Archive: `/home/ghuntley/.local/state/nix/build-logs/1790958326707-1514608-0.jsonl`.
Logs: `/tmp/kittens-host-takeover-slo-full.log`,
`/tmp/kittens-host-takeover-slo-doc-gates.log`,
`/tmp/kittens-host-takeover-slo-native-hldd.log`.

Origin's final documentation-only advance to
`6cdf0ae3f9fb57a5c164df8501abce394db9c4d8` records deployed Galileo Chromium,
CLI/direct/peer acceptance and campaign fixture cleanup, with passkey-authorized
retirement of its empty fixture account still pending. It changes ADR0080's
implementation evidence and services/scenario prose, not application/test/config,
protocol, migrations or validator sources. The local property is rebased onto
this captured SHA; only receipt JSON conflicts require explicit merged review.
Final structural/generated/evaluated handbook checks follow after integration.
The 393-second native handbook result retains its pre-documentation-merge chapter
capture; it is not represented as a fresh execution of the changed services prose.
The application full-gate result remains applicable through an exact source
comparison. Production campaign results are inherited recorded evidence, not
requests executed by this host-stream workload.

Final publication checks passed after the documentation-only integration:
HLDD receipts/references, generated options and scenario coverage, Ash/deployment
views, ADR structure/links and code-contract structural/regression checks
(19 tests). The evaluated Nix `hldd` check also passed. Logs:
`/tmp/kittens-host-takeover-publication-gates.log` and
`/tmp/kittens-host-takeover-publication-nix-hldd.log`.
The exact application/test/config, protocol, Lilly, scripts and Nix comparison
against tested commit `34dbc260` is empty. The earlier native browser chapter
capture remains explicitly historical. Final architecture impact remains test
and evidence maintenance for ADR0083, with no production behavior, decision or
contract change; hosted faults and the documented renewal windows remain gaps.


## Lilly terminal channel histories

Reviewed on base `14a2d6cea9604f3c7081a41683026af1b6d5b551`. Architecture impact:
local property/evidence maintenance under ADR0083; no production code, protocol,
authority, persistence or accepted-decision change. Root, Lilly, terminal and test
contracts were inspected together with Stream, Channel, Websocket and the shared
TerminalWindow. The current research is corrected explicitly: transport loss
synchronously stops channels while retaining guest managers; fresh attachments
reset local sequences and clients must not replay uncertain input.

Five generated real-local-TCP properties cover replay boundary/receipt histories,
actual transport-loss and same-ID successor PID refusal, exact input effects and
cumulative wire ACKs, independent sixteen-frame live-output credit and invalid
consumption, and delayed input-receipt frame/byte credit refusal. Every replay
history includes a byte-exhaustion witness; both input-credit families execute
in each generated history. Synthetic payloads are compared by hashes and failure
helpers report tags/counts rather than frames or terminal bytes. Real EOF state
with outstanding consumption is observed before final release permits closure.

Fresh-context review initially found weak exhaustion, ACK-counter, EOF and
incarnation oracles and payload-bearing failure assertions. These were corrected,
including actual sibling and same-ID successor processes. Initial drafts failed
because the test used a client WebSocket reader for masked client output and
passed Stream's unused struct to map-based production callbacks. The final
fixture uses a server-frame reader and the same map shape as real Stream startup.
A broad event helper draft consumed an unrelated monitor event; the corrected
bounded helper preserves deferred mailbox events without displaying payloads.
These failures were fixture/oracle mistakes, not production fixes.

The scope is Channel processes, local sockets and directly invoked production
Stream callbacks. It does not compose Stream's GenServer authentication, guest
HMAC hello, PTY persistence, TLS, native isolation, remote peers or partitions.
Delayed input receipts are imposed at the callback boundary. No guest or full
hosted Antithesis completion is inferred. Application Dialyzer does not independently
verify every test helper typespec. Full component and documentation gates follow.

Channel focused checks passed: **8 passed (5 properties, 3 tests)**, seed
`110981`, 5.2 seconds, pinned runtime. This includes the final fixed witnesses,
all five new properties and three existing Channel tests. Log:
`/tmp/kittens-channel-history-focused.log`. These are local socket/callback
results, not native guest acceptance.

The final fresh-context reread found no blocking issue and confirmed the fixed
boundary witnesses and scoped evidence. Its optional live-order oracle improvement
was applied: successive live frames now carry distinct synthetic sequence markers,
so swapped equal-length frames cannot pass a payload hash comparison. Full-gate
execution below includes that final oracle change; the focused capture above
precedes it. No producer or consumer source changed.

Lilly channel full gate passed: **473 passed (83 properties, 390 tests)**,
seed `504220`, 57.0 seconds; forced Dialyzer passed in 12.89 seconds with zero
errors, skipped warnings or unnecessary skips. Pinned runtime, ADR, contracts,
catalogued logging, compiler and format gates passed. Capture is base `14a2d6ce`
plus the final staged channel property and documentation/receipts. Log:
`/tmp/kittens-channel-history-lilly-full.log`. The evaluated Nix `hldd` gate also
passed in 13 seconds; archive
`/home/ghuntley/.local/state/nix/build-logs/1790961106502-3132223-0.jsonl`.

Origin advanced to `99f13b26059086f1348f94db60e2d31d5abb20e1` with descriptor-pinned
ZFS namespace cleanup and its recorded native acceptance. Its Lilly application,
tests/config/mix files, protocol, Marshall application/tests/config/mix files and
validator scripts compare exactly empty against this capture. Native Rust and
ZFS machine-driver changes are unrelated to the local terminal callback fixture;
their own passing native/Rust/Python/Lilly records remain inherited, not new
executions by this workload. Storage/network chapter and coverage updates require
merged handbook receipt/reference/evaluated checks. No terminal or native helper
contract is weakened. Marshall's required gate follows on the integrated tree.

Marshall integrated full gate on `9d3df7bf` passed: **1,409 passed (211 properties, 1,198 tests), 2 excluded**, seed `892340`, 1275.4 seconds. Forced Dialyzer passed in 40.36 seconds with zero errors, skips or unnecessary skips. Log: `/tmp/kittens-channel-history-marshall-full.log`. Integrated structural/generated checks and evaluated Nix HLDD also passed before the subsequent Galileo integration.

Publication integrates `b96443ffd17c0862d152c4ec24d0e7c019672067`: current Galileo owner liveness and archived-team token refusal are independent of Lilly Channel callbacks. No Lilly Elixir, shared protocol or validator source changed since the recorded full gates. Upstream Galileo full-gate evidence remains scoped to its recorded revision; combined affected Galileo and terminal checks, compiler/static gates and forced Dialyzer follow on this merged tree. ADR-0083 and its authority decisions are unchanged; ADR-0134 is inherited from upstream. Native and hosted fault gaps remain open.

Merged publication checks passed: compiler warnings-as-errors, format, contracts, catalogued logging, structural/generated HLDD/options/coverage/views and ADR checks. Galileo renewal and terminal takeover/host-stream files passed **13 checks (6 properties, 7 tests)**, seed `960408`, 27.9 seconds. Forced Dialyzer passed in 60.56 seconds with zero errors/skips/unnecessary skips. Log: `/tmp/kittens-channel-history-merged-gates.log`. Galileo authorization and real three-node peer-token checks then passed **13 tests**, 8.2 seconds; evaluated Nix HLDD passed in 13 seconds. Log: `/tmp/kittens-channel-history-merged-peer-nix.log`; Nix archive `/home/ghuntley/.local/state/nix/build-logs/1790963181721-250045-0.jsonl`. These affected-file executions supplement separately scoped full gates; they are not a fresh full combined suite or native/hosted acceptance.


## Dirty audit sender recovery

Developed in `/home/ghuntley/src/kittens-antithesis-audit-recovery` from
`9d3df7bf2f68f4ecc3bf50aa7a77c0355aa55c82` while the captured Marshall gate
continued in the separate local worktree. The existing AuditRuntime property
scans empty metadata files and the readiness unit's actor map is empty. Neither
establishes the dirty-restart ordering promised under ADR0074/0017.

The new property creates real bounded VM execution journal backlogs under OS
locks and real paused actors. The production Runtime connection-result callback
starts actual audit delivery through a local HTTP fixture and current Client
codec. Partial acknowledgements, pending-task sender death/restart and exact
retained event IDs precede complete drain. Only current-sender readiness then
releases actor effects into a controlled blocked executor. Fixed witnesses cover
full64-event journal pairs/forced death and one-event/zero-ACK graceful restart.

Fresh source review identified setup/cleanup leaks during StreamData shrinking;
a per-history temporary supervisor and nested server/sender cleanup now protect
those resources. The original draft started AuditRuntime directly, leaving the
historical early-connect reconciliation regression outside the oracle. It now
exercises the actual connection-result handler and inspects paused actors
immediately afterwards. A newly unused alias was removed. Pinned Elixir1.20.4
parsed/formatted the draft using the existing profile binary; no second devenv
shell was launched alongside the live Marshall run.

Initial architecture assessment was test/evidence maintenance. Execution then
exposed and repaired a production drain-readiness violation within the existing
ADR-0074 decision; protocol and isolation boundaries remain unchanged. Contracts for root/Lilly/control/host,
Actor/Journal/Outbox/Client and the lifecycle resources were inspected. Auth
results are synthetic; Runtime's full process/bootstrap/ownership checks are not
composed. This tests local sender/task death, not Lilly/guest process lifetime.
No TLS, authentic Marshall, physical effect or hosted-fault assertion is made.
Repeated readiness checks establish unchanged gate state, not exactly-one casts.
Runtime/compiler/Dialyzer, sensitivity and handbook gates are pending; this draft
must not be represented as executed acceptance.

The initial focused execution failed before any successful generated run: the
current sender reported readiness while the exact journal oracle still retained
events. AuditRuntime had continued only the remaining traversal after a bounded
offer; a later empty suffix incorrectly established drain. The repair restarts
configured-root traversal after every successful delivery, including partial or
zero acknowledgement. Only a complete offer-free scan may report readiness.
This preserves bounded 128-path/16-event passes and does not grant new execution
authority. Initial reproduction: `/tmp/kittens-audit-recovery-focused.log`.
Repaired focused property passed, seed `771441`, 22.7 seconds:
`/tmp/kittens-audit-recovery-repaired-focused.log`. Full gates remain pending.

Fresh review found that the initial root-reset repair could starve later journals
under repeated zero acknowledgements. The final repair retains traversal progress
and tracks offers across the complete pass; only a complete offer-free pass
establishes readiness. The property now checks that all restored actor journals
receive offers during a zero-ACK traversal. The initial full Lilly gate failed
three checks (471/474 passed, seed `345813`): two existing scheduling-sensitive
checks and a new oracle read racing acknowledgement replacement. The oracle now
waits for the actual delivery task to finish before acquiring the audit lock and
reading journals, avoiding both rename races and competing with the production
nonblocking ACK lock. Final focused recovery/OTP/propagation checks passed:
**10 checks (one property, nine tests)**, seed `310553`, 23.9 seconds. Log:
`/tmp/kittens-audit-recovery-fair-focused.log`. Initial full-gate Dialyzer passed
with zero warnings but does not verify the final revised source; full rerun follows.

Final recovery fresh review found no concrete blocker. Full pinned Lilly gate passed: **474 checks (84 properties, 390 tests)**, seed `929763`, 84.6 seconds; forced Dialyzer passed in 13.04 seconds with zero errors/skips/unnecessary skips. Runtime, ADR, HLDD, contracts, catalogued logging, compiler and format gates passed on the final fair-traversal repair and locked-after-delivery oracle. Log: `/tmp/kittens-audit-recovery-lilly-final-full.log`. Marshall consumer and final documentation/evaluated checks follow.

Recovery integrated Marshall full gate passed: **1,410 checks (212 properties,
1,198 tests), two exclusions**, seed `977346`, 1437.4 seconds. Forced Dialyzer
passed in 48.64 seconds with zero errors, skips or unnecessary skips. Compiler,
contracts, logging, format, terminal, dashboard and workspace gates passed.
Log: `/tmp/kittens-audit-recovery-marshall-final-full.log`. Structural/generated
handbook/options/coverage/views and ADR checks passed, and evaluated Nix HLDD
passed in eight seconds; archive
`/home/ghuntley/.local/state/nix/build-logs/1790963951270-726208-0.jsonl`.
Capture is `e002401a` plus the final staged fair-traversal repair/property and
documentation. Native physical recovery and hosted faults remain unverified.

Origin advanced to `3f7ebc11c99d3f1c12d17f913afeaf09d2a8f16a`: independent SLO
publisher backlog freshness refusal plus native fleet measurement evidence.
Its Lilly Elixir, protocol and validator scripts compare unchanged. Its own
recorded full and merged focused checks remain scoped to their revisions.
The source guard affects publication of numeric snapshots, not lifecycle audit
delivery/readiness, and is integrated with affected merged checks below.

Merged recovery publication checks passed on `c5ab10a8`: SLO publisher, lifecycle
audit and real provisioner transport files passed **34 checks (four properties,
30 tests)**, seed `163743`, 19.4 seconds. Compiler warnings-as-errors, format,
contracts and logging checks passed. Forced Dialyzer passed in 50.29 seconds
with zero errors/skips/unnecessary skips. Structural/generated handbook/options/
coverage/views and ADR gates passed; evaluated Nix HLDD passed in 12 seconds.
Log: `/tmp/kittens-audit-recovery-merged-gates.log`; archive
`/home/ghuntley/.local/state/nix/build-logs/1790965923955-1728570-0.jsonl`.
Lilly Elixir/test/config/mix, protocol and validator sources compare exactly
unchanged against the full recovery capture `d7b94acc`. This supplements the
separate full gates; no fresh full combined suite, native recovery or hosted
execution is claimed. Final source review preserves ADR0074/0017 authority and
ADR0133 measurement boundaries. The remaining research gaps stay explicit.

## Audit expiry/reoffer history

Developed in `/home/ghuntley/src/kittens-antithesis-audit-expiry` from
`e002401aad2a3677a15f3f8be41db2d2540e4b15` while the recovery Marshall gate ran
in the warm worktree. ADR0074 decision and implementation status remain unchanged;
this extends evidence without production changes. The existing expiry case has
one event; generated histories add partial retention, mixed retained/expired
reoffers, future cursor continuation and atomic invalid-batch refusal.

Fresh review corrected protocol-invalid obsolete events, the late operational
baseline and a physical inventory oracle that initially ran only after sweep.
Every subsequent refusal/reoffer now compares raw physical IDs as well as
projected rows and cursors. A valid next event precedes wrong-host, wrong-placement,
retained conflict and future-gap refusals. Four draws additionally run fixed
one/all, two/prefix, fifteen/alternating and sixteen/all histories, guaranteeing
retained conflict/full expiry/batch boundaries without claiming all combinations.
The typed wire-event map constrains values and generated accepted/replay/refusal
events use the closed protocol validator.

Root/Marshall/test/compute and ingestion/cursor/event/sweep contracts were reviewed.
Four operational resource classes are compared, not all workflow/receipt tables.
The production retention function executes directly after workload-only SQL
backdating, so no Oban cron, restart, concurrent process, Lilly outbox or hosted
fault claim follows. Source formatting, compilation and focused execution passed; full Marshall static gates passed; final
mandatory handbook/evaluated gates passed.

The property sends these exchanges through the real Lilly Client to the
actual Marshall provisioner API over verified loopback HTTPS using disposable
fixture trust. Client session opening and request/response validation are composed
with the database oracle. It still does not run a Lilly outbox, restart Marshall,
schedule Oban or establish native/hosted faults; focused compilation and execution passed.

Each history also withholds one to three successful audit acknowledgements by
replacing the real API's reply with HTTP503 in a test-only before-send hook.
Ingestion has completed its transaction boundary within the SQL sandbox;
the Client observes temporary unavailability. This does not establish durable
commit outside the sandbox. Exact physical rows, cursor and operational records are checked
after every attempt before a successful replay returns the original IDs. This
is an accepted-but-unobserved reply fixture over real TLS, not a socket drop,
server crash or independent-service partition. The focused run passed 14 checks (three properties and eleven tests), seed `461284`, in 13.0 seconds; log `/tmp/kittens-audit-expiry-focused.log`. Full Marshall precommit passed 1412 checks (213 properties, 1199 tests), two exclusions, seed `367039`, in 1130.3 seconds; forced Dialyzer passed with zero errors/skips in 38.72 seconds. Structural/generated/reference and evaluated Nix HLDD gates passed before and after upstream integration.

Ownership refusal uses an existing foreign host and an actual allocated retained
placement for the same VM on that host, alongside an invented placement. The
foreign placement is metadata-only fixture state, not an admission, launch or
physical copy. It catches removal of the host filter before cursor suppression,
which an unknown placement alone would miss. All VM placements enter the
operational snapshot before audit exchange.

The full Marshall test stage passed 1412 checks (213 properties, 1199 tests),
with two exclusions, seed 367039, in 1130.3 seconds. Forced Dialyzer passed with zero errors, skips or unnecessary skips in 38.72
seconds; the full precommit command exited successfully. Captured application/test
sources are unchanged by upstream `8d172891`; merged documentation gates remain
required. Log: `/tmp/kittens-audit-expiry-marshall-full.log`.

## Expiry publication integration

Rebased onto `fcb047fb` after reviewing upstream Brady streaming-cache and
proc-less namespace repair source/evidence. The later Galileo documentation
records two observed deletions after healthy activation; it does not establish
arbitrary namespace churn. Marshall library, tests, configuration, mix files,
protocol and shared HLDD validator sources compare exactly unchanged against
the full expiry capture `a1b9149e`. The pre-rebase structural/generated/reference
gates and evaluated Nix HLDD check passed (7 seconds; archive
`1790967761033-2933872-0.jsonl`). Merged documentation verification passed. Native upstream records retain their own scopes; no fresh combined
native execution is claimed.

Merged ADR, HLDD receipts/references, generated coverage/views/options and
evaluated Nix HLDD gates passed; Nix took10 seconds (archive
`1790967891809-3014207-0.jsonl`). Normal commit hooks passed. Log:
`/tmp/kittens-audit-expiry-merged-gates.log`. Architecture impact remains
additional bounded ADR0074 evidence; decision/status and execution authority
are unchanged. Independent-service commit/crash and native/hosted gaps remain.


## Mixed service level backlog histories (focused execution recorded)

The local draft property `mixed deadline backlogs preserve totals and refuse
premature freshness` extends ADR0133 evidence without changing its accepted
architecture or partial implementation status. It uses real Ash admissions and
bounded production reconciliation, with sandbox-only synthetic measurement clocks.
Every history owns a fresh sandbox so an expected publisher rollback cannot
abort an enclosing workload transaction. Exact first-scan counts enforce the
100-attempt bound; second-scan completion checks progress past future attempts.
Future attempts remain pending, operations remain unchanged and terminal totals,
buckets, durations and source lifetimes remain exact. Refusals retain prior file
bytes; success must advance a shared sample clock and publish the same lifetimes
and numeric totals. The value menu covers0/1/99/100/101/102 overdue attempts,
with fixed zero/below/at/above/all-overdue witnesses and both ordering families.

Fresh source review caught and repaired nested rollback isolation and the missing
bounded-scan oracle; success freshness checks were then strengthened. Formatting and compilation passed. The ID-map version passed one focused
property (seed `572736`, 49.8 seconds); the stronger successive-sample oracle also passed (seed `614922`, 44.3 seconds).
Full gates and HLDD verification remain pending. No external
commit, process restart, independent publisher contention, native guest outcome,
collector/exporter or hosted fault claim follows from this draft. Existing
native execution records retain their original revision and scope.

The first pinned focused run (seed `248568`) failed an unordered operation-list
comparison after three successful generated runs. Independent comparison of the
reported 51 left/right records found identical IDs and complete record contents.
The oracle now maps complete operations by ID; no state fields were removed and
no production change was made. Formatting/compilation passed; the corrected
focused run passed. Failure log: `/tmp/kittens-slo-backlog-focused.log`.

The successive-sample SLO oracle passed one property, seed `614922`, in44.3
seconds, including guaranteed0/99/100/101/102 overdue histories and generated
0/1/99/100/101/102 mixtures. Every success advances from its immediate prior
files and all services share one sample clock. Log:
`/tmp/kittens-slo-backlog-focused-fresh.log`. Full/static and evaluated gates
remain pending.


The pinned full Marshall test stage passed 1,413 checks (214 properties and
1,199 tests), with two exclusions, seed `252201`, in 1,289.0 seconds. This
includes the successive-sample backlog oracle. Log:
`/tmp/kittens-slo-backlog-marshall-full.log`. Forced Dialyzer passed in 49.65
seconds with zero errors, skips or unnecessary skips; the full precommit command
exited successfully. Final handbook/evaluated gates remain pending.

Final SLO publication verification: pinned ADR/HLDD/generated coverage/options/
views and evaluated Nix HLDD passed before rebase (8 seconds, archive
`1790969868572-86080-0.jsonl`) and after integration (9 seconds, archive
`1790969950294-132379-0.jsonl`). Compared with full capture `82c9ab4b`, Marshall
lib/test/config/mix, protocol and shared handbook validator sources are unchanged.
Upstream live egress acceptance and its scenarios are preserved. No fresh combined
native execution or hosted fault acceptance is claimed.
