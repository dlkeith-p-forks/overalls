"""Regression cases for physical holds that nominal VM totals miss."""

import unittest
from dataclasses import replace
from datetime import datetime, timedelta
from uuid import UUID

from admission.capacity import CapacityFrame, Hold


class CapacityFrameTests(unittest.TestCase):
    def test_cross_pool_startup_and_materialized_credit(self) -> None:
        host_id = UUID("00000000-0000-4000-8000-000000000001")
        pool_id = UUID("00000000-0000-4000-8000-000000000002")
        other_pool = UUID("00000000-0000-4000-8000-000000000003")
        first = Hold(
            UUID("00000000-0000-4000-8000-000000000004"),
            UUID("00000000-0000-4000-8000-000000000005"),
            pool_id,
            2,
            600,
            1000,
            True,
            True,
            True,
            True,
            100,
            50,
        )
        second = Hold(
            UUID("00000000-0000-4000-8000-000000000006"),
            UUID("00000000-0000-4000-8000-000000000007"),
            other_pool,
            1,
            200,
            800,
            True,
            True,
            True,
            True,
            0,
            0,
        )
        now = datetime.now()
        frame = CapacityFrame(
            host_id,
            pool_id,
            now,
            7,
            now - timedelta(seconds=1),
            now - timedelta(seconds=1),
            {"version": 1, "cpu_headroom_millicores": 6000, "memory_headroom_bytes": 3000},
            1,
            100,
            3000,
            100,
            {str(first.placement_id): 400},
            (first, second),
        )
        # Both startup compute holds charge this host, even across pools.
        # Only this pool's physically materialized 400 bytes offset its
        # creation hold; temporary copy and resize retain their own charges.
        self.assertEqual(frame.available(), (2, 2100, 2150))

    def test_missing_measured_usage_withholds_budget(self) -> None:
        identity = UUID("00000000-0000-4000-8000-000000000001")
        now = datetime.now()
        frame = CapacityFrame(identity, identity, now, 0, now, now, None, 1, 1, 10_000, 1, {}, ())
        self.assertIsNone(frame.available())

    def test_overhead_change_invalidates_admission_bracket(self) -> None:
        identity = UUID("00000000-0000-4000-8000-000000000001")
        new_placement = UUID("00000000-0000-4000-8000-000000000002")
        now = datetime.now()
        frame = CapacityFrame(
            identity,
            identity,
            now,
            1,
            now,
            now,
            {"version": 1, "cpu_headroom_millicores": 2000, "memory_headroom_bytes": 3000},
            1,
            100,
            5000,
            100,
            {},
            (),
        )
        for field in ("overhead_cores", "overhead_memory_bytes", "overhead_bytes"):
            changed = replace(frame, **{field: getattr(frame, field) + 1})
            self.assertFalse(frame.same_measurement(changed, new_placement=new_placement))
        self.assertFalse(
            frame.same_measurement(
                replace(frame, pool_reported_at=now + timedelta(seconds=1)),
                new_placement=new_placement,
            )
        )


if __name__ == "__main__":
    unittest.main()
