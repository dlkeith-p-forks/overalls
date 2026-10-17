#!/usr/bin/env python3.13
"""Terminal once-per-timeline credential rotation and old socket fence."""

from control.host_sessions import main_rotation

if __name__ == "__main__":
    raise SystemExit(main_rotation())
