#!/usr/bin/env python3.13
"""Require blocked PTY master input before testing explicit kill progress."""

from terminal.command import execute

if __name__ == "__main__":
    raise SystemExit(execute("kill"))
