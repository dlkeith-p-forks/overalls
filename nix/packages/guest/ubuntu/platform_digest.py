"""Print Lilly's guest-trust bundle digest for public root files; build-time only."""

import hashlib
import sys
from collections.abc import Sequence


def digest(roots: Sequence[bytes]) -> str:
    """@cc [owner:ghuntley,label:security;build] ubuntu-platform-digest-parity
    The digest MUST equal Lilly.VM.GuestTrust.digest/1 and overalls-trustd's
    check over the same exact root bytes: SHA-256 over the sorted
    concatenation of each root's SHA-256, as lowercase hex.
    """
    if not roots:
        raise ValueError("platform roots are required")
    fingerprints = sorted(hashlib.sha256(root).digest() for root in roots)
    return hashlib.sha256(b"".join(fingerprints)).hexdigest()


def main() -> None:
    roots: list[bytes] = []
    for path in sys.argv[1:]:
        with open(path, "rb") as handle:
            roots.append(handle.read())
    # The receiver compares the marker's exact bytes: no trailing newline.
    sys.stdout.write(digest(roots))


if __name__ == "__main__":
    main()
