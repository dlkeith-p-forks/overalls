"""The accounting oracle distinguishes replay, missing settlement and unknown usage."""

from decimal import Decimal
from unittest import TestCase
from uuid import UUID

from satellite.oracle import Completion, Daily, InferenceSnapshot, conserved

OWNER = UUID("11111111-1111-4111-8111-111111111111")
HOST = UUID("22222222-2222-4222-8222-222222222222")
REQUEST = UUID("33333333-3333-4333-8333-333333333333")
DAY = "2026-10-13"


def snapshot(
    completions: tuple[Completion, ...],
    requests: int,
    unknown: int,
    input_tokens: int,
    output_tokens: int = 0,
) -> InferenceSnapshot:
    return InferenceSnapshot(
        completions,
        (
            Daily(
                DAY,
                OWNER,
                "openai",
                "fixture-model",
                requests,
                unknown,
                Decimal(input_tokens),
                Decimal(output_tokens),
            ),
        ),
    )


class ConservationTests(TestCase):
    def test_unknown_completion_counts_once_without_fabricated_tokens(self) -> None:
        before = snapshot((), 0, 0, 0)
        completion = Completion(
            REQUEST,
            OWNER,
            HOST,
            "openai",
            "fixture-model",
            DAY,
            "interrupted",
            "unknown",
            None,
            None,
        )
        self.assertTrue(conserved(before, snapshot((completion,), 1, 1, 0), frozenset({REQUEST})))
        self.assertFalse(conserved(before, snapshot((completion,), 2, 2, 0), frozenset({REQUEST})))

    def test_unsettled_completion_has_no_verdict(self) -> None:
        before = snapshot((), 0, 0, 0)
        incomplete = Completion(
            REQUEST,
            OWNER,
            HOST,
            "openai",
            "fixture-model",
            DAY,
            None,
            None,
            None,
            None,
        )
        self.assertIsNone(conserved(before, snapshot((incomplete,), 0, 0, 0), frozenset({REQUEST})))

    def test_exact_known_token_contribution(self) -> None:
        before = snapshot((), 4, 1, 11)
        completion = Completion(
            REQUEST,
            OWNER,
            HOST,
            "openai",
            "fixture-model",
            DAY,
            "completed",
            "complete",
            3,
            7,
        )
        self.assertTrue(
            conserved(before, snapshot((completion,), 5, 1, 14, 7), frozenset({REQUEST}))
        )
        self.assertFalse(
            conserved(before, snapshot((completion,), 5, 2, 14, 7), frozenset({REQUEST}))
        )
