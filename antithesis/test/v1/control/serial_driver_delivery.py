#!/usr/bin/env python3.13
"""Probe ambiguous Control delivery against real Marshall and durable SQL."""

from control.delivery import main_redelivery

if __name__ == "__main__":
    raise SystemExit(main_redelivery())
