# control-no-hidden-redelivery

Priority: P0. Confidence: high. Type: Safety.

## Guarantee and proposed assertions

One explicit call into the control transport emits at most one application request frame. A disconnected/busy call is not queued, and pending work lost with a connection is not automatically resent. Proposed workload `Always(peer_count_per_explicit_call <= 1 && no_reconnect_replay, "Control transport never redelivers an uncertain application call")`; the condition uses an independent explicit-call and peer-receipt ledger. Evaluate in the baseline and after every reconnect, so `Always` is required. Optional SUT-side no-effect check: `AlwaysOrUnreachable(no_request_queue_restored, "Control connection replacement has no retired request queue")`. Assertions are missing per `../../existing-assertions.md`.

## Evidence and failure history

- `protocol/lib/overalls_protocol/control/client.ex:52–57`, contract `control-request-no-hidden-redelivery`, distinguishes transport refusal from application reconciliation. `handle_call/3` at 124–145 returns disconnected/busy immediately; it sends once and retains only response waiting data. `lost/2` at 401–415 clears pending rather than enqueuing replay.
- `lilly/lib/lilly/control/client.ex:896–919`, `request/3`, explicitly sends each authenticated exchange once; adapter classification at 982–993 cannot imply a domain outcome or retry.
- `marshall/lib/marshall/control/socket.ex:3–7`, 132–142: async domain transactions may outlive the dead socket; only the response can be lost. This is the most important ambiguous-effect history, not a rollback guarantee.
- Ordinary regression `protocol/test/control/client_test.exs:388–547` checks no replay of retired batches. Lilly runtime `lilly/lib/lilly/control/runtime.ex:823–858` intentionally coalesces one application exchange task and periodic/hint work. Such fresh cadence is allowed and must receive a new explicit-call ledger entry. No specific closed issue or fresh reproduction was found; this is an explicit recovery contract target.

## Fault history, independent oracle and workload

Start one explicit exchange with a unique workload nonce through the real adapter; allow Marshall's domain transaction to commit, cut its response path, reconnect, and remain silent at the application layer while transport retry proceeds. Separately cut before dispatch and saturate the negotiated capacity. A dedicated test peer counts application request frames by invocation nonce; a real-service scenario queries committed receipts/effects by a stable domain operation ID to show why unproven cannot be treated as no effect.

Keep two ledgers: transport invocation identity and domain idempotency identity. Only the former must have at most one wire delivery. Applications may intentionally make later explicit calls with the same domain key, and domains may idempotently return an old receipt. Do not assert that every request commits exactly once, that an unproven call rolled back, or that no layer retries. Peer evidence must include observation after reconnect and a fresh sentinel call to show the absence of old frames is not merely a permanently dead client. Ordinary transport decoding helpers may parse captured frames; expected counts must come from the workload's independent invocation ledger.

Parameter menu: each service; pending 1/L/L+1 for limits 1/8/64/256; cut before send, after peer receipt, before commit, after commit, before response; deadline 50/5,000 ms; loss, draining 4007, idle 4008, overload 4004 and unknown close. Hold application cadence through at least two peer-observed recovered handshakes rather than rely on a fixed sleep. Retry ceiling 1,000→2,000→4,000 ms uses full jitter 1..ceiling, and draining uses 1..500 ms.

Add a branch checkpoint after durable commit and before socket reply, then replay with response-path loss. That checkpoint must be a reviewed Events/SDK boundary carrying only identifiers and fixed outcomes, never command arguments, credentials or payloads. A controlled peer alone proves wire delivery behavior; a real DB transaction is needed for the ambiguous committed-effect case. Native execution idempotency belongs to the execution focus. No mutation patch or acceptance claim is included.

## Open Questions

- None. The allowed application cadence is explicit in source and does not weaken the transport-only invariant.
