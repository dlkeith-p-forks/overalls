"""A closed, bounded TCP probe for the pinned OmniOS Python runtime."""

from __future__ import annotations

import argparse
import socket

DESTINATIONS = (
    "8.8.8.8",
    "8.8.4.5",
    "10.20.0.204",
    "172.16.20.1",
    "169.254.254.1",
    "10.20.0.1",
)


def connected(destination: str, source: str | None = None) -> bool:
    """@cc [owner:ghuntley,label:verification;security] native-tcp-probe-boundary
    The fixture MUST connect only to its closed synthetic destinations and
    port, with a two-second deadline. It MUST NOT send, read or log user bytes.
    An optional source MUST be only the fixture's unassigned address.
    """
    if destination not in DESTINATIONS or source not in (None, "10.20.0.205"):
        raise ValueError("unreviewed native TCP probe identity")
    try:
        with socket.create_connection(
            (destination, 18080),
            timeout=2,
            source_address=None if source is None else (source, 0),
        ):
            return True
    except OSError:
        return False


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", choices=DESTINATIONS)
    parser.add_argument("--source", choices=("10.20.0.205",))
    arguments = parser.parse_args()
    if not connected(arguments.destination, arguments.source):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
