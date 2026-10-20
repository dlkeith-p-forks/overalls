# ADR-0232: SOPS-delivered public host addresses

- ID: ADR-0232
- Date: 2026-10-20
- Status: accepted
- Implementation: partial
- Components: host inventory, host tool, NixOS host profile, fleet firewall, SOPS secrets
- Supersedes: none
- Superseded by: none

## Context

[ADR-0231](0231-hetzner-cloud-hosts-and-susan-placement.md) declared the
salopettes uplink with static address literals, and the fleet firewall's
destination-scoped public listeners
([ADR-0091](0091-fleet-perimeter-public-listeners.md)) require their IPv4
address at evaluation time. The repository is public, so every literal is
published with the host declaration. The operator requires the Susan host's
addresses to come only from the SOPS secret system, so a later address
rotation needs no repository literal. Hetzner Cloud serves the primary IPv4
address by DHCP; the IPv6 /64 has no DHCP or router advertisement.

## Decision

- **No address literals on hcloud.** Hetzner Cloud host declarations take
  IPv4 from DHCP and hold no `Address` entries or preferred sources; the
  profile refuses one (`@cc hcloud-addresses-outside-repository`). Discovery
  proposes DHCP and keeps only each default route's interface. The provider's
  fixed IPv6 gateway `fe80::1` stays declared.
- **Host-bound address document.** `overalls.publicAddress` decrypts a
  host-bound SOPS document (project `overalls-public-address`, `PUBLIC_IPV4`
  and `PUBLIC_IPV6` with its prefix) through the ordinary secret bundle. Its
  unit validates both values and applies the IPv6 address as a runtime
  systemd-networkd drop-in under `/run`; a missing or malformed document fails
  the unit (`@cc public-address-from-sops`).
- **Runtime-address public listeners.** A fleet firewall public service may
  name an `addressFile` and its publishing `addressUnit` instead of an
  `address`. The evaluated rules only jump to a dedicated, initially empty
  chain; a unit following the address unit validates the runtime IPv4 address
  and fills the chain with destination-scoped accepts. A failed or malformed
  document leaves the chain empty, a firewall reload keeps the validated
  rules, and a rotation replaces them. This variant requires the iptables
  backend.
- **Salopettes** uses all three: document `salopettes-address`, the Susan
  listener on TCP 80 and 443 at the runtime address, and nginx bound to every
  address behind that scoped rule.

Authorization: the operator's instruction that the salopettes address is a
secret and must come from the Nix SOPS secret system.

## Alternatives

- **Static addresses in an encrypted Nix input:** evaluation would need the
  plaintext on every builder and store it in the Nix store. Rejected.
- **Interface-scoped listeners (`-i enp1s0`):** admits any address the
  interface later gains and weakens ADR-0091's destination scoping. Rejected.
- **An nftables named set:** the NixOS nftables firewall flushes the whole
  ruleset on reload, so runtime set contents would need a second reload hook.
  Deferred until a runtime-address host uses nftables.

## Consequences

- Address rotation is a SOPS document change; the updater restarts the bundle
  and its dependents.
- The base system boots and installs without the document, using DHCP.
- Earlier trunk history still contains the literals published with ADR-0231;
  the operator chose to rotate the address instead of rewriting history.
- DNS records still publish the service address by design.

## Invariants and verification

- `public-address` NixOS machine test: no listener before decryption, only the
  declared port at the decrypted address, persistence across firewall reload
  and restart, rotation, a malformed document closing the listener, and the
  IPv6 drop-in applied by networkd (`@cc public-address-machine-check`).
- `fleet-firewall-configuration` checks the runtime chain, ordering, and
  refusals (missing unit, both address forms, nftables).
- `host-planning` `test_hcloud_discovery_keeps_addresses_out_of_the_candidate`.

## Implementation evidence

- [`public-address.nix`](../../../nix/domains/system/public-address.nix),
  [`fleet-firewall.nix`](../../../nix/domains/system/fleet-firewall.nix),
  [`fleet-firewall-runtime.py`](../../../nix/domains/system/fleet-firewall-runtime.py),
  [`profile.nix`](../../../nix/platform/hosts/profile.nix) and
  [`cli.py`](../../../nix/domains/artifacts/host/cli.py).
- [`salopettes`](../../../fleet/hosts/salopettes/configuration.nix) with
  `secrets/salopettes-address.enc.json`. Deployment evidence on the host is
  pending enrollment.

## Open questions

- Runtime-address listeners on the nftables backend.
- Forward filtering for exit-node hosts: like the other fleet exit nodes,
  salopettes leaves the FORWARD policy at its default.

## Related decisions

Amends [ADR-0231](0231-hetzner-cloud-hosts-and-susan-placement.md) (hcloud
addressing) and [ADR-0091](0091-fleet-perimeter-public-listeners.md)
(runtime-address listeners).
