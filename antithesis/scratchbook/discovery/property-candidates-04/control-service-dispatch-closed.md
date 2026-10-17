# control-service-dispatch-closed

Priority: P1. Confidence: high for service prefix isolation; domain-body coverage requires route audit. Type: Safety.

## Guarantee and proposed assertions

A welcomed socket dispatches only operations for its authenticated service, with the route's current document version and validated body; a wrong-service or malformed request cannot cause a durable or external effect. Proposed `Always(wrong_service_or_invalid_document_has_no_effect, "Control rejects cross-service and invalid documents before domain effects")` checks each negative attempt against a separately inventoried effect ledger. It is missing per `../../existing-assertions.md`. This is a stateful authorization test across a valid connection, not a pure envelope decoder test.

## Evidence and failure history

- `marshall/lib/marshall/control/socket.ex:118-142,172-176` passes a decoded op/body to the bound service module. `protocol/lib/overalls_protocol/control/envelope.ex:68-74,102-106,135-147` validates closed outer shape and bounded names but intentionally leaves service op and body semantics to that module.
- `marshall/lib/marshall/control/services/{audi,lilly,porsche,ziggy,galileo}.ex` each `handle_request/3` accepts only its own prefixed operation and has an invalid-request fallback: Audi `:79-86`, Lilly `:51-58`, Porsche `:45-52`, Ziggy `:44-54`, Galileo `:30-40`. Audi's request version is checked in `marshall/lib/marshall/ingress/control_requests.ex:66-72`; Ziggy requires body version 2 in its service wrapper; Lilly's decoder is reached through `compute/provisioner_requests.ex:63-75`.
- Control v1, execution document v4 and local Store v3 are independent contracts. Source behavior provides no evidence that an arbitrary v3 Store shape is an accepted Control body. There is no identified incident or fresh failing reproduction.

## Fault history, independent oracle and workload

Bind each real service with its own credential, then send correctly shaped outer `req` frames carrying another service's op and a mutation-capable body, an unknown op in the own namespace, and own-service documents with wrong version, extra fields, missing fields or swapped identity. Follow with a valid own-service sentinel request. The oracle records all attempted fixture IDs and independently reads durable rows, native effects or upstream witness calls after task quiescence. `invalid_request` alone is not enough: check that no invalid attempt caused an effect. Avoid assuming every malformed body has the same refusal name; the invariant concerns effect exclusion.

Parameter menu: five bound services × four foreign prefixes; body version current/current−1/current+1 and absent; empty/extra/wrong-type fields; frame split/coalescing; concurrent valid and invalid requests; cut response before/after dispatch. SUT branch anchors before `handle_request/3` and at each domain decoder refusal can guide search without logging payloads. Real Marshall and database are required; effectful native/upstream routes need a witness fixture. No mutant or hosted run exists.

## Open Questions

- Which mutation-capable route in each service offers the cheapest independently observable negative probe, without relying on an internal refusal response?
