"""Refuse malformed metadata before it can configure an isolated native host."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import native_isolation as isolation
import native_services as services
import native_tcp_probe as tcp


class BoundaryTest(unittest.TestCase):
    def test_only_the_actual_derived_identity_is_accepted(self) -> None:
        value: dict[str, object] = {
            "namespace": "lilly-bd7662a5eeb4",
            "tap": "lvbd7662a5eeb4",
            "guard": "guard_11111111111141118111111111111111",
            "address": "10.20.0.203",
            "gateway": "10.20.0.1",
            "mac": "02:fc:0a:14:00:cb",
            "ingress_mark": 0x41554449,
        }
        self.assertEqual(isolation.identity(json.dumps(value).encode()).tap, value["tap"])
        for key, replacement in (
            ("ingress_mark", True),
            ("tap", "lvbad; nft flush ruleset"),
            ("address", "10.20.0.204"),
            ("mac", "02:fc:0a:00:00:cb"),
            ("extra", "unknown"),
        ):
            with self.subTest(key=key), self.assertRaises(services.ProtocolError):
                isolation.identity(json.dumps(value | {key: replacement}).encode())

    def test_counter_types_and_closed_destinations(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "counts.json"
            baseline: dict[str, object] = dict.fromkeys(isolation.DESTINATIONS, 0)
            path.write_text(json.dumps(baseline))
            self.assertEqual(isolation.counts(path)[isolation.PUBLIC], 0)
            for bad in (True, -1, 10_001, "1", None):
                path.write_text(json.dumps(baseline | {isolation.PUBLIC: bad}))
                with self.subTest(value=bad), self.assertRaises(services.ProtocolError):
                    isolation.counts(path)
            path.write_text(json.dumps(baseline | {"127.0.0.1": 0}))
            with self.assertRaises(services.ProtocolError):
                isolation.counts(path)

    def test_probe_rejects_destinations_and_sources_before_network_effects(self) -> None:
        for destination, source in (
            ("127.0.0.1", None),
            (isolation.PUBLIC, "0.0.0.0"),
            (isolation.PUBLIC, isolation.SIBLING),
        ):
            with (
                self.subTest(destination=destination, source=source),
                self.assertRaises(ValueError),
            ):
                tcp.connected(destination, source)


if __name__ == "__main__":
    unittest.main()
