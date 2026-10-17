"""Namespace custody and fixed private authority, without native networking claims."""

import hashlib
import importlib.util
import json
import os
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
private_spec = importlib.util.spec_from_file_location(
    "private_runtime", source / "private_runtime.py"
)
if private_spec is None or private_spec.loader is None:
    raise RuntimeError("private runtime helper unavailable")
private_runtime = importlib.util.module_from_spec(private_spec)
sys.modules["private_runtime"] = private_runtime
private_spec.loader.exec_module(private_runtime)

HOST = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
OTHER = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"


class PrivateRuntimeTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.state = Path(self.temporary.name) / "state"
        self.runtime = Path(self.temporary.name) / "runtime"
        self.state.mkdir(mode=0o700)
        self.runtime.mkdir(mode=0o700)
        self.enroll()

    def enroll(self, host: str = HOST, private: object = True) -> None:
        publish(
            self.state / "lilly.json",
            encode({"host_id": host, "execution": {"private_services": private}}),
        )

    def prepare(self) -> None:
        private_runtime.prepare(self.state, self.runtime)

    def test_exact_namespace_and_inner_authority_with_stable_retry(self) -> None:
        self.prepare()
        link = self.runtime / "private-netns"
        self.assertEqual(
            os.readlink(link), "/run/netns/lilly-" + hashlib.sha256(HOST.encode()).hexdigest()[:12]
        )
        before = {p.name: p.read_bytes() for p in self.runtime.glob("*.json")}
        self.prepare()
        self.assertEqual(before, {p.name: p.read_bytes() for p in self.runtime.glob("*.json")})
        frontend = json.loads(before["audi-private.json"])
        renewal = json.loads(before["audi-private-renewal.json"])
        self.assertEqual(frontend["host_id"], HOST)
        self.assertEqual(frontend["connector_path"], "/run/lilly-ingress/private.sock")
        self.assertEqual(renewal["control_plane"], "https://localhost:5443")
        self.assertEqual(renewal["roots"], "/run/inception-public/private-root.pem")
        self.assertTrue(all(p.stat().st_mode & 0o777 == 0o600 for p in self.runtime.glob("*.json")))

    def test_changed_host_cannot_rebind_existing_namespace(self) -> None:
        self.prepare()
        original = (self.runtime / "audi-private.json").read_bytes()
        target = os.readlink(self.runtime / "private-netns")
        self.enroll(OTHER)
        with self.assertRaises(SetupError):
            self.prepare()
        self.assertEqual(os.readlink(self.runtime / "private-netns"), target)
        self.assertEqual((self.runtime / "audi-private.json").read_bytes(), original)

    def test_foreign_namespace_or_regular_file_is_preserved_and_refused(self) -> None:
        path = self.runtime / "private-netns"
        path.symlink_to("/proc/1/ns/net")
        with self.assertRaises(SetupError):
            self.prepare()
        self.assertEqual(os.readlink(path), "/proc/1/ns/net")
        path.unlink()
        path.write_bytes(b"foreign")
        with self.assertRaises(SetupError):
            self.prepare()
        self.assertEqual(path.read_bytes(), b"foreign")
        self.assertFalse((self.runtime / "audi-private.json").exists())

    def test_private_networking_and_canonical_host_are_required(self) -> None:
        for host, private in [(HOST, False), (HOST, 1), ("invalid", True), (HOST.upper(), True)]:
            self.enroll(host, private)
            with self.assertRaises((ValueError, SetupError)):
                self.prepare()
            self.assertFalse(os.path.lexists(self.runtime / "private-netns"))

    def test_nonprivate_lock_is_rejected_before_publication(self) -> None:
        path = self.runtime / "private-runtime.lock"
        path.write_bytes(b"")
        path.chmod(0o644)
        with self.assertRaises(SetupError):
            self.prepare()
        self.assertFalse(os.path.lexists(self.runtime / "private-netns"))


unittest.main()
