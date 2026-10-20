"""Fill the runtime firewall chain from rules whose addresses are runtime data.

Addresses come from root-owned runtime files (normally a decrypted SOPS
bundle), so they never enter the repository or the Nix store. Every address is
validated before anything is admitted; one malformed address leaves the whole
chain empty, so a bad rotation never keeps an old address open. An optional
rule whose runtime file is absent is skipped; every other rule still applies.
"""

import contextlib
import ipaddress
import json
import subprocess
import sys
from pathlib import Path
from typing import TypedDict


class RuleSpec(TypedDict):
    name: str
    source: str | None
    sourceFile: str | None
    destination: str | None
    destinationFile: str | None
    protocol: str
    ports: list[int]
    interface: str | None
    comment: str
    optional: bool


class Specification(TypedDict):
    chain: str
    backend: str
    rules: list[RuleSpec]


class Rule(TypedDict):
    source: str | None
    destination: str | None
    protocol: str
    ports: list[int]
    interface: str | None
    comment: str


def canonical(text: str) -> str:
    """Return text if it is a canonical explicit unicast IPv4 address."""
    try:
        parsed = ipaddress.IPv4Address(text)
    except ValueError:
        raise SystemExit("Runtime firewall address is not an IPv4 address") from None
    if (
        str(parsed) != text
        or parsed.is_unspecified
        or parsed.is_loopback
        or parsed.is_multicast
        or parsed.is_link_local
    ):
        raise SystemExit(
            "Runtime firewall address must be a canonical explicit unicast IPv4 address"
        )
    return text


def side(static: str | None, file: str | None) -> str | None:
    if file is None:
        return static
    return canonical(Path(file).read_text(encoding="ascii").strip())


def resolve(spec: RuleSpec) -> Rule:
    return {
        "source": side(spec["source"], spec["sourceFile"]),
        "destination": side(spec["destination"], spec["destinationFile"]),
        "protocol": spec["protocol"],
        "ports": spec["ports"],
        "interface": spec["interface"],
        "comment": spec["comment"],
    }


def nft_rule(chain: str, rule: Rule) -> str:
    parts = ["add rule inet nixos-fw", chain]
    if rule["interface"] is not None:
        parts.append(f'iifname "{rule["interface"]}"')
    if rule["source"] is not None:
        parts.append(f"ip saddr {rule['source']}")
    if rule["destination"] is not None:
        parts.append(f"ip daddr {rule['destination']}")
    if rule["protocol"] == "any":
        parts.append("meta l4proto { tcp, udp }")
    else:
        ports = ", ".join(str(port) for port in rule["ports"])
        parts.append(f"{rule['protocol']} dport {{ {ports} }}")
    parts.append(f'accept comment "{rule["comment"]}"')
    return " ".join(parts)


def iptables_rules(chain: str, rule: Rule) -> list[list[str]]:
    prefix = ["-A", chain]
    if rule["interface"] is not None:
        prefix += ["-i", rule["interface"]]
    if rule["source"] is not None:
        prefix += ["-s", rule["source"]]
    if rule["destination"] is not None:
        prefix += ["-d", rule["destination"]]
    suffix = ["-m", "comment", "--comment", rule["comment"], "-j", "ACCEPT"]
    if rule["protocol"] == "any":
        return [[*prefix, "-p", protocol, *suffix] for protocol in ("tcp", "udp")]
    return [
        [*prefix, "-p", rule["protocol"], "--dport", str(port), *suffix] for port in rule["ports"]
    ]


def nft(script: str) -> None:
    subprocess.run(["nft", "-f", "-"], input=script, text=True, check=True)


def iptables(args: list[str], check: bool = True) -> int:
    return subprocess.run(["iptables", "-w", *args], check=check).returncode


def flush(spec: Specification) -> None:
    chain = spec["chain"]
    if spec["backend"] == "nftables":
        nft(f"add chain inet nixos-fw {chain}\nflush chain inet nixos-fw {chain}\n")
    elif iptables(["-F", chain], check=False) != 0:
        iptables(["-N", chain])


def present(spec: RuleSpec) -> bool:
    """Return False only for an optional rule whose runtime file is absent."""
    files = [file for file in (spec["sourceFile"], spec["destinationFile"]) if file is not None]
    return not spec["optional"] or all(Path(file).exists() for file in files)


def apply(spec: Specification) -> None:
    # Close first: validation failures must never leave earlier rules open.
    flush(spec)
    rules = [resolve(rule) for rule in spec["rules"] if present(rule)]
    chain = spec["chain"]
    if spec["backend"] == "nftables":
        nft("".join(nft_rule(chain, rule) + "\n" for rule in rules))
    else:
        for rule in rules:
            for args in iptables_rules(chain, rule):
                iptables(args)


def main() -> None:
    action, path = sys.argv[1], Path(sys.argv[2])
    spec: Specification = json.loads(path.read_text(encoding="utf-8"))
    if action == "apply":
        apply(spec)
    elif action == "flush":
        # Stopping after the backend is gone has nothing left to close.
        with contextlib.suppress(subprocess.CalledProcessError):
            flush(spec)
    else:
        raise SystemExit("usage: runtime-firewall.py apply|flush SPECIFICATION")


if __name__ == "__main__":
    main()
