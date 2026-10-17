"""Delegate native ZFS unchanged, with isolated command audit and inspection outage."""

import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Literal


def pause(phase: Literal["before", "after"], args: list[str]) -> bool:
    """@cc [owner:ghuntley,label:verification;recovery] native-effect-barrier-publication
    The barrier MUST appear atomically only for the selected native effect phase
    and exact command. A timed-out before-effect barrier MUST never submit work.
    """
    if not Path("/run/cleanup-pause-" + phase).exists():
        return False
    temporary = Path("/run/cleanup-effect-barrier.pending")
    temporary.write_text(json.dumps({"phase": phase, "args": args}))
    temporary.replace("/run/cleanup-effect-barrier.json")
    # Never submit a delayed effect after the barrier's bounded lifetime.
    time.sleep(30)
    return True


def main() -> int:
    """@cc [owner:ghuntley,label:verification;recovery] native-cleanup-command-delegation
    Every successful command MUST run the actual pinned ZFS executable. The
    outage MUST fail inspection without supplying fabricated successful output.
    Audit MUST record actual destruction before post-destroy inspection fails.
    """
    args = sys.argv[1:]
    with Path("/run/cleanup-zfs-audit.jsonl").open("a") as stream:
        stream.write(json.dumps(args) + "\n")
    if args and args[0] == "list" and Path("/run/cleanup-inspection-down").exists():
        return 1
    if args and args[0] == "destroy" and pause("before", args):
        return 1
    result = subprocess.run([os.environ["NATIVE_ZFS"], *args], check=False)
    if result.returncode == 0 and args and args[0] == "destroy":
        with Path("/run/cleanup-zfs-commits.jsonl").open("a") as stream:
            stream.write(json.dumps(args) + "\n")
        if pause("after", args):
            return 1
    if (
        result.returncode == 0
        and args
        and args[0] == "destroy"
        and Path("/run/cleanup-fail-after-destroy").exists()
    ):
        Path("/run/cleanup-inspection-down").touch()
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
