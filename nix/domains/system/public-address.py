"""Validate the SOPS-delivered public addresses and apply the IPv6 address.

The addresses never enter the repository or the Nix store: the IPv6 address
is written as a runtime systemd-networkd drop-in under /run, and the IPv4
address stays in the bundle for destination-scoped firewall listeners.
"""

import argparse
import ipaddress
import os
import subprocess
from pathlib import Path


def ipv4(path: Path) -> ipaddress.IPv4Address:
    text = path.read_text(encoding="ascii").strip()
    try:
        parsed = ipaddress.IPv4Address(text)
    except ValueError:
        raise SystemExit("PUBLIC_IPV4 is not an IPv4 address") from None
    if str(parsed) != text or parsed.is_unspecified or parsed.is_loopback or parsed.is_multicast:
        raise SystemExit("PUBLIC_IPV4 must be a canonical explicit unicast address")
    return parsed


def ipv6(path: Path) -> ipaddress.IPv6Interface:
    text = path.read_text(encoding="ascii").strip()
    try:
        parsed = ipaddress.IPv6Interface(text)
    except ValueError:
        raise SystemExit("PUBLIC_IPV6 is not an IPv6 address/prefix") from None
    address = parsed.ip
    if (
        "/" not in text
        or address.is_unspecified
        or address.is_loopback
        or address.is_multicast
        or address.is_link_local
        or address.ipv4_mapped is not None
    ):
        raise SystemExit("PUBLIC_IPV6 must be an explicit unicast address with its prefix")
    return parsed


def drop_in(network: str) -> Path:
    return Path("/run/systemd/network") / f"{network}.network.d" / "50-public-address.conf"


def reload() -> None:
    subprocess.run(["networkctl", "reload"], check=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle", required=True, type=Path)
    parser.add_argument("--network", required=True)
    parser.add_argument("--remove", action="store_true")
    args = parser.parse_args()
    target = drop_in(args.network)
    if args.remove:
        if target.exists():
            target.unlink()
            reload()
        return
    ipv4(args.bundle / "ipv4")
    address = ipv6(args.bundle / "ipv6")
    target.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    staged = target.with_suffix(".tmp")
    staged.write_text(f"[Network]\nAddress={address.with_prefixlen}\n", encoding="ascii")
    # networkd reads the drop-in as systemd-network; it holds no credential.
    os.chmod(staged, 0o644)
    os.replace(staged, target)
    reload()


if __name__ == "__main__":
    main()
