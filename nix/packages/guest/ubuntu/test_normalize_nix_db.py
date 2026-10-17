"""Exercise deterministic guest Nix registration without building an image."""

import hashlib
import sqlite3
import tempfile
import unittest
from pathlib import Path

from normalize_nix_db import normalize


def fixture(database: Path, timestamp: int) -> None:
    with sqlite3.connect(database) as connection:
        connection.execute(
            "CREATE TABLE ValidPaths (id INTEGER PRIMARY KEY, path TEXT NOT NULL, registrationTime INTEGER NOT NULL)"
        )
        connection.execute("CREATE TABLE Refs (referrer INTEGER, reference INTEGER)")
        connection.executemany(
            "INSERT INTO ValidPaths VALUES (?, ?, ?)",
            [(1, "/nix/store/one", timestamp), (2, "/nix/store/two", timestamp)],
        )
        connection.execute("INSERT INTO Refs VALUES (1, 2)")
        connection.commit()
        connection.execute("PRAGMA journal_mode=WAL")


class NormalizeGuestNixDatabaseTest(unittest.TestCase):
    def test_different_registration_times_produce_identical_valid_databases(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = root / "first.sqlite"
            second = root / "second.sqlite"
            fixture(first, 1_790_679_819)
            fixture(second, 1_790_679_828)
            # The real guest builds retained different shared-memory sidecars
            # even though each WAL contained zero committed bytes.
            Path(str(first) + "-shm").write_bytes(b"a" * 32_768)
            Path(str(second) + "-shm").write_bytes(b"b" * 32_768)
            Path(str(first) + "-wal").touch()
            Path(str(second) + "-wal").touch()
            self.assertNotEqual(
                hashlib.sha256(first.read_bytes()).digest(),
                hashlib.sha256(second.read_bytes()).digest(),
            )

            normalize(first)
            normalize(second)
            self.assertEqual(first.read_bytes(), second.read_bytes())
            for database in (first, second):
                with sqlite3.connect(database) as connection:
                    self.assertEqual(
                        connection.execute(
                            "SELECT path, registrationTime FROM ValidPaths ORDER BY id"
                        ).fetchall(),
                        [("/nix/store/one", 1), ("/nix/store/two", 1)],
                    )
                    self.assertEqual(connection.execute("SELECT * FROM Refs").fetchall(), [(1, 2)])
                    self.assertEqual(connection.execute("PRAGMA quick_check").fetchone(), ("ok",))
                self.assertFalse(Path(str(database) + "-wal").exists())
                self.assertFalse(Path(str(database) + "-shm").exists())

    def test_empty_registration_refuses(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            database = Path(directory) / "empty.sqlite"
            with sqlite3.connect(database) as connection:
                connection.execute(
                    "CREATE TABLE ValidPaths (id INTEGER PRIMARY KEY, registrationTime INTEGER)"
                )
            with self.assertRaisesRegex(ValueError, "no paths"):
                normalize(database)

    def test_symlinked_registration_refuses(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            database = root / "real.sqlite"
            fixture(database, 5)
            linked = root / "linked.sqlite"
            linked.symlink_to(database)
            with self.assertRaisesRegex(ValueError, "unsafe"):
                normalize(linked)


if __name__ == "__main__":
    unittest.main()
