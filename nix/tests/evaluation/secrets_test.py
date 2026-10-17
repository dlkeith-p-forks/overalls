"""Actual SOPS and runtime-generated synthetic identities; no private artifacts retained."""

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from collections.abc import Sequence
from pathlib import Path
from typing import TypedDict, cast
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("fleet_secrets", sys.argv.pop(1))
if spec is None or spec.loader is None:
    raise RuntimeError("fleet secrets helper unavailable")
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)


class ManifestUser(TypedDict, total=False):
    sshKeys: list[str]
    secretRecovery: bool
    login: bool


class ManifestHost(TypedDict):
    sshKeys: list[str]


class ManifestDocument(TypedDict, total=False):
    path: str
    hosts: list[str]
    recoveryOnly: bool | str | int


class ManifestInventory(TypedDict):
    hosts: dict[str, ManifestHost]
    documents: dict[str, ManifestDocument]


class Manifest(TypedDict):
    users: dict[str, ManifestUser]
    inventory: ManifestInventory


class Reconciliation(unittest.TestCase):
    def setUp(self) -> None:
        os.umask(0o077)
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.root = self.work / "repo"
        (self.root / "secrets").mkdir(parents=True)
        self.keys: dict[str, str] = {}
        for name in ("operator", "second", "host", "outsider"):
            path = self.work / name
            subprocess.run(
                ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(path)], check=True
            )
            self.keys[name] = path.with_suffix(".pub").read_text().strip()
        self.raw: Manifest = {
            "users": {"operator": {"sshKeys": [self.keys["operator"]], "secretRecovery": True}},
            "inventory": {
                "hosts": {"host": {"sshKeys": [self.keys["host"]]}},
                "documents": {"example": {"path": "secrets/example.enc.json", "hosts": ["host"]}},
            },
        }
        self.payload = json.dumps(
            {"overalls-example": {"production": {"TOKEN": "private-fixture"}}}
        ).encode()
        self.path = self.root / "secrets/example.enc.json"
        _, _, documents = cli.policy(self.raw)
        self.seal(self.path, documents["example"]["recipients"])

    def seal(self, path: Path, recipients: Sequence[str]) -> None:
        sealed = cli.run(
            [
                "sops",
                "--encrypt",
                "--age",
                ",".join(recipients),
                "--input-type",
                "json",
                "--output-type",
                "json",
                "/dev/stdin",
            ],
            self.payload,
            cli.clean_environment(self.work),
        )
        path.write_bytes(sealed)

    def decrypt_as(self, name: str, path: Path | None = None) -> object:
        with (
            tempfile.TemporaryDirectory(dir=self.work) as directory,
            cli.identity(self.work / name, Path(directory)) as (env, _),
        ):
            return json.loads(cli.decrypt((path or self.path).read_bytes(), "json", env))

    def rekey(self) -> None:
        _, recovery, documents = cli.policy(self.raw)
        with tempfile.TemporaryDirectory(dir=self.work) as directory:
            cli.reconcile(self.root, documents, recovery, self.work / "operator", Path(directory))

    def data_key(self, ciphertext: bytes) -> bytes:
        with (
            tempfile.TemporaryDirectory(dir=self.work) as directory,
            cli.identity(self.work / "operator", Path(directory)) as (env, recipient),
        ):
            entry = next(
                entry
                for entry in json.loads(ciphertext)["sops"]["age"]
                if entry["recipient"] == recipient
            )
            return cli.run(
                ["age", "--decrypt", "-i", env["SOPS_AGE_KEY_FILE"]], entry["enc"].encode(), env
            )

    def test_add_remove_and_idempotence(self) -> None:
        self.assertEqual(self.decrypt_as("host"), json.loads(self.payload))
        with self.assertRaises(cli.Failure):
            self.decrypt_as("second")
        self.raw["users"]["second"] = {"sshKeys": [self.keys["second"]], "secretRecovery": True}
        self.rekey()
        self.assertEqual(self.decrypt_as("second"), json.loads(self.payload))
        old = self.path.read_bytes()
        self.rekey()
        self.assertEqual(old, self.path.read_bytes())
        del self.raw["users"]["second"]
        self.rekey()
        self.assertNotEqual(old, self.path.read_bytes())
        self.assertTrue(
            self.data_key(old) != self.data_key(self.path.read_bytes()),
            "Recipient removal must replace the document data key",
        )
        with self.assertRaises(cli.Failure):
            self.decrypt_as("second")
        with self.assertRaises(cli.Failure):
            self.decrypt_as("outsider")
        self.assertEqual(self.decrypt_as("operator"), json.loads(self.payload))
        self.assertEqual(self.decrypt_as("host"), json.loads(self.payload))

    def test_all_preparation_precedes_publication(self) -> None:
        previous = self.path.read_bytes()
        self.raw["users"]["second"] = {"sshKeys": [self.keys["second"]], "secretRecovery": True}
        self.raw["inventory"]["documents"]["broken"] = {
            "path": "secrets/broken.enc.json",
            "hosts": ["host"],
        }
        (self.root / "secrets/broken.enc.json").write_text("invalid")
        with self.assertRaises(cli.Failure):
            self.rekey()
        self.assertEqual(previous, self.path.read_bytes())

    def test_recovery_only_cli_roundtrip_and_reconciliation(self) -> None:
        self.raw["inventory"]["hosts"] = {}
        self.raw["inventory"]["documents"]["example"].update(hosts=[], recoveryOnly=True)
        self.path.unlink()
        source = self.work / "recovery-input.json"
        source.write_bytes(self.payload)
        result = self.invoke("encrypt", "example", "--input", str(source))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.invoke("check").returncode, 0)
        self.assertEqual(self.decrypt_as("operator"), json.loads(self.payload))
        for name in ("host", "outsider"):
            with self.assertRaises(cli.Failure):
                self.decrypt_as(name)
        output = self.work / "recovery-output.json"
        result = self.invoke(
            "decrypt", "example", "--ssh-key", str(self.work / "operator"), "--output", str(output)
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(output.read_bytes()), json.loads(self.payload))
        self.assertEqual(output.stat().st_mode & 0o777, 0o600)
        self.raw["users"]["second"] = {"sshKeys": [self.keys["second"]], "secretRecovery": True}
        self.assertNotEqual(self.invoke("check").returncode, 0)
        result = self.invoke("rekey", "--ssh-key", str(self.work / "operator"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.invoke("check").returncode, 0)
        self.assertEqual(self.decrypt_as("second"), json.loads(self.payload))
        old = self.path.read_bytes()
        self.rekey()
        self.assertEqual(old, self.path.read_bytes())
        del self.raw["users"]["second"]
        self.rekey()
        self.assertNotEqual(self.data_key(old), self.data_key(self.path.read_bytes()))
        with self.assertRaises(cli.Failure):
            self.decrypt_as("second")
        self.assertEqual(self.decrypt_as("operator"), json.loads(self.payload))

    def test_recovery_only_rejects_implicit_or_conflicting_policy(self) -> None:
        document = self.raw["inventory"]["documents"]["example"]
        for hosts, flag in (([], None), ([], False), ([], "true"), (["host"], True), ([], 1)):
            with self.subTest(hosts=hosts, flag=flag):
                document.update(hosts=hosts)
                document.pop("recoveryOnly", None)
                if flag is not None:
                    document["recoveryOnly"] = flag
                with self.assertRaises(cli.Failure):
                    cli.policy(self.raw)
        document.update(hosts=[], recoveryOnly=True)
        self.raw["users"]["operator"]["secretRecovery"] = False
        with self.assertRaises(cli.Failure):
            cli.policy(self.raw)

    def test_recovery_only_is_staged_with_host_documents(self) -> None:
        recovery_path = self.root / "secrets/recovery.enc.json"
        self.raw["inventory"]["documents"]["recovery"] = {
            "path": "secrets/recovery.enc.json",
            "hosts": [],
            "recoveryOnly": True,
        }
        self.raw["inventory"]["documents"] = {
            "recovery": self.raw["inventory"]["documents"]["recovery"],
            "example": self.raw["inventory"]["documents"]["example"],
        }
        _, _, documents = cli.policy(self.raw)
        self.seal(recovery_path, documents["recovery"]["recipients"])
        previous = recovery_path.read_bytes()
        self.raw["users"]["second"] = {"sshKeys": [self.keys["second"]], "secretRecovery": True}
        self.path.write_text("invalid")
        with self.assertRaises(cli.Failure):
            self.rekey()
        self.assertEqual(previous, recovery_path.read_bytes())
        self.seal(self.path, documents["example"]["recipients"])
        self.rekey()
        self.assertEqual(self.decrypt_as("second"), json.loads(self.payload))
        self.assertEqual(self.decrypt_as("second", recovery_path), json.loads(self.payload))
        with self.assertRaises(cli.Failure):
            self.decrypt_as("host", recovery_path)

    def test_login_does_not_imply_recovery(self) -> None:
        self.raw["users"]["outsider"] = {"sshKeys": [self.keys["outsider"]], "login": True}
        _, recovery, documents = cli.policy(self.raw)
        outsider = cli.public_recipient(self.keys["outsider"])
        self.assertNotIn(outsider, recovery)
        self.assertNotIn(outsider, documents["example"]["recipients"])

    def test_invalid_inventory_and_keys(self) -> None:
        for key in ("ssh-rsa invalid", "ssh-ed25519 invalid", "ssh-ed25519 " + "A" * 68):
            with self.assertRaises(cli.Failure):
                cli.public_recipient(key)
        for path in (
            "/tmp/secret.enc.json",
            "secrets/../secret.enc.json",
            "secrets//secret.enc.json",
        ):
            self.raw["inventory"]["documents"]["example"]["path"] = path
            with self.assertRaises(cli.Failure):
                cli.policy(self.raw)
        self.raw["inventory"]["documents"]["example"] = {
            "path": "secrets/example.enc.json",
            "hosts": ["missing"],
        }
        with self.assertRaises(cli.Failure):
            cli.policy(self.raw)

    def test_symlink_and_concurrent_write_rejection(self) -> None:
        linked = self.root / "secrets/link.enc.json"
        linked.symlink_to(self.path)
        with self.assertRaises(cli.Failure):
            cli.document_path(self.root, "secrets/link.enc.json")
        with self.assertRaises(cli.Failure):
            cli.publish(self.path, b"replacement", b"stale")
        with self.assertRaises(cli.Failure):
            cli.publish(self.path, b"replacement", None)

    def test_private_identity_cleanup(self) -> None:
        directory = self.work / "identity-test"
        directory.mkdir()
        with self.assertRaises(RuntimeError), cli.identity(self.work / "operator", directory):
            raise RuntimeError("interrupted")
        self.assertEqual(list(directory.iterdir()), [])

    def test_removed_operator_cannot_reconcile(self) -> None:
        old = self.path.read_bytes()
        self.raw["users"] = {"second": {"sshKeys": [self.keys["second"]], "secretRecovery": True}}
        with self.assertRaisesRegex(cli.Failure, "retained recovery identity"):
            self.rekey()
        self.assertEqual(old, self.path.read_bytes())

    def test_partial_publication_is_rerunnable(self) -> None:
        second_path = self.root / "secrets/second.enc.json"
        second_path.write_bytes(self.path.read_bytes())
        self.raw["inventory"]["documents"]["second"] = {
            "path": "secrets/second.enc.json",
            "hosts": ["host"],
        }
        self.raw["users"]["second"] = {"sshKeys": [self.keys["second"]], "secretRecovery": True}
        publish = cli.publish

        def interrupted(path: Path, data: bytes, original: bytes | None) -> None:
            if path == second_path:
                raise OSError("synthetic publication interruption")
            publish(path, data, original)

        with (
            patch.object(cli, "publish", interrupted),
            self.assertRaisesRegex(
                cli.Failure, "completed documents: example; possibly updated document: second"
            ),
        ):
            self.rekey()
        self.assertEqual(self.decrypt_as("second"), json.loads(self.payload))
        with self.assertRaises(cli.Failure):
            self.decrypt_as("second", second_path)
        self.rekey()
        self.assertEqual(self.decrypt_as("second", second_path), json.loads(self.payload))

    def invoke(self, *args: str) -> subprocess.CompletedProcess[bytes]:
        manifest = self.work / "manifest.json"
        manifest.write_text(json.dumps(self.raw))
        return subprocess.run(
            [
                sys.executable,
                cast(str, cli.__file__),  # loaded from the argv[1] file path
                "--manifest",
                str(manifest),
                *args,
                "--root",
                str(self.root),
            ],
            capture_output=True,
        )

    def test_cli_roundtrip_and_private_output_policy(self) -> None:
        self.path.unlink()
        source = self.work / "plaintext.json"
        source.write_bytes(self.payload)
        result = self.invoke("encrypt", "example", "--input", str(source))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.invoke("check").returncode, 0)
        destination = self.work / "recovered.json"
        result = self.invoke(
            "decrypt",
            "example",
            "--ssh-key",
            str(self.work / "operator"),
            "--output",
            str(destination),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(destination.read_bytes()), json.loads(self.payload))
        self.assertEqual(destination.stat().st_mode & 0o777, 0o600)
        result = self.invoke(
            "decrypt",
            "example",
            "--ssh-key",
            str(self.work / "operator"),
            "--output",
            str(self.root / "plaintext.json"),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "plaintext.json").exists())
        result = self.invoke(
            "decrypt",
            "example",
            "--ssh-key",
            str(self.work / "outsider"),
            "--output",
            str(self.work / "bad.json"),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(b"private-fixture", result.stdout + result.stderr)
        self.assertNotIn(b"Traceback", result.stderr)
        inside = self.root / "identity"
        inside.write_bytes((self.work / "operator").read_bytes())
        result = self.invoke("rekey", "--ssh-key", str(inside))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"outside the repository", result.stderr)

    def test_encrypt_requires_explicit_atomic_replacement(self) -> None:
        previous = self.path.read_bytes()
        replacement = self.work / "replacement.json"
        replacement_payload = {
            "overalls-example": {"production": {"TOKEN": "rotated-private-fixture"}}
        }
        replacement.write_text(json.dumps(replacement_payload))

        result = self.invoke("encrypt", "example", "--input", str(replacement))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.path.read_bytes(), previous)

        result = self.invoke("encrypt", "example", "--input", str(replacement), "--replace")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.decrypt_as("operator"), replacement_payload)
        self.assertNotEqual(self.data_key(previous), self.data_key(self.path.read_bytes()))

    def test_yaml_rotation(self) -> None:
        path = self.root / "secrets/example.enc.yaml"
        _, _, documents = cli.policy(self.raw)
        path.write_bytes(
            cli.run(
                [
                    "sops",
                    "--encrypt",
                    "--age",
                    ",".join(documents["example"]["recipients"]),
                    "--input-type",
                    "yaml",
                    "--output-type",
                    "yaml",
                    "/dev/stdin",
                ],
                b"overalls-example:\n  production:\n    TOKEN: private-fixture\n",
                cli.clean_environment(self.work),
            )
        )
        self.raw["inventory"]["documents"]["example"]["path"] = "secrets/example.enc.yaml"
        self.raw["users"]["second"] = {"sshKeys": [self.keys["second"]], "secretRecovery": True}
        self.rekey()
        self.assertIn(
            cli.public_recipient(self.keys["second"]), cli.metadata(path.read_bytes(), "yaml")
        )


if __name__ == "__main__":
    unittest.main()
