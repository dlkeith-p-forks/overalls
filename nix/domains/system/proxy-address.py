"""Validate a runtime listener address and publish it as a systemd EnvironmentFile.

The address comes from a root-owned runtime file (normally a decrypted SOPS
bundle output), so it never enters the repository or the Nix store. HAProxy
expands the published variable inside quoted bind arguments. Any malformed,
wildcard or missing value removes the previous publication and fails, so a
listener can never fall back to binding every address.
"""

import argparse
import ipaddress
import os
import re
from pathlib import Path


def address(path: Path) -> str:
    """Return the canonical explicit unicast IPv4 address held in path."""
    try:
        text = path.read_text(encoding="ascii").strip()
        parsed = ipaddress.IPv4Address(text)
    except (OSError, UnicodeDecodeError, ValueError):
        raise SystemExit("Runtime listener address is missing or not an IPv4 address") from None
    if (
        str(parsed) != text
        or parsed.is_unspecified
        or parsed.is_multicast
        or parsed.is_link_local
        or parsed == ipaddress.IPv4Address("255.255.255.255")
    ):
        raise SystemExit(
            "Runtime listener address must be a canonical explicit unicast IPv4 address"
        )
    return text


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--address-file", required=True, type=Path)
    parser.add_argument("--variable", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    variable: str = args.variable
    output: Path = args.output
    if not re.fullmatch(r"[A-Z][A-Z0-9_]{0,63}", variable):
        raise SystemExit("Invalid environment variable name")
    # Withdraw the previous publication first: a failed rotation must not
    # leave consumers starting with the retired address.
    output.unlink(missing_ok=True)
    value = address(args.address_file)
    staged = output.with_suffix(".tmp")
    staged.write_text(f"{variable}={value}\n", encoding="ascii")
    os.chmod(staged, 0o600)
    os.replace(staged, output)


if __name__ == "__main__":
    main()
