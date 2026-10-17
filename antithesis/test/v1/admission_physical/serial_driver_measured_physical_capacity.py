#!/usr/bin/env python3.13
"""Create on a measured ZFS host and verify locked report plus physical sample."""

from admission.physical_scenario import run_measured_physical_capacity

if __name__ == "__main__":
    raise SystemExit(run_measured_physical_capacity())
