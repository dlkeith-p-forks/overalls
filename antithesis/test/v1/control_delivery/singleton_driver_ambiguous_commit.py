#!/usr/bin/env python3.13
"""Once per timeline, probe an uncertain Control commit and unique SQL receipt."""

from control.delivery import main_ambiguous_commit

if __name__ == "__main__":
    raise SystemExit(main_ambiguous_commit())
