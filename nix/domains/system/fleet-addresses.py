"""Validate SOPS-delivered fleet addresses and apply the static uplink.

Values never enter the repository or the Nix store. The uplink is written as a
runtime systemd-networkd drop-in, and each applied drop-in is kept as a
root-only recovery copy so a later decryption failure cannot strand the host.
"""

import ipaddress
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import TypedDict


class Uplink(TypedDict):
    network: str
    addresses: list[str]
    prefix: str
    gateway: str
    hostRoutes: list[str]
    recoveryFile: str


class Specification(TypedDict):
    directory: str
    names: dict[str, str]
    uplink: Uplink | None


class Invalid(Exception):
    pass


def address(text: str) -> ipaddress.IPv4Address:
    try:
        parsed = ipaddress.IPv4Address(text)
    except ValueError:
        raise Invalid("not an IPv4 address") from None
    if (
        str(parsed) != text
        or parsed.is_unspecified
        or parsed.is_loopback
        or parsed.is_multicast
        or parsed.is_link_local
    ):
        raise Invalid("not a canonical explicit unicast IPv4 address")
    return parsed


def prefix(text: str) -> int:
    if not text.isdigit() or str(int(text)) != text or not 8 <= int(text) <= 32:
        raise Invalid("not an IPv4 prefix length")
    return int(text)


def read(spec: Specification, name: str) -> str:
    return (Path(spec["directory"]) / name).read_text(encoding="ascii").strip()


def validate(spec: Specification) -> None:
    for name, secret in spec["names"].items():
        value = read(spec, name)
        try:
            prefix(value) if secret.endswith("_PREFIX") else address(value)
        except Invalid as error:
            raise SystemExit(f"Fleet address {name} is invalid: {error}") from None


def render(spec: Specification, uplink: Uplink) -> str:
    """Return the networkd drop-in for the uplink, validating every value."""
    length = prefix(read(spec, uplink["prefix"]))
    gateway = address(read(spec, uplink["gateway"]))
    locals_ = [address(read(spec, name)) for name in uplink["addresses"]]
    network = ipaddress.IPv4Network(f"{locals_[0]}/{length}", strict=False)
    if gateway not in network or any(local not in network for local in locals_):
        raise Invalid("uplink addresses and gateway must share one on-link network")
    routes = [address(read(spec, name)) for name in uplink["hostRoutes"]]
    lines = ["[Network]", *(f"Address={local}/{length}" for local in locals_), ""]
    lines += ["[Route]", f"Destination={gateway}/32", "Scope=link", ""]
    lines += ["[Route]", f"Gateway={gateway}", "GatewayOnLink=yes", ""]
    for destination in [str(network), *(f"{route}/32" for route in routes)]:
        lines += [
            "[Route]",
            f"Destination={destination}",
            f"Gateway={gateway}",
            "GatewayOnLink=yes",
            "",
        ]
    return "\n".join(lines)


def write(path: Path, text: str, mode: int) -> None:
    path.parent.mkdir(mode=0o700 if mode == 0o600 else 0o755, parents=True, exist_ok=True)
    staged = path.with_name(path.name + ".tmp")
    staged.write_text(text, encoding="ascii")
    os.chmod(staged, mode)
    os.replace(staged, path)


def uplink(spec: Specification) -> None:
    configuration = spec["uplink"]
    if configuration is None:
        raise SystemExit("No uplink is declared")
    recovery = Path(configuration["recoveryFile"])
    try:
        text = render(spec, configuration)
    except (OSError, Invalid) as error:
        if not recovery.is_file():
            raise SystemExit(
                f"Uplink addresses unavailable and no recovery copy: {error}"
            ) from None
        print(json.dumps({"event": "fleet_uplink.recovery_copy_used"}), flush=True)
        text = recovery.read_text(encoding="ascii")
    else:
        write(recovery, text, 0o600)
    # networkd reads drop-ins as systemd-network; the drop-in holds no credential.
    target = Path("/run/systemd/network") / f"{configuration['network']}.network.d"
    write(target / "50-fleet-addresses.conf", text, 0o644)
    subprocess.run(["networkctl", "reload"], check=True)


def main() -> None:
    action, path = sys.argv[1], Path(sys.argv[2])
    spec: Specification = json.loads(path.read_text(encoding="utf-8"))
    if action == "validate":
        validate(spec)
    elif action == "uplink":
        uplink(spec)
    else:
        raise SystemExit("usage: fleet-addresses.py validate|uplink SPECIFICATION")


if __name__ == "__main__":
    main()
