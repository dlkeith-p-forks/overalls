"""Validate an operator-supplied public hostname delivered as a systemd credential."""

import re
import sys


def hostname(data: bytes) -> str:
    """@cc [owner:ghuntley,label:security] marshall-runtime-public-host
    Runtime host input MUST be one canonical ASCII DNS name with an optional
    final newline, at most 253 bytes and 63 bytes per label. Empty labels, IPv6,
    shell syntax, control bytes and additional lines MUST fail without echoing
    the input. Runtime selection MUST NOT fall back to a static host on error.
    """
    if len(data) > 254:
        raise ValueError("invalid public host")
    value = data.removesuffix(b"\n")
    if not 1 <= len(value) <= 253 or any(
        not re.fullmatch(rb"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label)
        for label in value.split(b".")
    ):
        raise ValueError("invalid public host")
    return value.decode("ascii")


if __name__ == "__main__":
    try:
        with open(sys.argv[1], "rb") as stream:
            value = hostname(stream.read(255))
        print(value)
    except (OSError, ValueError, IndexError):
        sys.exit("Marshall public hostname unavailable or invalid")
