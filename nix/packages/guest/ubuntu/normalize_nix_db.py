"""Canonicalize an offline guest image's Nix registration database (NixOS and Ubuntu)."""

import argparse
import sqlite3
from contextlib import closing
from pathlib import Path


def normalize(database: Path) -> None:
    """@cc [owner:ghuntley,label:build;security] ubuntu-canonical-nix-registration
    The guest Nix DB MUST retain every registered path/reference while removing
    build-time registration timestamps and ephemeral SQLite WAL/SHM bytes.
    Refuse a missing, empty or invalid DB; never copy a different host's image
    or rewrite package content to hide a digest mismatch.
    """
    if not database.is_file() or database.is_symlink():
        raise ValueError("guest Nix registration DB is missing or unsafe")

    with closing(sqlite3.connect(database)) as connection:
        row = connection.execute("SELECT count(*) FROM ValidPaths").fetchone()
        if row is None or not isinstance(row[0], int) or row[0] == 0:
            raise ValueError("guest Nix registration DB has no paths")
        count = row[0]
        # Switching away from WAL checkpoints committed frames. The chrooted
        # nix-store --load-db has exited before this single-writer build step.
        mode = connection.execute("PRAGMA journal_mode=DELETE").fetchone()
        if mode != ("delete",):
            raise ValueError("guest Nix registration DB cannot be checkpointed")
        connection.execute("UPDATE ValidPaths SET registrationTime = 1")
        connection.commit()
        connection.execute("VACUUM")
        verified = connection.execute(
            "SELECT count(*) FROM ValidPaths WHERE registrationTime = 1"
        ).fetchone()
        if verified != (count,) or connection.execute("PRAGMA quick_check").fetchone() != ("ok",):
            raise ValueError("guest Nix registration DB failed normalization")

    for suffix in ("-wal", "-shm"):
        sidecar = Path(str(database) + suffix)
        if sidecar.exists():
            if not sidecar.is_file() or sidecar.is_symlink():
                raise ValueError("guest Nix DB sidecar is unsafe")
            if suffix == "-wal" and sidecar.stat().st_size != 0:
                raise ValueError("guest Nix DB has uncheckpointed WAL content")
            sidecar.unlink()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("database", type=Path)
    args = parser.parse_args()
    normalize(args.database)


if __name__ == "__main__":
    main()
