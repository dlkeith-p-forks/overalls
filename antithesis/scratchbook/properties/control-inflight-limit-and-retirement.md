---
sut_path: /home/ghuntley/src/overalls-antithesis-reset
commit: c835eb1017d24a001215c319373fa4204d64269b
updated: 2026-10-13
external_references: []
scope_answer: "Repository only (Recommended)"
focus: "05 — Resource Boundaries"
---

# control-inflight-limit-and-retirement

**Claim, priority, confidence.** P1 safety, high confidence in client contract. The shared Control WebSocket must hold no more pending requests than the current accepted welcome limit; saturation returns busy without sending a new frame, and timeout/disconnect retires pending calls without automatic redelivery. Proposed unique assertion: Always("control client pending requests fit negotiated window and busy calls send no frame", pending_count <= welcome_limit && busy_ids_have_no_wire_request). Missing per ../existing-assertions.md. This is the memory/request-ID boundary, not a promise that the remote task did not commit after a lost reply.

**Source and history.** protocol/lib/overalls_protocol/control/client.ex:21-32 defines default in_flight=8 and maximum=256. request/4 at :52-65 defines the no-hidden-redelivery contract; handle_call at :116-145 refuses non-ready or full pending state before frame send, then owns timer and pending map. Timeout at :175-185 removes pending entry; disconnect settlement and welcome validation are later in the same module. marshall/lib/marshall/control/socket.ex:118 starts a supervised request task, so a remote effect may outlive the reply channel. Existing property candidates in focus04 cover response retirement; this focus isolates the configured pending window and transport resources.

**Workload and oracle.** Run real Control server and client over a socket proxy that can hold response frames while recording outbound request IDs. Issue 8/9 or configured 256/257 concurrent valid reads/mutations, then drop the connection and reconnect. Compare client pending state under a debug-only snapshot with proxy-observed frames and server-received IDs. Busy calls must produce no frame; completed/timeouts/disconnects release caller slots; no old ID may be retransmitted on new socket. Reconcile any mutating timed-out request against durable Marshall identity before alleging no effect.

**Limit menu.** Invalid/missing welcome falls back to 8; valid advertised 1, 8, 255, 256; invalid 0/257; exact window and one over. Include short caller timeout, delayed server task and reconnect. Do not exceed practical socket/BEAM capacity merely to hit the configured maximum.

**SUT guidance and limits.** Mark window validation, busy refusal, pending insertion and retirement with bounded metadata only. Real hosted WebSockets suffice; a mocked GenServer cannot validate wire-frame absence. Open questions: None for fixture design. Actual proxy correctness and postcommit timing require a hosted setup check before a result is claimed.

**Architecture/HLDD impact.** No source or handbook change; tests existing Control memory and reply-custody contracts.

### Investigation Log (2026-10-13)

#### Frame history and postcommit receipt fixture

- Examined: `Control.Client` pending/send/retirement, `Marshall.Control.Socket` task dispatch and `Marshall.SSH.Commands` atomic request receipt. Found: a recorder placed before the server can assign an exact sequence to each complete outbound request before forwarding, then suppress one server response after the unique Porsche Request/Operation commits; the domain row is an independent effect witness. Not found: an existing checked-in proxy or hosted execution proving half-close behavior. Conclusion: this is a concrete fixture design; first validate proxy ordering and record completeness with a no-fault and forced-half-close control run. A dropped reply is `:unproven`, not evidence of no effect.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `control`. real-hosted-db-and-control; independent witness: consistent PostgreSQL rows plus independent caller/wire ledger. Native companion: not required for this bounded claim. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

### Authored workload (2026-10-13)

`antithesis/control_peer/runner.exs` now invokes the real shared BEAM client
against a socket-observed peer. The `capacity` mode inventories exactly the
negotiated number of requests, tests one excess call, records its wire absence,
settles the batch, reconnects with a replacement welcome and sends a fresh
sentinel. `antithesis/workload/control/bounds.py` emits the catalog's primary
literal only from a complete typed result; fixture failures remain unavailable.
SDK-selected windows include 0/257 fallback and 1/8/64/255/256 valid bounds.
This is authored local transport coverage, not a recorded hosted baseline or a
Marshall domain-effect proof.

## Authored assertion snapshot

**Authored assertion snapshot (2026-10-13 15:03 UTC):** Primary `always` message is present at `antithesis/workload/control/bounds.py:44`. Real BEAM Control client against an independent controlled WebSocket frame ledger; Marshall domain effects are outside the peer fixture. It is in current staged control-core command/dependency set. This records source presence, not a passing hosted or native result.
