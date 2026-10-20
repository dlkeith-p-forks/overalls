"""Apply a validated runtime IPv4 listen address to a declared socket unit.

The address comes from a root-owned runtime file (normally a decrypted SOPS
bundle output), so it never enters the repository or the Nix store. The socket
declares no static ListenStream; this program writes a /run drop-in that resets
the list and adds exactly one explicit address, reloads systemd and restarts the
socket. A malformed or wildcard address withdraws the drop-in and fails, leaving
the socket without any listener rather than one on every address.
"""

import argparse
import ipaddress
import os
import re
import subprocess
from pathlib import Path

DROP_IN = "50-address.conf"


def address(path: Path) -> str:
    """Return the canonical explicit unicast IPv4 address held in path."""
    try:
        text = path.read_text(encoding="ascii").strip()
        parsed = ipaddress.IPv4Address(text)
    except (OSError, UnicodeDecodeError, ValueError):
        raise SystemExit("Runtime socket address is missing or not an IPv4 address") from None
    if (
        str(parsed) != text
        or parsed.is_unspecified
        or parsed.is_multicast
        or parsed.is_link_local
        or parsed == ipaddress.IPv4Address("255.255.255.255")
    ):
        raise SystemExit("Runtime socket address must be a canonical explicit unicast IPv4 address")
    return text


def systemctl(*arguments: str) -> None:
    subprocess.run(["systemctl", *arguments], check=True, stdin=subprocess.DEVNULL, timeout=90)


def triggered(unit: str) -> list[str]:
    """Return the service units the socket activates."""
    result = subprocess.run(
        ["systemctl", "show", "--property=Triggers", "--value", unit],
        check=True,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        timeout=30,
    )
    return [
        name for name in result.stdout.split() if re.fullmatch(r"[a-zA-Z0-9_.@-]+\.service", name)
    ]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--address-file", type=Path)
    parser.add_argument("--port", type=int)
    parser.add_argument("--remove", action="store_true")
    args = parser.parse_args()
    socket: str = args.socket
    if not re.fullmatch(r"[a-zA-Z0-9_.@-]{1,200}", socket):
        raise SystemExit("Invalid socket unit name")
    directory = Path("/run/systemd/system") / f"{socket}.socket.d"
    drop_in = directory / DROP_IN
    # Withdraw the previous address first: a failed rotation must not leave
    # the socket able to start on the retired address. Activated services
    # inherit the listening descriptor, so they stop with the socket.
    if drop_in.exists():
        systemctl("stop", "--no-block", f"{socket}.socket", *triggered(f"{socket}.socket"))
    drop_in.unlink(missing_ok=True)
    if args.remove:
        systemctl("daemon-reload")
        return
    address_file: Path | None = args.address_file
    port: int | None = args.port
    if address_file is None or port is None or not 1 <= port <= 65535:
        systemctl("daemon-reload")
        raise SystemExit("A runtime socket requires --address-file and a valid --port")
    try:
        value = address(address_file)
    except SystemExit:
        systemctl("daemon-reload")
        raise
    directory.mkdir(mode=0o755, parents=True, exist_ok=True)
    staged = directory / f".{DROP_IN}.tmp"
    staged.write_text(f"[Socket]\nListenStream=\nListenStream={value}:{port}\n", encoding="ascii")
    os.chmod(staged, 0o644)
    os.replace(staged, drop_in)
    systemctl("daemon-reload")
    systemctl("restart", "--no-block", f"{socket}.socket")


if __name__ == "__main__":
    main()
