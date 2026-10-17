#!/usr/bin/env python3.13
"""Use two Marshall sockets to fence an old host connection nonce."""

from control.host_sessions import main_successor

if __name__ == "__main__":
    raise SystemExit(main_successor())
