"""A joined first allocation requires exactly one dispatch job."""

import unittest
from dataclasses import replace
from uuid import UUID

from admission.oracle import Allocation


class AllocationTests(unittest.TestCase):
    def test_dispatch_job_cardinality(self) -> None:
        identity = UUID("00000000-0000-4000-8000-000000000001")
        allocation = Allocation(
            identity,
            identity,
            "request-key",
            False,
            1,
            identity,
            identity,
            identity,
            1,
            1,
            1,
            1,
            1,
            0,
        )
        self.assertTrue(allocation.joined_at_admission())
        self.assertFalse(replace(allocation, dispatch_jobs=0).joined_at_admission())
        # The minute scheduler may repeat the hint for a still-pending operation.
        self.assertTrue(replace(allocation, dispatch_jobs=2).joined_at_admission())
        self.assertFalse(replace(allocation, provision_operations=2).joined_at_admission())


if __name__ == "__main__":
    unittest.main()
