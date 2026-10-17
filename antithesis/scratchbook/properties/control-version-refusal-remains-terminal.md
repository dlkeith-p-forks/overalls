# control-version-refusal-remains-terminal

P0; high source confidence; safety `Always`, message **"Control transport version refusal stops its owner without losing its class"**. The full planned SDK assertion is missing per the [current scan](../existing-assertions.md). The current Python Control smoke partially checks that an observed wrong outer version receives 426, but it does not check client-owner terminal classification, pending-call retirement, 4001, or absence of retry. A wrong/missing outer Control v1 upgrade receives 426 before socket or domain effect; an accepted peer that sends 4001 stops its client owner, retires pending calls as unproven, preserves `unsupported_version`, and does not silently reconnect. A wrong *service document* version is a permanent refusal for that request but leaves a valid outer socket usable. An authentication refusal or 503 has its own class. This merged target does not conflate outer v1, Execution v4, or Store v3.

## Evidence and fault history

`marshall/lib/marshall_web/control_api.ex:12-85` orders version/service/bearer checks before upgrade; `marshall/lib/marshall/control/socket.ex:45-49` and `protocol/lib/overalls_protocol/control/close.ex:7-51` define 4001; `protocol/lib/overalls_protocol/control/client.ex:327-329,401-447` retires pending and stops. Service adapters in Lilly/Audi/Ziggy/Galileo/Porsche map owner status; Ziggy v2 and Execution v4 remain inner documents. [Focus 04](../discovery/property-candidates-04/control-version-refusal-remains-terminal.md) grounds client classification; [focus 10](../discovery/property-candidates-10/control-v1-version-refusal-preserves-intent.md) grounds pre-upgrade durable-intent preservation and compatible resync. Race pending calls with 426/4001, wrong service/version/body and transport loss. A lost response remains uncertain, not a failed effect.

## Oracle, environment, and instrumentation

A controlled TLS peer records handshakes and wire IDs for 426/4001 classification; real Marshall/PostgreSQL independently shows no new domain rows for definite pre-upgrade refusals. Observe supervised socket/task inventory to establish no socket was created; after 426/4001, count retries over normal backoff ceilings. Separately send wrong service document over valid socket, then a fresh valid request; a recoverable 503/transport loss should reconnect and resync durable state. Hosted real TLS/BEAM/PG suffices. `Reachable` marks before-socket refusal, and `Sometimes(recoverable_socket_reestablished)` is conditional on healthy endpoint, with a unique message.

## Open questions

- None for the refusal oracle. A dedicated client/Marshall fixture and wire handshake capture attribute the attempted upgrade; task inventory is optional diagnostics.

### Investigation Log (2026-10-13)

#### Attribution of a refused upgrade

- Examined: `MarshallWeb.ControlAPI.call/2`, `Control.Client.opened/2` and `retry/2`, `Control.Close.reaction/1`, and the pre-upgrade ControlAPI test. Found: 426 returns before the upgrade call; the client classifies it as `unsupported_version` and `retry/2` enters stopped phase with no scheduled connect. Not found: a reliable per-attempt supervised WebSock task inventory in current code. Conclusion: use an isolated single-client fixture plus wire handshake capture, terminal client status and matching DB no-effect row. An aggregate process count is unnecessary and can be misleading.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `control`. real-hosted-db-and-control; independent witness: consistent PostgreSQL rows plus independent caller/wire ledger. Native companion: not required for this bounded claim. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R9`: Use distinct command/branch IDs for permanent 426/4001 refusal and recoverable outage reconnect. A healthy reconnect does not satisfy permanent-refusal coverage. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.
