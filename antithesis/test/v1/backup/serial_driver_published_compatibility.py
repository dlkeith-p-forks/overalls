#!/usr/bin/env python3.13
"""Check coordinator-published points against its production manifest validator."""

from backup.scenarios import run_published_compatibility

if __name__ == "__main__":
    raise SystemExit(run_published_compatibility())
