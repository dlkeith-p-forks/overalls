"""Exercise the real kernel flock witness and strict passive snapshot parser."""

import fcntl
import json
import os
import tempfile
import time
import unittest
from pathlib import Path

from core.outcome import State
from repository.native import occupied_slots, service_generation
from repository.observer import read_snapshot


class NativeWitnessTest(unittest.TestCase):
    def test_release_generation_distinguishes_restart_from_retained_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.assertEqual(service_generation(root).state, State.UNAVAILABLE)
            marker = root / "launch-generation"
            marker.write_text("1\n", encoding="ascii")
            self.assertEqual(service_generation(root).value, 1)
            marker.write_text("02\n", encoding="ascii")
            self.assertEqual(service_generation(root).state, State.UNAVAILABLE)

    def test_existing_private_slot_inodes_and_live_flock(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for index in range(8):
                path = root / f".enrico-git-slot-{index}.lock"
                descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_RDWR, 0o600)
                os.close(descriptor)
            before = occupied_slots(root)
            self.assertEqual(before.state, State.OBSERVED)
            self.assertEqual(before.value, frozenset())
            descriptor = os.open(root / ".enrico-git-slot-7.lock", os.O_RDWR)
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX)
                during = occupied_slots(root)
                self.assertEqual(during.value, frozenset({7}))
            finally:
                os.close(descriptor)
            (root / ".enrico-git-slot-7.lock").unlink()
            self.assertEqual(occupied_slots(root).state, State.UNAVAILABLE)

    def test_snapshot_requires_complete_current_generation_and_unique_inodes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "snapshot.json"
            snapshot: dict[str, object] = {
                "version": 1,
                "generation": 3,
                "observed_at_unix_ms": time.time_ns() // 1_000_000,
                "complete": True,
                "slots": [
                    {"slot": index, "device": 1, "inode": index + 10, "holder_pids": [100 + index]}
                    for index in range(8)
                ],
                "repositories": [],
            }
            path.write_text(json.dumps(snapshot), encoding="utf-8")
            self.assertEqual(read_snapshot(path, 3).state, State.OBSERVED)
            self.assertEqual(read_snapshot(path, 2).state, State.UNAVAILABLE)
            snapshot["complete"] = False
            path.write_text(json.dumps(snapshot), encoding="utf-8")
            self.assertEqual(read_snapshot(path, 3).state, State.UNAVAILABLE)
