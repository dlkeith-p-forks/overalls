"""Operator-only private PKI preparation; encrypt output with overalls-secrets."""

import argparse
import json
import sys
from pathlib import Path

from authority import (
    bootstrap,
    create_private,
    issue,
    private_bytes,
    public_bytes,
    request,
)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "directory",
        type=Path,
        help="Existing empty private directory outside the repository and Nix store",
    )
    args = parser.parse_args()
    directory = args.directory.absolute()
    if (
        directory != directory.resolve()
        or directory.is_relative_to("/nix/store")
        or list(directory.iterdir())
    ):
        raise ValueError("invalid destination")
    if any((parent / ".git").exists() for parent in [directory, *directory.parents]):
        raise ValueError("repository custody forbidden")
    key, root, issuer_key, issuer = bootstrap()
    server_key, csr = request()
    server = issue(csr, issuer_key, issuer)
    chain = public_bytes(server) + public_bytes(issuer)
    for name, value in {
        "root.key": private_bytes(key),
        "root.pem": public_bytes(root),
        "issuer.key": private_bytes(issuer_key),
        "issuer.pem": public_bytes(issuer),
        "server.key": private_bytes(server_key),
        "server.pem": public_bytes(server),
        "chain.pem": chain,
    }.items():
        create_private(directory / name, value)
    recovery = {
        "overalls-private-ca": {
            "production": {
                "AUDI_PRIVATE_ROOT_KEY": private_bytes(key).decode("ascii"),
                "AUDI_PRIVATE_ROOT_CERTIFICATE": public_bytes(root).decode("ascii"),
                "AUDI_PRIVATE_ISSUER_KEY": private_bytes(issuer_key).decode("ascii"),
                "AUDI_PRIVATE_ISSUER_CERTIFICATE": public_bytes(issuer).decode("ascii"),
            }
        }
    }
    runtime = {
        "overalls-audi-private": {
            "production": {
                "AUDI_PRIVATE_CERTIFICATE_CHAIN": chain.decode("ascii"),
                "AUDI_PRIVATE_CERTIFICATE_KEY": private_bytes(server_key).decode("ascii"),
            }
        }
    }
    create_private(directory / "recovery.json", json.dumps(recovery).encode())
    create_private(directory / "audi-private.json", json.dumps(runtime).encode())
    print(
        "Private CA and fleet wildcard prepared; encrypt recovery and runtime custody separately."
    )


if __name__ == "__main__":
    try:
        main()
    except Exception:
        print("Private CA preparation failed", file=sys.stderr)
        sys.exit(1)
