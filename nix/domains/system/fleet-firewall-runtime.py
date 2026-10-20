"""Fill a fleet firewall chain for a public listener whose address is runtime data.

The address comes from a root-owned runtime file (normally a decrypted SOPS
bundle), so it never enters the repository or the Nix store. The chain is
flushed first, so a rotated address replaces the previous rules, and a
malformed address leaves the chain empty: the listener stays closed.
"""

import argparse
import ipaddress
import re
import subprocess
from pathlib import Path
from typing import NamedTuple


class Rule(NamedTuple):
    protocol: str
    port: int


def rule(value: str) -> Rule:
    match = re.fullmatch(r"(tcp|udp):([0-9]{1,5})", value)
    if match is None or not 1 <= int(match.group(2)) <= 65535:
        raise argparse.ArgumentTypeError("rule must be tcp:PORT or udp:PORT")
    return Rule(match.group(1), int(match.group(2)))


def address(path: Path) -> str:
    """Return the canonical explicit IPv4 address held in path."""
    text = path.read_text(encoding="ascii").strip()
    try:
        parsed = ipaddress.IPv4Address(text)
    except ValueError:
        raise SystemExit("Runtime public address is not an IPv4 address") from None
    if (
        str(parsed) != text
        or parsed.is_unspecified
        or parsed.is_loopback
        or parsed.is_multicast
        or parsed.is_link_local
    ):
        raise SystemExit("Runtime public address must be a canonical explicit unicast IPv4 address")
    return text


def iptables(*args: str) -> None:
    subprocess.run(["iptables", "-w", *args], check=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--chain", required=True)
    parser.add_argument("--address-file", required=True, type=Path)
    parser.add_argument("--comment", required=True)
    parser.add_argument("--rule", action="append", required=True, type=rule)
    args = parser.parse_args()
    chain: str = args.chain
    rules: list[Rule] = args.rule
    # Close the listener before validating, so a bad rotation never keeps the
    # previous address open.
    if subprocess.run(["iptables", "-w", "-F", chain], check=False).returncode != 0:
        iptables("-N", chain)
    destination = address(args.address_file)
    # Accept directly: a reference to nixos-fw-accept would stop the NixOS
    # firewall from recreating that chain on reload.
    for item in rules:
        iptables(
            "-A",
            chain,
            "-d",
            destination,
            "-p",
            item.protocol,
            "--dport",
            str(item.port),
            "-m",
            "comment",
            "--comment",
            args.comment,
            "-j",
            "ACCEPT",
        )


if __name__ == "__main__":
    main()
