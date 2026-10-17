#!/usr/bin/env python3.13
"""Drive response reorder, timeout, stale reply and successor request."""

from control.pending import run_pending

if __name__ == "__main__":
    raise SystemExit(run_pending())
