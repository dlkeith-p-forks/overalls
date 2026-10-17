"""Typed isolated reader group whose leader exits before its descendants."""

import json
import os
import sys
import time
from pathlib import Path
from typing import Literal


def main() -> None:
    """@cc [owner:ghuntley,label:verification] backup-reader-fixture-group
    The fixture MUST publish actual descendant PIDs after every reader opens
    the source file. Readers MUST stay in the leader's process group; the leader
    MUST exit without reaping them to exercise cleanup after leader exit.
    """
    root = Path(sys.argv[1])
    count = int(sys.argv[2])
    raw = sys.argv[3]
    if raw not in {"timeout", "success", "nonzero", "overflow"} or count not in {1, 2, 3}:
        raise ValueError("invalid fixture menu")
    mode: Literal["timeout", "success", "nonzero", "overflow"] = raw
    identities: list[dict[str, int | str]] = []
    for index in range(count):
        identity = os.fork()
        if identity == 0:
            if mode in {"success", "nonzero"}:
                os.close(1)
            with (root / "source").open("rb") as source:
                assert source.read() == b"reader witness"
                (root / f"ready-{index}").touch()
                time.sleep(30)
            os._exit(0)
        fields = (Path("/proc") / str(identity) / "stat").read_text().rsplit(") ", 1)[1].split()
        identities.append({"pid": identity, "group": os.getpgrp(), "start": fields[19]})
    deadline = time.monotonic() + 5
    while len(list(root.glob("ready-*"))) != count:
        if time.monotonic() >= deadline:
            raise RuntimeError("reader readiness timed out")
        time.sleep(0.001)
    (root / "readers.json").write_text(json.dumps(identities))
    if mode == "overflow":
        os.write(1, b"x" * 4096)
    os._exit(1 if mode == "nonzero" else 0)


if __name__ == "__main__":
    main()
