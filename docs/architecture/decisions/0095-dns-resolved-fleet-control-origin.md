# ADR-0095: DNS-resolved fleet control origin

- ID: ADR-0095
- Date: 2026-09-22
- Status: accepted
- Implementation: implemented
- Components: NixOS fleet networking, Marshall deployment, service control clients
- Supersedes: none
- Superseded by: none

## Context

Fleet services used `ghuntley.dev` as the verified TLS name while `/etc/hosts`
silently redirected that public name to loopback on Overalls and to the
`10.90.0.1` overlay address on Dungarees. The user explicitly required removing
both aliases because the private address is no longer a valid hostname-routing
contract. Live removal proved that Marshall's authenticated port 5443 listener
was otherwise unreachable under the public name, causing Audi to withdraw DNS
routes as designed.

Overalls and Dungarees share a provider subnet whose remote additional addresses
must be routed through the provider gateway rather than direct neighbour
discovery. ADR-0075 already permits reviewed fleet source addresses to reach all
TCP ports, while application credentials and verified private-CA TLS remain the
authorization boundary for Marshall's fleet API.

## Decision

The user's September 22, 2026 instruction to remove the stale aliases authorizes
this decision. Public fleet names resolve through DNS on both physical hosts.
Overalls exposes a TLS-preserving systemd socket relay on its primary address and
port 5443 to Marshall's loopback TLS listener. The relay binds no wildcard or
plaintext listener and remains reachable only from ADR-0075's reviewed sources,
including both physical hosts. Marshall continues to authenticate every service
credential and terminates TLS itself.

Each reviewed physical host declaration routes remote host and service addresses
on the provider subnet through the provider gateway. The relay is an explicit
replacement for hostname rewriting; it does not make Audi's anonymous public
ports or Marshall's browser origin interchangeable with the fleet API.

This amends ADR-0090's worker-control-path requirement: the Dungarees Audi DNS
replica may use the source-restricted physical path when the overlay alias is
absent. Its independently authenticated credential, verified private-CA TLS and
separate unprivileged unit remain mandatory.

## Alternatives

Keeping the `/etc/hosts` aliases preserves a hidden machine-local routing
dependency and contradicts the user's instruction. Binding Marshall directly to
every physical address broadens application-process listeners and duplicates
endpoint configuration. Sending the fleet API through the public browser proxy
mixes independently reviewed route sets. Adding IP addresses to the private
certificate would couple certificate rotation to physical and overlay topology.

## Consequences

Local and remote fleet clients exercise the same DNS name and TLS identity.
Same-subnet service access no longer depends on neighbour discovery. The relay
adds one supervised forwarding unit and makes availability of the physical path
part of worker control connectivity. Source filtering is defense in depth only;
service credentials and verified TLS remain required.

## Invariants and verification

- Neither host may map `ghuntley.dev` or `overalls` to loopback or an overlay
  address in `networking.hosts`.
- The relay must bind exactly `136.243.69.55:5443`, forward bytes only to
  `127.0.0.1:5443`, and retain systemd hardening.
- The fleet firewall must continue to suppress ordinary global openings; only
  reviewed sources may reach the relay.
- Dungarees must route `136.243.69.55` and the remote Audi address
  `136.243.69.37` through `136.243.69.1`.
- Both host closures must build, and live validation must establish verified
  control exchange plus ordinary public-certificate HTTPS without `--insecure`.

## Implementation evidence

The [Overalls configuration](../../../fleet/hosts/overalls/configuration.nix)
declares the hardened relay and removes the loopback alias. The
[Dungarees configuration](../../../fleet/hosts/dungarees/configuration.nix)
removes the overlay alias, while its reviewed
[host declaration](../../../fleet/hosts/dungarees/host.json) adds the remote
Audi `/32` provider route. Both host closures build. Commits `0aefbe0` and
`e6195a0` activated successfully on Overalls and Dungarees respectively. Live
checks found no stale host alias, observed the exact relay bind and provider
routes, and returned positive Dungarees gateway/DNS readiness. Both OSS guest
names validated production Let's Encrypt chains and returned their distinct
pages without an insecure override; strict-known-host SSH still reached both
Firecracker guests after activation.

On 2026-10-16 the fleet control origin was renamed to `ghuntley.dev:5443`
after `overalls.dev` lapsed; the decision is unchanged. The same name is now
the DNS and TLS identity, served by a reissued backend certificate under the
bundled internal service CA described in ADR-0048.

## Open questions

None for this decision. Cross-gateway failover for a host-local route remains an
operational Audi exercise tracked separately from the control-origin change.

## Related decisions

Amends [ADR-0075](0075-fleet-overlay-and-source-access.md) and
[ADR-0090](0090-second-audi-dns-replica-on-worker.md). The anonymous Audi
listeners remain governed by
[ADR-0091](0091-fleet-perimeter-public-listeners.md).

