"""Runtime identity and shared SMTP boundary checks; no production credentials."""

import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("inception_runtime", sys.argv.pop(1))
if spec is None or spec.loader is None:
    raise RuntimeError("inception runtime helper unavailable")
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class InceptionRuntimeTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.smtp = {
            "version": 1,
            "host": "smtp.example.test",
            "port": 465,
            "username": "fixture",
            "password": "fixture-password",
            "from": "fixture@example.test",
            "tls": "implicit",
        }

    def test_unique_instances_and_stable_restart(self) -> None:
        first = runtime.identities(self.root / "one")
        self.assertEqual(first, runtime.identities(self.root / "one"))
        second = runtime.identities(self.root / "two")
        for key in first.keys() - {"version"}:
            self.assertNotEqual(first[key], second[key])
        self.assertEqual((self.root / "one" / "identity.json").stat().st_mode & 0o777, 0o600)

    def test_missing_identity_after_initialization_does_not_reset(self) -> None:
        runtime.identities(self.root)
        (self.root / "identity.json").unlink()
        with self.assertRaisesRegex(runtime.SetupError, "persistent identity missing"):
            runtime.identities(self.root)
        self.assertFalse((self.root / "identity.json").exists())

    def test_corrupt_identity_never_discloses_or_replaces_its_contents(self) -> None:
        runtime.identities(self.root)
        path = self.root / "identity.json"
        for body in [b"private-value", b"null", b"{}", b"[]"]:
            path.write_bytes(body)
            with self.assertRaisesRegex(runtime.SetupError, "persistent identity invalid"):
                runtime.identities(self.root)
            self.assertEqual(path.read_bytes(), body)

    def test_symlinks_and_shared_files_are_not_private_identity(self) -> None:
        runtime.identities(self.root)
        path = self.root / "identity.json"
        path.chmod(0o644)
        with self.assertRaises(runtime.SetupError):
            runtime.identities(self.root)
        path.chmod(0o600)
        target = self.root / "saved"
        path.rename(target)
        path.symlink_to(target)
        with self.assertRaises(runtime.SetupError):
            runtime.identities(self.root)
        path.unlink()
        os.link(target, path)
        with self.assertRaises(runtime.SetupError):
            runtime.identities(self.root)

    def test_shared_smtp_rejects_internal_secrets_and_plaintext(self) -> None:
        for change in [
            {"database_password": "shared"},
            {"token_signing_secret": "shared"},
            {"tls": "never"},
            {"tls": "local_relay"},
            {"port": True},
            {"password": "first\nSECRET_KEY_BASE=second"},
            {"host": "localhost; id"},
            {"version": True},
            {"ca_pem": "not a certificate"},
        ]:
            with self.assertRaises(runtime.SetupError):
                runtime.smtp_environment({**self.smtp, **change}, self.root)

    def test_smtp_refresh_preserves_internal_secrets(self) -> None:
        identity = runtime.identities(self.root)
        before = runtime.application_environment(
            identity, runtime.smtp_environment(self.smtp, self.root), "/ca"
        )
        after = runtime.application_environment(
            identity,
            runtime.smtp_environment({**self.smtp, "password": "rotated"}, self.root),
            "/ca",
        )
        changed = [key for key in before if before[key] != after[key]]
        self.assertEqual(changed, ["MARSHALL_SMTP_PASSWORD"])
        keyring = json.loads(after["MARSHALL_CLOAK_KEYS"])
        self.assertEqual(keyring[0]["key"], identity["cloak_key"])

    def test_systemd_environment_escaping_preserves_literal_shell_characters(self) -> None:
        value = 'literal"backslash\\$(false)`false`$HOME'
        encoded = runtime.environment_file({"MARSHALL_SMTP_PASSWORD": value})
        self.assertIn(b'\\"', encoded)
        self.assertIn(b"\\\\", encoded)
        self.assertIn(b"$(false)`false`$HOME", encoded)
        with self.assertRaises(runtime.SetupError):
            runtime.environment_file({"SECRET_KEY_BASE": "one\ntwo"})


unittest.main()
