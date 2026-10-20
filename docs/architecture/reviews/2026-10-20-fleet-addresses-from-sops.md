# Fleet addresses from SOPS and the Susan fleet path

Scope: [ADR-0233](../decisions/0233-fleet-addresses-from-sops.md), which
supersedes ADR-0232 and amends ADR-0075, ADR-0091 and ADR-0231. The change
moves every fleet public address into one shared SOPS document, adds runtime
forms for the firewall, WireGuard endpoints, the uplink and service binds, and
puts salopettes on `fleet0` so Marshall reaches Susan over the tunnel.

The rollout is staged because the updater has no rollback:

1. **Stage A (this review):** the mechanism, the document, the runtime
   consumers on all three hosts, and salopettes on `fleet0` with IPv6 off.
   Overalls and Dungarees keep their literal uplink addresses and routes and
   their Lilly protected networks, so the runtime and literal values coincide.
2. **Later stages:** the literals are removed from Dungarees, then Overalls,
   each with its own evidence.

## Boundaries reviewed

- **Authorization.** Reviewed-source grants keep their names in policy
  (`nix/policy/network/allowed-hosts.nix`). Only the address became runtime
  data. Each grant admits one validated source on every port, as before. On
  Overalls, salopettes' WireGuard handshake is admitted only from
  `SALOPETTES_IPV4`, to `OVERALLS_PRIMARY_IPV4`, on UDP 51820.
- **Execution fencing.** Every consumer orders after
  `overalls-fleet-addresses.service` and requires it. The refill unit flushes
  before validating, so a malformed rotation leaves the runtime chain empty
  instead of keeping an older address open. Service binds refuse wildcard,
  empty and non-canonical values at start.
- **Isolation.** All runtime rules share one chain reached by a static jump.
  The nftables refill follows `ReloadPropagatedFrom=nftables.service`, because
  a reload deletes and recreates `inet nixos-fw`.
- **Storage.** Values exist only in `/run/overalls-secrets/fleet-addresses/`,
  the per-service runtime configurations under `/run`, and the root-only
  uplink recovery copy in `/var/lib/overalls-host/uplink.conf`. None reaches
  the Nix store. A closure scan of salopettes found none of the fleet values.
- **Recovery.**
  - A dedicated host's uplink falls back to its recovery copy, and
    installation writes that copy from authenticated discovery facts.
  - Tailscale stays the operator recovery path, since administrative SSH
    already listens there.
  - Dungarees is offline and receives every stage when it returns.
- **Transport.** Overalls maps `notifications.overalls.dev` to `10.90.0.3`, and
  Marshall still verifies Susan's public Let's Encrypt certificate inside the
  tunnel. The tunnel is IPv4-only on all three hosts.

## Findings

1. **Medium (accepted requirement, explicit gap): salopettes can reach every
   Overalls fleet TCP port.** `fleet-network.nix` opens a host's `tcpPorts` to
   all of its peers. Salopettes can therefore open connections to Overalls'
   Marshall fleet API, Audi relay, collector and metrics ports. Each of those
   services still requires its own application credential or enrolled peer
   identity (ADR-0075). Recommendation: add per-peer port scoping before
   another single-purpose host joins `fleet0`.
2. **Low (consequence): Marshall now requires the fleet address unit.** The
   wildcard issuer reads the Audi DNS replica addresses as credentials, so a
   document that fails to decrypt on Overalls stops Marshall along with the
   proxy, Porsche and Audi. The same machinery has run on salopettes since
   enrollment. Recovery is a document fix over Tailscale.
3. **Low (explicit gap): Lilly protected networks stay literal in stage A.**
   The updater reads runtime files at preflight. Referencing them before the
   bundle exists on a host would refuse the update, so the literals move in
   the later stages. Rotating a protected address needs the deliberate Lilly
   rebind flow.
4. **Observation (pre-existing, unchanged): public reachability on Overalls'
   primary address.** The perimeter admits only TCP 80 and 3443 there from any
   source. TCP 443 and 22 are reachable from the reviewed sources and Tailscale.
   This change preserves that exactly.
5. **Operator action: Cloudflare.** `notifications.overalls.dev` must be
   DNS-only. While it is proxied, the public origin loops on redirects for Mila
   devices.

## Checks run

These ran on the integrated tree before stage A was committed:

- Recorded run: NixOS machine test `fleet-addresses` **passed** (7 subtests on
  nftables and iptables nodes, including the uplink recovery copy).
- Recorded run: NixOS machine test `fleet-network` **passed** (4 subtests,
  including a peer whose endpoints and handshake rule are runtime-only).
- Recorded run: NixOS machine test `proxy-runtime-address` **passed**.
- Evaluation checks passed: `fleet-firewall-configuration`,
  `enrollment-configuration`, `module-configuration` (including the rendered
  nameserver line), `host-planning` (32 tests, including the install recovery
  copy byte-equal to the runtime drop-in), `porsche-configuration`,
  `audi-configuration`, `brady-configuration`, `public-grafana-configuration`,
  `runtime-socket-configuration` and `acme-http01`.
- Script and Audi tests passed: `test_egress_acceptance`,
  `test_provisioning_benchmark` and `audi/test/config_test.exs` (15 tests).
- Assertions pass on `overalls`, `dungarees`, `salopettes` and their `-base`
  systems. The `dungarees` and `salopettes` toplevels evaluate. The `overalls`
  toplevel is blocked by the pre-existing default image identity derivation,
  which another session owns.
- prek (ruff, ruff-format, ty, conflict markers), `check_contracts`, and
  `check_adrs` passed.
- A `git grep` with the plaintext values from private storage finds fleet
  addresses only in the two host declarations and the two Lilly protected
  lists that later stages remove.

Not run: the `public-grafana` machine test. The HAProxy fork reported a
dashboard panel-count failure there that it attributes to pre-existing work and
did not compare against trunk.

## Deployment evidence

- **Salopettes, stage A (`9ac8b01e`).** The updater activated stage A. Its
  state:
  - no failed units;
  - `overalls-fleet-addresses`, `overalls-runtime-firewall`,
    `wireguard-fleet0`, `overalls-fleet-endpoint-overalls`, Susan and nginx
    active;
  - no global IPv6 address;
  - `fleet0` at `10.90.0.3/32` sending handshakes to the runtime endpoint;
  - the runtime chain holds the handshake rule, the Susan TCP 80/443
    destination rules and both reviewed-source grants, all at SOPS-delivered
    addresses;
  - Susan `/healthz` answers 200.

  No handshake is received yet, because Overalls has not activated stage A.
- **Overalls, stage A.** Not activated: its updater fails at the build phase
  on the pre-existing `OverallsProtocol.GuestAgents.parse/1` failure in the
  default image identity derivation, which another session owns.
- **Dungarees.** Offline.

## Stage B (Dungarees declaration)

The Dungarees declaration loses every address literal:

- uplink addresses and routes become `addresses.uplink`, the runtime drop-in;
- discovery keeps only the default route's interface;
- the Lilly transfer endpoint names `DUNGAREES_PRIMARY_IPV4` by secret, and
  `prepare-enrollment` resolves it with the recovery key.

A drop-in rendered from the private values reproduces the five literal routes
and both addresses exactly. Its Lilly protected networks stay literal: the
updater compares the raw binding while the address files are missing, so
moving them before Dungarees has run stage A would refuse its update when it
returns.

- Recorded run: `enrollment-preparation` **passed** (12 tests, including the
  transfer address from the fleet document and its refusals).

## Follow-up

- Stage A deployment evidence:
  - the WireGuard handshake between Overalls and salopettes;
  - Susan `/healthz` over `fleet0`;
  - runtime chains and binds on Overalls.
- Later stages:
  - the uplink drop-in and recovery copy on Overalls and Dungarees;
  - removing the host declaration literals and Lilly protected literals.
- Per-peer fleet port scoping (finding 1).
- Machine tests that start Porsche, Audi and Lilly with runtime addresses.
