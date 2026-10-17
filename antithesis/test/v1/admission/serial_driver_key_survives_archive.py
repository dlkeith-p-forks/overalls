#!/usr/bin/env python3.13
"""Replay one Compute key through real delete and observed archive."""

from admission.scenarios import run_key_survives_archive

if __name__ == "__main__":
    raise SystemExit(run_key_survives_archive())
