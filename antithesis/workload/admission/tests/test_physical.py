"""Physical sample freshness and identity are prerequisites for capacity proof."""

import json
import tempfile
import time
import unittest
from datetime import datetime
from pathlib import Path
from uuid import UUID

from admission.capacity import CapacityFrame
from admission.physical import read_sample
from core.outcome import State


class PhysicalSampleTests(unittest.TestCase):
    def test_current_inner_zfs_sample_matches_exact_pool(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "physical.json"
            sample: dict[str, object] = {
                "version": 1,
                "sampled_at_ns": time.time_ns(),
                "boot_id": "00000000-0000-4000-8000-000000000001",
                "zpool_guid": "123",
                "dataset_guid": "456",
                "dataset": "tank/lilly",
                "available_bytes": 5000,
                "used_bytes": 1000,
                "referenced_bytes": 900,
                "zpool_total_bytes": 10000,
                "zpool_free_bytes": 6000,
                "memory_limit_bytes": 8192,
                "memory_current_bytes": 4096,
                "cpu_quota_us": 200000,
                "cpu_period_us": 100000,
                "connected": True,
                "execution_ready": True,
            }
            path.write_text(json.dumps(sample), encoding="utf-8")
            result = read_sample(path)
            self.assertIs(result.state, State.OBSERVED)
            self.assertIsNotNone(result.value)
            frame = CapacityFrame(
                UUID("00000000-0000-4000-8000-000000000002"),
                UUID("00000000-0000-4000-8000-000000000003"),
                datetime.now(),
                1,
                None,
                None,
                None,
                1,
                1,
                4500,
                1,
                {},
                (),
                "123",
                "456",
                "tank/lilly",
            )
            if result.value is not None:
                self.assertTrue(result.value.matches(frame))

            sample["sampled_at_ns"] = time.time_ns() - 20_000_000_000
            path.write_text(json.dumps(sample), encoding="utf-8")
            self.assertIs(read_sample(path).state, State.UNAVAILABLE)


if __name__ == "__main__":
    unittest.main()
