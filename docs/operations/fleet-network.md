# IPv4 fleet control network

The [physical deployment](../../fleet/fleet-network.nix) assigns Overalls
`10.90.0.1/32` and Dungarees `10.90.0.2/32` on `fleet0`. WireGuard uses UDP
51820 between their physical IPv4 addresses. Only declared peers may reach that
UDP destination; each peer owns exactly one tunnel `/32`. IPv6 is disabled.

```text
Public browser -> 136.243.69.55:443 -> Marshall browser listener (4443)
Public SSH     -> 136.243.69.55:22  -> Porsche
Public apps    -> 136.243.69.37     -> Audi (Overalls)  -> local Lilly connector -> guest
Public apps    -> 136.243.69.32     -> Audi (Dungarees) -> local Lilly connector -> guest
Public DNS     -> 136.243.69.37 / 136.243.69.32 UDP+TCP 53 -> Audi DNS replicas

Dungarees fleet clients
  -> verified HTTPS over fleet0
  -> 10.90.0.1:5443 -> Marshall machine APIs
       ^
       |
Overalls local fleet clients -> 127.0.0.1:5443
```

The fleet API still requires purpose-bound application credentials. WireGuard
peer identity does not grant Marshall authority. Public browser endpoints return
404 for machine API paths, retaining only current SSH host-key discovery there.
The tunnel does not forward guest traffic or carry public Audi ingress.

Overalls retains its loopback DNS mapping for local database and service TLS.
Dungarees maps `ghuntley.dev` to the tunnel address and uses port 5443 with the
existing service CA. The public browser hostname and external DNS remain separate
from this host-local resolution. Lilly, Ziggy, private Audi certificate renewal,
Audi's gateway and DNS roles, and monitoring use the fleet endpoint. There is no
public-API fallback.

ZFS replication retains the separately authenticated
[transfer SSH service](../../nix/domains/system/transfer.nix) and its explicit transfer
endpoints. This tunnel does not replace that service with administrative SSH.
Administrative SSH and reciprocal Nix builders also retain their existing paths.

The [module](../../nix/domains/system/fleet-network.nix) opens declared TCP ports only for
configured peer sources on `fleet0`, and drops forwarded traffic entering or
leaving the tunnel. Guest policy additionally protects `10.90.0.0/24`.
The tunnel interface is not globally trusted. Missing key custody prevents tunnel
startup; Marshall waits for its configured tunnel address before binding.

## Key custody and validation

Each host has a separate inventoried `HOST-fleet-network` SOPS document. Its
SecretSpec payload is `overalls-fleet-network.production.WIREGUARD_PRIVATE_KEY`.
Only the owning host and configured recovery users receive the document.
[Public peer keys](../../fleet/fleet-public-keys.json) are committed separately;
private keys are delivered to `/run/overalls-secrets/fleet-network/private-key`.

The keys were generated in private temporary storage, encrypted with the existing
inventory tool and checked against its recipient policy. Temporary plaintext was
removed. Host/recovery decryption and production handshakes are not yet verified.
Rotation must update the owning host's ciphertext and the other host's public
peer key together, with explicit restart/recovery validation; existing encrypted
documents must not be overwritten by routine builds or boot-time key generation.

Both host configurations evaluate. Module checks cover both firewall backends,
IPv4 routes, collisions, and refusal of disabled firewalls or a trusted tunnel.
The [native test](../../nix/verification/tests/machines/fleet-network/default.nix) additionally
exercises traffic, denied ports, physical-interface refusal, forwarding drop
counters and key revocation. The two-VM test passed on September 18, including
both nftables and iptables forwarding counters and refusal after peer removal.
No production deployment is claimed.

## Audi public plane rollout

Both hosts enable Audi's gateway and authoritative DNS roles
([ADR-0090](../architecture/decisions/0090-second-audi-dns-replica-on-worker.md),
[ADR-0091](../architecture/decisions/0091-fleet-perimeter-public-listeners.md))
on the reserved explicit addresses, serving the delegated `apps.ghuntley.dev`
subzone. The committed SOPS documents carry nonfunctional placeholder tokens;
replace them before activation, following the Ziggy placeholder precedent.

Operator rollout order:

1. At the external `ghuntley.dev` DNS provider, create
   `ns1.ghuntley.dev A 136.243.69.37` and `ns2.ghuntley.dev A 136.243.69.32`,
   then delegate `apps.ghuntley.dev NS ns1.ghuntley.dev, ns2.ghuntley.dev`.
   Keep the apex `ghuntley.dev A 136.243.69.55` external: the proxy's HTTP-01
   issuance and Porsche's public origin depend on it, and Audi DNS serves no
   apex A record.
2. On Overalls, enroll services with the Marshall operator CLI, writing each
   token to private storage outside the checkout:
   `audi-dns-rotate audi-overalls-dns /private/overalls-dns.token`,
   `audi-gateway-rotate audi-overalls HOST_ID 136.243.69.37 /private/overalls.token`,
   `audi-dns-rotate audi-dungarees-dns /private/dungarees-dns.token`, and
   `audi-gateway-rotate audi-dungarees HOST_ID 136.243.69.32 /private/dungarees.token`.
   `HOST_ID` is the host's enrolled Lilly host UUID. Verify each file with
   `audi-dns-verify` / `audi-gateway-verify`.
3. Encrypt the four values into the inventoried documents
   (`overalls-audi.production.AUDI_GATEWAY_TOKEN`,
   `overalls-audi-dns.production.AUDI_DNS_TOKEN`) with
   `nix run .#secrets -- encrypt HOST-audi --input ... --replace` and run
   `nix run .#secrets -- check`.
4. Provision the encrypted backup document and S3 destination, enable
   `services.overallsBackups`, and complete a PostgreSQL/keyring recovery point
   before making the shared wildcard key a production dependency. Deploy
   Overalls first (Marshall gains the wildcard issuer and both local Audi
   roles), then Dungarees (worker roles reach Marshall over `fleet0`).
5. Validate externally: `dig @136.243.69.37 apps.ghuntley.dev SOA` and the same
   against `.32`; `dig +trace apps.ghuntley.dev NS` from a public resolver;
   confirm TCP 22/443/80 and UDP/TCP 53 reach both addresses from an
   unlisted source; stop one `audi-dns` at a time and confirm the other
   replica keeps answering.

The checked-in host declarations now select one Marshall-issued Let's Encrypt
wildcard for `apps.ghuntley.dev`, with gateway trust from the public CA bundle.
The earlier per-VM issuer and staging rollout are historical. After deployment,
inspect **Administrator audit → Certificates** for the active generation and an
installation receipt from each gateway, then verify an actual VM hostname over
HTTPS through both public gateway addresses. Nix evaluation and the isolated
fleet machine test do not establish this physical cutover.
