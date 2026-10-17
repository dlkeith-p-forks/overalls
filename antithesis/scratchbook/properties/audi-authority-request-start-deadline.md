# audi-authority-request-start-deadline

Priority: P0. Confidence: high for client deadline arithmetic, with the catalog receiver limit now enforced. Type: Safety, with optional rare-path reach.

## Guarantee and proposed assertions

An Audi authority response cannot create a lease later than the request's start plus the accepted TTL for its class; a reply arriving after that deadline is refused, and an accepted renewal preserves the exact identity/execution binding. Use `Always(accepted_authority_deadline_and_binding_are_bounded, "Audi authority never extends beyond request-start TTL or changes its binding")` at accepted grant installation and effect use, comparing to a workload monotonic timestamp and independent publication/execution identity. `Reachable("Audi late authority reply is refused after its request-start deadline")` anchors a delayed response history. Both are missing in `../existing-assertions.md`.

## Evidence and failure history

- `audi/lib/audi/control/client.ex:185-203,330-359,383-419,485-504` starts clocks before exchange, computes `expires_at = started + ttl`, rejects expired replies and invokes class-specific codecs. `protocol/lib/overalls_protocol/{web_stream,editor_stream,nested_stream}.ex` validates bindings/TTL; the client also checks previous bindings on renewal.
- Accepted policy under ADR-0142/0153 and the existing `sut-analysis.md` is 30,000 ms for ordinary web/SSH/editor streams and 5,000 ms for nested/catalog/DNS authority; nested authority is also publication-bound. Marshall currently emits gateway catalog TTL 5,000 at `marshall/lib/marshall/ingress/catalog.ex:95`. `protocol/lib/overalls_protocol/ingress_catalog.ex:4-6,23` currently enforces the five-second receiver limit, with a regression test rejecting 5,001 ms. An earlier discovery snapshot observed a 30,000-ms decoder ceiling; that claim is stale against the current working tree.
- `audi/lib/audi/dns/authority.ex:209-225` caps published DNS answer TTL by remaining publication lifetime. Historical local checks and accepted decisions are claims to verify, not hosted evidence.

## Fault history, independent oracle and workload

Use a real Audi gateway and Marshall, optionally a controlled response-delay seam, to hold a response across its class deadline while revoking the corresponding user, VM, route or publication. Record request-start monotonic time outside Audi, received TTL and independent authoritative binding/publication state; after the delay, attempt the actual web/editor/nested connection or DNS query. The oracle compares the installed deadline and effect boundary to the external clock and fresh authority state. At exact equality scheduler order may vary; either refusal or a still-valid response is allowed if no effect occurs after expiry. A renewal with a different VM/placement/epoch/generation/user/host key must fail even if its token looks valid. Do not impose a universal five-second ceiling on ordinary streams.

Parameter menu: TTL 1, 4,999, 5,000, 5,001, 29,999, 30,000 ms by class; response delay just before/at/after expiry; changed one binding component at a time; publication expiry before nested response; loss/reconnect before reply. For catalog, include an adversarial 5,001-ms reply as a targeted negative regression for the current decoder, while noting current Marshall only emits 5,000. A SUT branch at grant installation and `:expired_response` refusal helps replay. Hosted real service plus guest connector is needed for effect checks; pure codec probes only isolate decoder policy. No mutant or hosted run.

## Open Questions

- None for the current source: the decoder refuses a 5,001-ms catalog before Audi can install it. Hosted effect coverage remains unrun.

### Investigation Log (2026-10-13)

#### Catalog reader and current TTL policy

- Examined: `protocol/lib/overalls_protocol/ingress_catalog.ex:23`, `protocol/test/ingress_catalog_test.exs:55-63`, `audi/lib/audi/control/client.ex:182-203`, `audi/lib/audi/tls/fleet_worker.ex:251-280`, `audi/lib/audi/tls/readiness.ex:135-148`. Found: the current working-tree decoder enforces 1..5,000 ms and its test explicitly rejects 5,001 and 30,000; FleetWorker is the composed reader; Client derives expiry from request start; Readiness refuses expired work. Not found: a separate five-second TTL check in Readiness, or a hosted run. Conclusion: the old decoder-mismatch premise is stale against the current source; a 5,001-ms catalog is rejected before installation. Preserve a regression probe; do not claim hosted validation.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-real-inner-zfs-backed-lilly-plus-tcg-guest; unbuilt, no Firecracker proof; independent witness: post-fence guest nonce and current authority/lease/boot ledger; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.
