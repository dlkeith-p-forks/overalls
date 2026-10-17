#!/usr/bin/env python3.13
"""Restart real Enrico and test native Git slot admission."""

from repository.campaign import run_exclusive
from repository.scenarios import run_native_admission_after_restart

if __name__ == "__main__":
    raise SystemExit(run_exclusive(run_native_admission_after_restart))
