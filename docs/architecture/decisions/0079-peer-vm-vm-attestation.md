# ADR-0079: Peer VM-to-VM integrations

- ID: ADR-0079
- Date: 2026-09-19
- Status: accepted
- Implementation: partial
- Components: Galileo, Marshall, Audi, protocol
- Supersedes: none
- Superseded by: none

## Context

The user included exe.dev-style peer integrations in scope: one VM calls
another VM through a named integration, with a platform-generated
credential and a source-VM header that the target can trust because the
platform, not the caller, attests it. The header must be impossible for
guests to forge.

## Decision

A peer integration targets the current Audi ingress HTTPS endpoint of a
designated machine owned by the integration owner or their team. On each
request, Marshall's authorization mints a short-lived (thirty-second)
purpose-built `galileo_peer_` token bound to the source machine and
integration name, stored only as a digest. Galileo forwards the request to
the target endpoint carrying that token. The destination Audi gateway
presents the token to Marshall over its authenticated ingress API, which
verifies the digest and freshness and returns a closed attestation
(source machine, integration name, expiry). Only then does Audi set
`x-overalls-source-vm` on the request forwarded into the target machine and
strip any guest-supplied copy. Tokens never grant admission, route
authority or control-plane effects; they only carry provenance.

## Alternatives

Signing attestations with a fleet-shared HMAC key delivered to every Audi
gateway was rejected: it adds key distribution and rotation machinery to
avoid one verified call to Marshall that the gateways already make. Letting
Galileo set the source header directly on the forwarded request was
rejected: the target edge cannot distinguish a platform hop from a guest
without verification. mTLS between machines was rejected: guest-side
certificates would place secrets inside the VM, defeating the off-VM
credential model.

## Consequences

Peer requests traverse two edges (source Galileo, target Audi) and depend
on Marshall availability for both, consistent with every other authorized
path. Target machines consume provenance via one well-known header.
Relocation of either machine is supported because routing is resolved per
request from current placement.

## Invariants and verification

Protocol tests cover the attestation envelope's closed fields. Marshall tests
cover opaque token shape, digest-only persistence, database-time expiry,
bounded expired-row reclamation and atomic one-use consumption. Audi tests cover
verification before guest connection, fail-closed malformed or denied tokens,
removal of peer authorization and replacement of forged provenance with exactly
one trusted source header. The nested-KVM Galileo fleet check now passes a peer
request across real Firecracker guests on two Lilly machines through packaged
destination Audi, including successful forwarding after source relocation.

## Implementation evidence

Peer token persistence is modeled by the
[Ash resource](../../../marshall/lib/marshall/galileo/peer_token.ex); minting,
bounded retention and atomic consumption live in
[peer_tokens.ex](../../../marshall/lib/marshall/galileo/peer_tokens.ex). The
[authorization module](../../../marshall/lib/marshall/galileo/authorizations.ex)
issues tokens;
the [ingress API](../../../marshall/lib/marshall_web/ingress_api.ex) exposes
token verification to Audi gateways; peer forwarding in
[upstream.ex](../../../galileo/lib/galileo/upstream.ex) carries the token. The
[Audi control client](../../../audi/lib/audi/control/client.ex) consumes that
endpoint and the [HTTP proxy](../../../audi/lib/audi/http/proxy.ex) verifies the
token before opening the target connection and injects trusted provenance. The
[fleet scenario](../../../nix/tests/machines/fleet/scenarios/galileo.py) verifies
cross-guest provenance replacement and absence of forwarded peer authorization.
These NixOS machines share one physical failure domain.

The [campaign verification review](../reviews/2026-09-25-integration-renewal-verification.md)
records passing application execution of three independently started Marshall
BEAMs consuming one committed token. Three actual PostgreSQL DELETE waiters
produce exactly one attestation, with durable replay/expiry/archive refusal.
This adds replica-ordering evidence, not native peer transport acceptance.

## Open questions

Production rollout and independent physical failure-domain acceptance remain
separate from the passing nested-KVM scenario.

## Related decisions

- [ADR-0047](0047-audi-ingress-and-authoritative-dns.md): ingress gateway authority.
- [ADR-0080](0080-named-edge-integrations.md): integration model.
