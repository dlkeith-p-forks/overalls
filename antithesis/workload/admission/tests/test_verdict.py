"""An acknowledged admission must fail on contradictory durable observations."""

import unittest
from dataclasses import replace
from datetime import UTC, datetime
from time import time_ns
from uuid import UUID

from admission.capacity import CapacityFrame, Hold
from admission.client import CatalogImage, Provisioned
from admission.oracle import Allocation
from admission.physical import PhysicalSample
from admission.verdict import measured_capacity_verdict
from core.outcome import Observation


class MeasuredVerdictTests(unittest.TestCase):
    def setUp(self) -> None:
        self.vm_id = UUID("00000000-0000-4000-8000-000000000001")
        self.owner_id = UUID("00000000-0000-4000-8000-000000000002")
        self.placement_id = UUID("00000000-0000-4000-8000-000000000003")
        self.host_id = UUID("00000000-0000-4000-8000-000000000004")
        self.pool_id = UUID("00000000-0000-4000-8000-000000000005")
        image_id = "sha256:" + "a" * 64
        self.image = CatalogImage(image_id, 536_870_912, 2_147_483_648)
        self.receipt = Provisioned(
            self.vm_id,
            self.owner_id,
            self.placement_id,
            self.host_id,
            1,
            1,
            image_id,
            "standard",
            1,
            536_870_912,
            2_147_483_648,
        )
        self.allocation = Allocation(
            self.vm_id,
            self.owner_id,
            "request-key",
            False,
            1,
            self.placement_id,
            self.host_id,
            self.pool_id,
            1,
            1,
            1,
            1,
            1,
            1,
        )
        now = datetime.now(UTC)
        self.before = CapacityFrame(
            self.host_id,
            self.pool_id,
            now,
            1,
            now,
            now,
            {"version": 1, "cpu_headroom_millicores": 8000, "memory_headroom_bytes": 8_000_000_000},
            1,
            1,
            10_000_000_000,
            1,
            {},
            (),
            "123",
            "456",
            "tank/lilly",
        )
        self.physical = PhysicalSample(
            time_ns(),
            self.vm_id,
            "123",
            "456",
            "tank/lilly",
            10_000_000_000,
            1,
            1,
            11_000_000_000,
            10_000_000_000,
            None,
            1,
            None,
            100_000,
        )

    def verdict(
        self, rows: tuple[Allocation, ...], after: Observation[CapacityFrame | None]
    ) -> bool | None:
        return measured_capacity_verdict(
            self.receipt, rows, self.before, after, self.physical, self.image
        )

    def test_success_with_zero_or_multiple_committed_rows_fails(self) -> None:
        after = Observation.observed(self.before)
        self.assertIs(self.verdict((), after), False)
        self.assertIs(self.verdict((self.allocation, self.allocation), after), False)

    def test_wrong_committed_identity_or_placement_fails(self) -> None:
        after = Observation.observed(self.before)
        self.assertIs(self.verdict((replace(self.allocation, vm_id=self.pool_id),), after), False)
        self.assertIs(self.verdict((replace(self.allocation, pool_id=self.vm_id),), after), False)
        self.assertIs(
            self.verdict((replace(self.allocation, placement_id=self.pool_id),), after), False
        )

    def test_observed_missing_pool_fails_but_changed_report_is_unknown(self) -> None:
        self.assertIs(self.verdict((self.allocation,), Observation.observed(None)), False)
        self.assertIs(self.verdict((self.allocation,), Observation.unavailable()), None)
        changed = replace(self.before, report_sequence=2)
        self.assertIs(self.verdict((self.allocation,), Observation.observed(changed)), None)

    def test_wrong_physical_sample_identity_is_unknown(self) -> None:
        wrong = replace(self.physical, zpool_guid="999")
        result = measured_capacity_verdict(
            self.receipt,
            (self.allocation,),
            self.before,
            Observation.observed(self.before),
            wrong,
            self.image,
        )
        self.assertIs(result, None)

    def test_sample_older_than_sql_frame_is_unknown(self) -> None:
        old = replace(self.physical, sampled_at_ns=0)
        result = measured_capacity_verdict(
            self.receipt,
            (self.allocation,),
            self.before,
            Observation.observed(self.before),
            old,
            self.image,
        )
        self.assertIs(result, None)

    def test_later_physical_free_disagreement_is_unknown(self) -> None:
        own = Hold(
            self.vm_id,
            self.placement_id,
            self.pool_id,
            1,
            603_979_776,
            3_221_225_472,
            True,
            True,
            True,
            True,
            0,
            0,
        )
        after = replace(self.before, holds=(own,))
        overstated = replace(self.physical, available_bytes=self.before.free_bytes - 1)
        result = measured_capacity_verdict(
            self.receipt,
            (self.allocation,),
            self.before,
            Observation.observed(after),
            overstated,
            self.image,
        )
        self.assertIs(result, None)


if __name__ == "__main__":
    unittest.main()
