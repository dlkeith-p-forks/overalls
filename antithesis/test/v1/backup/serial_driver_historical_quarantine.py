#!/usr/bin/env python3.13
"""Restore a mixed-time backup graph only to an isolated private target."""

from backup.scenarios import run_historical_quarantine

if __name__ == "__main__":
    raise SystemExit(run_historical_quarantine())
