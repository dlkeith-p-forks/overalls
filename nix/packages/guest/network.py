"""Validated guest address configuration shared by NixOS and Ubuntu."""

import ipaddress
import subprocess
import sys


def parameters(cmdline: str) -> tuple[str, str]:
    """@cc [owner:ghuntley,label:security] guest-network-validated-before-effects
    Missing, duplicate, malformed and reserved lilly.ipv4 parameters MUST fail
    before any network command. Accepted addresses MUST retain /32 host routing.
    """
    values = [
        part.partition("=")[2] for part in cmdline.split() if part.partition("=")[0] == "lilly.ipv4"
    ]
    if len(cmdline) > 4096 or len(values) != 1:
        raise ValueError("invalid guest address")
    address = ipaddress.IPv4Address(values[0])
    first, profile, high, low = address.packed
    if first != 10 or profile not in (10, 20, 30, 40) or not 2 <= high * 256 + low <= 65534:
        raise ValueError("invalid guest address")
    return str(address), f"10.{profile}.0.1"


def configure(cmdline: str, ip: str) -> None:
    """@cc [owner:ghuntley,label:security] guest-inception-paired-address
    Only validated Inception addresses MUST receive an additional 10.41 /32 at
    the identical slot. Other profiles MUST receive only their primary address.
    """
    address, gateway = parameters(cmdline)
    _, profile, high, low = ipaddress.IPv4Address(address).packed
    commands = [
        ["link", "set", "eth0", "up"],
        ["address", "replace", address + "/32", "dev", "eth0"],
    ]
    if profile == 40:
        commands.append(["address", "replace", f"10.41.{high}.{low}/32", "dev", "eth0"])
    commands.extend(
        [
            ["route", "replace", gateway + "/32", "dev", "eth0", "scope", "link"],
            ["route", "replace", "default", "via", gateway, "dev", "eth0"],
        ]
    )
    for arguments in commands:
        subprocess.run([ip, *arguments], check=True)


if __name__ == "__main__":
    with open("/proc/cmdline", encoding="ascii") as source:
        configure(source.read(4097), sys.argv[1])
