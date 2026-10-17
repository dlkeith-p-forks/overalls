# ADR-0106: Inception child Audi wildcard

- ID: ADR-0106
- Date: 2026-09-23
- Status: accepted
- Implementation: partial
- Components: Marshall, Audi, Lilly, protocol, NixOS, backups
- Supersedes: none
- Superseded by: none

## Context

ADR-0105 requires wildcard coverage for every public Audi name. A parent
`*.<zone>` certificate cannot authenticate an application under
`apps.<environment>.inception.<zone>` because a wildcard covers only one DNS
label. The child retains its own Marshall, Audi and application authorization;
the parent forwards its public TLS and SSH without terminating child TLS.

## Decision

Each Inception environment uses one child wildcard for
`*.apps.<environment>.inception.<parent-zone>`. Child Marshall issues and stores
its account and certificate private keys as AshCloak ciphertext in its own
PostgreSQL database, and child Audi receives the active certificate through the
authenticated local fleet API into memory. The parent never receives the child
private key. Alternate-port application names use a single flat label below the
child apps zone. Control HTTPS retains its separate certificate and issuer.

The child publishes its apps-zone apex DNS-01 proof as an empty, proof-only
label in the bounded Inception exchange. Parent Lilly verifies the proof at
the exact configured public DNS replicas. Parent Marshall projects it as
`_acme-challenge.apps.<environment>.inception.<parent-zone>` only while the
bound publication and host lease are current. An empty label cannot publish an
address or gain routing authority. The child issuer receives only validated
operator ACME settings and the public DNS replica addresses. The parent
continues to forward opaque TLS; child Audi authenticates the requested name.

## Alternatives

The parent wildcard cannot cover deeper child application names. Issuing one
certificate per child VM repeats the ACME order and private-key custody problem.
Giving the parent the child wildcard key crosses the independent child
authentication boundary. A dedicated child wildcard confines persistent key
custody to the child control plane.

## Consequences

One child ACME order replaces per-VM child orders. A new Inception environment
still needs its own wildcard order. Child key recovery requires the child
PostgreSQL state and matching Cloak keyring. Lilly's native ZFS capture includes
the child VM drives, but application-level recovery from that guest snapshot
has not been verified. The separate
control certificate retains its existing recovery obligations. A native nested
machine test must prove real ACME issuance, DNS proof propagation, child TLS
hostname validation, restart recovery and independent child authorization.

## Invariants and verification

- Empty child labels carry bounded DNS-01 proofs only; they cannot create an A
  record or route.
- The parent proof owner is derived from the bound environment namespace and
  is removed when the short publication lease expires.
- The child wildcard certificate must cover every child Audi HTTP hostname,
  including flat alternate-port labels, while control HTTPS keeps its own
  certificate and authorization.
- Focused protocol, guest publication and DNS tests exercise these boundaries.
  The native nested machine test and child backup restore remain required.

## Open questions

The native Lilly backup includes child guest drives and requests a bounded
filesystem sync from a running guest. A restore test must recover the child
PostgreSQL database and matching Cloak keyring, validate decryption of the
wildcard material and prove that a restarted child Audi reinstalls it.

## Related decisions

- [ADR-0105](0105-public-audi-wildcard-custody.md) defines the parent public
  wildcard issuer and database custody.
- [ADR-0085](0085-inception-public-ingress.md) records the independent child
  authentication and opaque forwarding requirements retained here.
- [ADR-0070](0070-host-recovery-backups.md) defines Lilly's native guest-drive
  backup and crash-consistent recovery boundary.

## Implementation evidence

The [protocol](../../../protocol/lib/overalls_protocol/inception_exchange.ex),
[guest projection](../../../nix/domains/artifacts/guest/inception/publication.py),
[parent proof observation](../../../lilly/lib/lilly/inception/propagation.ex),
[parent snapshot](../../../marshall/lib/marshall/ingress/publications.ex) and
[Audi DNS decoder](../../../audi/lib/audi/dns/snapshot.ex) form the bounded
proof path. The [inner namespace bootstrap](../../../nix/domains/artifacts/guest/inception/ingress.py)
selects its own issuer and trust roots. Focused tests and runtime evaluation
pass: the [Marshall projection test](../../../marshall/test/marshall/compute/inception_test.exs),
[Lilly replica test](../../../lilly/test/inception/propagation_test.exs),
[Audi authoritative DNS test](../../../audi/test/dns_replica_test.exs) and
[guest publication test](../../../nix/verification/tests/evaluation/inception-publication.py)
exercise proof scope and routing separation. The native Inception scenario
now includes a [child wildcard handshake probe](../../../nix/verification/tests/machines/inception/wildcard_probe.py)
for two workload names, control-origin rejection and Marshall/Audi restart
with the same certificate. Its driver evaluates,
but the run stops before nested boot proof and does not yet execute this probe
or validate child database recovery.
