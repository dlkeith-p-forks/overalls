"""Real cryptographic custody with simulated SSH observations and fault injection."""

import copy
import json
import os
import subprocess
import tempfile
import unittest
import uuid
from pathlib import Path
from types import SimpleNamespace
from typing import TypedDict
from unittest.mock import patch

import preparation as p  # ty: ignore[unresolved-import] # PYTHONPATH nix/packages/host


class ManifestUser(TypedDict, total=False):
    sshKeys: list[str]
    secretRecovery: bool


class ManifestDocument(TypedDict, total=False):
    path: str
    hosts: list[str]
    recoveryOnly: bool


class ManifestInventory(TypedDict):
    hosts: dict[str, ManifestUser]
    documents: dict[str, ManifestDocument]


class Manifest(TypedDict):
    users: dict[str, ManifestUser]
    inventory: ManifestInventory


class HostLilly(TypedDict, total=False):
    controlPlane: str
    egressInterface: str
    overheads: dict[str, int]
    credentialTtlSeconds: int | float | bool | str


class HostDeclaration(TypedDict):
    name: str
    platform: str
    firmware: str
    identity: dict[str, object]
    credentials: list[object]
    inventory: dict[str, object]
    storage: dict[str, object]
    budgets: dict[str, int]
    lilly: HostLilly


class Preparation(unittest.TestCase):
    def setUp(self) -> None:
        os.umask(0o077)
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.work = Path(temporary.name)
        self.root = self.work / "repo"
        (self.root / "fleet/hosts/example").mkdir(parents=True)
        (self.root / "secrets").mkdir()
        self.keys: dict[str, str] = {}
        for name in ("recovery", "host", "outsider"):
            key = self.work / name
            subprocess.run(
                ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)], check=True
            )
            self.keys[name] = key.with_suffix(".pub").read_text().strip()
        self.host: HostDeclaration = {
            "name": "example",
            "platform": "ec2",
            "firmware": "uefi",
            "identity": {"sshKeys": [], "hostId": "12345678"},
            "credentials": [],
            "inventory": {
                "arch": "x86_64",
                "disks": [{"id": "root", "size": 8000000}, {"id": "nvme", "size": 1000000}],
            },
            "storage": {"system": ["root"], "guests": ["nvme"], "quotaBytes": None, "ashift": 12},
            "budgets": {"guestMemoryMiB": 1024, "guestCpuCores": 1, "arcMaxMiB": 512},
            "lilly": {
                "controlPlane": "https://control.test",
                "egressInterface": "eth0",
                "overheads": {"cores": 1, "memoryBytes": 1000, "storageBytes": 100},
            },
        }
        self.path = self.root / "fleet/hosts/example/host.json"
        self.path.write_text(json.dumps(self.host))
        self.raw: Manifest = {
            "users": {"recovery": {"sshKeys": [self.keys["recovery"]], "secretRecovery": True}},
            "inventory": {
                "hosts": {},
                "documents": {
                    "git-bootstrap": {
                        "path": "secrets/git-bootstrap.enc.json",
                        "hosts": [],
                        "recoveryOnly": True,
                    }
                },
            },
        }
        _, _, documents = p.custody.policy(self.raw)
        with p.custody.identity(self.work / "recovery", self.work) as (env, _):
            sealed = p.seal(
                {"overalls-git": {"production": {"GIT_DEPLOY_KEY": "synthetic-key"}}},
                documents["git-bootstrap"]["recipients"],
                env,
            )
        (self.root / "secrets/git-bootstrap.enc.json").write_text(sealed)
        self.request = p.declaration_request(
            self.host, {"poolGuid": "1", "datasetGuid": "2"}, "sha256:" + "a" * 64
        )
        self.host_id = str(uuid.uuid4())
        self.pool_id = str(uuid.uuid4())
        self.operations: dict[str, dict[str, object]] = {}
        self.calls: list[str] = []
        self.args = SimpleNamespace(
            root=str(self.root),
            host="example",
            command="prepare-enrollment",
            marshall_target="root@marshall",
            recovery_key=str(self.work / "recovery"),
            ssh_port=2222,
            marshall_ssh_port=2223,
        )
        self.stack = __import__("contextlib").ExitStack()
        self.addCleanup(self.stack.close)
        self.stack.enter_context(
            patch.dict(os.environ, {"XDG_STATE_HOME": str(self.work / "state")})
        )
        self.stack.enter_context(patch.object(p.cli, "validate", side_effect=lambda h: h))
        self.stack.enter_context(
            patch.object(p, "observed_request", return_value=(self.request, self.keys["host"]))
        )
        self.stack.enter_context(
            patch.object(p, "manifest", side_effect=lambda _: copy.deepcopy(self.raw))
        )
        self.stack.enter_context(patch.object(p.cli, "ssh", side_effect=self.ssh))

    def ssh(self, args: SimpleNamespace, command: list[str], data: bytes, target: str) -> bytes:
        self.assertEqual(args.ssh_port, 2223)
        self.assertEqual(command, ["overalls-marshall-enrollment"])
        value = json.loads(data)
        operation = value["operation_id"]
        self.calls.append(operation)
        if operation not in self.operations:
            credential_id = str(uuid.uuid4())
            envelope: dict[str, object] = {
                "version": 1,
                "host_id": self.host_id,
                "credential_id": credential_id,
                "credential": credential_id + ":" + "x" * 43,
                "expires_at": "2031-09-16T00:00:00Z",
            }
            pool = {k: v for k, v in self.request["pools"][0].items() if k != "overhead_bytes"}
            pool.update(id=self.pool_id, filesystem_id="zfs:1:2")
            metadata: dict[str, object] = {
                k: envelope[k] for k in ("host_id", "credential_id", "expires_at")
            }
            metadata.update(
                operation_id=operation,
                name="example",
                machine_id=self.request["machine_id"],
                architecture="x86_64",
                transfer_endpoint=None,
                pools=[pool],
            )
            self.operations[operation] = {"envelope": envelope, "metadata": metadata}
        return json.dumps(self.operations[operation]).encode()

    def test_prepare_and_retry_protect_custody(self) -> None:
        p.prepare(self.args)
        host = json.loads(self.path.read_text())
        self.assertEqual(host["lilly"]["credentialTtlSeconds"], 157680000)
        self.assertEqual(host["lilly"]["binding"]["host_id"], self.host_id)
        self.assertEqual(
            set(host["lilly"]["binding"]["pools"][0]), {"id", "name", "filesystem_id", "storage"}
        )
        ciphertext = self.root / "secrets/example-lilly.enc.json"
        first = ciphertext.read_bytes()
        p.prepare(self.args)
        self.assertEqual(ciphertext.read_bytes(), first)
        self.assertEqual(self.calls[0], self.calls[1])
        for identity in ("recovery", "host"):
            with p.custody.identity(self.work / identity, self.work) as (env, _):
                value = json.loads(p.custody.decrypt(first, "json", env))
                self.assertIn("LILLY_CREDENTIAL", value["overalls-lilly"]["production"])
        with (
            p.custody.identity(self.work / "outsider", self.work) as (env, _),
            self.assertRaises(p.custody.Failure),
        ):
            p.custody.decrypt(first, "json", env)
        for path in self.root.rglob("*"):
            if path.is_file():
                self.assertNotIn(b"x" * 43, path.read_bytes())
        # Journal holds ciphertext and public metadata, never the issued token.
        for path in (self.work / "state").rglob("*.json"):
            self.assertNotIn(b"x" * 43, path.read_bytes())

    def test_partial_publication_recovers_same_operation(self) -> None:
        original = p.custody.publish
        count = 0

        def interrupted(*args: object) -> object:
            nonlocal count
            count += 1
            if count == 2:
                raise OSError("injected failure")
            return original(*args)

        with (
            patch.object(p.custody, "publish", side_effect=interrupted),
            self.assertRaises(OSError),
        ):
            p.prepare(self.args)
        p.prepare(self.args)
        self.assertEqual(len(set(self.calls)), 1)
        self.assertIn("binding", json.loads(self.path.read_text())["lilly"])

    def test_lost_response_and_encryption_failure_reuse_id(self) -> None:
        original = self.ssh

        def lost(args: SimpleNamespace, command: list[str], data: bytes, target: str) -> bytes:
            original(args, command, data, target)
            raise p.cli.Failure("lost reply")

        with (
            patch.object(p.cli, "ssh", side_effect=lost),
            self.assertRaises(p.cli.Failure),
        ):
            p.prepare(self.args)
        with (
            patch.object(p, "seal", side_effect=p.cli.Failure("encryption failed")),
            self.assertRaises(p.cli.Failure),
        ):
            p.prepare(self.args)
        p.prepare(self.args)
        self.assertEqual(len(set(self.calls)), 1)

    def test_recovery_failure_precedes_authority(self) -> None:
        self.args.recovery_key = str(self.work / "outsider")
        with self.assertRaises(p.cli.Failure):
            p.prepare(self.args)
        self.assertEqual(self.calls, [])

    def test_changed_file_is_never_overwritten(self) -> None:
        p.prepare(self.args)
        self.path.write_text(self.path.read_text() + "\n")
        with self.assertRaises(p.cli.Failure):
            p.prepare(self.args)

    def test_rotation_is_explicit_and_interrupted_retry_reuses_id(self) -> None:
        p.prepare(self.args)
        initial = self.calls[-1]
        self.args.command = "rotate-credential"
        with (
            patch.object(p, "seal", side_effect=p.cli.Failure("failure")),
            self.assertRaises(p.cli.Failure),
        ):
            p.prepare(self.args)
        rotation = self.calls[-1]
        self.assertNotEqual(initial, rotation)
        p.prepare(self.args)
        self.assertEqual(rotation, self.calls[-1])

    def test_unavailable_marshall_preserves_declaration(self) -> None:
        before = self.path.read_bytes()
        with (
            patch.object(p.cli, "ssh", side_effect=p.cli.Failure("unavailable")),
            self.assertRaises(p.cli.Failure),
        ):
            p.prepare(self.args)
        self.assertEqual(self.path.read_bytes(), before)
        self.assertFalse((self.root / "secrets/example-lilly.enc.json").exists())
        p.prepare(self.args)
        self.assertIn("binding", json.loads(self.path.read_bytes())["lilly"])

    def test_duplicate_host_recipient_precedes_authority(self) -> None:
        self.raw["inventory"]["hosts"]["another"] = {"sshKeys": [self.keys["host"]]}
        with self.assertRaises(p.cli.Failure):
            p.prepare(self.args)
        self.assertEqual(self.calls, [])

    def test_ttl_boundaries(self) -> None:
        for ttl in (1, 31536000, 157680000):
            host = copy.deepcopy(self.host)
            host["lilly"]["credentialTtlSeconds"] = ttl
            self.assertEqual(
                p.declaration_request(
                    host, {"poolGuid": "1", "datasetGuid": "2"}, "sha256:" + "a" * 64
                )["credential_ttl_seconds"],
                ttl,
            )
        for ttl in (0, -1, 157680001, True, 1.0, "157680000"):
            host = copy.deepcopy(self.host)
            host["lilly"]["credentialTtlSeconds"] = ttl
            with self.assertRaises(p.cli.Failure):
                p.declaration_request(
                    host, {"poolGuid": "1", "datasetGuid": "2"}, "sha256:" + "a" * 64
                )

    def test_request_pool_has_no_logical_budget(self) -> None:
        self.assertEqual(set(self.request["pools"][0]), {"name", "storage", "overhead_bytes"})

    def test_storage_headroom_stays_below_reviewed_guest_capacity(self) -> None:
        def request(host: HostDeclaration) -> object:
            return p.declaration_request(
                host, {"poolGuid": "1", "datasetGuid": "2"}, "sha256:" + "a" * 64
            )

        # EC2: the summed raw size of the dedicated local guest disks bounds headroom.
        for storage_bytes, accepted in ((0, True), (999999, True), (1000000, False)):
            host = copy.deepcopy(self.host)
            host["lilly"]["overheads"]["storageBytes"] = storage_bytes
            if accepted:
                request(host)
            else:
                with self.assertRaises(p.cli.Failure):
                    request(host)
        # Hetzner: the reviewed guest dataset quota bounds headroom.
        for storage_bytes, accepted in ((499, True), (500, False)):
            host = copy.deepcopy(self.host)
            host["platform"] = "hetzner"
            host["storage"] = {"system": ["root"], "guests": [], "quotaBytes": 500, "ashift": 12}
            host["lilly"]["overheads"]["storageBytes"] = storage_bytes
            if accepted:
                request(host)
            else:
                with self.assertRaises(p.cli.Failure):
                    request(host)
        host = copy.deepcopy(self.host)
        host["platform"] = "hetzner"
        host["storage"] = {"system": ["root"], "guests": [], "quotaBytes": None, "ashift": 12}
        with self.assertRaises(p.cli.Failure):
            request(host)


if __name__ == "__main__":
    unittest.main()
