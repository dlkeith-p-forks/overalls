"""The workload must accept exactly the access fixture Marshall's operator writes."""

import base64
import json
import os
import secrets
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from uuid import uuid4

from access.fixture import read_access_fixture
from core.config import Config
from core.profile_readiness import access_smtp_ready

# antithesis/operator/fixture.ex sec1_der/1: a minimal P-256 SEC1 ECPrivateKey.
_SEC1_PREFIX = bytes((0x30, 0x31, 0x02, 0x01, 0x01, 0x04, 0x20))
_SEC1_SUFFIX = bytes((0xA0, 0x0A, 0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07))


def _encode(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def _actor(role: str, fixture_id: str) -> dict[str, object]:
    return {
        "id": str(uuid4()),
        "email": f"fixture-{role}-{fixture_id}@example.test",
        "authenticator": {
            "id": _encode(secrets.token_bytes(32)),
            "private_sec1_der": _encode(_SEC1_PREFIX + secrets.token_bytes(32) + _SEC1_SUFFIX),
        },
    }


def _operator_manifest(fixture_id: str) -> dict[str, object]:
    """Mirror the field set and encodings of fixture.ex create_fixture!/1."""
    return {
        "schema_version": 1,
        "fixture_id": fixture_id,
        "namespace": "github",
        "owner": "fixture",
        "name": "demo",
        "repository_id": str(uuid4()),
        "registered_by_id": str(uuid4()),
        "webauthn_origin": "https://marshall-a:4443",
        "webauthn_rp_id": "marshall-a",
        "admin_a": _actor("admin-a", fixture_id),
        "admin_b": _actor("admin-b", fixture_id),
        "target": _actor("target", fixture_id),
    }


def _config(directory: Path) -> Config:
    return Config(
        marshall_urls=("https://marshall-a:4443",),
        ca_file=directory / "ca.crt",
        fixture_manifest=directory / "fixture.json",
        db_host="pg",
        db_port=5432,
        db_user="oracle",
        db_name="marshall",
        db_password_file=directory / "db-password",
        timeout_seconds=1,
    )


class AccessFixtureTests(unittest.TestCase):
    def test_operator_manifest_is_accepted(self) -> None:
        fixture_id = secrets.token_hex(16)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "access.json"
            path.write_text(json.dumps(_operator_manifest(fixture_id)), encoding="utf-8")
            fixture = read_access_fixture(path)
        self.assertEqual(fixture.fixture_id, fixture_id)
        self.assertEqual(len(fixture.admin_a.authenticator.private_der), 51)

    def test_rejection_names_the_failed_check_without_values(self) -> None:
        fixture_id = secrets.token_hex(16)
        manifest = _operator_manifest(fixture_id)
        manifest["webauthn_rp_id"] = "other-host"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "access.json"
            path.write_text(json.dumps(manifest), encoding="utf-8")
            with (
                patch.dict(os.environ, {"ANTITHESIS_ACCESS_FIXTURE_FILE": str(path)}),
                self.assertLogs("core.profile_readiness", level="WARNING") as logs,
            ):
                self.assertFalse(access_smtp_ready(_config(Path(directory)), fixture_id))
        self.assertIn("(ValueError: invalid WebAuthn RP binding)", logs.output[0])
        self.assertNotIn(directory, logs.output[0])
        self.assertNotIn("other-host", logs.output[0])

    def test_unreviewed_error_text_is_not_echoed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "access.json"
            path.write_text("{not json secret-value", encoding="utf-8")
            with (
                patch.dict(os.environ, {"ANTITHESIS_ACCESS_FIXTURE_FILE": str(path)}),
                self.assertLogs("core.profile_readiness", level="WARNING") as logs,
            ):
                self.assertFalse(access_smtp_ready(_config(Path(directory)), "fixture-b"))
        self.assertIn("(JSONDecodeError)", logs.output[0])
        self.assertNotIn("secret-value", logs.output[0])


if __name__ == "__main__":
    unittest.main()
