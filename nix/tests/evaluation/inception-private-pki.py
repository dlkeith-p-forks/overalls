"""Real crypto custody checks; these do not establish private inference acceptance."""

import importlib.util
import shutil
import sys
import tempfile
import unittest
from datetime import UTC, datetime
from pathlib import Path
from unittest.mock import patch

source = Path(sys.argv.pop(1))
authority_source = Path(sys.argv.pop(1))
spec = importlib.util.spec_from_file_location("runtime", source / "runtime.py")
if spec is None or spec.loader is None:
    raise RuntimeError("runtime helper unavailable")
runtime = importlib.util.module_from_spec(spec)
sys.modules["runtime"] = runtime
spec.loader.exec_module(runtime)
SetupError = runtime.SetupError
publish = runtime.publish
authority_spec = importlib.util.spec_from_file_location(
    "authority", authority_source / "authority.py"
)
if authority_spec is None or authority_spec.loader is None:
    raise RuntimeError("authority helper unavailable")
authority = importlib.util.module_from_spec(authority_spec)
sys.modules["authority"] = authority
authority_spec.loader.exec_module(authority)
private_spec = importlib.util.spec_from_file_location("private_pki", source / "private_pki.py")
if private_spec is None or private_spec.loader is None:
    raise RuntimeError("private PKI helper unavailable")
private_pki = importlib.util.module_from_spec(private_spec)
sys.modules["private_pki"] = private_pki
private_spec.loader.exec_module(private_pki)


class PrivatePKITest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.state, self.public = self.root / "state", self.root / "public"

    def prepare(self) -> None:
        private_pki.prepare(authority, self.state, self.public)

    def snapshot(self) -> dict[str, bytes]:
        return {p.name: p.read_bytes() for p in (self.state / "private-pki").iterdir()}

    def test_unique_hierarchy_stable_restart_and_public_root_only(self) -> None:
        self.prepare()
        original = self.snapshot()
        self.prepare()
        self.assertEqual(original, self.snapshot())
        private_pki.prepare(authority, self.root / "second", self.root / "second-public")
        for name in ["root.key", "issuer.key", "root.pem", "issuer.pem"]:
            self.assertNotEqual(
                original[name], (self.root / "second/private-pki" / name).read_bytes()
            )
        self.assertEqual({p.name for p in self.public.iterdir()}, {"private-root.pem"})
        self.assertEqual((self.public / "private-root.pem").read_bytes(), original["root.pem"])
        self.assertNotIn(b"PRIVATE KEY", (self.public / "private-root.pem").read_bytes())
        self.assertEqual(self.public.stat().st_mode & 0o777, 0o755)
        self.assertEqual((self.public / "private-root.pem").stat().st_mode & 0o777, 0o644)
        for path in (self.state / "private-pki").iterdir():
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_missing_published_keys_never_trigger_rotation(self) -> None:
        self.prepare()
        original = self.snapshot()
        (self.state / "private-pki/issuer.key").unlink()
        with patch.object(authority, "bootstrap") as bootstrap:
            with self.assertRaises(SetupError):
                self.prepare()
            bootstrap.assert_not_called()
        self.assertEqual((self.state / "private-pki/root.key").read_bytes(), original["root.key"])
        shutil.rmtree(self.state / "private-pki")
        with patch.object(authority, "bootstrap") as bootstrap:
            with self.assertRaises(SetupError):
                self.prepare()
            bootstrap.assert_not_called()

    def test_foreign_binding_and_mismatched_key_fail_without_replacement(self) -> None:
        self.prepare()
        target = self.state / "private-pki"
        original = self.snapshot()
        publish(target / "binding.json", b'{"version":1,"instance_id":"foreign"}')
        with self.assertRaises(SetupError):
            self.prepare()
        publish(target / "binding.json", original["binding.json"])
        publish(target / "issuer.key", original["root.key"])
        with self.assertRaises(SetupError):
            self.prepare()
        self.assertEqual((target / "issuer.key").read_bytes(), original["root.key"])

    def test_interrupted_marker_publication_reuses_complete_hierarchy(self) -> None:
        self.prepare()
        original = self.snapshot()
        (self.state / "private-pki-ready").unlink()
        with patch.object(authority, "bootstrap") as bootstrap:
            self.prepare()
            bootstrap.assert_not_called()
        self.assertEqual(original, self.snapshot())

    def test_expired_hierarchy_is_not_published(self) -> None:
        now = datetime.now(UTC)
        issued = authority.years_after(now, -(authority.INTERMEDIATE_YEARS + 1))
        expired = authority.bootstrap(issued)
        self.assertLess(expired[3].not_valid_after_utc, now)
        with (
            patch.object(authority, "bootstrap", return_value=expired),
            self.assertRaises(SetupError),
        ):
            self.prepare()
        self.assertFalse((self.state / "private-pki").exists())
        self.assertFalse((self.state / "private-pki-ready").exists())
        self.assertFalse(self.public.exists())


unittest.main()
