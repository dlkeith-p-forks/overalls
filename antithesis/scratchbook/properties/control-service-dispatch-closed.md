# control-service-dispatch-closed

Priority: P1. Confidence: high for service prefix isolation; domain-body coverage requires route audit. Type: Safety.

## Guarantee and proposed assertions

A welcomed socket dispatches only operations for its authenticated service, with the route's current document version and validated body; a wrong-service or malformed request cannot cause a durable or external effect. Proposed `Always(wrong_service_or_invalid_document_has_no_effect, "Control rejects cross-service and invalid documents before domain effects")` checks each negative attempt against a separately inventoried effect ledger. Per `../existing-assertions.md` (2026-10-17) it is authored for a Lilly-bound socket only; see the snapshot below. This is a stateful authorization test across a valid connection, not a pure envelope decoder test.

## Evidence and failure history

- `marshall/lib/marshall/control/socket.ex:118-142,172-176` passes a decoded op/body to the bound service module. `protocol/lib/overalls_protocol/control/envelope.ex:68-74,102-106,135-147` validates closed outer shape and bounded names but intentionally leaves service op and body semantics to that module.
- `marshall/lib/marshall/control/services/{audi,lilly,porsche,ziggy,galileo}.ex` each `handle_request/3` accepts only its own prefixed operation and has an invalid-request fallback: Audi `:79-86`, Lilly `:51-58`, Porsche `:45-52`, Ziggy `:44-54`, Galileo `:30-40`. Audi's request version is checked in `marshall/lib/marshall/ingress/control_requests.ex:66-72`; Ziggy requires body version 2 in its service wrapper; Lilly's decoder is reached through `compute/provisioner_requests.ex:63-75`.
- Control v1, execution document v4 and local Store v3 are independent contracts. Source behavior provides no evidence that an arbitrary v3 Store shape is an accepted Control body. There is no identified incident or fresh failing reproduction.

## Fault history, independent oracle and workload

Bind each real service with its own credential, then send correctly shaped outer `req` frames carrying another service's op and a mutation-capable body, an unknown op in the own namespace, and own-service documents with wrong version, extra fields, missing fields or swapped identity. Follow with a valid own-service sentinel request. The oracle records all attempted fixture IDs and independently reads durable rows, native effects or upstream witness calls after task quiescence. `invalid_request` alone is not enough: check that no invalid attempt caused an effect. Avoid assuming every malformed body has the same refusal name; the invariant concerns effect exclusion.

Parameter menu: five bound services × four foreign prefixes; body version current/current−1/current+1 and absent; empty/extra/wrong-type fields; frame split/coalescing; concurrent valid and invalid requests; cut response before/after dispatch. SUT branch anchors before `handle_request/3` and at each domain decoder refusal can guide search without logging payloads. Real Marshall and database are required; effectful native/upstream routes need a witness fixture. No mutant or hosted run exists.

## Open Questions

- None for route selection. Each selected negative probe still needs a positive valid control and durable-row check in the hosted workload.

### Investigation Log (2026-10-13)

#### Observable route menu

- Examined: Audi `Ingress.Sessions`, Lilly `ProvisionerControl`, Porsche `SSH.Commands`, Ziggy `Agents.ModelCalls`, Galileo `Authorizations`/`PeerTokens`. Found: `audi.ssh_open` creates an ingress session; `lilly.sessions` changes the durable host connection session; `porsche.commands` creates a pinned request receipt for a mutation; `ziggy.agent_next` claims a model-call row; peer `galileo.authorize` mints a digest-backed one-use peer token. Not found: a Galileo Control route that directly performs an upstream mutation; it has identity/authorize/renew only. Conclusion: use the named rows as independent negative-effect oracles and a valid own-service sentinel for each. Do not describe Galileo peer-token mint as an upstream effect.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `control`. real-hosted-db-and-control; independent witness: consistent PostgreSQL rows plus independent caller/wire ledger. Native companion: not required for this bounded claim. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R4`: Keep exhaustive fixed decoder/version/migration matrices in ordinary tests. In Antithesis, race representative invalid input with a real restart, authority change or valid effect and observe the independent outcome. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

## Authored assertion snapshot

**Authored assertion snapshot (2026-10-17):** Primary `always` message is present at `antithesis/workload/control/dispatch.py:195`. A Lilly-bound socket sends one valid foreign-service document per invocation (Audi `ssh_open`, Porsche `commands`, Ziggy v2 `agent_next` or Galileo `authorize`, each accepted by its own decoder) plus drawn invalid Lilly documents. The verdict requires a correlated refusal, an absent fresh Lilly session row and unchanged read-only counts of `ingress_sessions`, `ssh_requests`, claimed `agent_model_calls` and `galileo_peer_tokens`; a lost reply without an effect stays unknown. Scope: the bound service is Lilly only; Audi, Porsche, Ziggy and Galileo sockets, native effects and external upstreams are not bound or observed. The `control_dispatch` singleton is in the staged control-core selection. This records source presence, not a passing hosted or native result.
