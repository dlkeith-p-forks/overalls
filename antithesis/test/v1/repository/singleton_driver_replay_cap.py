#!/usr/bin/env python3.13
"""One bounded campaign across Enrico's 1,024 completed receipt cap."""

from repository.campaign import run_exclusive
from repository.scenarios import run_replay_cap

if __name__ == "__main__":
    raise SystemExit(run_exclusive(run_replay_cap))
