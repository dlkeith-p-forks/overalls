# Fleet overlay and firewall perimeter

## Scope and architecture impact

This review covers Tailscale enablement and the authoritative fleet-host ingress
policy accepted in [ADR-0075](../decisions/0075-fleet-overlay-and-source-access.md).
It changes host network authorization: new external TCP and UDP connections may
arrive only over `tailscale0` or from the three reviewed IPv4 sources. Application
authentication, guest networking and forwarding rules are unchanged.

## Findings and decisions

- **Resolved ownership ambiguity:** the firewall policy is isolated in
  `overalls.fleetFirewall`; it is not coupled to named SSH account configuration.
- **Resolved service-rule bypass:** the fleet module force-clears global TCP/UDP
  port and range openings and owns extra input rules, so a service's
  `openFirewall` setting cannot bypass the source boundary.
- **Intentional availability change:** anonymous public HTTP, HTTPS, Porsche,
  Audi and HTTP-01 traffic is blocked. HTTP 80 and HTTPS 443 remain reachable
  from the registry addresses and through Tailscale. DNS-01 or another outbound
  certificate workflow is required if public certificate renewal remains needed.
- **Operational trust boundary:** source IP addresses provide broad network
  reach but are not identities; SSH, TLS and application authentication remain
  necessary. Address ownership must be checked before production activation.
- **Tailscale connectivity limit:** the firewall does not open the public
  Tailscale UDP listen port. Outbound/stateful DERP connectivity remains possible,
  but direct peer connectivity needs live verification and may relay.
- **Exit-node routing:** a default-off NixOS option now maps explicit host opt-in
  to Tailscale server routing, kernel forwarding and declarative exit-route
  advertisement. Overalls and Dungarees enable it; tailnet authorization remains
  external policy.

## Verification performed

- Built `fleet-firewall-configuration`, covering the disabled module, mandatory
  comments, malformed/duplicate IPv4 rejection, trusted `tailscale0`, empty
  global port lists and unrestricted destination ports for both nftables and
  iptables output.
- Built `tailscale-configuration`, `enrollment-configuration`,
  `access-configuration`, `module-configuration` and `storage-configuration`.
- Evaluated Overalls and Dungarees with identical typed registries. Evaluated
  Overalls' effective nftables input rules and both hosts' empty global TCP/UDP
  port/range lists.
- ADR validation was attempted but is blocked by an unrelated existing edit to
  ADR-0021 whose title/status no longer matches its index entry. That file was
  not modified as part of this work.

## Remaining gaps

No live host was activated. Packet-level proof from each allowed address, a
denied external address and a tailnet peer remains pending. Direct versus DERP
Tailscale behavior and production certificate renewal also remain to be checked.
