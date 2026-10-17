# control-version-refusal-remains-terminal

Priority: P0. Confidence: high for the transport and named adapters; hosted verification absent. Type: Safety with a separate recovery progress check.

## Guarantee and proposed assertions

An unsupported Control v1 upgrade or close remains a permanent version refusal at the owning service adapter, including a pending call retired as `:unproven`; the same client does not reconnect after this *transport* refusal. A wrong service document version remains a distinct permanent result for that request, but does not stop an otherwise valid Control v1 connection. Proposed `Always(version_refusal_preserves_terminal_class_and_stops_owner, "Control transport version refusal stops its owner without losing its class")` compares a fault peer's actual 426/4001 with adapter outcome and handshake count. `Always(document_version_refusal_not_outage, "Control document version refusal is not reported as transport outage")` checks the document layer separately. A separate `Sometimes(recoverable_socket_reestablished, "Control reconnects after a recoverable socket loss")` is meaningful progress only for a deliberately recoverable loss with a healthy endpoint. All are missing per `../../existing-assertions.md`.

## Evidence and failure history

- `marshall/lib/marshall_web/control_api.ex:48-53` returns 426 for wrong upgrade version; `marshall/lib/marshall/control/socket.ex:45-49` maps unsupported hello to close; `protocol/lib/overalls_protocol/control/close.ex:7-17,40-51` assigns 4001 and `:stop`.
- `protocol/lib/overalls_protocol/control/client.ex:327-329,401-447` captures 426/close, retires pending as unproven and stops without reconnect for unsupported version. `lilly/lib/lilly/control/client.ex:957-993`, `audi/lib/audi/control/client.ex:661-680`, `ziggy/lib/ziggy/control.ex:24-28,90-107`, `galileo/lib/galileo/control.ex:17-47` and `porsche/lib/porsche/client.ex:174-214` map pending transport loss using owner status.
- Service document versions remain separate from Control v1. Ziggy v2 is checked at `marshall/lib/marshall/control/services/ziggy.ex:44-54`; Lilly's current execution client sends v4 at `lilly/lib/lilly/control/client.ex:258-295`; Lilly Store v3 is local persistence (`lilly/lib/lilly/control/store.ex:11-29`). A mismatch at one layer is not proof another layer changed.
- The explicit terminal contracts and current ordinary regression tests are source evidence, not a fresh hosted result or a known bug report.

## Fault history, independent oracle and workload

Run real clients against a controlled verified-TLS upgrade peer that returns HTTP 426 or accepts then closes 4001. Keep one pending request when close arrives, and compare the adapter result with an independent peer receipt ledger. Count subsequent connection attempts over two normal backoff ceilings and then send a new explicit call: it should retain the terminal class without a new handshake. Separately, use real Marshall to return a wrong service-document-version refusal and verify the request class without demanding socket shutdown. For 503, 4007 draining, 4008 idle or raw transport loss, verify a later welcome plus a fresh successful explicit request. Never infer a domain effect from `:unproven` or classify an unknown close as 4001.

Parameter menu: 426/401/503; close 4001/4000/4007/4008/unknown; refusal before welcome, after welcome, pending call; Control header v0/v1/v2; service body valid/current−1/current+1 where supported. Reconnect jitter has a 1-ms lower end and ceilings 1,000→2,000→4,000 ms; draining uses 1..500 ms. A SUT checkpoint at `Client.retry/2` `:stop` branch plus adapter classification helps replay. Controlled peer proves transport classification; real Marshall is needed for actual document-version refusal. No mutant or hosted run.

## Open Questions

- None. Porsche's pending-version mapping and the transport/document distinction are source-resolved.

### Investigation Log

#### Does Porsche preserve a pending transport version refusal?

- Examined: `porsche/lib/porsche/client.ex:174-214`, especially `response/2` at 203-214.
- Found: a pending `:unproven` or disconnected call checks the owning shared client's status and returns `:unsupported_version` when that owner stopped for that reason. Other losses map to `:transport_error`.
- Conclusion: resolved; no human input or open question remains.
