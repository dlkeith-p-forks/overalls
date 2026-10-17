#!/usr/bin/env python3.13
"""Stall one real viewer while a second PTY delivers unique output."""

from terminal.command import execute

if __name__ == "__main__":
    raise SystemExit(execute("neighbor"))
