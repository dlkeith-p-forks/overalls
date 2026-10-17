#!/usr/bin/env python3.13
"""Drive published Enrico head preservation through a failed Git refresh."""

from repository.campaign import run_exclusive
from repository.scenarios import run_published_head

if __name__ == "__main__":
    raise SystemExit(run_exclusive(run_published_head))
