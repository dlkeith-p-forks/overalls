"""Validate exact restart receipt matching and generation advancement."""

import json
import tempfile
import threading
import time
import unittest
from pathlib import Path
from uuid import uuid4

from repository.restart import EnricoRestarter


class RestartTest(unittest.TestCase):
    def test_exact_restart_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "requests").mkdir()
            (root / "results").mkdir()
            request_id = uuid4()

            def respond() -> None:
                request = root / "requests" / f"{request_id}.json"
                while not request.exists():
                    time.sleep(0.01)
                body = json.loads(request.read_text(encoding="utf-8"))
                self.assertEqual(
                    body,
                    {"version": 1, "operation": "restart_enrico", "request_id": str(request_id)},
                )
                result = root / "results" / f"{request_id}.json"
                result.write_text(
                    json.dumps(
                        {
                            "version": 1,
                            "request_id": str(request_id),
                            "status": "restarted",
                            "previous_pid": 101,
                            "current_pid": 102,
                            "previous_generation": 1,
                            "generation": 2,
                        }
                    ),
                    encoding="utf-8",
                )
                result.chmod(0o600)

            worker = threading.Thread(target=respond)
            worker.start()
            try:
                receipt = EnricoRestarter(root).restart(request_id)
                self.assertIsNotNone(receipt)
                self.assertEqual(receipt.generation if receipt else None, 2)
            finally:
                worker.join(timeout=2)
