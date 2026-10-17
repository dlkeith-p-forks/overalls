# host-credential-rotation-fences-old-socket

P0; high confidence; safety. Proposed `Always` message **"Committed host credential rotation fences old Control request authority"**. SDK instrumentation is **missing** per [fresh scan](../existing-assertions.md).

Source: `marshall/lib/marshall/compute/credentials.ex:22-55,74-85` archives old credentials, invalidates current session and report, and issues the new credential under one host lock; `:100-131` rereads active credential after taking that lock and checks database-clock expiry and secret before domain dispatch. `:180-185` increments the connection epoch and clears the session but retains reservations. `marshall/lib/marshall/control/services/lilly.ex:25-54` authenticates at upgrade and binds the host in hello, yet passes the token through each request to `ProvisionerRequests`, so an already-open socket must also be fenced. ADR-0003 and ADR-0142 distinguish shared durable authority from transport identity. `marshall/test/marshall/compute/credentials_test.exs:49` includes stale-session coverage.

History: establish an old Control socket and a valid session; rotate/revoke credential through Marshall replica A; submit an otherwise valid old-token exchange over the still-open socket on replica B, including a prepared physical outcome, then enroll/use a new credential and session. Race rotation with the old request in both lock orders; only requests whose host lock precedes the rotation may commit first. Also let the old WebSocket reconnect after rotation.

Independent oracle: compare credential archival and host epoch/session to committed operation, outcome, report and reservation rows, plus Lilly's physical command IDs. After rotation's committed linearization point, old-token requests may not create an outcome, refresh a report or receive usable commands; the new credential can open and progress. Retained VM reservations are expected. A denied response is insufficient without checking rows and effect witness.

SUT guidance: proposed `AlwaysOrUnreachable` **"Archived host token failed current revalidation inside request task"** at the optional `Credentials.with_host/2` stale branch. The workload checks the primary `Always`. Proposed `Reachable` **"New host credential opened a successor session after rotation"** guides recovery.

Values: rotation/revoke/expiry; request before lock, while lock is held, and after commit; same/different Marshall replica; existing/reconnecting socket; old and new token; 1-second and configured upper-bound TTL, expiry boundary; old report fresh/stale. Service-only checks cover DB authority. Native host proof is required for a claim about physical execution.

Open questions: None for fixture design. The actual open-socket rotation race remains a hosted test target.

### Investigation Log (2026-10-13)

#### Open-socket rotation fixture

- Examined: `Control.Socket`, Lilly service adapter, `Credentials.rotate/revoke/with_host`, and `ProvisionerRequests`. Found: the WebSocket retains its bound principal while each request task forwards the original token to host-locked authentication; rotating credentials does not itself require closing the socket. Not found: a source constraint forcing service-handler-only testing, or a hosted race run. Conclusion: keep one old Control socket open on Marshall B, rotate through A, and issue the stale exchange on the same connection; use one real Lilly owner or a raw protocol client, not two competing Lilly runtimes.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `control`. real-hosted-db-and-control; independent witness: consistent PostgreSQL rows plus independent caller/wire ledger. Native companion: not required for this bounded claim. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

### Workload implementation (2026-10-13)

`antithesis/test/v1/host_rotation/singleton_driver_old_socket_fence.py` opens a session and confirms a valid empty v4 exchange on an issued-credential socket, then keeps it open while the separate reviewed operator process rotates against the shared PostgreSQL authority. After PostgreSQL confirms archival and the cleared session/incremented epoch, the old socket sends the same valid exchange and a fresh session request. A one-statement read-only snapshot checks host/session, report, operation, outcome and reservation effects; a fresh old-token upgrade on the other Marshall listener is probed independently. The new credential opens a successor socket and accepts an empty exchange. Rotation is terminal for this template because Lilly retains its startup credential. The controlled pool cannot yield a physical outcome; simultaneous pre-commit lock orders, native effects and hosted baseline execution remain unexercised.

## Authored assertion snapshot

**Authored assertion snapshot (2026-10-13 15:03 UTC):** Primary `always` message is present at `antithesis/workload/control/host_sessions.py:348`. Current Lilly old-socket/new-credential route only; other services and physical effects are separate. It is outside the currently staged control-core selection. This records source presence, not a passing hosted or native result.
