"""Set a fleet WireGuard peer's endpoint from a validated runtime address file."""

import argparse
import ipaddress
import subprocess
from pathlib import Path


def endpoint(path: Path) -> str:
    text = path.read_text(encoding="ascii").strip()
    try:
        parsed = ipaddress.IPv4Address(text)
    except ValueError:
        raise SystemExit("Runtime fleet endpoint is not an IPv4 address") from None
    if str(parsed) != text or parsed.is_unspecified or parsed.is_loopback or parsed.is_multicast:
        raise SystemExit("Runtime fleet endpoint must be a canonical explicit unicast address")
    return text


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--interface", required=True)
    parser.add_argument("--public-key", required=True)
    parser.add_argument("--address-file", required=True, type=Path)
    parser.add_argument("--port", required=True, type=int)
    args = parser.parse_args()
    address = endpoint(args.address_file)
    subprocess.run(
        [
            "wg",
            "set",
            args.interface,
            "peer",
            args.public_key,
            "endpoint",
            f"{address}:{args.port}",
        ],
        check=True,
    )


if __name__ == "__main__":
    main()
