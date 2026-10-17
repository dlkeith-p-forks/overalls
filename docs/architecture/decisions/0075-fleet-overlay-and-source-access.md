# ADR-0075: Fleet overlay and source access

- ID: ADR-0075
- Date: 2026-09-20
- Status: accepted
- Implementation: partial
- Components: NixOS access, host firewall, fleet networking
- Supersedes: none
- Superseded by: none

## Context

Overalls and Dungarees need Tailscale, and every current and future deployed
fleet host must receive the same overlay client. Operators also require a small,
reviewable set of public IPv4 sources that can reach TCP and UDP listeners on
every host. The initial set is the public address of each current physical host
and Geoffrey Huntley's `103.134.170.11` address. Each grant needs a comment so a
reviewer can identify its owner or purpose.

The fleet profile already enables authoritative named SSH access and the NixOS
firewall. Service modules open their own public ports. Tailscale creates a
separate authenticated interface, while public source grants remain ordinary
source-address policy and do not authenticate an application protocol.

## Decision

The user's September 20, 2026 instruction authorizes this decision. Enable the
Tailscale client daemon on every base and enrolled fleet host, without embedding
an authentication key or automatically joining a tailnet. Trust all ingress on
the `tailscale0` firewall interface. Provide a default-off exit-node option that
enables Tailscale server routing and advertises the node. Enable that option
explicitly on Overalls and Dungarees.

Maintain one typed Nix attribute set of named public IPv4 sources in a dedicated
fleet-firewall module, separate from human SSH account policy. Every entry
contains a canonical address and a required human-readable comment. The firewall
module permits each listed source to reach every TCP and UDP port on every fleet
host, including HTTP 80 and HTTPS 443, using the active NixOS firewall backend.
It does not grant other protocols. Reject malformed or duplicate addresses at
evaluation. Fleet hosts suppress global TCP/UDP port and port-range openings
requested by service modules, making this policy authoritative for new external
TCP/UDP connections. Preserve loopback and stateful replies to outbound traffic.

## Alternatives

Per-host lists would drift and could omit future machines. Opening every TCP and
UDP port globally would discard the requested source boundary. Treating public
addresses as Tailscale peers would conflate two trust mechanisms. Automatic
Tailscale enrollment would require a new secret lifecycle and was not requested.

## Consequences

Fleet nodes gain a provider-independent management path after an operator joins
them to the tailnet. Public listeners are reachable only through the overlay or
from listed sources; public HTTP-01 and anonymous public service ingress are
intentionally unavailable. A stale, reassigned or compromised allowed address
therefore has broad network reach and must be removed promptly. Host and
application authentication remain required; source addresses are not identities.

The policy adds one central review point and applies automatically to future
fleet profiles. It intentionally does not apply to guest images or consumers
that import service modules without enabling fleet access.

## Invariants and verification

- Every base and enrolled fleet host enables `tailscaled` and trusts
  `tailscale0` in the NixOS firewall.
- Exit-node mode defaults off. Overalls and Dungarees opt in, advertise an exit
  route and enable the kernel IPv4 forwarding required to carry tailnet traffic.
- The registry includes Overalls and Dungarees, with a required comment for
  every entry. On 2026-10-16 the user removed every personal address, including
  the initial `103.134.170.11`; operators reach hosts through the tailnet.
- Both nftables and iptables configurations accept TCP and UDP from every
  registry address on every destination port, including HTTP and HTTPS, and do
  not create an equivalent other-protocol source rule.
- Fleet profiles expose no global TCP/UDP ports or port ranges, even when a
  service module requests `openFirewall`.
- Duplicate, malformed or noncanonical IPv4 addresses and missing/unsafe
  comments fail evaluation.
- No Tailscale credential enters the Nix store or repository.

## Implementation evidence

The [fleet host profile](../../../nix/hosts/profile.nix) enables Tailscale and
the fleet firewall. The
[Tailscale module](../../../nix/modules/tailscale.nix) provides the default-off
exit-node option; the Overalls and Dungarees host configurations enable it. The
[fleet firewall module](../../../nix/modules/fleet-firewall.nix) trusts the
overlay interface and renders both firewall backends from the typed
[source registry](../../../nix/allowed-hosts.nix). The
[firewall evaluation](../../../nix/tests/evaluation/fleet-firewall.nix) covers
defaults, both backends and invalid data; the
[Tailscale evaluation](../../../nix/tests/evaluation/tailscale.nix) covers every
fleet fixture. Live tailnet enrollment and packet-level production verification
remain pending, so implementation is partial.

## Open questions

Production activation must confirm each source address still belongs to its
documented owner and that direct Tailscale connectivity succeeds on both hosts.

## Related decisions

[ADR-0091](0091-fleet-perimeter-public-listeners.md) amends this record's
consequence that anonymous public service ingress is unavailable: reviewed
destination-scoped Audi listeners are now admitted from any source through the
typed `publicServices` registry.
[ADR-0181](0181-public-proxy-http01-ingress.md) amends the consequence that
public HTTP-01 is unavailable: an opted-in proxy admits TCP 80 from any source
for ACME challenges and HTTPS redirects.
[ADR-0030](0030-nixos-deployment-and-tls.md) requires coordinated host firewall
ownership. [ADR-0041](0041-declarative-fleet-users.md) defines authoritative
human SSH access; this source policy does not replace SSH authentication.
