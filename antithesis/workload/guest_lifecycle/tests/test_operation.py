"""Refusal reasons are kept only as closed tokens that are safe to log."""

import unittest

from guest_lifecycle.operation import reason_token


class ReasonTokenTest(unittest.TestCase):
    def test_closed_tokens_are_kept(self) -> None:
        for token in ("insufficient_capacity", "image_unavailable", "a"):
            with self.subTest(token=token):
                self.assertEqual(reason_token(token), token)

    def test_other_values_collapse(self) -> None:
        for raw in (None, 7, "", "Has Space", "x" * 65, "line\nbreak", "_lead"):
            with self.subTest(raw=raw):
                self.assertEqual(reason_token(raw), "unrecognized_reason")


if __name__ == "__main__":
    unittest.main()
