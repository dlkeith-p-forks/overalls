"""Allocate isolated service identities while assembling a pinned foreign rootfs."""

import os
import sys
from pathlib import Path
from typing import Final

SERVICE_NAMES: Final = ("sshd", "overalls-ssh")
FIELD_COUNTS: Final = {"passwd": 7, "group": 4, "shadow": 9, "gshadow": 4}


def records(path: Path, fields: int) -> list[list[str]]:
    """Reject malformed or duplicate local account records before mutation."""
    if not path.exists():
        return []
    rows = [line.split(":") for line in path.read_text().splitlines() if line]
    names: set[str] = set()
    for row in rows:
        if len(row) != fields or not row[0] or row[0] in names:
            raise ValueError("invalid local account database")
        names.add(row[0])
    return rows


def numeric_id(value: str) -> int:
    if not value.isascii() or not value.isdecimal() or not 0 <= int(value) < 2**32 - 1:
        raise ValueError("invalid local account identity")
    return int(value)


def install(root: Path) -> None:
    """@cc [owner:ghuntley,label:security;build] foreign-linux-service-identities
    sshd and overalls-ssh MUST have distinct unused nonroot system UIDs/GIDs,
    locked shadow passwords and noninteractive shells. Existing unrelated
    account records MUST survive unchanged; malformed databases and exhausted
    system identity space MUST fail before writing any account database.
    """
    etc = root / "etc"
    tables = {name: records(etc / name, count) for name, count in FIELD_COUNTS.items()}
    for row in tables["passwd"]:
        numeric_id(row[2])
        numeric_id(row[3])
    for row in tables["group"]:
        numeric_id(row[2])
    tables = {
        name: [row for row in rows if row[0] not in SERVICE_NAMES] for name, rows in tables.items()
    }
    used: set[int] = set()
    for row in tables["passwd"]:
        used.update((numeric_id(row[2]), numeric_id(row[3])))
    for row in tables["group"]:
        used.add(numeric_id(row[2]))
    available = [value for value in range(999, 99, -1) if value not in used]
    if len(available) < len(SERVICE_NAMES):
        raise ValueError("no unused system service identities")
    for name, identity in zip(SERVICE_NAMES, available, strict=False):
        uid = str(identity)
        tables["passwd"].append(
            [name, "x", uid, uid, "Overalls SSH service", "/var/empty", "/usr/sbin/nologin"]
        )
        tables["group"].append([name, "x", uid, ""])
        tables["shadow"].append([name, "!", "1", "0", "99999", "7", "", "", ""])
        tables["gshadow"].append([name, "!", "", ""])
    for name, rows in tables.items():
        temporary = etc / (name + ".overalls-new")
        temporary.write_text("".join(":".join(row) + "\n" for row in rows))
        temporary.chmod(0o600 if name in ("shadow", "gshadow") else 0o644)
        os.replace(temporary, etc / name)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: foreign_linux_accounts.py ROOT")
    install(Path(sys.argv[1]))
