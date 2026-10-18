"""Guest substrate readiness must name the exact unmet catalog condition."""

import unittest
from pathlib import Path
from unittest.mock import patch
from uuid import UUID

from core.outcome import Observation
from guest_lifecycle.operation import OperatorReply
from guest_lifecycle.readiness import capacity_gap, capacity_ready, substrate_gap
from guest_lifecycle.witness import GuestIdentity

REQUEST = UUID("11111111-1111-4111-8111-111111111111")
IMAGE = "sha256:" + "a" * 64
IDENTITY = GuestIdentity(IMAGE, 4_294_967_296, 2_147_483_648, 1, None)


def catalog(
    *,
    known: bool = True,
    image: str = IMAGE,
    vcpu: int = 1,
    memory: int = 2_214_592_512,
    disk: int = 4_294_967_296,
    status: str = "ok",
) -> OperatorReply:
    value: dict[str, object] = {
        "capacity_known": known,
        "images": [{"id": image}],
        "available": {"vcpu": vcpu, "memory_bytes": memory, "disk_bytes": disk},
    }
    return OperatorReply(REQUEST, "compute.catalog", status, value if status == "ok" else None)


class ReadinessTests(unittest.TestCase):
    def test_catalog_gap_tokens(self) -> None:
        self.assertIsNone(capacity_gap(catalog(), IDENTITY))
        self.assertTrue(capacity_ready(catalog(), IDENTITY))
        cases: tuple[tuple[OperatorReply, str], ...] = (
            (catalog(status="refused"), "catalog_not_ok"),
            (catalog(known=False), "capacity_unknown"),
            (catalog(image="sha256:" + "b" * 64), "image_not_offered"),
            (catalog(vcpu=0), "capacity_insufficient"),
            (catalog(memory=1), "capacity_insufficient"),
            (catalog(memory=2_147_483_648), "capacity_insufficient"),
            (catalog(disk=4096), "capacity_insufficient"),
        )
        for reply, reason in cases:
            with self.subTest(reason=reason):
                self.assertEqual(capacity_gap(reply, IDENTITY), reason)
                self.assertFalse(capacity_ready(reply, IDENTITY))

    def test_substrate_needs_identity_then_catalog(self) -> None:
        root = Path("/run/overalls-control-requests")
        with (
            patch("guest_lifecycle.readiness.GuestWitnessClient") as witness,
            patch("guest_lifecycle.readiness.ComputeLifecycleOperator") as operator,
        ):
            witness.return_value.identity.return_value = Observation.unavailable()
            self.assertEqual(substrate_gap(root), "guest_identity_unavailable")
            operator.return_value.catalog.assert_not_called()
            witness.return_value.identity.return_value = Observation.observed(IDENTITY)
            operator.return_value.catalog.return_value = Observation.unavailable()
            self.assertEqual(substrate_gap(root), "compute_catalog_unavailable")
            operator.return_value.catalog.return_value = Observation.observed(catalog(known=False))
            self.assertEqual(substrate_gap(root), "capacity_unknown")
            operator.return_value.catalog.return_value = Observation.observed(catalog())
            self.assertIsNone(substrate_gap(root))


if __name__ == "__main__":
    unittest.main()
