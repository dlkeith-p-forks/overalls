# ADR-0091: Fleet perimeter public listeners for Audi

- ID: ADR-0091
- Date: 2026-09-22
- Status: accepted
- Implementation: partial
- Components: NixOS fleet firewall, Audi gateway, Audi DNS
- Supersedes: none
- Superseded by: none

## Context

[ADR-0075](0075-fleet-overlay-and-source-access.md) made the fleet perimeter
authoritative: reviewed public IPv4 sources may reach every TCP/UDP listener,
and ordinary per-service firewall contributions are suppressed, so anonymous
public ingress (including HTTP-01) became intentionally unavailable. The user
then authorized enabling Audi's public plane on Overalls and Dungarees with
the explicit requirement that Audi, when enabled, is always accessible from
the public internet through the firewall (September 22, 2026 instruction).

Audi's gateway (SSH 22, HTTP 80, HTTPS 443) and authoritative DNS (UDP/TCP 53)
must accept anonymous clients: any resolver must be able to query the zone,
and any browser or OpenSSH client must be able to reach a VM's current
gateway. Source-address grants cannot express this.

## Decision

Amend ADR-0075's perimeter policy with one reviewed exception. The fleet
firewall module gains a typed `publicServices` registry: named listeners,
each with an explicit local IPv4 destination address, a nonempty unique set of
TCP and/or UDP ports, and a required human-readable comment. Configured
listeners are admitted from any IPv4 source at that destination and port, in
both firewall backends, at the same force priority as the reviewed-source
grants and the authenticated fleet-transport rules.

Everything else in ADR-0075 is unchanged: global port, port-range and ordinary
per-service firewall openings remain suppressed; wildcard destinations are
rejected at evaluation; duplicate addresses or duplicate per-protocol ports
are rejected; the registry is reviewed like `allowed-hosts.nix`. A
`publicServices` entry must not broaden into a wildcard destination or cover
an address other than its declared listener.

The initial registry entries are the Audi planes: Overalls
`136.243.69.37` and Dungarees `136.243.69.32`, each TCP 22/53/80/443 and
UDP 53.

## Alternatives

Disabling the fleet perimeter would discard the reviewed-source boundary for
management paths. Enumerating "the internet" in `allowed-hosts` is impossible
and would wrongly grant all ports, not just declared listeners. Placing Audi
behind the public proxy conflates the ingress tier with the application tier,
and DNS UDP 53 and SSH are not HTTP-proxyable. Leaving Audi source-restricted
would contradict the user's explicit availability requirement.

## Consequences

The two Audi addresses become anonymously reachable on exactly the declared
ports. Application authentication remains the actual boundary: DNS supplies an
address, never permission; Audi SSH and HTTPS authenticate platform authority
per connection with at most five-second renewal windows; the ACME issuer
validates DNS-01 proofs. Other listeners (Marshall proxy, Porsche,
administrative SSH) remain reachable only from reviewed sources, the tailnet
or the fleet tunnel. The proxy's own anonymous HTTP-01 availability is
unchanged by this decision and remains governed by ADR-0075.

## Invariants and verification

- `publicServices` entries require canonical explicit IPv4 destinations;
  `0.0.0.0` fails evaluation, as do duplicate addresses, empty port sets and
  duplicate per-protocol ports.
- Both nftables and iptables renderings admit only the declared
  destination/port pairs; the fleet firewall evaluation check requires an
  ordinary `dport 9999` contribution to stay suppressed while public service
  rules survive composition.
- The destination addresses stay fenced from guest egress through Lilly's
  `protectedCidrs` on both hosts.
- Host evaluation shows the rendered per-port accept rules for
  `136.243.69.37` and `136.243.69.32` alongside the reviewed-source grants.

## Implementation evidence

The typed registry, assertions and both backend renderings live in
[fleet-firewall.nix](../../../nix/domains/system/fleet-firewall.nix); composition,
rejection and suppression cases are in
[fleet-firewall.nix evaluation](../../../nix/verification/tests/evaluation/fleet-firewall.nix),
which passes. The Audi entries are declared in the
[Overalls](../../../fleet/hosts/overalls/services.nix) and
[Dungarees](../../../fleet/hosts/dungarees/configuration.nix) host
configurations, and both hosts evaluate with the expected accept rules.
Deployment and live external reachability checks remain outstanding, so
implementation is partial.

## Open questions

Whether the public proxy's HTTP-01 issuance should later move to DNS-01
through the Audi zone (it already serves `_acme-challenge` TXT for per-VM
certificates) is a separate operator decision under ADR-0075.
[ADR-0181](0181-public-proxy-http01-ingress.md) resolves it for Overalls with
public HTTP-01 on TCP 80 rather than DNS-01.

## Related decisions

Amends [ADR-0075](0075-fleet-overlay-and-source-access.md).
[ADR-0047](0047-audi-ingress-and-authoritative-dns.md) defines the Audi
listeners this exception serves; [ADR-0085](0085-inception-public-ingress.md)
extends them to nested ingress; [ADR-0090](0090-second-audi-dns-replica-on-worker.md)
places the second DNS replica.
