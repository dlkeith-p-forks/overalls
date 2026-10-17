#!/usr/bin/env python3.13
"""Drive bounded retained Enrico attempt replay against native Git."""

from repository.campaign import run_exclusive
from repository.scenarios import run_replay

if __name__ == "__main__":
    raise SystemExit(run_exclusive(run_replay))
