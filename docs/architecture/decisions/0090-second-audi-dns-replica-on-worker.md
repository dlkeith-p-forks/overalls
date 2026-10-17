# ADR-0090: Second Audi DNS replica on the worker host

- ID: ADR-0090
- Date: 2026-09-22
- Status: accepted
- Implementation: partial
- Components: Audi DNS, Nix fleet hosts, fleet network
- Supersedes: none
- Superseded by: none

## Context

[ADR-0047](0047-audi-ingress-and-authoritative-dns.md) requires at least two
control-plane hosts to run Audi's DNS role, and
[ADR-0085](0085-inception-public-ingress.md) requires two independent
authoritative endpoints for live public ingress. The physical fleet has exactly
one control-plane host (Overalls) and one Lilly worker (Dungarees), fixed by
[ADR-0048](0048-single-host-service-deployment.md) and the
`dungarees-worker-only` contract. Enabling the public application zone
therefore needs a second authoritative replica somewhere, and the user
authorized enabling Audi on both machines with the DNS role on both hosts and
an explicit decision record for the worker placement (September 22, 2026
instruction).

The Audi DNS module already runs as its own unprivileged user without gateway
keys or Lilly privileges (`audi-dns-service-boundary` contract), and Dungarees
already reaches the control plane only through the authenticated WireGuard
fleet tunnel with the private service CA.

## Decision

Amend ADR-0047's placement wording: the second Audi DNS replica may run on a
Lilly worker host when the fleet has a single control plane, provided all of
the following hold:

- The DNS service keeps its own unprivileged systemd unit, its separately
  enrolled DNS credential, and no gateway keys, Lilly privileges or connector
  access.
- It reaches Marshall only through the authenticated fleet tunnel over
  verified HTTPS with the private service CA, ordered after
  `wireguard-fleet0.service`.
- The worker-only contract stays intact: no local Marshall, PostgreSQL, public
  proxy or Porsche gateway.
- At least one replica remains on the control-plane host with a
  tunnel-independent control path, so a fleet-tunnel failure cannot remove
  every authoritative endpoint.
- Both replicas serve the same delegated zone with the same two to eight
  out-of-zone nameserver names.

The zone delegates as a strict subzone (`apps.ghuntley.dev`) of the externally
managed `ghuntley.dev` zone; the apex keeps the proxy's HTTP-01 issuance and
Porsche's public origin and is never delegated to Audi DNS.

## Alternatives

A single replica on Overalls with both nameserver names pointing at it passes
the module's name-count assertion but hides a zone-wide single point of
failure, contradicting ADR-0047's independence rationale. Promoting Dungarees
to a control-plane host would violate ADR-0048 and expand database and
authority scope far beyond this need. Acquiring a third physical host for DNS
alone is out of scope for the two-machine fleet.

## Consequences

The zone survives either host failing, either Audi DNS unit failing, or a
fleet-tunnel failure (the Overalls replica keeps its loopback control path).
A control-plane or database outage still produces SERVFAIL on both replicas by
design; snapshots live at most five seconds. The worker replica adds a
tunnel-dependent failure mode that did not exist for DNS before, monitored
through the fleet monitor's explicit unit list.

## Invariants and verification

- Dungarees' worker-only assertion fails evaluation if Marshall, PostgreSQL,
  the public proxy or Porsche are enabled alongside the DNS role.
- The `audi-dns` unit retains `CapabilityBoundingSet = CAP_NET_BIND_SERVICE`
  only and no gateway credential.
- Both hosts' configurations evaluate with identical zone, mailbox and
  nameserver names; `elixir scripts/check_adrs.exs` passes.
- Fleet monitor units include `audi-dns.service` on both hosts.
- Live acceptance still requires deployed replicas answering the same SOA/NS
  and a failover check stopping one replica at a time.

## Implementation evidence

Both host configurations enable the DNS role with explicit IPv4 binds
(Overalls `136.243.69.37`, Dungarees `136.243.69.32`):
[Overalls services](../../../fleet/hosts/overalls/services.nix) and
[Dungarees configuration](../../../fleet/hosts/dungarees/configuration.nix).
Tunnel ordering and monitor units are wired in
[fleet-network.nix](../../../fleet/fleet-network.nix) and the host configs.
Both `nixosConfigurations.overalls` and `nixosConfigurations.dungarees`
evaluate with all assertions passing, and the fleet firewall evaluation check
passes. Operator enrollment uses the new
[audi-dns rotate/verify/revoke CLI](../../../marshall/lib/marshall/operations/audi.ex)
with tests in
[audi_test.exs](../../../marshall/test/marshall/operations/audi_test.exs).
Deployment, real credentials, delegation and live DNS/failover checks remain
outstanding, so implementation is partial.

The [terminal-version review](../reviews/2026-10-03-audi-terminal-version-refusal.md)
records explicit 426 fencing of DNS, SSH publication and certificate work,
including suspended scheduler retirement and active installation-job death.
The packaged DNS check passes stopped refresh, original snapshot expiry,
readiness refusal after control recovery and operator restart. Installed
certificate state is retained at its original expiry; packaged gateway refusal
and physical mixed-version rollout remain unverified. Implementation stays partial.

## Open questions

Live failover behavior between a control-plane-local and a tunnel-dependent
replica should be observed during rollout, including the tunnel reconnection
window after a Dungarees reboot.

## Related decisions

Amends [ADR-0047](0047-audi-ingress-and-authoritative-dns.md).
[ADR-0085](0085-inception-public-ingress.md) requires the two independent
endpoints this placement provides. [ADR-0091](0091-fleet-perimeter-public-listeners.md)
opens the perimeter for the same listeners.
[ADR-0095](0095-dns-resolved-fleet-control-origin.md) amends the worker control
path after removal of the stale overlay hostname alias.
