"""Validate an operator-supplied default image identity delivered as a systemd credential."""

import re
import sys


def image_id(data: bytes) -> str:
    """@cc [owner:ghuntley,label:security] marshall-runtime-default-image
    Runtime default image input MUST be either empty (disabling the default) or
    one canonical sha256 content identity with an optional final newline. Any
    other input MUST fail without echoing it, and runtime selection MUST NOT
    fall back to a static identity on error.
    """
    if len(data) > 73:
        raise ValueError("invalid default image")
    value = data.removesuffix(b"\n")
    if value == b"":
        return ""
    if not re.fullmatch(rb"sha256:[0-9a-f]{64}", value):
        raise ValueError("invalid default image")
    return value.decode("ascii")


if __name__ == "__main__":
    try:
        with open(sys.argv[1], "rb") as stream:
            value = image_id(stream.read(74))
        print(value)
    except (OSError, ValueError, IndexError):
        sys.exit("Marshall default image unavailable or invalid")
