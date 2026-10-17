#!/usr/bin/env python3.13
"""Interrupt a production backup restore between verified components."""

from backup.scenarios import run_interrupted_restore

if __name__ == "__main__":
    raise SystemExit(run_interrupted_restore())
