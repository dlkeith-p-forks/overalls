"""Admission command early returns are logged once and never become verdicts."""

import unittest
from uuid import UUID

from admission import scenarios
from admission.client import Catalog, CatalogImage, DomainResult
from admission.oracle import Allocation
from core.outcome import Observation

_LOGGER = "admission.scenarios"
_SMALL = CatalogImage("sha256:" + "a" * 64, 536_870_912, 1_073_741_824)
_LARGE = CatalogImage("sha256:" + "b" * 64, 8_589_934_592, 1_073_741_824)


def _catalog(
    *, known: bool = True, vcpu: int = 4, images: tuple[CatalogImage, ...] = (_SMALL,)
) -> Observation[Catalog]:
    return Observation.observed(Catalog(known, vcpu, 4_294_967_296, 51_539_607_552, images))


def _allocation() -> Allocation:
    ids = [UUID(f"00000000-0000-4000-8000-00000000000{n}") for n in range(1, 5)]
    return Allocation(ids[0], ids[1], "key", False, 1, ids[2], ids[3], ids[3], 1, 1, 1, 1, 1, 1)


class UnexercisedLoggingTests(unittest.TestCase):
    def setUp(self) -> None:
        scenarios._REPORTED.clear()

    def test_reason_is_logged_once_per_process(self) -> None:
        with self.assertLogs(_LOGGER, level="INFO") as logs:
            scenarios.unexercised("Compute catalog result unavailable")
            scenarios.unexercised("Compute catalog result unavailable")
            scenarios.unexercised("pre-submission SQL snapshot unavailable")
        self.assertEqual(
            logs.output,
            [
                f"INFO:{_LOGGER}:Compute admission unexercised: Compute catalog result unavailable",
                f"INFO:{_LOGGER}:Compute admission unexercised: "
                "pre-submission SQL snapshot unavailable",
            ],
        )

    def test_unavailable_catalog_selects_nothing(self) -> None:
        with self.assertLogs(_LOGGER, level="INFO") as logs:
            self.assertIsNone(scenarios.select_image(Observation.unavailable()))
        self.assertIn("Compute catalog result unavailable", logs.output[0])

    def test_unknown_capacity_selects_nothing(self) -> None:
        with self.assertLogs(_LOGGER, level="INFO") as logs:
            self.assertIsNone(scenarios.select_image(_catalog(known=False)))
        self.assertIn("measured eligible host capacity unavailable", logs.output[0])

    def test_missing_image_selects_nothing(self) -> None:
        with self.assertLogs(_LOGGER, level="INFO") as logs:
            self.assertIsNone(scenarios.select_image(_catalog(images=())))
        self.assertIn("no enabled catalog image advertised", logs.output[0])

    def test_fitting_image_is_preferred(self) -> None:
        self.assertEqual(scenarios.select_image(_catalog(images=(_LARGE, _SMALL))), _SMALL)

    def test_insufficient_headroom_still_lets_marshall_decide(self) -> None:
        with self.assertNoLogs(_LOGGER, level="INFO"):
            self.assertEqual(scenarios.select_image(_catalog(vcpu=0)), _SMALL)

    def test_settled_requires_reply_and_committed_rows(self) -> None:
        refusal = DomainResult("compute.provision", "error", None, "insufficient_capacity")
        with self.assertLogs(_LOGGER, level="INFO") as logs:
            self.assertIsNone(scenarios._settled(Observation.unavailable(), ()))
            self.assertIsNone(scenarios._settled(Observation.observed(refusal), None))
        self.assertIn("Marshall admission reply unavailable", logs.output[0])
        self.assertIn("post-submission SQL snapshot unavailable", logs.output[1])
        self.assertEqual(scenarios._settled(Observation.observed(refusal), ()), (refusal, ()))

    def test_operator_precheck_refusal_is_not_an_admission_decision(self) -> None:
        precheck = DomainResult("compute.provision", "error", None, "image_unavailable")
        rows = (_allocation(),)
        with self.assertLogs(_LOGGER, level="INFO") as logs:
            self.assertIsNone(scenarios._settled(Observation.observed(precheck), rows))
        self.assertIn("operator image precheck refused before admission", logs.output[0])


if __name__ == "__main__":
    unittest.main()
