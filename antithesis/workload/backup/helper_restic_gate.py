#!/usr/bin/env python3.13
"""Fixed Restic gate for a disposable fixture's backup or restore operation."""

import json
import os
import subprocess
import sys
import time
from pathlib import Path


def main() -> int:
    value: object = json.loads(Path(__file__).with_name("gate.json").read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError("invalid fixture gate")
    verb = value.get("verb")
    target = value.get("target")
    marker = value.get("marker")
    real = value.get("real")
    after = value.get("after")
    if (
        verb not in ("restore", "backup")
        or not isinstance(target, str)
        or not isinstance(marker, str)
        or not isinstance(real, str)
        or not isinstance(after, bool)
    ):
        raise ValueError("invalid fixture gate")
    arguments = sys.argv[1:]
    selected = arguments and arguments[0] == verb
    if verb == "backup":
        selected = selected and "host-manifest" in arguments
    else:
        selected = selected and target in arguments
    if not selected:
        return subprocess.run([real, *arguments], check=False).returncode
    result = subprocess.run([real, *arguments], check=False).returncode if after else 0
    Path(marker).write_text(str(os.getpid()), encoding="ascii")
    time.sleep(3600)
    return result


if __name__ == "__main__":
    raise SystemExit(main())
