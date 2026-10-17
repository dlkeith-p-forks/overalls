# Console relay review

## Scope and evidence

ADR-0021 adds bounded console v1 envelopes over v2 host execution sessions,
durable console connections/request ordering, encrypted per-VM mailboxes, user
byte actions and HTTPS server/client methods. It extends ADR-0020's local gate
with explicit discard and delivery-result tracking. ADR-0019's VM lock remains
the user/session/writer serialization boundary.

## Findings and resolution

- **High, corrected stale-producer risk:** a relay can restart within the same
  host execution session. Consumed connection nonces and increasing console
  epochs exclude its predecessor. Host-session replacement and credential
  rotation also invalidate the connection.
- **High, corrected delayed-request risk:** a client HTTP timeout does not cancel
  a server transaction. Persisted request sequences reject older/equal requests
  before mailbox changes. A rollback does not consume the sequence. The client
  validates host, both session identities/epochs, request ID and request sequence.
- **High, corrected duplicate-input risk:** one pending sequence per writer epoch
  provides backpressure. Exact pending retries are idempotent; changed bodies
  conflict. Expired input becomes a no-byte discard, preserving sequence order.
  A gate restart reports uncertainty; subsequent input requires explicit writer
  release/reclaim. Already acknowledged attempts remain known across later gate
  uncertainty for that same sequence.
- **High, corrected retention/reset risk:** payload cleanup must not reset the
  active writer's input watermark. Cleanup preserves sequencing and pending
  discard metadata while clearing bytes. Access checks the inactivity deadline
  independently of AshOban execution. Last-reader closure clears payloads; a new
  reader lifetime rotates the relay ID. Joining readers cannot seek before their
  current mailbox tail. Output already in transit may arrive after they join.
- **High, corrected authorization risk:** every user read/input rechecks the
  account token, VM generation and Cedar access under the VM lock. Host exchanges
  take Host before sorted VM locks, prune revoked readers, and validate the writer
  before activating its fence. Sharing/lifecycle changes retain their existing
  lock order and invalidate queued authority. No terminal bytes enter PaperTrail.
- **Medium, explicit loss/backpressure behavior:** 64 KiB copied output windows,
  16 KiB pages, 4 KiB input and bounded VM collections prevent unbounded retained
  payloads. Overlaps must agree; truncation and incarnation changes report gaps.
  PostgreSQL encryption, polling and row-lock costs still require load measurement.
- **High, addressed runtime ownership boundary (2026-09-16):** the transport may
  obtain a gate only through an actor authorized by Runtime. The actor checks its
  current durable running generation and the executor verifies the physical VMM
  before supplying the socket. Gate directories are actor-derived. Both actor and
  relay death detach the socket. Supersession closes the old gate; VMM lifetime
  remains independent. Capability advertisement follows the authenticated console
  handshake, and new sessions require a fresh supporting host report.
- **Follow-up boundary:** ADR-0022 now adds the browser terminal; its review
  records separate browser acceptance and remaining gaps.

## Verification

Protocol precommit passed 22 cases (11 properties, 11 tests) and Dialyzer without
exclusions. Lilly precommit passed 78 cases (17 properties, 61 tests), Dialyzer
without exclusions, and rebuilt the production release and development modules.
Marshall's complete suite passed 143 cases (12 properties, 131 tests), including
the three-node race in which conflicting input bodies for one sequence produce
exactly one accepted enqueue. The focused relay/authority/connection/TLS suite
passed 42 cases, including actual TLS/socket traffic through the running relay,
simulated running-VM observations, token revocation and relay reconnection.

Marshall Dialyzer passed with its one existing upstream exclusion; no exclusion
was added. It caught a map typespec mismatch, corrected by passing only connection
fields to the connection authority callback. All four host checks passed. The
local three-VM KVM harness passed the new discard/uncertainty checks and its
existing isolation/persistence/cleanup regression. The full remote KVM execution harness also passed on 2026-09-16: Marshall's
user-authorized terminal actions reached the actual guest through HTTPS, the
transport and the actor-owned gate. It verified duplicate suppression, viewer/
operator handoff, grant and login-token revocation, relay restart and guest disk
effects. Its lifecycle regression verified independent VMM survival after Lilly
death, stop/start persistence, exactly three crash restarts, credential rotation
and cleanup-gated deletion. The harness reported physical and database cleanup
complete. Structural ADR validation covers 21 decisions and does not establish
runtime safety.

## Limits and follow-up

TLS unit/integration tests simulate physical observations; the execution KVM
harness now proves API-user-to-guest behavior on one physical host. It does not
exercise browser rendering or terminal failover between Marshall nodes.
Complete browser rendering with bounded input, fresh authorization and explicit
loss reporting. Verify failover, restart and revocation through the complete path.
The second physical host, workload targets and 100-instance acceptance remain
open platform obligations. The broader plan is not complete.
