# ADR-0105: Public Audi wildcard issuance and encrypted custody

- ID: ADR-0105
- Date: 2026-09-23
- Status: superseded
- Implementation: partial
- Components: Marshall, Audi, protocol, Lilly, NixOS, backups
- Supersedes: ADR-0047, ADR-0085
- Superseded by: ADR-0159

> Superseded by [ADR-0159](0159-remove-legacy-compatibility.md) only for retention of historical per-VM issuance rows. ADR-0159 carries every other requirement of this record forward unchanged.

## Context

ADR-0047 issued and saved a certificate per VM on its Audi host. ADR-0085
extended that arrangement to nested public names and assigned inner TLS keys to
the child. A new VM consequently creates another ACME order. Audi's former disk
custody also made every gateway's certificate directory part of host recovery.
The user authorized one wildcard per public application zone, breaking changes,
NixOS machine verification, structured events and audit history, then explicitly
required certificate and private-key custody in the database using Cloak.

The existing backup design captures Marshall PostgreSQL and its separately
protected Cloak keyring. A database snapshot alone cannot decrypt these fields.
The offline private-service wildcard in ADR-0078 has a different trust and
delivery path and is unaffected by this public ACME decision.

## Decision

Marshall alone creates ACME accounts and orders for `*.<zone>` through DNS-01.
One selected Marshall instance consumes a serial Oban certificate queue. Ash
resources hold account keys, CSR/private keys and the issued chain as AshCloak
ciphertext in PostgreSQL. PaperTrail records state transitions and gateway
installation acknowledgements without secret bytes. Durable state transitions
separate order, proof, validated issue and activation; activation is serialized
in PostgreSQL. An uncertain new-order response cannot create a second order for
the same generation. After a one-hour quarantine, the stalled generation is
recorded as failed and the next due check may allocate a new generation.

Two or more Audi DNS replicas publish the exact zone-apex DNS-01 TXT owner from
Marshall's bounded snapshot. Gateway credentials may fetch the active generation
over verified fleet HTTPS. Audi validates the exact wildcard SAN, chain, private
key and expiry, installs it in memory, probes its own listener and acknowledges
that generation. Marshall accepts route readiness only from a current gateway
acknowledging the active generation. Failed delivery or validation withholds new
readiness. Certificate bytes do not enter Oban arguments, events, audit versions,
Nix store paths or Audi's persistent state.

Public VM and alternate-port names use one DNS label immediately below the zone.
The immutable VM UUID remains in the label. Nested Inception public names use
their own apps-zone wildcard under ADR-0106 because the parent `*.<zone>`
cannot cover those deeper names. Its native and recovery acceptance remain
outstanding. The other isolation, authorization and independent child
authentication requirements of ADR-0085 continue to apply.

## Alternatives

Keeping per-VM issuance retains a new order and key for each VM. Saving the
shared wildcard private key in an Audi host directory would spread persistent
custody to every host and require per-host certificate backups. A private-key
blob in an unencrypted SQL column would bypass the existing Cloak keyring and
its recovery controls. Sharing the private-service wildcard from ADR-0078
would join unrelated trust domains. These do not meet the user's requirements.

## Consequences

Gateways share one public private key, so compromise of one gateway requires
rotation for the whole zone. Database and Cloak-keyring recovery becomes a
prerequisite for renewal and delivery. Gateways need Marshall connectivity after
restart to reinstall the certificate in memory. Issuance and DNS proof work are
centralized while route and application authorization remain per VM. The selected
issuer and DNS replicas must be monitored for stalled generations and expiry.

## Invariants and verification

- Only the selected issuer may perform ACME network work; all replicas may
  submit due-work requests under one database lock.
- A certificate is active only after exact wildcard validation and a committed
  Ash state transition. A gateway acknowledgement matches its service identity,
  host, generation and fingerprint.
- A route report and complete DNS route publication fail without the active
  wildcard and an exact current gateway installation acknowledgement. DNS proof
  publication never grants an application route.
- The private Audi API does not expose per-VM issuance or direct per-VM proof
  reads; complete DNS snapshots ignore historical per-VM issuance proofs.
  Marshall retains historical issuance and PaperTrail rows as a read-only Ash
  resource, with no per-VM admission or proof actions. ADR-0106 defines the
  separate child wildcard path, whose native acceptance remains outstanding.
- Restoring PostgreSQL and the matching Cloak keyring can decrypt account and
  certificate material. Restoring either alone cannot establish readiness.
- Events carry catalogued identifiers and outcomes only. PaperTrail versions and
  backup manifests contain no private key, CSR bytes or certificate payload.
- Property/unit tests cover name bounds, cryptographic material and encrypted
  persistence; native NixOS tests exercise real ACME, DNS replicas, a gateway
  restart with the issuer unavailable, and recovery.
- Complete native Inception acceptance must prove every public hostname matches
  its presented certificate and preserves independent child authentication.

## Implementation evidence

[Marshall's certificate resource](../../../marshall/lib/marshall/ingress/fleet_certificate.ex)
uses AshCloak, AshOban, AshStateMachine and PaperTrail. The
[coordinator](../../../marshall/lib/marshall/ingress/certificate_authority.ex)
and [delivery action](../../../marshall/lib/marshall/ingress/fleet_certificate_delivery.ex)
implement order progression, activation and credential-bound delivery. The
[route action](../../../marshall/lib/marshall/ingress/routes.ex) and
[complete DNS snapshot](../../../marshall/lib/marshall/ingress/publications.ex)
require the active wildcard and current gateway receipt without a deployment
fallback. The
[Audi worker](../../../audi/lib/audi/tls/fleet_worker.ex) and
[store](../../../audi/lib/audi/tls/store.ex) validate and install only the
wildcard in memory. The former Audi per-VM issuer, custody, local certificate
store and control protocol have been retired from production source.
[Encrypted-persistence tests](../../../marshall/test/marshall/ingress/fleet_certificate_test.exs)
and the [administrator audit projection test](../../../marshall/test/marshall_web/admin_audit_live_test.exs)
pass, as do the protocol naming properties. The
[installation coordinator](../../../marshall/lib/marshall/ingress/fleet_certificate_delivery.ex)
now rebinds the exact active certificate to a newer generation of the same
gateway service after credential rotation. The guarded Ash update preserves the
single current host/certificate row and PaperTrail audit; old credentials,
different service identities and conflicting fingerprints remain refused. A
[generated ingress history](../../../marshall/test/marshall/ingress/history_test.exs)
and the focused installation test pass after this correction. This is local
PostgreSQL evidence; no native gateway credential-rotation journey is recorded.
The [propagation checker](../../../marshall/lib/marshall/ingress/acme/propagation.ex)
now keeps a closed failure class and the coordinator emits a catalogued event
after the proof refresh transaction. Generated loopback DNS-over-TCP
[properties](../../../marshall/test/marshall/ingress/propagation_test.exs)
check exact proof acceptance and the negative response classes over one and two
configured replicas. They do not establish deployed DNS or issuer timing; the
generation still retries while challenging, and operator escalation policy is
unresolved.
The
[fleet machine scenario](../../../nix/verification/tests/machines/fleet/scenarios/audi.py)
now asserts real wildcard issuance, encrypted SQL columns, gateway installation
and a CA-offline restart. Native runs issued, activated, installed and
acknowledged generation 1 on both gateways. A later run passed real guest HTTPS,
dual-replica UDP/TCP DNS answers and stream revocation. A subsequent run passed
private browser HTTP and WebSocket approval after separating the public browser
origin from the private machine API. Its SSH fixture stopped at an inactive guest
`sshd.service`; the fixture now starts the service after installing its key. A
subsequent native run passed independent-key SSH, isolation, outage and failover
checks, and restarted the gateway twice after stopping the CA, reloading the
same wildcard generation without certificate files. The full fleet test then
passed gateway and DNS package-update recovery. The
[backup machine scenario](../../../nix/verification/tests/machines/backups/driver.py) passes
with real Marshall AshCloak account and active certificate fields: a fresh
release rejects an unrelated keyring, then decrypts the restored database rows
using the matching restored fixture keyring and verifies their saved digests. The
[administrator rotation action](../../../marshall/lib/marshall/ingress/rotate_fleet_certificate.ex)
can allocate an immediate generation under the same PostgreSQL lock as renewal,
and the [audit view](../../../marshall/lib/marshall_web/live/admin/audit_live.ex)
shows its actor and subsequent gateway receipts.
The [Overalls](../../../fleet/hosts/overalls/services.nix) and
[Dungarees](../../../fleet/hosts/dungarees/configuration.nix) declarations
select the wildcard issuer and Audi browser origins. Evaluating those host
declarations proves their NixOS configuration shape, not physical issuance or
deployment; live cutover remains an operator rollout. Overalls selects
PostgreSQL capture when host backups are enabled, but its backup service is
still disabled pending an operator-supplied S3 destination and secret document.

ADR-0106 selects a separate child apps-zone wildcard and flat alternate-port
labels while preserving opaque parent forwarding. Its native acceptance and
child database recovery remain open. The one-hour uncertain order recovery has
no native failure-injection evidence yet. The public fleet and backup recovery
machine checks and Marshall, Audi and protocol precommit gates have passed.

The [private browser verification](../reviews/2026-09-25-private-web-verification.md)
records a reproduced omission of team membership from Cedar's private web action.
The repaired rule admits current team member/admin web use without creating direct
grants or adding management authority; Customer guards and request-start leases
remain unchanged. Generated browser authorization/renewal histories and a dedicated
native team withdrawal journey distinguish application and transport evidence.
Accepted and partial status remain unchanged.

The [terminal-version review](../reviews/2026-10-03-audi-terminal-version-refusal.md)
records explicit 426 fencing of DNS, SSH publication and certificate work,
including suspended scheduler retirement and active installation-job death.
The packaged DNS check passes stopped refresh, original snapshot expiry,
readiness refusal after control recovery and operator restart. Installed
certificate state is retained at its original expiry; packaged gateway refusal
and physical mixed-version rollout remain unverified. Implementation stays partial.

*Transport (2026-10-05).* Audi's gateway and DNS roles now reach Marshall
over the control WebSocket
([ADR-0142](0142-overallsprotocol-control-websocket.md)), as `audi.*`
requests on one long-lived connection per role.

- Every route except the lyra `host-certificate` request moved. The HTTPS
  routes are deleted except `identity`, `dns-snapshot` (Inception
  publication), `host-key` and `host-certificate` (lyra) and public
  known-hosts discovery.
- Documents, decoders, denial classes and version refusal are unchanged.
- Wildcard delivery, acknowledgement and catalog reads keep their cadence
  until hint producers land.

## Open questions

The administrator certificate audit view now shows the generation and retry
eligibility time for an uncertain order without exposing ACME URLs or key
material. The one-hour quarantine has no operator bypass; a later generation
is allocated through the ordinary due check after the failed transition.
A native network-fault test must still exercise the lost-response path.

## Related decisions

[ADR-0047](0047-audi-ingress-and-authoritative-dns.md),
[ADR-0085](0085-inception-public-ingress.md),
[ADR-0106](0106-inception-child-audi-wildcard.md),
[ADR-0070](0070-host-recovery-backups.md) and
[ADR-0078](0078-fleet-wildcard-certificate.md).
