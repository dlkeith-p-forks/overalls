"""Verify existing journal shard cursors before the collector reads them."""

from __future__ import annotations

import json
import os
import sqlite3
import stat
import sys
from pathlib import Path

SHARDS = frozenset({"applications-a", "applications-b", "platform", "edge"})


def shard_names(value: object) -> list[str]:
    if not isinstance(value, dict):
        raise ValueError("invalid descriptor")
    rows: object = value.get("journalShards")
    if not isinstance(rows, list):
        raise ValueError("invalid shards")
    result: list[str] = []
    for row in rows:
        if not isinstance(row, str) or row not in SHARDS or row in result:
            raise ValueError("invalid shard")
        result.append(row)
    return result


def private_file(path: Path) -> bool:
    try:
        info = path.lstat()
    except FileNotFoundError:
        return False
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_mode & 0o077:
        raise ValueError("invalid checkpoint custody")
    return True


def check(state: Path, shards: list[str]) -> None:
    """@cc [owner:ghuntley,label:recovery] logging-shard-cursor-check
    The check MUST run with the collector stopped and MUST only read: every
    existing shard cursor must be a private, singly linked regular SQLite file
    that passes `PRAGMA quick_check`. A missing shard cursor is allowed and
    starts fresh. Unsafe or corrupt cursors MUST refuse startup and remain
    unchanged; no other checkpoint format is read or converted.
    """
    for shard in shards:
        target = state / f"journal-{shard}.db"
        if not private_file(target):
            continue
        with sqlite3.connect(f"{target.as_uri()}?mode=ro", uri=True) as checkpoint:
            if checkpoint.execute("PRAGMA quick_check").fetchone() != ("ok",):
                raise ValueError("invalid checkpoint")


def main() -> int:
    os.umask(0o077)
    try:
        raw: object = json.loads(Path(sys.argv[1]).read_text())
        state = (
            Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else Path("/var/lib/overalls-logging")
        )
        check(state, shard_names(raw))
    except (OSError, ValueError, sqlite3.Error):
        print('{"event":"logging.cursor_check_refused"}', file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
