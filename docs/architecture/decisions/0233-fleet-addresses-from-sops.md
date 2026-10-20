# ADR-0233: Fleet addresses from SOPS and the Susan fleet path

- ID: ADR-0233
- Date: 2026-10-20
- Status: accepted
- Implementation: partial
- Components: fleet addresses, runtime firewall, fleet WireGuard, host profile, host tool, Porsche, Audi, Audi DNS, Marshall proxy, Lilly, Brady, Susan, SOPS secrets
- Supersedes: ADR-0232
- Superseded by: none

## Context

[ADR-0232](0232-sops-delivered-public-host-addresses.md) moved salopettes'
addresses into a host-bound SOPS document, but Overalls and Dungarees still
declared about 45 address literals: uplink addresses, gateways, routes,
listener binds, reviewed-source grants, WireGuard endpoints and Lilly's
protected networks. Every one was evaluated into the Nix store of a public
repository. The operator asked for the same SOPS pattern on Overalls and
Dungarees, and noted that each dedicated host has its own gateway.

Separately, Marshall at `ghuntley.dev` must reach Susan on salopettes. Susan's
origin `https://notifications.overalls.dev` is compiled into Marshall; the
operator chose the fleet WireGuard path that Dungarees already uses, with
IPv6 disabled on salopettes and Overalls admitting salopettes' handshake only
from its SOPS-delivered address.

Observed constraints:

- Overalls and Dungarees use the nftables firewall, which deletes and
  recreates `inet nixos-fw` on every reload; ADR-0232's runtime chain was
  iptables-only.
- The updater has no rollback, so a networking mistake on a dedicated host
  stays until repaired over Tailscale or the console.
- The addresses are also published by DNS and remain in earlier history.
  Removing them from the repository does not make them private.

## Decision

- **One shared document.** `secrets/fleet-addresses.enc.json` (project
  `overalls-fleet-addresses`) holds every fleet address: each dedicated host's
  primary and service IPv4, its own prefix and gateway, and salopettes' IPv4.
  Its recipients are the recovery users and all three hosts. It replaces
  `salopettes-address`.
- **`overalls.fleetAddresses`.** A host maps logical names to secret names
  (`*_IPV4` or `*_PREFIX`). The bundle writes one root-only file per name and
  an environment file. `overalls-fleet-addresses.service` validates every value
  (canonical, explicit unicast) before any consumer starts, and a malformed or
  missing document fails it (`@cc fleet-addresses-from-sops`). Shared policy
  names the hosts (`nix/policy/network/fleet-addresses.nix`); host declarations
  add their own prefix and gateway names.
- **Runtime uplink with a recovery copy.** A dedicated host's static uplink is
  a runtime systemd-networkd drop-in under `/run` (addresses, an on-link
  gateway route, the default route, the subnet route and `/32` routes to the
  other host). Each applied drop-in is kept as a root-only recovery copy in
  `/var/lib/overalls-host/uplink.conf`. The unit falls back to that copy when
  the document cannot be read, and host installation writes it from the
  authenticated discovery facts, so neither a SOPS failure nor a base system
  without the document strands the host (`@cc fleet-uplink-recovery-copy`).
  The profile refuses IPv4 address, gateway or destination literals on a host
  with a runtime uplink (`@cc uplink-addresses-outside-repository`).
- **Runtime firewall on both backends.** `overalls.runtimeFirewall` is one
  chain, `overalls-runtime`, reached by a static jump from the input allow
  path. Its refill unit flushes first and then validates every address, so a
  malformed value leaves the chain empty. It follows the publishing units and
  refills after every reload or restart of either backend
  (`@cc runtime-firewall-addresses`). It carries the runtime forms of
  reviewed-source grants (`allowedHosts.*.addressFile`), destination-scoped
  public listeners (`publicServices.*.addressFile`) and WireGuard handshakes.
- **Runtime WireGuard endpoints.** A fleet host's own endpoint and each peer's
  endpoint may be runtime files. A per-peer unit sets the endpoint with
  `wg set` after the peer unit and the address units, and sets it again on
  every peer restart (`@cc fleet-runtime-endpoints`).
- **Salopettes joins `fleet0`** at `10.90.0.3`, peering only with Overalls,
  with IPv6 disabled. Its private key is in `salopettes-fleet-network`, and its
  fleet TCP ports are 443 (Susan), 9464 and 9467 (metrics). Overalls resolves
  `notifications.overalls.dev` to `10.90.0.3`, so Marshall's compiled origin
  uses the tunnel and the public Let's Encrypt certificate still validates.
  Mila devices keep the public origin.
- **Service consumers take runtime addresses.** Porsche, Audi and Audi DNS
  accept `bindAddressFile`/`bindAddressUnit` and render their configuration
  into `/run` at start, refusing a wildcard or malformed address; with a
  runtime address, Audi refuses at start to share Porsche's address and port.
  The HAProxy listeners and the fleet relay socket bind runtime addresses
  through a start-time guard. Lilly and Brady append runtime protected
  addresses as `/32` networks, and the updater compares the effective
  protected set, so moving a literal into a file is not a binding change.
- **Hetzner Cloud discovery is IPv4-only.** It proposes DHCP IPv4 with link-local
  addressing off and no IPv6 route.

Authorization: the operator's instructions to use the encrypted network
address pattern for Overalls and Dungarees, that each machine has its own
gateway, to take the WireGuard network path for Marshall → Susan with IPv6
disabled and the salopettes address from SOPS, and to migrate Dungarees while
it is offline.

## Alternatives

- **Tailscale for Marshall → Susan:** it works today, but it puts the push path
  on a third-party coordination plane that the fleet's control traffic does
  not otherwise depend on. Rejected in favour of `fleet0`.
- **Keep host-bound address documents:** every host would need the other
  hosts' addresses for grants, routes and endpoints, duplicating values across
  documents and making rotation a multi-document change. Rejected for one
  shared document.
- **nftables named sets refilled after reload:** equivalent to the runtime
  chain, but it needs per-set declarations in the evaluated table and has no
  iptables counterpart. Rejected for one chain on both backends.
- **Static literals for routes only:** the gateways and subnet would still
  identify the hosts. Rejected.

## Consequences

- Rotating any fleet address is one document change. Rotating a
  Lilly-protected address also changes Lilly's network claim and needs the
  deliberate rebind flow.
- Rollout is staged because the updater has no rollback: the mechanism and
  runtime consumers land first, alongside the existing literals and with
  equal values. The literals are removed host by host afterwards, with
  Tailscale as the recovery path.
- Dungarees is offline during the migration and receives every stage when it
  returns.
- The remote builder entry for Dungarees uses its Tailscale address, like
  Overalls, so no public address is evaluated.
- The public `notifications.overalls.dev` record must be DNS-only. When the
  record is proxied, the public origin loops on redirects.
- History and DNS still publish the addresses; the operator will rotate them.
- Docs name addresses by secret (for example `OVERALLS_PRIMARY_IPV4`);
  operators decrypt the document into private storage when a command needs a
  value.

## Invariants and verification

- `fleet-addresses` NixOS machine test (`@cc fleet-addresses-machine-check`):
  on nftables and iptables nodes, nothing is admitted or addressed before
  decryption. After decryption only the declared rules open; source grants
  follow rotation; reloads and restarts refill the chain; and a malformed
  document closes every rule. The uplink drop-in addresses the interface and
  reaches its gateway, and the recovery copy keeps the address when the
  document is malformed.
- `fleet-network` NixOS machine test: a peer whose endpoints and handshake rule
  are runtime-only stays closed until they are published, refuses a malformed
  endpoint, then gains the `wg` endpoint and the runtime handshake rule.
- `fleet-firewall-configuration`, `enrollment-configuration`,
  `porsche-configuration`, `audi-configuration`, `brady-configuration` and
  `host-planning` cover the evaluated wiring, refusals, the install recovery
  copy (byte-equal to the runtime drop-in) and the effective protected set.
- A `git grep` and closure scan with the plaintext values from private storage
  finds none of the fleet addresses outside history.

## Implementation evidence

- [`fleet-addresses.nix`](../../../nix/domains/system/fleet-addresses.nix) and
  [`fleet-addresses.py`](../../../nix/domains/system/fleet-addresses.py);
  [`runtime-firewall.nix`](../../../nix/domains/system/runtime-firewall.nix) and
  [`runtime-firewall.py`](../../../nix/domains/system/runtime-firewall.py);
  [`fleet-firewall.nix`](../../../nix/domains/system/fleet-firewall.nix);
  [`fleet-network.nix`](../../../nix/domains/system/fleet-network.nix) and
  [`fleet-endpoint.py`](../../../nix/domains/system/fleet-endpoint.py).
- [`runtime-bind.nix`](../../../nix/domains/system/runtime-bind.nix) for Porsche,
  Audi and Audi DNS;
  [`protected-addresses.nix`](../../../nix/domains/system/protected-addresses.nix)
  for Lilly and Brady; the updater's effective protected set in
  [`runtime.py`](../../../nix/domains/system/auto-update/runtime.py).
- [`profile.nix`](../../../nix/platform/hosts/profile.nix),
  [`fleet-addresses` policy](../../../nix/policy/network/fleet-addresses.nix),
  [`allowed-hosts.nix`](../../../nix/policy/network/allowed-hosts.nix),
  [`fleet-network.nix`](../../../fleet/fleet-network.nix) and the host tool's
  [`cli.py`](../../../nix/domains/artifacts/host/cli.py) and
  [`remote.py`](../../../nix/domains/artifacts/host/remote.py).
- Tests: [`fleet-addresses`](../../../nix/verification/tests/machines/fleet-addresses/default.nix),
  [`fleet-network`](../../../nix/verification/tests/machines/fleet-network/default.nix),
  [`fleet-firewall`](../../../nix/verification/tests/evaluation/fleet-firewall.nix) and
  [`host-planning`](../../../nix/verification/tests/evaluation/host-planning.py).
- Host declarations: the retired Overalls declaration and
  [Dungarees](../../../fleet/hosts/dungarees/host.json) carry no address
  literals; both hosts' Lilly protected networks are runtime files
  ([Overalls](../../../fleet/roles/control-plane/services.nix),
  [Dungarees](../../../fleet/hosts/dungarees/configuration.nix)).
- Remaining gaps: deployment evidence (the WireGuard handshake with salopettes, Susan health
  over `fleet0`, runtime chains, binds and the recovery copy) is recorded as
  each stage reaches the hosts. No machine test starts Porsche, Audi, HAProxy
  or Lilly with a runtime address.

## Open questions

- Forward filtering on exit-node hosts, carried over from ADR-0232.

## Related decisions

[ADR-0239](0239-salopettes-joins-panterloons-tunnel.md) moves Salopettes and
the Susan fleet path to the Panterloons tunnel.
[ADR-0234](0234-installer-source-administrative-grant.md) amends the base-system
case: a base system without this document admits its recorded installer source
to administrative SSH. Supersedes [ADR-0232](0232-sops-delivered-public-host-addresses.md). Amends
[ADR-0075](0075-fleet-overlay-and-source-access.md) (runtime WireGuard
endpoints, runtime-source grants and the third peer),
[ADR-0091](0091-fleet-perimeter-public-listeners.md) (runtime-address listeners
on both backends) and
[ADR-0231](0231-hetzner-cloud-hosts-and-susan-placement.md) (salopettes on
`fleet0` with IPv6 off).
