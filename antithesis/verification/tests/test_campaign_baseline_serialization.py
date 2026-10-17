"""Regression tests for baseline reservation and green lineage ordering."""

from __future__ import annotations

import multiprocessing
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from campaign import initialize, modify, reserve, transition
from schema import EvidenceError, Json, field, obj


def green_receipt(run_id: str, identity: str) -> dict[str, Json]:
    return {
        "format": 1,
        "run_id": run_id,
        "identity_sha256": identity,
        "result": "green",
        "setup_complete": True,
        "execution_scope": "control-core",
    }


def baseline_worker(path: str, queue: multiprocessing.Queue[str]) -> None:
    try:
        attempt = modify(Path(path), "reserve", "identity", ["safety"], purpose="baseline")
        queue.put(str(attempt["attempt_id"]))
    except EvidenceError as exc:
        queue.put(f"refused:{exc}")


class BaselineSerializationTests(unittest.TestCase):
    def test_five_active_attempts_are_allowed_and_sixth_is_refused(self) -> None:
        ledger = initialize(None, "identity", ["safety", "safety-two"])
        for _ in range(5):
            attempt = reserve(ledger, "identity", "bootstrap", None)
            self.assertEqual(attempt["status"], "reserved")
        with self.assertRaisesRegex(EvidenceError, "five remote attempts already in flight"):
            reserve(ledger, "identity", "bootstrap", None)

    def test_active_baseline_blocks_reservation_until_terminal_transition(self) -> None:
        ledger = initialize(None, "identity", ["safety"])
        first = reserve(ledger, "identity", "baseline", None)
        with self.assertRaisesRegex(EvidenceError, "baseline already reserved or submitted"):
            reserve(ledger, "identity", "baseline", None)

        transition(ledger, str(first["attempt_id"]), "submitted", "run-1", duration_minutes=60)
        with self.assertRaisesRegex(EvidenceError, "baseline already reserved or submitted"):
            reserve(ledger, "identity", "baseline", None)

        transition(
            ledger,
            str(first["attempt_id"]),
            "completed",
            result="green",
            duration_minutes=60,
            receipt=green_receipt("run-1", "identity"),
        )
        selected = obj(
            field(obj(field(ledger, "configurations"), "configurations"), "control-core"),
            "configuration",
        )
        self.assertEqual(selected["green_baseline"], "identity")
        self.assertEqual(selected["baseline_run_id"], "run-1")

        second = reserve(ledger, "identity", "baseline", None)
        self.assertEqual(second["status"], "reserved")
        self.assertIsNone(selected["green_baseline"])
        self.assertIsNone(selected["baseline_run_id"])

    def test_abandoned_baseline_releases_only_its_config(self) -> None:
        ledger = initialize(None, "identity-a", ["safety"], "config-a")
        initialize(ledger, "identity-b", ["safety"], "config-b")
        first = reserve(ledger, "identity-a", "baseline", None, "config-a")
        other = reserve(ledger, "identity-b", "baseline", None, "config-b")
        self.assertEqual(other["status"], "reserved")
        with self.assertRaisesRegex(EvidenceError, "baseline already reserved or submitted"):
            reserve(ledger, "identity-a", "baseline", None, "config-a")
        transition(ledger, str(first["attempt_id"]), "abandoned")
        replacement = reserve(ledger, "identity-a", "baseline", None, "config-a")
        self.assertNotEqual(replacement["attempt_id"], first["attempt_id"])

    def test_concurrent_reservations_commit_only_one_baseline(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "ledger.json"
            modify(path, "init", "identity", ["safety"])
            queue: multiprocessing.Queue[str] = multiprocessing.Queue()
            children = [
                multiprocessing.Process(target=baseline_worker, args=(str(path), queue))
                for _ in range(2)
            ]
            for child in children:
                child.start()
            results = [queue.get(timeout=10) for _ in children]
            for child in children:
                child.join(timeout=10)
                self.assertEqual(child.exitcode, 0)
            self.assertEqual(sum(not result.startswith("refused:") for result in results), 1)
            self.assertEqual(
                sum("baseline already reserved or submitted" in result for result in results),
                1,
            )


if __name__ == "__main__":
    unittest.main()
