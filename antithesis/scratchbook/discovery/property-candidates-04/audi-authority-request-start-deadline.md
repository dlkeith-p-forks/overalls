# audi-authority-request-start-deadline

Priority: P0. Confidence: high for client deadline arithmetic, with a known catalog receiver-policy mismatch. Type: Safety, with optional rare-path reach.

## Guarantee and proposed assertions

An Audi authority response cannot create a lease later than the request's start plus the accepted TTL for its class; a reply arriving after that deadline is refused, and an accepted renewal preserves the exact identity/execution binding. Use `Always(accepted_authority_deadline_and_binding_are_bounded, "Audi authority never extends beyond request-start TTL or changes its binding")` at accepted grant installation and effect use, comparing to a workload monotonic timestamp and independent publication/execution identity. `Reachable("Audi late authority reply is refused after its request-start deadline")` anchors a delayed response history. Both are missing in `../../existing-assertions.md`.

## Evidence and failure history

- `audi/lib/audi/control/client.ex:185-203,330-359,383-419,485-504` starts clocks before exchange, computes `expires_at = started + ttl`, rejects expired replies and invokes class-specific codecs. `protocol/lib/overalls_protocol/{web_stream,editor_stream,nested_stream}.ex` validates bindings/TTL; the client also checks previous bindings on renewal.
- Accepted policy under ADR-0142/0153 and the existing `sut-analysis.md` is 30,000 ms for ordinary web/SSH/editor streams and 5,000 ms for nested/catalog/DNS authority; nested authority is also publication-bound. Marshall currently emits gateway catalog TTL 5,000 at `marshall/lib/marshall/ingress/catalog.ex:95`. `protocol/lib/overalls_protocol/ingress_catalog.ex:4-6,23` claims at most five seconds but currently accepts up to 30,000. This known receiver-policy mismatch is a narrow source finding; it does not show current production publishes long-lived catalog grants.
- `audi/lib/audi/dns/authority.ex:209-225` caps published DNS answer TTL by remaining publication lifetime. Historical local checks and accepted decisions are claims to verify, not hosted evidence.

## Fault history, independent oracle and workload

Use a real Audi gateway and Marshall, optionally a controlled response-delay seam, to hold a response across its class deadline while revoking the corresponding user, VM, route or publication. Record request-start monotonic time outside Audi, received TTL and independent authoritative binding/publication state; after the delay, attempt the actual web/editor/nested connection or DNS query. The oracle compares the installed deadline and effect boundary to the external clock and fresh authority state. At exact equality scheduler order may vary; either refusal or a still-valid response is allowed if no effect occurs after expiry. A renewal with a different VM/placement/epoch/generation/user/host key must fail even if its token looks valid. Do not impose a universal five-second ceiling on ordinary streams.

Parameter menu: TTL 1, 4,999, 5,000, 5,001, 29,999, 30,000 ms by class; response delay just before/at/after expiry; changed one binding component at a time; publication expiry before nested response; loss/reconnect before reply. For catalog, include an adversarial 5,001-ms reply as a targeted negative regression against the accepted contract, while noting current Marshall only emits 5,000. A SUT branch at grant installation and `:expired_response` refusal helps replay. Hosted real service plus guest connector is needed for effect checks; pure codec probes only isolate decoder policy. No mutant or hosted run.

## Open Questions

- Which composed Audi reader installs and consumes gateway catalog after a crafted 5,001-ms reply, and does it independently cap freshness? The decoder mismatch is confirmed; the end-to-end effect is unproven.
