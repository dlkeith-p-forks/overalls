# Thread attachments architecture review

The attachment feature adds Marshall-owned metadata and an encrypted blob adapter.
PostgreSQL remains authoritative for thread ownership, lifecycle state, idempotency,
and audit identity; the blob store must never grant access.

The 2026-10-21 implementation audit found this feature incomplete. Follow-up
changes add current authorization and atomic token consumption at redemption,
HTTP transfers, and an independent lifecycle property oracle. Durable shared blob
placement, deletion reconciliation and comprehensive audit coverage remain
outstanding. The pure lifecycle property does not establish database concurrency
or native storage durability.

The hardcoded blob encryption key fallback has been removed: missing or invalid
explicit key configuration now refuses operations. Production key provisioning
and rotation integration remain unfinished. Native blob durability and malware
scanning are also unverified. This review is not deployment acceptance.

Subsequent implementation work replaced schema-less metadata reads with the Ash
resource and uploads with create/begin-upload/publish/fail actions. Database
regressions now exercise upload persistence, token issuance, wrong-token refusal,
redemption and replay refusal. Eight concurrent callers using the test sandbox
observe exactly one successful redemption; separate-connection linearizability
and revocation races remain unverified. The lifecycle property now uses an
independent oracle. A browser POST download route has been added with persisted
login verification, CSRF protection, a header token and no-store binary responses;
Focused controller tests exercise authenticated upload/download and login
revocation; browser and native transfer acceptance remain unverified.

Current follow-up evidence includes authenticated multipart upload/download,
revoked-login refusal without token consumption, server-worker attachment dispatch
and transactional content-free tool outcome receipts. Guest executors exclude
server-owned thread and attachment commands. Upload retries compare content hash
and size; conflicting content refuses. The retry lookup uses the same thread-wide namespace as the resource identity,
including retries by another currently authorized writer; it preserves the original
uploader. Failed storage writes retain their expected hash and size for recovery
with the same content. Upload creation is serialized under the
user-thread lock and upload success diagnostics are deferred until outer commit.

## Remaining acceptance work

- Replace model base64 arguments with an implemented guest transfer/reference flow.
- Provision durable shared storage and rotating production encryption keys.
- Extend passing shared-reader and revoked-grant regressions to independent-connection races.
- Extend upload failure recovery coverage; complete cleanup reconciliation and audit coverage.
- Extend generated upload database histories to authorization and independent-connection races.
- Reconcile snapshots, ADR/HLDD scenarios and review receipts; run full gates.
- Revalidate original prompt auto-start, failure reporting, UI action placement,
  profile-scoped message boards, stop/suspend cleanup notifications and thread tools.
- Commit and push the completed, verified follow-up without overwriting other agents.

## Generated upload recovery evidence

`marshall/test/marshall/agents/attachment_history_test.exs` passed on 2026-10-21
in 8.8 seconds (ExUnit seed 392305). The Hegel dependency checkout matches the
locked `b0dec2abf868c7036950c00256a2ebf5af2929e7` revision. The property uses the
runner's default exploration setting and bounded sequences of up to 15 uploads,
with three synthetic contents and available/unavailable encryption configuration.
An independent model checks persisted identity, state, digest, size, successful
blob reads, conflicting retries and recovery from failed writes. Each generated
case creates and cleans its own sandbox and blob directory. This is sequential
BEAM/database evidence, not independent-connection, process-crash, native storage,
production key rotation or multi-replica acceptance. Full gates remain pending.

## Server worker lock-order finding and correction

High severity: `Marshall.Agents.ThreadToolWorker.claim_locked/0` first locks the
command, and `authorized?/2` then locks its VM. Attachment upload or token issuance
subsequently locks the user thread. `Marshall.Threads.Sharing.run/3` locks the user
thread before the VM, as required by `thread-share-lock-order`. Concurrent sharing
and attachment execution can therefore deadlock (worker holds VM and waits for
thread; sharing holds thread and waits for VM). Guest executor operations also
acquire command locks after their execution-authority checks. Current focused
sandbox tests do not establish independent-connection deadlock freedom.

The worker must select a candidate without claiming it, acquire the applicable
user-thread and execution-authority locks in the established order, then claim
and recheck the command/current running turn before effects. Attachment targets
can differ from the executing thread, so all required user threads need a stable
ordering. Claim races must leave one durable outcome and one audit receipt; stale
turns, grant revocation and machine stop must refuse effects. This correction and
independent-connection regression remain required before deployment acceptance.

The follow-up worker now selects an unlocked candidate, prelocks its attachment
target user thread, locks and rechecks the running turn/current agent thread,
checks VM authority, then locks and rechecks the queued command before dispatch.
This removes the identified attachment target-thread/VM inversion and the initial
command-before-VM claim order. Existing turn/model coordinator ordering is retained.
Other lifecycle paths and independent-connection races still require review and
execution; this source correction is not a general deadlock-freedom claim.

Download integrity now compares decrypted bytes with PostgreSQL SHA-256 and size
before token consumption. The service regression substitutes an authenticated
same-length encrypted blob, verifies refusal, restores the original and redeems
the unchanged token. The focused service suite passed three tests (seed 759840).
That devenv-shell run also emitted repeated content-redacted runtime diagnostics;
the isolated PostgreSQL log identifies connection exhaustion (`too many clients`).
The test pool uses twice the online scheduler count; this devenv run exposed 192
schedulers. Use `ERL_FLAGS="+S 4:4"` for the isolated test database to bound the
pool to eight connections. The diagnostics reviewer has been notified.

## Guest transfer integration boundary

Source inspection confirms that renaming `content_base64` to a path in the model
schema alone cannot implement transfers. `lyra/src/agent.rs` executes guest tools
only after the fenced started transition and currently has no attachment branch.
`Marshall.Agents.ExecutorSession` explicitly excludes attachments from guest claims;
`ThreadToolWorker` executes them on Marshall, which cannot open a guest path.
The model schema in `model_protocol.ex` still accepts content bytes despite its
out-of-context description. This remains an implementation gap, not a completed
transfer feature.

Existing authenticated transport can carry a dedicated transfer operation:
Lyra's typed lease/command requests reach Ziggy's private agent routes, whose
host binding is validated by `Marshall.Agents.ExecutorRPC`. Route allowlists also
exist in `Ziggy.Control` and `Marshall.Inference.ControlRequests`. Existing
bootstrap/maintenance artifact routes demonstrate authorization but serve
startup-verified host artifacts, so they are not an attachment storage endpoint.
A guest attachment implementation must register the operation across these
boundaries, validate current command/executor/fence and thread authority, bound
transfer bodies, and keep bytes out of command arguments, terminal results and
model context. Upload/download tool arguments must select guest paths; responses
must contain metadata only. No route, claim exclusion or model schema has been
changed speculatively during this inspection.

Marshall now implements `ExecutorSession.attachment_upload/5` and the
`agent_attachment_upload` control route through `ExecutorRPC`. The closed input
contains binding, executor ID, fence, command ID and base64 transfer body; decoded
content is limited to 10 MiB. The body is separate from command arguments/results.
Current started command, executor/VM binding and thread write authority are
required. This is only the Marshall leg: Ziggy forwarding, Lyra execution,
download transfer and model schema replacement remain outstanding.

## Transfer framing constraint discovered before Ziggy integration

The one-shot upload RPC is not yet transport-compatible for the full attachment
limit. `Marshall.Control.Services.Ziggy` accepts at most 1,100,000 + 4,096 inbound
bytes; ADR-0142 explicitly records that limit and 256 concurrent requests. A
10 MiB base64 upload exceeds it. The passing direct ExecutorRPC regression does
not exercise socket framing. Ziggy's existing agent POST handler also limits
bodies to 12,288 bytes. Adding an allowlist entry alone would ship a broken path.

Keep the established shared control bounds. The next transfer implementation must
use bounded chunks with durable upload identity, expected size/hash, ordered or
idempotent chunk writes, an explicit finalize transition, and cleanup for abandoned
uploads. Per-chunk authorization must bind the current command/executor fence;
finalization must publish metadata only after whole-content verification. Downloads
need bounded offset reads under the same current authority. No Ziggy route or
shared socket limit was changed in this inspection. The current one-shot internal
RPC must be replaced or confined to the chunk protocol before guest integration.

Chunk persistence groundwork now uses the Agents `AttachmentChunk` Ash resource,
backed by PostgreSQL and AshCloak/Marshall.Vault. The new additive migration stores
only encrypted content, offset, size and digest, with a unique attachment/offset
identity. Trusted locked helpers enforce aligned 256 KiB slots, identical replay,
conflict refusal and whole-content assembly verification. This is partial staging
storage, not yet the production published-blob adapter or a connected guest RPC.
Resource snapshots, domain inventory, architecture decision and cleanup/transfer
integration still require reconciliation before commit.

`AttachmentTransfers` now implements current-thread-authorized begin, chunk and
finalize operations under thread/attachment locks. Begin replays compare declared
size and digest; finalization refuses incomplete content and publishes the verified
PostgreSQL chunks without a local blob copy. Chunk-backed downloads use the
existing current-authority/single-use-token path. Empty attachments publish with
the empty-content digest. Guest RPC wiring and orphan cleanup remain pending.

Lyra's attachment module now executes bounded uploads and downloads through the
chunk RPC. Downloads verify identity, offsets, lengths and whole-file SHA-256,
write a private temporary sibling, sync it and publish without replacing an
existing destination. Results contain metadata only. Three focused Rust tests
passed, including multi-chunk upload/download, heartbeat refusal, oversized input,
digest refusal and existing-file preservation. These local tests inject the
transport; they do not establish real guest/TLS/Marshall end-to-end acceptance.
Download model admission remains pending.

Browser multipart uploads now call `AttachmentTransfers.upload/4`, publishing
bounded encrypted PostgreSQL chunks and metadata in one transaction. Identical
completed retries return the existing identity; failed chunks roll back the
buffered operation. Client filenames/media types are discarded. This consolidates
browser persistence with the guest chunk path; it does not close the pending
storage-placement ADR, durable audit or orphan-cleanup requirements.
The four attachment controller tests passed against isolated PostgreSQL with seed
805150 and local AttachmentStore configuration removed, including browser upload,
chunk storage identity, byte redemption, single-use tokens and login revocation.
These tests establish BEAM/controller behavior only, not deployed durability or
native guest transport. Full gates and generated chunk histories remain open.

The durable buffered-upload property and legacy failure/retry property passed
in 36.4 seconds (ExUnit seed 829229). The Hegel dependency checkout matches
mix.lock revision b0dec2abf868c7036950c00256a2ebf5af2929e7. The new independent
per-key model covers empty, one-byte, exactly-256-KiB and multi-chunk inputs,
conflicting content and exact token redemption. This is sequential sandbox
coverage; native acceptance and independent-connection races remain open.

AttachmentAudit adds append-only content-free receipts for successful begin,
chunk write, publication and chunk read operations, in the operation transaction.
Browser token issuance/redemption, denied operations, deletion and audit failure
injection remain outstanding; this is not comprehensive audit coverage yet.
The focused service/history suite passed five tests in 37.8 seconds (ExUnit seed
180385) after adding transactional success receipts. Assertions verify exact
operation counts, initiating actor/thread attribution and successful chunk reads.
This does not yet verify audit-store failure atomicity or denied-operation receipts.

Generated receipt-insert fault injection passed (ExUnit seed 504506, one property,
7.6 seconds; two unrelated properties excluded). It injects PostgreSQL failures
at begin, chunk and finish receipts, asserts no attachment/chunk/receipt remains,
and checks fresh retry. An initial failed run (seed 611190) expected an exception;
the coordinator correctly returns a rejected transaction, so the oracle now
asserts that result and the unchanged database. Browser token issuance and
redemption now also persist transactional receipts. Redemption locks/rechecks the
attachment after acquiring thread authority before decrypting chunks. Token-specific
fault injection and denied/deletion receipts remain open.
After token audit integration, the combined three history properties and four
controller tests passed in 50.8 seconds (ExUnit seed 425205). Browser upload,
single-use download and login revocation remain green. This is focused evidence;
full project, distributed and native gates have not passed for this change.

Thread tool correction (ADR-0175): search now traverses authorized user-thread
pages and matches titles only; results link user-thread IDs. Reads check current
Cedar authority before resolving retained transcript bindings. Shared archived
read/search and revocation tests passed with the executor suite: 22 tests,
ExUnit seed 296716, 4.3 seconds. Malformed targets now produce a terminal failed
command with a content-free receipt instead of exceptions and endless polling.
The old diagnostic test depended on the malformed-ID defect; it now checks that
refusal, while unexpected-exception diagnostic fault injection remains separate.
Subscriptions/replay still use the old path and require implementation.

Subscription/replay correction: typed Ash resources replace schema-less writes
and reads. Current user-thread authority and retained binding are checked under
the user-thread lock. The worker acquires this target lock before turn/VM/command
locks. Replay requires an active subscription and uses a strict ascending cursor;
shared readers see authorized notifications without impersonating their creator.
The focused transcript/executor suite passed 22 tests (seed 460541, 4.5 seconds)
before the subsequent explicit active/inactive state-machine migration. Repeated
subscribe, unsubscribe, replay cursor and grant revocation assertions are present.
Cross-generation subscription continuity, reliable production, audit coverage and
property histories remain outstanding.

The active/inactive Ash state machine and preserving boolean-to-state migration
passed six transcript tests, including a generated activation history with an
independent boolean oracle (ExUnit seed 272987, 33.2 seconds). Every generated
case creates a fresh sandbox and checks stable subscription identity, persisted
state and replay refusal while inactive. This does not verify replacement-machine
continuity or actual cleanup-event production/delivery.

The schema-less message-board facade failed UUID encoding during physical stop
and confused user-thread post IDs with agent-thread notification IDs. It now uses
Ash Board/Post resources under MessageBoards.Domain. Cleanup and per-thread
notification insertion share a transaction and serialize with machine-tagged
post admission through the VM lock; diagnostics wait for commit. Notification
sequence assignment uses a per-agent-thread advisory lock, with no conflict-drop
fallback. Posting checks current actor/thread/VM authority and running state.
The atomic VM-change callback now retains the cleanup hook. Stale cleanup calls
skip a resumed VM whose current desired and observed states no longer match.
An initial board/capability/prompt suite passed 14 tests (seed 897170, 3.1 seconds),
before the subsequent callback/state-guard changes. Generated cleanup validation
is still pending; no deployed subscriber-delivery claim is made.

The generated cleanup property and ordinary-machine cleanup test passed with the
prompt suite: 10 tests, ExUnit seed 456568, 21.9 seconds. The property checks
pause/stop/delete, exact per-thread counts, unrelated-post retention, idempotent
cleanup and late-post refusal. Its first run (seed 727178) exposed a malformed
return path: Ash treated the returned forbidden tuple as a transaction error and
the facade pattern-matched success. The fixed facade returns domain refusal as
data, preserving the transaction boundary. Native subscriber wake/delivery,
independent-connection races and notification-write fault injection remain open.

Seven generated Ash snapshots now cover attachments, chunks, attachment audits,
thread-tool events/subscriptions and boards/posts. Resource migration metadata
was reconciled with handwritten foreign keys, index names, defaults and checks
before generating snapshots in a scratch directory. Only those seven tables were
copied; the scratch generator's extension migration was moved out without applying
it. After reconciliation the combined attachment histories, cleanup histories,
transcript/subscription and controller suite passed 15 tests in 96.1 seconds
(ExUnit seed 313351). ADR-0251/0252 record accepted requirements and explicit partial
implementation; this does not close native, distributed, delivery or full-gate gaps.

## Original prompt incident: live diagnostic boundary

Read-only production inspection on 2026-10-21 found the initial prompt for
`01a15ae0-001d-7f4f-9945-97038de0499e` had been automatically admitted with its
`thread-initial:` request key. All three recorded turns failed at the provider
boundary on dungarees. Historical records retain `upstream_error` but not the
HTTP status or provider classification, so their precise causes remain unknown.

The deployed Ziggy configuration routes OpenAI-compatible requests to local
Underclass at `http://127.0.0.1:8080`. A minimal request through that configured
route returned HTTP 503 with closed error type `no_accounts`. The read-only local
monitor reported zero configured accounts. This establishes the current inference
blocker, not a retrospective diagnosis of every historical failure. An earlier
direct OpenAI probe used the proxy credential and returned 401; that probe used
the wrong destination and is not evidence of an invalid deployed credential.
No credentials or production database passwords were changed. Account enrollment
or restoration and successful end-to-end prompt execution remain outstanding.

The full Marshall precommit attempt stopped at stale HLDD review receipts before
compilation or tests. It is not a passing application gate. Thread-tool reads now
explicitly refuse JSON-encoded objects over 64 KiB, with a generated regression
covering ASCII, Unicode and JSON escaping. The isolated transcript suite passed
seven tests in 38.2 seconds (ExUnit seed 128374), including that property and the
subscription state history. This verifies the bounded read response in the BEAM
test environment, not live provider or guest integration.

## Board tool registration and typed cursor correction

The model catalog and persisted command enum now include `message_board` for
Standard and OSS. The server worker derives account identity from the turn actor,
profile/machine from the current root, and an optional user-thread link from the
locked current binding. Arguments accept only list or body/retry-key post data.
Guest command selection excludes these commands. Existing command completion and
tool audit records share the transaction. Board list output includes thread links,
is capped at 100 posts and refuses encoded arrays above 1 MiB. Older-post paging
and the requested Work profile mapping remain unresolved.

The thread replay schema and parser previously required a string cursor even
though the coordinator required a nonnegative integer. They now agree on integer
cursors, and each thread operation rejects unrelated fields. This corrects the
model-facing API under ADR-0252 without changing thread authorization.

The first focused run passed 33 of 34 tests. The new integration fixture attempted
to start a second simultaneous running turn and correctly hit the database's
single-running-turn constraint. It now queues its list command in the existing
running turn. This is a fixture correction, not a relaxation of the constraint.
The rerun passed all 35 model protocol, capability property and executor-session
tests in 3.9 seconds (ExUnit seed 505470). Assertions cover server execution,
guest-claim exclusion, derived machine/thread attribution, thread links, private
board isolation, successful audit receipt, forged-scope refusal, unsupported
profiles and replay cursor typing. No native delivery or full application gate
acceptance follows from this registration change.

## Durable subscription identity across machine generations

Subscription and notification resources now retain both a durable user-thread ID
and the originating agent-thread ID. Subscription lookup and replay use the user
thread; notification sequence allocation uses its advisory lock across machine
generations. Existing subscriptions can replay and change active/inactive state
while replacement provisioning has cleared the current agent binding. Creating
a first subscription still requires a bound agent thread. Current Cedar read
authority remains mandatory under the durable thread row lock.

The additive migration preserves origin IDs and existing cursor values, backfills
through current and retained generation bindings, and refuses ambiguous mappings
or uniqueness conflicts rather than deleting histories. A compatibility insert
trigger derives attribution for old writers and assigns their notifications the
next durable thread cursor. It is temporary rollout code; remove it only after
both replicas converge. A read-only production count on 2026-10-21 found both old
tables empty, but migration still validates its actual input transactionally.
The migration has not been applied to production.

The isolated transcript and cleanup suites passed nine tests in 47.7 seconds
(ExUnit seed 587060). This includes activation and cleanup properties plus a
replacement-machine regression checking retained subscription identity, pending
replacement replay/unsubscribe/resubscribe, and strict cursors across generations.
The additional old-writer trigger regression passed separately in 1.1 seconds
(ExUnit seed 67043): a generation-local cursor inserted without user attribution
becomes the next global cursor and replays after the previous generation. Generated
snapshots for the two affected resources were compared with the additive migration
and copied from scratch output; no generated migrations were applied. Full gates
and native automatic delivery remain outstanding.

## Automatic receiver delivery

ThreadReceiver adds a persisted active/inactive state machine and per-agent
acknowledged cursor. Agent subscribe/replay now checks that receiver independently
of the account subscription. Root-agent destinations follow their durable user
thread; child agents and ordinary machines retain their exact agent identity.
One receiver can unsubscribe without disabling a peer. The application supervises
ThreadDelivery alongside the existing agent loop and server tool worker.

Delivery locks target and destination user threads in stable UUID order, then
the destination agent, VM and receiver. It rechecks target read and destination
write authority. Permission loss disables the receiver; an unavailable machine
defers without automatic wake. One metadata-only system-notification turn, its
content-free admission receipt and the receiver cursor commit together. Stable
receiver/sequence request keys prevent duplicate turn admission. Model context
identifies the event as a system notification rather than a fabricated user
request. The ordinary agent loop processes the queued turn through its existing
context, model and executor checks. Unexpected polling exceptions emit the
catalogued `agent.notification_poll_failed` event with a closed reason only.

The initial suite passed 35 tests (seed 63196, 37.2 seconds), then 36 tests with
paused receivers and context checks (seed 809131, 36.2 seconds). The expanded
authority suite passed 36 tests in 43.7 seconds (ExUnit seed 78191). Its generated
cleanup histories cover pause/stop/delete, delivery retries, a paused receiving
machine, revoked target read access, explicit resubscription, and failure of the
mandatory admission audit write. Failure leaves no turn or notification event and
does not acknowledge the cursor; a retry after removing the fault produces one
turn. A server-worker regression verifies root/child receiver separation and
unsubscribe/replay refusal without disabling the child. These are isolated
BEAM/PostgreSQL results, not independent-node, live-provider or physical guest
delivery acceptance. Full gates remain outstanding.

## Attachment cleanup completion evidence

Attachment deletion and abandoned-upload reclamation now use the attachment state
machine. Manage-authorized deletion destroys durable chunks before `deleted` and
records content-free deletion receipts. A supervised hourly-equivalent poll
expires pending/uploading rows older than 24 hours into `failed`, with a null-actor
system receipt; matching retries reuse the row identity. Available attachments
remain readable through retained user-thread history after archival. The focused
attachment tool suite passed five tests (ExUnit seed 989234, 1.4 seconds), and the
executor upload regression passed with the same build. The prior full-suite run
had one stale compiled-resource failure for the newly introduced touch action;
removing the unnecessary action from chunk writes fixed that path. A separate
account lifecycle property timed out in Cedar policy simplification after 120
seconds and is unrelated to attachments; the full gate is not green.

## Attachment retention and cleanup

Attachment reads now resolve retained user-thread history, so authorized readers can
read available content after machine archival. Explicit deletion requires current
thread manage authority, destroys encrypted chunks before terminal `deleted`, and
records content-free deletion receipts. A supervised cleanup worker expires
pending/uploading rows older than 24 hours into `failed` with a system receipt;
matching retry keys reuse the durable row identity. Machine stop/suspension leaves
available attachments intact. The focused attachment tool suite passed five tests
(ExUnit seed 989234, 1.4 seconds), including deletion and expiration. Independent
connection races, key rotation, native transfer acceptance and full gates remain
open.

## Gate result

The Marshall precommit run on 2026-10-21 passed toolchain, ADR and HLDD checks,
then stopped in the repository-wide code-contract gate on nine pre-existing Mila
Rust files (`mila/rust/mila-crypto`, `mila-ffi`, `mila-model`, `mila-protocol`,
and `mila-runtime`) whose surrounding comments lack `@cc` directives. No changed
Marshall, Ziggy or Lyra file was named in that failure. The gate was not bypassed;
this remains a repository-level blocker for a clean precommit result.
