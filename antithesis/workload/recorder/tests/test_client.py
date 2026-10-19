"""Verify VM file transport, independent sample gating and strict witness parsing."""

import json
import sqlite3
import tempfile
import threading
import time
import unittest
from pathlib import Path

from recorder.client import (
    Client,
    Config,
    read_filesystem,
    read_identity,
    read_spool_identity,
    read_status,
)


class RecorderClientTest(unittest.TestCase):
    def test_producer_result_requires_later_observation_and_records_ack(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = Config(
                root / "requests", root / "results", root / "observation", root / "ledger.sqlite"
            )
            for path in (config.requests, config.results, config.observation):
                path.mkdir()
            (config.observation / "status.json").write_text('{"sample_ns":1}')
            client = Client(config)
            captured: list[dict[str, object]] = []

            def bridge_fixture() -> None:
                deadline = time.monotonic() + 2
                requests: list[Path] = []
                while time.monotonic() < deadline and not requests:
                    requests = list(config.requests.glob("[0-9a-f]" * 32 + ".json"))
                    time.sleep(0.01)
                if not requests:
                    return
                request = requests[0]
                captured.append(json.loads(request.read_text()))
                (config.results / request.name).write_text('{"status":"ok","admitted":[7]}')
                for sample in range(2, 30):
                    (config.observation / "status.json").write_text(
                        json.dumps({"sample_ns": sample})
                    )
                    time.sleep(0.02)

            worker = threading.Thread(target=bridge_fixture)
            worker.start()
            reply = client.call({"op": "admit", "count": 1})
            worker.join(timeout=2)
            self.assertIsNotNone(reply)
            self.assertEqual(reply.admitted if reply else (), (7,))
            self.assertEqual(captured, [{"op": "producer", "command": {"op": "admit", "count": 1}}])
            self.assertEqual(client.counts("admit"), (1, 1))

    def test_identity_and_filesystem_are_validated(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            observation = root / "observation"
            observation.mkdir()
            config = Config(
                root / "requests", root / "results", observation, root / "ledger.sqlite"
            )
            (observation / "identity.json").write_text(
                json.dumps(
                    {
                        "pid": 42,
                        "uid": 100,
                        "start_ticks": 500,
                        "cgroup": "0::/fixture.slice/recorder-peer.service",
                    }
                )
            )
            (observation / "filesystem.json").write_text(
                json.dumps(
                    {
                        "archive_device": 2,
                        "root_device": 1,
                        "free_bytes": 4096,
                        "total_bytes": 67108864,
                    }
                )
            )
            identity = read_identity(config)
            filesystem = read_filesystem(config)
            self.assertEqual(identity.pid if identity else None, 42)
            self.assertEqual(filesystem.archive_device if filesystem else None, 2)
            (observation / "spool_identity.json").write_text(
                json.dumps(
                    {
                        "pid": 43,
                        "uid": 101,
                        "start_ticks": 501,
                        "cgroup": "0::/system.slice/overalls-trace-recorder.service",
                    }
                )
            )
            spool_identity = read_spool_identity(config)
            self.assertEqual(spool_identity.pid if spool_identity else None, 43)
            (observation / "status.json").write_text(
                json.dumps(
                    {
                        "sample_ns": time.time_ns(),
                        "producer": True,
                        "recorder": True,
                        "spool": True,
                        "archive": True,
                    }
                )
            )
            status = read_status(config)
            self.assertTrue(status.archive if status else False)
            (observation / "status.json").write_text(
                json.dumps(
                    {
                        "sample_ns": time.time_ns() - 11_000_000_000,
                        "producer": True,
                        "recorder": True,
                        "spool": True,
                        "archive": True,
                    }
                )
            )
            self.assertIsNone(read_status(config))
            (observation / "identity.json").write_text(
                '{"pid":true,"uid":100,"start_ticks":500,"cgroup":"x"}'
            )
            self.assertIsNone(read_identity(config))
            (observation / "filesystem.json").write_text(
                '{"archive_device":2,"root_device":1,"free_bytes":-1,"total_bytes":64}'
            )
            self.assertIsNone(read_filesystem(config))

    def test_invalid_result_does_not_earn_acknowledgment(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = Config(
                root / "requests", root / "results", root / "observation", root / "ledger.sqlite"
            )
            for path in (config.requests, config.results, config.observation):
                path.mkdir()
            (config.observation / "status.json").write_text('{"sample_ns":1}')
            client = Client(config)

            def bridge_fixture() -> None:
                deadline = time.monotonic() + 2
                requests: list[Path] = []
                while time.monotonic() < deadline and not requests:
                    requests = list(config.requests.glob("[0-9a-f]" * 32 + ".json"))
                    time.sleep(0.01)
                if not requests:
                    return
                (config.results / requests[0].name).write_text('{"status":"bogus"}')
                for sample in range(2, 30):
                    (config.observation / "status.json").write_text(
                        json.dumps({"sample_ns": sample})
                    )
                    time.sleep(0.02)

            worker = threading.Thread(target=bridge_fixture)
            worker.start()
            with self.assertRaises(ValueError):
                client.call({"op": "hello"})
            worker.join(timeout=2)
            self.assertEqual(client.counts("hello"), (1, 0))

    def test_ledger_schema_separates_attempts_from_archive_witnesses(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = Config(root, root, root, root / "ledger.sqlite")
            Client(config)
            with sqlite3.connect(config.ledger) as db:
                names = {
                    row[0]
                    for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")
                }
            self.assertEqual(names, {"attempts", "archive_witness", "sequence_blocks"})


if __name__ == "__main__":
    unittest.main()
