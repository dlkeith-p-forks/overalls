"""Resource freshness, loss and cardinality checks; no native safety claims."""

import sys
import unittest

sys.path.insert(0, sys.argv.pop(1))
from exporter import Snapshot  # ty: ignore[unresolved-import] # argv[1] exporter directory
from runtime import Sample  # ty: ignore[unresolved-import] # argv[1] collector directory


def sample(now: float) -> Sample:
    return Sample(
        sample_id="private-request-id",
        version=1,
        machine_id="private-machine-id",
        boot_id="private-boot-id",
        collector_id="private-collector-id",
        sequence=1,
        sampled_at=now,
        monotonic_seconds=now,
        collection_seconds=0.1,
        roles=["lilly"],
        missing_sources=0,
        failures=[],
        records=[
            {
                "kind": "vm",
                "id": "private-placement-id",
                "context": {
                    "placement_id": "private-placement-id",
                    "invocation_id": "private-invocation-id",
                    "deployment_revision": "private-revision",
                },
                "gauges": {"memory_bytes": 0},
                "counters": {},
                "rates": {},
            }
        ],
    )


class ExporterTest(unittest.TestCase):
    def test_collection_loss_and_staleness_are_unknown_not_zero(self) -> None:
        state = Snapshot()
        self.assertEqual(
            state.render(100),
            b"overalls_fleet_collection_valid 0\noveralls_fleet_collection_failures_total 0\n",
        )
        state.update(sample(100), False)
        fresh = state.render(100).decode()
        self.assertIn(
            'overalls_fleet_gauge{kind="vm",entity="all",measure="memory_bytes"} 0', fresh
        )
        self.assertNotIn("private-", fresh)
        self.assertNotIn("overalls_fleet_gauge", state.render(116).decode())
        state.failed()
        failed = state.render(101).decode()
        self.assertIn("overalls_fleet_collection_valid 0", failed)
        self.assertIn("overalls_fleet_collection_failures_total 1", failed)
        self.assertNotIn("overalls_fleet_gauge", failed)
        state.update(sample(102), False)
        self.assertIn("overalls_fleet_collection_valid 1", state.render(102).decode())

    def test_storage_keeps_original_age_and_unknown_values_stay_absent(self) -> None:
        state = Snapshot()
        first = sample(100)
        first["records"] = [
            {
                "kind": "zpool",
                "id": "pool",
                "context": {"health": "ONLINE"},
                "gauges": {"free_bytes": 100},
                "counters": {},
                "rates": {},
            }
        ]
        state.update(first, True)
        state.update(sample(130), False)
        self.assertIn(
            'overalls_fleet_observed_at_seconds{kind="zpool",entity="pool"} 100',
            state.render(130).decode(),
        )
        failed = sample(135)
        failed["failures"] = ["zfs_collection_unavailable"]
        state.update(failed, True)
        self.assertIn('measure="free_bytes"} 100', state.render(135).decode())
        state.update(sample(191), False)
        self.assertNotIn('kind="zpool"', state.render(191).decode())

    def test_vm_churn_does_not_create_series_or_invalid_states(self) -> None:
        state = Snapshot()
        first = sample(100)
        second = sample(105)
        second["records"][0]["id"] = "different-placement"
        second["records"][0]["context"]["updater_phase"] = "private-arbitrary-text"
        state.update(first, False)
        before = [line.split(" ")[0] for line in state.render(100).decode().splitlines()]
        state.update(second, False)
        after = [line.split(" ")[0] for line in state.render(105).decode().splitlines()]
        self.assertEqual(before, after)


unittest.main()
