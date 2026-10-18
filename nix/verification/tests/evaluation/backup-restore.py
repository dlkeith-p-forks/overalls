"""Restore ordering and retry refusals with simulated root custody and subprocesses.

Real files, locking, durable publication and pgpass handling execute here. This
does not establish PostgreSQL, systemd or multi-host recovery execution.
"""

from __future__ import annotations

import hashlib
import json
import os
import stat
import sys
import tempfile
import unittest
from collections.abc import Mapping, Sequence
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(sys.argv[1]).resolve()))
import restore  # ty: ignore[unresolved-import] # argv[1] Nix backups module
from common import BackupError  # ty: ignore[unresolved-import] # argv[1] Nix backups module
from schema import (  # ty: ignore[unresolved-import] # argv[1] Nix backups module
    Config,
    Failure,
)

sys.argv.pop(1)
EPOCH = "12345678-1234-4234-8234-123456789abc"
OLD_EPOCH = "12345678-1234-4234-8234-123456789abd"
LSTAT = Path.lstat


def root_custody(path: Path) -> os.stat_result:
    """Model trusted root ancestors; retain real file kind and write permissions."""
    observed = LSTAT(path)
    values = list(observed)
    values[4] = 0
    if stat.S_ISDIR(observed.st_mode):
        values[0] = observed.st_mode & ~0o022
    return os.stat_result(values)


class Restore(unittest.TestCase):
    def exercise(self, *, fail: bool = False, previous: str | None = None) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            root.chmod(0o700)
            state = root / "state"
            state.mkdir(mode=0o700)
            archive = root / "database.dump"
            archive.write_bytes(b"synthetic-postgres-custom-capture")
            archive.chmod(0o600)
            archive.with_name("database.json").write_text(
                json.dumps(
                    {
                        "format": "postgres-custom",
                        "sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
                    }
                )
            )
            marker = root / "recovery" / "github-restore-epoch"
            if previous is not None:
                marker.parent.mkdir(mode=0o755)
                marker.write_text(previous + "\n")
                marker.chmod(0o644)
            pending = marker.with_name(marker.name + ".pending")
            config = Config(
                hostname="test",
                repository="test",
                region="test",
                password_file="test",
                cache_directory=str(root / "cache"),
                state_directory=str(state),
                revision=None,
                restic="test",
                zfs="test",
                findmnt="test",
                mount="test",
                umount="test",
                command_timeout=30,
                upload_limit_kib=0,
                keep_last=1,
                initialize=False,
                paths=[],
                materialize=[],
                images=[],
                protected_datasets=[],
                excludes=[],
                lilly=None,
                postgres={
                    "ca_file": "synthetic-ca.pem",
                    "pg_dump": "test",
                    "pg_restore": "restore-test",
                    "psql": "test",
                    "timeout": 30,
                },
            )
            descriptor = root / "config.json"
            descriptor.write_text(json.dumps(config))
            calls: list[str] = []

            def execute(
                arguments: Sequence[str],
                *,
                stage: Failure,
                timeout: float,
                environment: Mapping[str, str] | None = None,
            ) -> bytes:
                self.assertEqual(stage, "database")
                self.assertGreater(timeout, 0)
                self.assertEqual(marker.read_text(), EPOCH + "\n")
                self.assertEqual(pending.read_text(), EPOCH + "\n")
                calls.append(arguments[0])
                if arguments[0] == "restore-test":
                    self.assertEqual(calls, ["systemctl-test", "restore-test"])
                    self.assertIn("--exit-on-error", arguments)
                    self.assertNotIn("synthetic-password", " ".join(arguments))
                    self.assertIsNotNone(environment)
                    assert environment is not None
                    self.assertEqual(environment["PGSSLMODE"], "verify-full")
                    self.assertEqual(Path(environment["PGPASSFILE"]).stat().st_mode & 0o777, 0o600)
                    if fail:
                        raise BackupError("database")
                return b""

            argv = [
                "restore",
                str(descriptor),
                "--archive",
                str(archive),
                "--epoch",
                EPOCH,
                "--epoch-file",
                str(marker),
                "--systemctl",
                "systemctl-test",
                "--instance",
                "marshall-test.service",
            ]
            with (
                patch.object(sys, "argv", argv),
                patch.object(restore.os, "geteuid", return_value=0),
                patch.object(Path, "lstat", root_custody),
                patch.object(restore, "run", execute),
                patch.dict(
                    os.environ,
                    {"DATABASE_URL": "postgres://test:synthetic-password@database.test/test"},
                ),
            ):
                result = restore.main()
            if previous == EPOCH:
                self.assertEqual(result, 1)
                self.assertEqual(calls, [])
                self.assertFalse(pending.exists())
            else:
                self.assertEqual(result, int(fail))
                self.assertEqual(calls, ["systemctl-test", "restore-test"])
                self.assertEqual(marker.read_text(), EPOCH + "\n")
                self.assertEqual(pending.exists(), fail)
                self.assertFalse(list(state.glob("restore-auth-*")))

    def test_success_publishes_fresh_epoch_before_stopping_and_restoring(self) -> None:
        self.exercise(previous=OLD_EPOCH)

    def test_failed_restore_keeps_pending_fence_and_cleans_pgpass(self) -> None:
        self.exercise(fail=True)

    def test_reused_epoch_cannot_restore_or_publish_pending(self) -> None:
        self.exercise(previous=EPOCH)


if __name__ == "__main__":
    unittest.main()
