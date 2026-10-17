#!/usr/bin/env python3.13
"""Bounded trace archive, replay and quota pressure audit."""

from recorder.scenarios import main

if __name__ == "__main__":
    raise SystemExit(main("traces"))
