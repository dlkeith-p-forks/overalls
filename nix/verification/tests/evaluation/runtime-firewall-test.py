"""Unit checks for optional runtime firewall rules; documentation addresses only."""

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path
from types import ModuleType
from unittest.mock import patch


def load(path: str) -> ModuleType:
    spec = importlib.util.spec_from_file_location("runtime_firewall", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


firewall = load(sys.argv.pop(1))


def rule(name: str, source_file: str, optional: bool) -> dict[str, object]:
    return {
        "name": name,
        "source": None,
        "sourceFile": source_file,
        "destination": None,
        "destinationFile": None,
        "protocol": "tcp",
        "ports": [22],
        "interface": None,
        "comment": name,
        "optional": optional,
    }


class OptionalRules(unittest.TestCase):
    def apply(self, rules: list[dict[str, object]]) -> list[str]:
        scripts: list[str] = []
        spec = {"chain": "overalls-runtime", "backend": "nftables", "rules": rules}
        with patch.object(firewall, "nft", side_effect=scripts.append):
            firewall.apply(spec)
        return scripts

    def test_absent_optional_file_skips_only_that_rule(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fleet = Path(directory) / "fleet"
            fleet.write_text("198.51.100.7\n")
            scripts = self.apply(
                [rule("base", f"{directory}/absent", True), rule("fleet", str(fleet), False)]
            )
        self.assertIn("flush chain", scripts[0])
        self.assertIn("ip saddr 198.51.100.7", scripts[1])
        self.assertNotIn("base", scripts[1])

    def test_present_optional_file_is_admitted(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory) / "base"
            base.write_text("203.0.113.9\n")
            scripts = self.apply([rule("base", str(base), True)])
        self.assertIn("ip saddr 203.0.113.9 tcp dport { 22 }", scripts[1])

    def test_absent_required_or_malformed_optional_file_closes_the_chain(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            bad = Path(directory) / "bad"
            bad.write_text("not-an-address\n")
            for rules in (
                [rule("fleet", f"{directory}/absent", False)],
                [rule("base", str(bad), True)],
            ):
                scripts: list[str] = []
                with self.assertRaises((SystemExit, OSError)):
                    spec = {"chain": "overalls-runtime", "backend": "nftables", "rules": rules}
                    with patch.object(firewall, "nft", side_effect=scripts.append):
                        firewall.apply(spec)
                self.assertEqual(len(scripts), 1)
                self.assertIn("flush chain", scripts[0])


if __name__ == "__main__":
    unittest.main()
