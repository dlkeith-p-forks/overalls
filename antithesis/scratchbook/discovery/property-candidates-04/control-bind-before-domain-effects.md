# control-bind-before-domain-effects

Priority: P0. Confidence: high in the intended boundary; hosted verification absent. Type: Safety, with a separate Reachable scenario anchor.

## Guarantee and proposed assertions

An upgraded control connection may dispatch domain requests or identity-scoped hints only after a correct hello has bound the service identity. The client admits application requests only after welcome. Proposed workload `Always(bound_before_effect, "Control domain effects require the authenticated service hello")` checks every attempted request against a workload-maintained connection ledger, including attempts refused before binding. A separate client check uses `Always(requests_sent_only_after_welcome, "Control clients send application requests only after welcome")`. Both must be exercised, so `Always` rather than `AlwaysOrUnreachable` is appropriate. A test-side observation of the specific refused-first-request outcome emits `Reachable("Control first-request refusal is observed before any domain dispatch")`; this is positive scenario coverage, not a claim that a violation is reachable. All are missing per `../../existing-assertions.md`.

## Evidence and failure history

- `marshall/lib/marshall_web/control_api.ex:13–43`, `call/2`: HTTPS GET, exact version/service and authentication precede upgrade. `version/1`, `service/1`, `bearer/1`, `authenticate/2` at 48–84 distinguish 426, 401 and unavailable 503.
- `marshall/lib/marshall/control/socket.ex:21–40`, `init/1`: identity starts nil. `message/2` at 108–143 closes an incorrect first message, matches the upgraded service, and dispatches only when identity exists. `bind/2` at 150–169 calls the service binding callback before subscriptions and welcome. Bound-only hints/resync are at 70–74.
- `protocol/lib/overalls_protocol/control/client.ex:124–145`, `handle_call/3`, rejects requests outside ready; `message/2` at 343–353 accepts welcome only in awaiting-welcome. Service binding callbacks are `services/audi.ex:43–54`, `lilly.ex:36–45`, `ziggy.ex:30–38`, `porsche.ex:31–39`, `galileo.ex:23–28` under `marshall/lib/marshall/control/`.
- Current git history `a110760f` (2026-10-05) added server/client regression coverage and the explicit first-message contract. Its commit records historical local component checks, not fresh or hosted success. The current `marshall/test/marshall_web/control_api_test.exs` contains the first-envelope cases. No issue tracker was consulted and no new defect is established.

## Fault history, independent oracle and workload

Use real Marshall HTTPS upgrade plus all five production service modules, dedicated fixture credentials and isolated domain entities. Send req, hint-shaped, resync-shaped, wrong-service hello, wrong bind, unsupported integer version and extra-field hello as the first application message. Delay a correct hello around its deadline, concatenate first-message violation plus valid req in a TCP receive batch, and sever transport during binding. In a separate controlled TLS peer exercise the real client with delayed/missing/duplicate welcome.

The oracle records peer-visible handshake order and a preexisting independently queried durable/native effect inventory keyed by dedicated fixture IDs; it checks that negative first messages cause no request-caused mutation, guest dial, or scoped outbound hint. A lightweight dispatch counter at the service callback boundary can expose an invisible read-only dispatch, but it must be compared with the independently maintained handshake ledger, not merely assert `state.identity != nil` inside the same implementation. After actual valid bind, allow tasks to finish even if the socket dies: socket loss does not promise rollback (`socket.ex:3–7`). Do not count heartbeat or unrelated concurrent fixture work as a domain effect.

Parameter menu: service all five; valid/wrong/extra/missing bind; version current, current−1, current+1 and noninteger; hello delay 0, 4,999, 5,000, 5,001 ms around the current 5,000-ms server deadline; first frame text/binary; split TCP header/body and coalesced frames. Deadline scheduling affects which refusal wins; only the authorization boundary is exact.

Place SUT-side branch anchors immediately after service-bind success and immediately before async request dispatch; replay from bind then inject socket/credential faults. Pure codec and loopback client tests are narrower than real authenticated dispatch and cannot establish native isolation. No patches, fresh suites or hosted run were performed.

## Open Questions

- None. The implementation boundary is source-resolved; instrumentation remains planned work, not an uncertainty about the property.
