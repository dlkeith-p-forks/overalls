# control-pending-response-retirement

Priority: P0. Confidence: high. Type: Safety, with a Reachable stale-response anchor.

## Guarantee and proposed assertions

A received response settles only its still-pending wire ID and settles that caller once; timeout or connection loss retires pending work without allowing stale replies to settle successor work. Proposed central workload assertion: `Always(caller_results_match_independent_wire_ledger, "Control responses settle only their live pending request")`. Check after each result, timeout, loss and fresh sentinel. Proposed `Reachable("Control late retired response is ignored while fresh work completes")` sits at the confirmed stale-response/no-effect outcome. The primary assertion must be encountered in every baseline; a fault-only internal auxiliary can use `AlwaysOrUnreachable(stale_reply_did_not_change_pending, "Retired control response cannot change the current pending batch")`. All are missing according to `../existing-assertions.md`.

## Evidence and failure history

- `protocol/lib/overalls_protocol/control/client.ex:132–145`, `handle_call/3`: increasing ID, one pending caller/timer per successful send.
- `handle_info/2` at 175–183 pops on timeout and ignores old timeout messages; `message/2` at 356–365 pops matching response ID, cancels timer, ignores unknown and duplicate IDs.
- `lost/2` at 401–415 cancels pending timers, sends every pending caller `{:error, :unproven}` and clears the map. `frames/2` at 231–246 stops a received batch when disconnected or stopped; no response after a close in that batch is handled.
- `protocol/test/control/client_test.exs:388–547`, `pending_batch/3`, supplies actual peer-observed counts 1/7/8, reordered and unknown responses, capacity pressure, dropped/timed-out batches and fresh sentinel work. Tests are present; none were freshly executed for discovery. Git `a110760f` made terminal close halt the frame batch as well as disconnected close; inspected diff establishes this mechanism, not an independently reproduced incident.

## Fault history, independent oracle and workload

Run the real shared client and an adversarial TLS peer. For each explicit application call the peer records its wire ID and workload nonce, independently of the client's pending map. Return distinct nonce-bearing bodies out of order, duplicate responses, an unknown ID, a response at the request deadline, a close followed by a plausible response in one receive batch, and late replies from a retired socket. Observe each caller through a monitored workload process with a result count; include a fresh request after capacity is released and after reconnect.

Expected result is one matching successful response or one permitted timeout/unproven/loss classification, never success with another nonce or a second settlement. An uncertain call does not prove its domain effect failed. New work must use its independently observed new wire ID. Instrument the `Map.pop` result and current connection generation for replay guidance; do not derive expected matches by calling the production decoder/pending-map helper. Peer wire observations plus caller receipts are the oracle; ExUnit process exit is not.

Parameter menu: omitted/malformed advertised limit (fallback 8), limits 1/8/64/256; pending counts 0/1/L−1/L/L+1; generated timeout 1/50/5,000 ms and reply before/at/after deadline; reorder all/partial, duplicate 1/2/4 times; IDs unknown, retired, live. Inject TCP split/coalescing, opening worker death and task/caller death. Exact timer ordering at equality admits either matching live reply or timeout, but retirement must remain consistent.

A controlled peer establishes transport state-machine behavior; pair with a real Marshall run for domain outcomes, which are separate. A current client uses monotone IDs across reconnect; manually injecting a matching ID into an unrelated new client is outside same-owner retirement semantics. No hosted/native proof is claimed.

## Open Questions

- None. Capacity and timer boundary values are source-resolved; workload instrumentation is missing.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `control`. real-hosted-db-and-control; independent witness: consistent PostgreSQL rows plus independent caller/wire ledger. Native companion: not required for this bounded claim. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

### Authored workload (2026-10-13)

`antithesis/control_peer/runner.exs` now runs the real shared BEAM client against
an independent socket peer. The `pending` mode records two call/wire IDs,
returns a reordered reply plus unknown and duplicate IDs, lets one call time
out, sends stale replies around a fresh request, then drops the socket and
checks an unproven caller plus a succeeding sentinel after reconnect.
`antithesis/workload/control/pending.py` emits the catalog's primary literal
only from a complete typed result. SDK-selected timeouts are 50/500/5000 ms;
two simultaneous calls require an eight-or-greater effective welcome window.
This is authored local transport coverage, not a recorded hosted baseline or a
Marshall domain-effect proof.

## Authored assertion snapshot

**Authored assertion snapshot (2026-10-13 15:03 UTC):** Primary `always` message is present at `antithesis/workload/control/pending.py:42`. Real BEAM Control client and independent held/late response peer ledger; no hosted execution recorded. It is in current staged control-core command/dependency set. This records source presence, not a passing hosted or native result.
