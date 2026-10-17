"""Closed BEAM peer result boundary and uncertainty regression tests."""

import subprocess
import unittest
from unittest.mock import patch

from control.peer import parse_result, run_peer
from core.outcome import State


class PeerResultTests(unittest.TestCase):
    def test_only_single_complete_typed_result_is_observed(self) -> None:
        result = parse_result("RESULT\tobserved\tbusy=true\tlimit=8\tobserved=8\n")
        self.assertIs(result.state, State.OBSERVED)
        self.assertIsNotNone(result.value)
        assert result.value is not None
        self.assertIs(result.value.flag("busy"), True)
        self.assertEqual(result.value.count("limit"), 8)
        self.assertIsNone(result.value.count("busy"))
        for text in (
            "RESULT\tunavailable\n",
            "RESULT\tobserved\tbusy=true\tbusy=false\n",
            "RESULT\tobserved\tbusy=yes\n",
            "RESULT\tobserved\tbad-key=1\n",
            "RESULT\tobserved\tbusy=true\nRESULT\tobserved\tbusy=true\n",
            "RESULT\tobserved\tcount=-1\n",
        ):
            with self.subTest(text=text):
                self.assertIs(parse_result(text).state, State.UNAVAILABLE)

    def test_failed_process_does_not_become_a_verdict(self) -> None:
        with patch(
            "control.peer.subprocess.run",
            return_value=subprocess.CompletedProcess(
                args=[], returncode=1, stdout="RESULT\tobserved\tbusy=true\n", stderr=""
            ),
        ):
            self.assertIs(run_peer("capacity", 8, 500).state, State.UNAVAILABLE)

    def test_timeout_does_not_become_a_verdict(self) -> None:
        with patch(
            "control.peer.subprocess.run", side_effect=subprocess.TimeoutExpired("elixir", 90)
        ):
            self.assertIs(run_peer("pending", 8, 50).state, State.UNAVAILABLE)


if __name__ == "__main__":
    unittest.main()
