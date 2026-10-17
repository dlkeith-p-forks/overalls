"""Origin receipts expose only validated, content-free effect facts."""

from unittest import TestCase

from satellite.origin import _receipt


class OriginReceiptTests(TestCase):
    def test_registered_marker_and_header_predicates(self) -> None:
        receipt = _receipt(
            {
                "seq": 1,
                "family": "integration",
                "route": "probe",
                "operation_id": "fx-" + "a" * 32,
                "origin": "a",
                "accepted_at_ns": 123456,
                "target_is_a": True,
                "authorization_matches": True,
                "static_header_matches": True,
            }
        )
        self.assertIsNotNone(receipt)
        if receipt is not None:
            self.assertTrue(receipt.authorization_matches)

    def test_missing_timestamp_cannot_prove_absent_effect(self) -> None:
        self.assertIsNone(
            _receipt(
                {
                    "seq": 1,
                    "family": "openai",
                    "route": "responses",
                    "operation_id": "fixture-1",
                    "origin": "api.openai.com",
                    "target_is_a": None,
                    "authorization_matches": None,
                    "static_header_matches": None,
                }
            )
        )
