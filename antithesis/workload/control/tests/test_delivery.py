"""Delivery verdict tests keep incomplete peer inventories from becoming passes."""

import unittest

from control.delivery import PeerDelivery, delivery_verdict


class DeliveryVerdictTests(unittest.TestCase):
    def test_complete_recovered_wire_history_has_bounded_delivery(self) -> None:
        history = PeerDelivery(1, 0, 2, 1, True, True, True)
        self.assertIs(delivery_verdict(history), True)

    def test_replayed_or_duplicate_frame_is_a_violation_even_if_sentinel_fails(self) -> None:
        for history in (
            PeerDelivery(2, 0, 2, 1, True, False, True),
            PeerDelivery(1, 1, 2, 1, True, False, True),
        ):
            with self.subTest(history=history):
                self.assertIs(delivery_verdict(history), False)

    def test_missing_positive_control_or_loss_barrier_is_unknown(self) -> None:
        for history in (
            PeerDelivery(1, 0, 1, 1, True, True, True),
            PeerDelivery(1, 0, 2, 0, True, True, True),
            PeerDelivery(1, 0, 2, 1, False, True, True),
            PeerDelivery(1, 0, 2, 1, True, False, True),
            PeerDelivery(1, 0, 2, 1, True, True, False),
        ):
            with self.subTest(history=history):
                self.assertIsNone(delivery_verdict(history))
