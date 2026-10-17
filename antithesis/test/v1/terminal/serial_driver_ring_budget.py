#!/usr/bin/env python3.13
"""Compare actual guest VecDeque backing to live scrollback reservation."""

from terminal.command import execute

if __name__ == "__main__":
    raise SystemExit(execute("ring"))
