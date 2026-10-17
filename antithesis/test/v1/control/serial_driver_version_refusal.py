#!/usr/bin/env python3.13
"""Drive the real shared Control client through a held-call 4001 refusal."""

from control.version_refusal import main_version_refusal

if __name__ == "__main__":
    raise SystemExit(main_version_refusal())
