"""Backup telemetry freshness and private-field exclusion."""

import json
import sys
import unittest

sys.path.insert(0, sys.argv.pop(1))
from backup_status import backup_status  # ty: ignore[unresolved-import] # argv[1] fleet-exporter


class Reader:
    def __init__(self) -> None:
        self.body: str | None = None

    def exists(self, path: str) -> bool:
        return self.body is not None

    def read(self, path: str) -> str:
        if self.body is None:
            raise FileNotFoundError(path)
        return self.body


class BackupStatusTest(unittest.TestCase):
    def test_disabled_missing_corrupt_and_stale(self) -> None:
        reader = Reader()
        self.assertEqual(backup_status(reader, False, 4000)["context"]["backup_state"], "disabled")
        self.assertEqual(backup_status(reader, True, 4000)["context"]["backup_state"], "never-run")
        reader.body = "broken"
        self.assertEqual(backup_status(reader, True, 4000)["context"]["backup_state"], "unknown")
        data: dict[str, object] = {
            "version": 1,
            "state": "healthy",
            "failure": "none",
            "last_success_at": 3990,
            "guests_completed": 0,
            "password": "must-not-leave-host",
        }
        reader.body = json.dumps(data)
        row = backup_status(reader, True, 4000)
        self.assertEqual(row["context"]["backup_state"], "healthy")
        self.assertEqual(row["gauges"]["guests_completed"], 0)
        self.assertNotIn("must-not-leave-host", json.dumps(row))
        self.assertEqual(backup_status(reader, True, 8000)["context"]["backup_state"], "stale")
        changes: list[dict[str, object]] = [
            {"failure": "password=secret"},
            {"guests_completed": True},
            {"last_success_at": 5000},
            {"state": ["healthy"]},
        ]
        for change in changes:
            reader.body = json.dumps({**data, **change})
            self.assertEqual(
                backup_status(reader, True, 4000)["context"]["backup_state"], "unknown"
            )

    def test_stalled_run_preserves_last_success(self) -> None:
        reader = Reader()
        reader.body = json.dumps(
            {
                "version": 1,
                "state": "running",
                "failure": "none",
                "updated_at": 3000,
                "last_success_at": 2900,
            }
        )
        row = backup_status(reader, True, 4000)
        self.assertEqual(row["context"]["backup_state"], "stale")
        self.assertEqual(row["gauges"]["last_success_at"], 2900)


if __name__ == "__main__":
    unittest.main()
