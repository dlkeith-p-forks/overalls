"""Disposable fleet barrier around the real systemd unit submission executable."""

import os
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Literal

Phase = Literal["before", "after"]
ROOT = Path("/run/fleet-submission-barrier")


def armed_phase(arguments: list[str]) -> Phase | None:
    """Validate the public fixture selector before matching an exact unit name."""
    try:
        selector = (ROOT / "armed").read_text().splitlines()
    except FileNotFoundError:
        return None
    if len(selector) != 2 or selector[1] not in ("before", "after"):
        raise ValueError("invalid submission barrier selector")
    placement = str(uuid.UUID(selector[0]))
    if placement != selector[0]:
        raise ValueError("noncanonical submission barrier placement")
    if arguments.count("--unit") != 1:
        return None
    index = arguments.index("--unit")
    if index + 1 >= len(arguments) or arguments[index + 1] != f"lilly-vm-{placement}.service":
        return None
    return "before" if selector[1] == "before" else "after"


def checkpoint(phase: Phase) -> None:
    """@cc [owner:ghuntley,label:verification;recovery] submission-barrier-exact-boundary
    The marker MUST identify whether native submission has returned successfully.
    A repeated submission at the armed boundary MUST fail visibly rather than
    silently replace the original witness. No command arguments may be recorded.
    """
    # Publish numeric native identity before making the checkpoint observable.
    # The external command owner enforces its deadline even while BEAM is paused.
    start = int(Path("/proc/self/stat").read_text().rsplit(") ", 1)[1].split()[19])
    with (ROOT / "worker").open("x") as worker:
        worker.write(f"{os.getpid()}:{start}\n")
        worker.flush()
        os.fsync(worker.fileno())
    temporary = ROOT / "preparing"
    with temporary.open("x") as marker:
        marker.write(phase + "\n")
        marker.flush()
        os.fsync(marker.fileno())
    os.link(temporary, ROOT / "reached")
    temporary.unlink()
    deadline = time.monotonic() + 60
    while not (ROOT / "release").exists():
        if time.monotonic() >= deadline:
            raise TimeoutError("submission barrier release deadline")
        time.sleep(0.01)


def main(arguments: list[str]) -> int:
    """@cc [owner:ghuntley,label:verification;recovery] submission-barrier-native-delegation
    Unarmed calls MUST exec the pinned real executable with unchanged arguments.
    Before barriers MUST precede submission; after barriers MUST require a zero
    native exit. The fixture MUST NOT synthesize launch results or diagnostics.
    """
    if not arguments or not arguments[0].startswith("/nix/store/"):
        raise ValueError("missing pinned submission executable")
    executable, *native_arguments = arguments
    phase = armed_phase(native_arguments)
    if phase is None:
        os.execv(executable, [executable, *native_arguments])
    if phase == "before":
        checkpoint(phase)
    result = subprocess.run([executable, *native_arguments], check=False)
    if result.returncode == 0 and phase == "after":
        checkpoint(phase)
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
