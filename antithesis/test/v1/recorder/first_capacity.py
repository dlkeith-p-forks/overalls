#!/usr/bin/env python3.13
"""Exact production-capacity BEAM-worker run before injected faults."""

from recorder.scenarios import main

if __name__ == "__main__":
    raise SystemExit(main("capacity"))
