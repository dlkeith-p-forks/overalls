#!/usr/bin/env python3.13
"""Exercise real Restic retention and independent restored component hashes."""

from backup.scenarios import run_retained_closure

if __name__ == "__main__":
    raise SystemExit(run_retained_closure())
