"""Private, boot-bound configuration for independent inner service roles."""

from __future__ import annotations

import fcntl
import ipaddress
import json
import os
import sys
from pathlib import Path
from typing import TypedDict

import ingress
from runtime import SetupError, encode, publish, read_private


class RoleBoot(TypedDict):
    placement_id: str
    address: str


class PorscheConfig(TypedDict):
    version: int
    control_plane: str
    public_origin: str
    credential_file: str
    cacertfile: str
    host_key_dir: str
    bind: str
    port: int
    status_socket: str


class AudiTls(TypedDict):
    zone: str
    trust_file: str
    browser_origin: str
    trusted_proxy_peer: str


class AudiConfig(TypedDict, total=False):
    version: int
    role: str
    host_id: str
    control_plane: str
    credential_file: str
    cacertfile: str
    host_key_dir: str
    connector_path: str
    connector_uid: int
    bind: str
    port: int
    status_socket: str
    tls: AudiTls


class DnsConfig(TypedDict):
    version: int
    role: str
    control_plane: str
    credential_file: str
    cacertfile: str
    zone: str
    nameservers: list[str]
    mailbox: str
    bind: str
    port: int
    status_socket: str


def porsche(boot: RoleBoot, config: ingress.Configuration) -> PorscheConfig:
    """@cc [owner:ghuntley,label:security] inception-porsche-runtime-binding
    Porsche MUST bind the current Inception control IPv4 address and use only
    this boot's accepted parent namespace for browser approval. Its internal
    client MUST use local verified TLS and its own gateway credential. No peer
    field may choose a port, private-file path or alternate control endpoint.
    """
    control_address(boot, config)
    return PorscheConfig(
        version=1,
        control_plane="https://localhost:5443",
        public_origin="https://" + config["origins"]["control"],
        credential_file="/run/porsche/gateway.token",
        cacertfile="/run/credentials/porsche.service/ca.pem",
        host_key_dir="/var/lib/porsche/keys",
        bind=boot["address"],
        port=22,
        status_socket="/run/porsche/status.sock",
    )


def control_address(boot: RoleBoot, config: ingress.Configuration) -> ipaddress.IPv4Address:
    request = dict(config, request_id=boot["placement_id"])
    ingress.request(encode(request), boot)
    octets = ipaddress.IPv4Address(boot["address"]).packed
    if octets[:2] != bytes([10, 40]) or not 2 <= octets[2] * 256 + octets[3] <= 65534:
        raise SetupError("Inception role requires its control address")
    return ipaddress.IPv4Address(boot["address"])


def audi(boot: RoleBoot, config: ingress.Configuration, host: object) -> AudiConfig:
    """@cc [owner:ghuntley,label:security] inception-audi-local-binding
    Audi MUST bind the paired 10.41 address at the control address's exact slot,
    use its own enrolled inner host identity and credential, and connect only to
    the root-owned local Lilly connector. Public addresses remain parent-owned;
    neither bootstrap peers nor guest users may choose connector paths or UIDs.
    """
    control = control_address(boot, config).packed
    if not isinstance(host, str) or not ingress.UUID.fullmatch(host):
        raise SetupError("inner host identity invalid")
    address = str(ipaddress.IPv4Address(bytes([10, 41, control[2], control[3]])))
    runtime = AudiConfig(
        version=1,
        role="gateway",
        host_id=host,
        control_plane="https://localhost:5443",
        credential_file="/run/audi/gateway.token",
        cacertfile="/run/credentials/audi.service/ca.pem",
        host_key_dir="/var/lib/audi/keys",
        connector_path="/run/lilly-ingress/audi.sock",
        connector_uid=0,
        bind=address,
        port=22,
        status_socket="/run/audi/status.sock",
    )
    public = config.get("public")
    if public is not None:
        runtime["tls"] = AudiTls(
            zone=config["origins"]["apps"],
            trust_file="/run/credentials/audi.service/issuer-trust.pem",
            browser_origin="https://" + config["origins"]["control"],
            trusted_proxy_peer="10.40.0.1",
        )
    return runtime


def dns(boot: RoleBoot, config: ingress.Configuration) -> DnsConfig | None:
    """@cc [owner:ghuntley,label:security] inception-dns-local-replica
    Inner DNS MUST serve only its assigned app zone from inner Marshall's
    authenticated snapshot. Parent settings may select public NS/SOA names, but
    MUST NOT select its loopback listener, credential, trust or socket paths.
    Public delegation and public addresses remain owned by the parent.
    """
    control_address(boot, config)
    public = config.get("public")
    if public is None:
        return None
    return DnsConfig(
        version=1,
        role="dns",
        control_plane="https://localhost:5443",
        credential_file="/run/audi-dns/dns.token",
        cacertfile="/run/credentials/audi-dns.service/ca.pem",
        zone=config["origins"]["apps"],
        nameservers=[peer["name"] for peer in public["nameservers"]],
        mailbox=public["mailbox"],
        bind="127.0.0.1",
        port=53,
        status_socket="/run/audi-dns/status.sock",
    )


def main() -> None:
    sys.path.insert(0, sys.argv[1])
    from readiness import identity

    boot = identity(Path("/proc/cmdline").read_text())
    root = Path("/run/inception")
    fd = os.open(root / "ingress.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "r+b") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        config = json.loads(read_private(root / "ingress.json"))
        host = json.loads(read_private(Path("/var/lib/inception/lilly.json")))["host_id"]
        publish(root / "porsche.json", encode(porsche(boot, config)))
        publish(root / "audi.json", encode(audi(boot, config, host)))
        # This path comes from the immutable image configuration, never a peer.
        image = json.loads(Path("/etc/inception-public.json").read_bytes())
        with Path(image["system_ca"]).open("rb") as stream:
            system_roots = stream.read(1048577)
        if not 1 <= len(system_roots) <= 1048576:
            raise SetupError("system trust bundle invalid")
        public = config.get("public") or {}
        publish(
            root / "audi-issuer-ca.pem",
            public["issuer_ca_pem"].encode("ascii")
            if public.get("issuer_ca_pem") is not None
            else system_roots,
        )
        publish(
            root / "audi-trust.pem",
            public["trust_pem"].encode("ascii")
            if public.get("trust_pem") is not None
            else system_roots,
        )
        replica = dns(boot, config)
        if replica is not None:
            publish(root / "dns.json", encode(replica))
        else:
            (root / "dns.json").unlink(missing_ok=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, SetupError):
        sys.exit("Inception service configuration unavailable")
