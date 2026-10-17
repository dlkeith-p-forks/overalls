"""The guest stand-in channel accepts only fixed requests and exact results."""

import json
import tempfile
from pathlib import Path
from unittest import TestCase
from unittest.mock import patch
from uuid import uuid4

from satellite.standin import (
    GuestStandIn,
    StandInRequest,
    StandInResult,
    _request,
    parse_result,
    serve,
)

MARKER = "fx-" + "b" * 32


class StandInTests(TestCase):
    def test_request_menu_is_closed(self) -> None:
        identity = str(uuid4())
        base: dict[str, object] = {
            "version": 1,
            "request_id": identity,
            "family": "inference",
            "marker": MARKER,
            "name": "llm",
        }
        self.assertIsNotNone(_request(base))
        self.assertIsNone(_request({**base, "name": "other"}))
        self.assertIsNone(_request({**base, "family": "integration", "name": "ssh"}))
        self.assertIsNone(_request({**base, "marker": "fx-short"}))
        self.assertIsNone(_request({**base, "extra": True}))

    def test_result_must_match_request_and_outcome(self) -> None:
        identity = uuid4()
        good = {"version": 1, "request_id": str(identity), "outcome": "http", "status": 403}
        self.assertEqual(parse_result(good, identity), StandInResult(identity, "http", 403))
        self.assertIsNone(parse_result(good, uuid4()))
        self.assertIsNone(parse_result({**good, "status": None}, identity))
        self.assertIsNone(parse_result({**good, "outcome": "unreachable"}, identity))
        self.assertEqual(
            parse_result({**good, "outcome": "unreachable", "status": None}, identity),
            StandInResult(identity, "unreachable", None),
        )

    def test_channel_round_trip_answers_each_request_once(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "requests").mkdir()
            (root / "results").mkdir()
            calls: list[StandInRequest] = []

            def answer(_context: object, request: StandInRequest) -> StandInResult:
                calls.append(request)
                return StandInResult(request.request_id, "http", 403)

            identity = uuid4()
            body = {
                "version": 1,
                "request_id": str(identity),
                "family": "integration",
                "marker": MARKER,
                "name": "at-" + "c" * 20,
            }
            (root / "requests" / f"{identity}.json").write_text(json.dumps(body), "utf-8")
            with (
                patch("satellite.standin._context"),
                patch("satellite.standin._handshake", return_value=True),
                patch("satellite.standin.perform", side_effect=answer),
            ):
                serve(root, root / "root.pem", stop_after=0.5)
                serve(root, root / "root.pem", stop_after=0.3)
            self.assertEqual(len(calls), 1)
            ready = json.loads((root / "results/ready.json").read_text("utf-8"))
            self.assertTrue(ready["private_tls_verified"])
            result = json.loads((root / "results" / f"{identity}.json").read_text("utf-8"))
            self.assertEqual(parse_result(result, identity), StandInResult(identity, "http", 403))

    def test_missing_result_is_unavailable(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "requests").mkdir()
            (root / "results").mkdir()
            observed = GuestStandIn(root).send("inference", MARKER, "llm", timeout_seconds=0.3)
            self.assertIsNone(observed.value)
