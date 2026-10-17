#!/usr/bin/env python3.13
"""Once per timeline, fence a welcomed socket after Lilly credential rotation."""

from control.scenarios import main_revalidation

if __name__ == "__main__":
    raise SystemExit(main_revalidation())
