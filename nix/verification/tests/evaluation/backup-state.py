"""Exhaustive transition edges, crash replay and runtime credential boundaries."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, sys.argv.pop(1))
from common import (  # ty: ignore[unresolved-import] # argv[1] is the Nix backups module directory
    BackupError,
    atomic_json,
    private_directory,
    read_json,
)
from journal import TRANSITIONS, Journal  # ty: ignore[unresolved-import] # argv[1] backups module
from postgres import (  # ty: ignore[unresolved-import] # argv[1] backups module
    connection,
    environment,
)
from schema import Phase  # ty: ignore[unresolved-import] # argv[1] backups module


class JournalTest(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "run.json"

    def test_all_transition_edges_and_durable_replay(self) -> None:
        phases: list[Phase] = list(TRANSITIONS)
        for source in phases:
            for target in phases:
                with self.subTest(source=source, target=target):
                    self.path.unlink(missing_ok=True)
                    journal = Journal.create(self.path, "overalls", None)
                    journal.save(
                        phase=source,
                        cleanup_confirmed=True,
                        manifest_id="a" * 64,
                        failures=["capture"]
                        if source == "failed" or (source == "cleaning" and target == "failed")
                        else [],
                    )
                    before = self.path.read_bytes()
                    if target in TRANSITIONS[source]:
                        journal.transition(target)
                        recovered = Journal.load(self.path)
                        self.assertEqual(recovered.value["phase"], target)
                        self.assertGreater(recovered.value["sequence"], 1)
                    else:
                        with self.assertRaises(BackupError):
                            journal.transition(target)
                        self.assertEqual(before, self.path.read_bytes())

    def test_failed_cleanup_prevents_publication_and_replacement(self) -> None:
        journal = Journal.create(self.path, "dungarees", None)
        journal.transition("capturing")
        journal.component({"kind": "guest", "snapshot_id": "a" * 64})
        journal.failed("interrupted")
        journal.transition("cleaning")
        for phase in ("publishing", "failed"):
            with self.assertRaises(BackupError):
                journal.transition(phase)
        with self.assertRaises(BackupError):
            Journal.create(self.path, "dungarees", None)
        recovered = Journal.load(self.path)
        self.assertEqual(len(recovered.value["components"]), 1)
        self.assertEqual(recovered.value["failures"], ["interrupted"])
        recovered.save(cleanup_confirmed=True)
        recovered.transition("failed")
        replacement = Journal.create(self.path, "dungarees", None)
        self.assertNotEqual(recovered.value["run_id"], replacement.value["run_id"])

    def test_completion_requires_publication_and_no_failures(self) -> None:
        journal = Journal.create(self.path, "overalls", None)
        journal.transition("capturing")
        journal.transition("cleaning")
        journal.save(cleanup_confirmed=True)
        journal.transition("publishing")
        with self.assertRaises(BackupError):
            journal.transition("completed")
        journal.save(manifest_id="b" * 64)
        journal.failed("upload")
        with self.assertRaises(BackupError):
            journal.transition("completed")

    def test_corrupt_or_public_state_is_rejected_without_replacement(self) -> None:
        Journal.create(self.path, "overalls", None)
        self.path.chmod(0o644)
        with self.assertRaises(BackupError):
            Journal.load(self.path)
        self.path.chmod(0o600)
        self.path.write_text('{"phase":"completed"}')
        with self.assertRaises(BackupError):
            Journal.create(self.path, "overalls", None)
        self.assertEqual(json.loads(self.path.read_text()), {"phase": "completed"})

    def test_private_atomic_publication_and_symlink_refusal(self) -> None:
        atomic_json(self.path, {"value": 1})
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(read_json(self.path), {"value": 1})
        link = self.path.with_name("link.json")
        link.symlink_to(self.path)
        with self.assertRaises(OSError):
            read_json(link)

    def test_private_directories_reject_symlink_ancestors(self) -> None:
        root = self.path.parent
        destination = private_directory(root / "a" / "b")
        self.assertEqual(destination.stat().st_mode & 0o777, 0o700)
        (root / "link").symlink_to(root / "a", target_is_directory=True)
        with self.assertRaises(BackupError):
            private_directory(root / "link" / "b")


class DatabaseIdentityTest(unittest.TestCase):
    def test_remote_identity_and_private_password_file(self) -> None:
        identity = connection("ecto://marshall:p%3Aa%5Css@db.example:5544/control")
        self.assertEqual(
            identity,
            {
                "host": "db.example",
                "port": 5544,
                "user": "marshall",
                "password": "p:a\\ss",
                "database": "control",
            },
        )
        with tempfile.TemporaryDirectory() as directory:
            password = Path(directory) / "pgpass"
            env = environment(identity, "/run/ca.pem", password)
            self.assertEqual(password.stat().st_mode & 0o777, 0o600)
            self.assertEqual(password.read_text(), "db.example:5544:control:marshall:p\\:a\\\\ss\n")
            self.assertEqual(env["PGSSLMODE"], "verify-full")
            self.assertEqual(env["PGHOST"], "db.example")
            self.assertNotIn("PGPASSWORD", env)
            self.assertNotIn(identity["password"], str(env))

    def test_no_local_fallback_or_connection_overrides(self) -> None:
        for url in (
            None,
            "",
            "postgres:///control",
            "postgres://db/control",
            "postgres://u:p@db/",
            "postgres://u:p@db:0/control",
            "postgres://u:p@db/control?sslmode=disable",
            "postgres://u:p@db/control#fragment",
            "postgres://u:p@db,other/control",
            "postgres://u:p%0A@db/control",
            "https://u:p@db/control",
        ):
            with self.subTest(url=url), self.assertRaises(BackupError) as raised:
                connection(url)
            self.assertEqual(str(raised.exception), "database")


if __name__ == "__main__":
    unittest.main()
