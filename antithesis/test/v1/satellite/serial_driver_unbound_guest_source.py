#!/usr/bin/env python3.13
"""Send a forged guest-side request to private Audi from the labelled stand-in."""

from satellite.private_ingress import run_unbound_source

if __name__ == "__main__":
    raise SystemExit(run_unbound_source())
