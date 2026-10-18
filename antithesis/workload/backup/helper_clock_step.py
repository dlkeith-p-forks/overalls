#!/usr/bin/env python3.13
"""STUB (harness): step a preloaded coordinator's wall clock backward mid-capture.

The fixture copies this wrapper beside ``clock-step.json`` and names it as the
coordinator's Restic executable. When the coordinator starts its host-state
upload (after its journal recorded ``started_at``), the wrapper rewrites the
libfaketime spec file so every later coordinator wall-clock read is behind the
recorded start. Every invocation then runs the real pinned Restic unchanged;
Restic itself never loads libfaketime because the coordinator filters its
environment.
"""

import json
import subprocess
import sys
from pathlib import Path
from typing import TypedDict


class ClockStep(TypedDict):
    real: str
    spec: str
    offset: str


def load(path: Path) -> ClockStep:
    value: object = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError("invalid fixture clock step")
    real, spec, offset = value.get("real"), value.get("spec"), value.get("offset")
    if (
        not isinstance(real, str)
        or not isinstance(spec, str)
        or not isinstance(offset, str)
        or not offset.startswith("-")
        or not offset[1:].isdecimal()
    ):
        raise ValueError("invalid fixture clock step")
    return ClockStep(real=real, spec=spec, offset=offset)


def selected(arguments: list[str]) -> bool:
    return bool(arguments) and arguments[0] == "backup" and "host-state" in arguments


def main() -> int:
    step = load(Path(__file__).with_name("clock-step.json"))
    arguments = sys.argv[1:]
    if selected(arguments):
        Path(step["spec"]).write_text(step["offset"] + "\n", encoding="ascii")
    return subprocess.run([step["real"], *arguments], check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
