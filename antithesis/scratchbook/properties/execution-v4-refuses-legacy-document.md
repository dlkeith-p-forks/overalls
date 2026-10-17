# execution-v4-refuses-legacy-document

P0; high confidence; safety. Planned `AlwaysOrUnreachable` message: **"Execution v4 refuses legacy authority without changing durable command"**. If an authenticated Control-v1 connection delivers an execution session, exchange or command with unsupported **inner Execution version** (including a historical v1 receipt), Lilly must not turn it into executable intent, acknowledge an outcome, or erase the last durable command. The optional incompatible-document path can be absent, so `AlwaysOrUnreachable` checks every reached case. The [2026-10-17 assertion scan](../existing-assertions.md) finds the assertion authored with a narrower Marshall-side witness; see the snapshot below. `Reachable` **"Execution v4 accepted matching machine-bound session"** provides a positive compatible outcome.

Source: `protocol/lib/overalls_protocol/execution.ex:51-78,367-385` requires v4 session/machine identity and rejects other versioned documents; `lilly/lib/lilly/control/client.ex:216-220,284-295` validates session and command batches before use; `lilly/lib/lilly/control/runtime.ex:500-523` fences `unsupported_version` instead of backoff; `lilly/lib/lilly/control/config.ex:47-73` requires runtime config v4. Outer Control envelope v1 is independent (`control/envelope.ex:20,34-41`). The v1 receipt cannot be promoted merely because it arrives in a valid v1 WebSocket envelope.

Workload and independent oracle: run the real Control client and Runtime with a version-varying authenticated peer under a test-only server seam, seed a known v4 placement command, then inject a v1/v3/v5 session or response. Read Lilly Store and Journal files under owner lock, observe physical launch marker and current actor command, and compare with an independent command ledger. A closed or timed-out socket response is unproven; a definite unsupported-version error is terminal for this peer generation. After replacing with compatible v4 peer, require a fresh machine-bound session and durable resynchronization before a new effect.

Value menu: outer v1 with inner 1/3/4/5, missing version or extra field; matching/wrong machine SHA; one valid versus mixed invalid batch (limit 16); stale/new generation; initial session versus later exchange; reconnect with same versus changed peer release. Hosted real BEAM/Store/control service exercises protocol semantics; Firecracker effect fencing needs native testing. Open question: can the test-only peer seam inject malformed inner documents while preserving actual outer TLS/WebSocket and service binding?

Status: `(partial: Retain partial transport-fixture question; state the parser refusal separately)`

Next probe: Client.exchange_execution validates inner v4 response fields and command documents after a Control request; malformed inner data produces invalid_message or codec error before Runtime accepts commands. Existing test peers show controlled responses, but inspection does not establish a TLS/WebSocket service-bound malformed peer fixture. Probe an authenticated test peer through the actual Control endpoint with inner v1/v3/v5 documents.

### Investigation Log

#### Can a test peer inject malformed inner documents over the real authenticated Control transport?

- Examined: `lilly/lib/lilly/control/client.ex:244-295; protocol/lib/overalls_protocol/execution.ex:367-385; lilly/test/control/terminal_close_property_test.exs:36-80`.
- Found: Client.exchange_execution validates inner v4 response fields and command documents after a Control request; malformed inner data produces invalid_message or codec error before Runtime accepts commands. Existing test peers show controlled responses, but inspection does not establish a TLS/WebSocket service-bound malformed peer fixture. Probe an authenticated test peer through the actual Control endpoint with inner v1/v3/v5 documents.
- Not established: No current hosted/native execution was run in this investigation; source and test presence alone do not establish the physical outcome.
- Conclusion: partial; Retain partial transport-fixture question; state the parser refusal separately.Open questions:

- Can a test peer inject malformed inner documents over the real authenticated Control transport? `(partial: parser refusal shown; authenticated malformed-peer fixture unproven)`

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `control`. real-hosted-db-and-control; independent witness: consistent PostgreSQL rows plus independent caller/wire ledger. Native companion: not required for this bounded claim. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R2`: The focused command must also emit a distinct `Reachable` at the actual incompatible/corrupt/restart/negative-status danger branch. Optional-path safety can pass without that branch; positive compatible traffic is insufficient. `R4`: Keep exhaustive fixed decoder/version/migration matrices in ordinary tests. In Antithesis, race representative invalid input with a real restart, authority change or valid effect and observe the independent outcome. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

## Authored assertion snapshot

**Authored assertion snapshot (2026-10-17):** Primary `always_or_unreachable` message is present at `antithesis/workload/control/dispatch.py:351`. After a valid v4 session, inner Execution v1/v3/v5 session documents on an authenticated Control v1 socket must receive `unsupported_version`, leave their fresh session row absent and leave Marshall's committed host session and epoch unchanged; a concurrent change by the live Lilly runtime leaves that request unexercised. The distinct danger-branch `Reachable` is `Execution legacy inner session reaches authenticated decoder refusal`. Scope: Marshall's request decoder and durable host row only; Lilly's response parser, Store, Journal and physical launch marker are not observed. The `control_legacy_request` singleton is in the staged control-core selection. This records source presence, not a passing hosted or native result.
