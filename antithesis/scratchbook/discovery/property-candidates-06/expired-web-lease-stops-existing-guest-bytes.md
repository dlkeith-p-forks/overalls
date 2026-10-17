# expired-web-lease-stops-existing-guest-bytes

Priority: P0. Confidence: high for the claimed deadline, medium for composed hosted feasibility; no new hosted run. Type: safety, with a recovery progress witness.

## Guarantee and proposed assertions

An existing Audi private web or editor stream must stop delivering *new* guest bytes no later than the local monotonic expiry of its last valid, same-binding grant, even if Control renewal blocks, its hint is lost, or its guard process is suspended or killed. A renewal admitted before expiry may extend the deadline only with the same complete binding and user identity. Proposed `Always(no_guest_effect_after_old_lease_deadline, "Expired Audi web authority cannot forward new guest bytes")`; evaluate only a post-deadline nonce injected after a local causal barrier, excluding bytes already in flight. Proposed `Sometimes(current_lease_resumed_guest_bytes, "A freshly authorized Audi stream reaches its guest after expiry recovery")` checks meaningful recovered service. The fresh `../../existing-assertions.md` scan finds neither assertion; both are planned. A refusal or a closed client socket alone is insufficient.

## Source and decision trail

- `audi/CONTRACTS:5-7` says expired authority terminates existing streams. `audi/lib/audi/authority/lease.ex:7-37` computes expiry from request start using local monotonic time, rejects expired renewal and changed/stale binding. Its source comment says five seconds but actual `new/4` accepts 1–30 seconds and ordinary web/editor control grants can use 30 seconds under ADR-0142/0153; use issued TTL, not the stale comment.
- `audi/lib/audi/authority/stream_guard.ex:10-15,17-44,63-83,96-105,126-155` owns the stream process lifetime and has an unlinked watchdog whose deadline remains active while renewal is queued or the guard is suspended.
- `audi/lib/audi/http/authority.ex:7-11,12-33,42-74,116-120` performs renewal outside the owner/guard, treats inconclusive renewal as a bounded retry, and checks full binding and user ID.
- `marshall/lib/marshall/ingress/web_streams.ex:113-136,163-195` rechecks stored login and Cedar authority on renewal. `audi/lib/audi/http/proxy.ex:82-86,88-140` owns the guest socket while streaming. ADR-0142 (`docs/architecture/decisions/0142-overallsprotocol-control-websocket.md`) and ADR-0153 claim renewable short-lived authority; their accepted terms are test targets, not proof of runtime timing.

## Fault history, independent effect and progress witness

Open a real private HTTP streaming response or WebSocket to an owned guest echo/recorder through Audi. Record the exact local request-start and grant expiry on the Audi node without logging credentials. Deliver one nonce before expiry. Block or drop renewal responses, drop hints, and suspend or kill the guard/renewal worker in separately labeled schedules while keeping the client and guest alive. After the last grant deadline, use an Audi-local causal barrier, then inject a fresh nonce through the existing client connection; the independent guest recorder must never contain that nonce. Read the guest log after fault recovery and verify it is responsive with a fresh owner-authorized connection and another nonce. If a renewal committed before the deadline, take its actual new deadline; an uncertain reply does not establish expiry. A guard death is not sufficient evidence unless guest bytes cease.

Value menu: web versus editor; blocked versus refused versus lost renewal response; hint delivered/dropped; guard running/suspended/killed; boundary just before/at/after expiry; 30,000 ms ordinary grant and any shorter legitimately issued grant; HTTP streaming versus upgraded WebSocket. Do not synthesize a 5,000 ms web grant as if that were the universal policy. An SUT `Reachable` replay marker could be placed at `StreamGuard.watch_deadline/5` on expiry and at `Authority.renew_now/6` on inconclusive renewal; the property itself uses the external guest effect. Full scope needs real Audi, Marshall, PostgreSQL, Lilly connector and real guest service (TCG or native). An isolated StreamGuard unit test only validates its process behavior, not actual socket closure.

## Open Questions

- Can the hosted guest streaming fixture expose a post-deadline causal barrier and recorder without relying on synchronized clocks across Audi and guest?
- Which fault controller can suspend Audi's guard in hosted Antithesis while preserving the production owner/guard relation?
