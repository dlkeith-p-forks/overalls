# host-credential-rotation-fences-old-socket

P0; high confidence; safety. Proposed `Always` message **"Committed host credential rotation fences old Control request authority"**. SDK instrumentation is **missing** per [fresh scan](../../existing-assertions.md).

Source: `marshall/lib/marshall/compute/credentials.ex:22-55,74-85` archives old credentials, invalidates current session and report, and issues the new credential under one host lock; `:100-131` rereads active credential after taking that lock and checks database-clock expiry and secret before domain dispatch. `:180-185` increments the connection epoch and clears the session but retains reservations. `marshall/lib/marshall/control/services/lilly.ex:25-54` authenticates at upgrade and binds the host in hello, yet passes the token through each request to `ProvisionerRequests`, so an already-open socket must also be fenced. ADR-0003 and ADR-0142 distinguish shared durable authority from transport identity. `marshall/test/marshall/compute/credentials_test.exs:49` includes stale-session coverage.

History: establish an old Control socket and a valid session; rotate/revoke credential through Marshall replica A; submit an otherwise valid old-token exchange over the still-open socket on replica B, including a prepared physical outcome, then enroll/use a new credential and session. Race rotation with the old request in both lock orders; only requests whose host lock precedes the rotation may commit first. Also let the old WebSocket reconnect after rotation.

Independent oracle: compare credential archival and host epoch/session to committed operation, outcome, report and reservation rows, plus Lilly's physical command IDs. After rotation's committed linearization point, old-token requests may not create an outcome, refresh a report or receive usable commands; the new credential can open and progress. Retained VM reservations are expected. A denied response is insufficient without checking rows and effect witness.

SUT guidance: proposed `AlwaysOrUnreachable` **"Archived host token failed current revalidation inside request task"** at the optional `Credentials.with_host/2` stale branch. The workload checks the primary `Always`. Proposed `Reachable` **"New host credential opened a successor session after rotation"** guides recovery.

Values: rotation/revoke/expiry; request before lock, while lock is held, and after commit; same/different Marshall replica; existing/reconnecting socket; old and new token; 1-second and configured upper-bound TTL, expiry boundary; old report fresh/stale. Service-only checks cover DB authority. Native host proof is required for a claim about physical execution.

Open questions: Can the hosted fixture hold a Control socket open while an operator rotation commits, or must the stale request be driven through the service handler? The latter still covers authorization but less transport behavior.
