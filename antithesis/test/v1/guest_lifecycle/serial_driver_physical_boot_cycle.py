#!/usr/bin/env python3.13
"""Exercise a real guest provision, stop and fresh boot with separate witnesses."""

from guest_lifecycle.scenarios import run_physical_boot_cycle

if __name__ == "__main__":
    raise SystemExit(run_physical_boot_cycle())
