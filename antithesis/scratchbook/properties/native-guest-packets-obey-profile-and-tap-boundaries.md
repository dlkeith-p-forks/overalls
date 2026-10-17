# native-guest-packets-obey-profile-and-tap-boundaries

**Type/priority/status:** Safety, P0; proposed, unimplemented, unexecuted. Primary `Always(condition, "Physical guest packets cannot cross forbidden profile TAP or destination boundaries")`. `Always` compares each attempted forbidden packet with the receiver's packet ledger and current profile/placement, since one delivered forbidden datagram or connection is decisive. A separate `Sometimes(authorized_public_probe_delivered, "Authorized guest public probe reaches fixture origin")` should prove the fixture is reachable.

**Property:** Real guest packets cannot reach sibling guests, host/protected destinations or outside networks when the guest profile forbids them; spoofed MAC/source, VLAN and IPv6 traffic cannot evade the TAP guard. Customer's fixed private SSH authority DNS/TLS is an explicit local exception and must be tested for its own authorization result, not treated as universal private-network reachability.

**Primary source:** `lilly/lib/lilly/network/policy.ex:19-21,61-98` defines protected ranges, Customer forwarding drops, direct TAP isolation and eligible uplink forwarding; `:203-227` installs per-TAP MAC/address/ARP/family guards. `docs/architecture/decisions/0064-customer-workspace-isolation.md:25-48,63-78` states the profile boundary. `nix/tests/machines/fleet/network.exs:52-66,76-98,99-128,158-179` shows live peer listeners, guest-origin probes, TAP drop counters and positive public controls. Those test definitions are leads, not this pass's result.

**Independent oracle and action/fault recipe:** Launch at least one Customer and two egress-enabled real Firecracker guests under the native fleet, with owned TAP identities and live echo listeners on peer and fixture-origin sockets. Allocate one unpredictable synthetic nonce per attempted flow. From each guest, attempt direct peer, host, metadata/protected, public TCP, DNS UDP/TCP, ICMP, IPv6, spoofed source/MAC and VLAN packets. The independent listeners record received nonces and source tuple; the monitor reads TAP guard and forward rule packet counters before/after each probe and joins them to placement/boot ID. Restart Lilly, update its release or stop/start a Customer guest and repeat after new physical boot confirmation. Require forbidden listener ledger absence **and** expected kernel drop/reject evidence; timeout alone is ambiguous. Require positive authorized controls to reach the listener in the same network epoch. Use fixed private SSH authority requests separately to observe allowed DNS/TLS plus application refusal when no grant.

**Value menu:** Customer/Standard/OSS; same/different Lilly host; pre/post restart or stop/start; peer/host/protected/public destination; TCP/UDP/ICMP; unspoofed/spoofed MAC/IP, VLAN and IPv6; existing versus new conntrack flow. Reconfirm rules and live listeners after every network reset.

**Topology/proof limit:** `storage-router` TCG can exercise real nftables/TPROXY and veth peers, but it cannot prove packets originated from Firecracker or that TAP claims follow physical execution. The primary assertion needs native KVM, actual guest consoles and independent listeners. A two-Lilly VM fleet on one outer machine is not two independent physical hosts.

**Open questions:** Can a workload-owned packet collector capture both accepted and refused attempts without relying on a client timeout? `(partial: fleet fixture has live echo and nft drop counters, but no unified nonce packet ledger)`; which native test can rerun the full matrix after current source update and Customer recovery? `(partial: campaign inventory lists selectors and historical scopes, no current run)`.

### Investigation log

- Examined `Policy.router/1`, `Policy.guard/1`, fleet `network.exs` and ADR-0064. Found the direct packet and counter paths and the current Customer private SSH exception. Did not find a composed current Antithesis observer that correlates per-flow nonces, firewall counters and physical boot IDs; no packet delivery defect was reproduced.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `no selected hosted template`. native-KVM-physical-boundary-only; independent witness: actual Firecracker PID/start, jail namespace/UID/cgroup, TAP/nft packet receiver and guest profile. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.
