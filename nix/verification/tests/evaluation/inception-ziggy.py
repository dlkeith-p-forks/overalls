"""Independent runtime selection and private-file checks; no provider acceptance."""

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

source = Path(sys.argv.pop(1))
spec = importlib.util.spec_from_file_location("runtime", source / "runtime.py")
if spec is None or spec.loader is None:
    raise RuntimeError("runtime helper unavailable")
runtime = importlib.util.module_from_spec(spec)
sys.modules["runtime"] = runtime
spec.loader.exec_module(runtime)
SetupError = runtime.SetupError
encode = runtime.encode
publish = runtime.publish
ziggy_spec = importlib.util.spec_from_file_location("ziggy_runtime", source / "ziggy_runtime.py")
if ziggy_spec is None or ziggy_spec.loader is None:
    raise RuntimeError("ziggy runtime helper unavailable")
ziggy_runtime = importlib.util.module_from_spec(ziggy_spec)
sys.modules["ziggy_runtime"] = ziggy_runtime
ziggy_spec.loader.exec_module(ziggy_runtime)

HOST = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"


class ZiggyRuntimeTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.state = Path(self.temporary.name) / "state"
        self.runtime = Path(self.temporary.name) / "runtime"
        self.state.mkdir(mode=0o700)
        self.runtime.mkdir(mode=0o700)
        publish(self.state / "lilly.json", encode({"host_id": HOST}))

    def prepare(self) -> dict[str, object]:
        ziggy_runtime.prepare(self.state, self.runtime)
        return json.loads((self.runtime / "ziggy.json").read_bytes())

    def test_local_authority_and_explicit_provider_selection(self) -> None:
        value = self.prepare()
        self.assertEqual(value["host_id"], HOST)
        self.assertEqual(value["control_plane"], "https://localhost:5443")
        self.assertEqual(value["enabled_providers"], ["openai", "anthropic"])
        publish(
            self.state / "ziggy-providers.json",
            encode({"version": 1, "enabled_providers": ["openai"]}),
        )
        self.assertEqual(self.prepare()["enabled_providers"], ["openai"])
        self.assertEqual((self.runtime / "ziggy.json").stat().st_mode & 0o777, 0o600)

    def test_invalid_selection_cannot_replace_prepared_configuration(self) -> None:
        self.prepare()
        original = (self.runtime / "ziggy.json").read_bytes()
        selections = [[], ["openai", "openai"], ["unknown"], "openai", [None]]
        values = [{"version": 1, "enabled_providers": providers} for providers in selections]
        values += [
            {"version": True, "enabled_providers": ["openai"]},
            {"version": 1, "enabled_providers": ["openai"], "control_plane": "https://parent.test"},
        ]
        for value in values:
            publish(self.state / "ziggy-providers.json", encode(value))
            with self.assertRaises(SetupError):
                self.prepare()
            self.assertEqual((self.runtime / "ziggy.json").read_bytes(), original)

    def test_foreign_file_permissions_and_symlinks_fail(self) -> None:
        selection = self.state / "ziggy-providers.json"
        publish(selection, encode({"version": 1, "enabled_providers": ["openai"]}))
        selection.chmod(0o644)
        with self.assertRaises(SetupError):
            self.prepare()
        selection.unlink()
        selection.symlink_to(self.state / "lilly.json")
        with self.assertRaises(OSError):
            self.prepare()
        self.assertFalse((self.runtime / "ziggy.json").exists())

    def test_invalid_host_does_not_publish(self) -> None:
        for host in [None, "invalid", HOST.upper(), "parent.test"]:
            publish(self.state / "lilly.json", encode({"host_id": host}))
            with self.assertRaises((SetupError, ValueError)):
                self.prepare()
            self.assertFalse((self.runtime / "ziggy.json").exists())


unittest.main()
