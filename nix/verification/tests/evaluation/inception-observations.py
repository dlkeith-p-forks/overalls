"""Offer-anchored DNS evidence: no new lifetime from delay, replay or another boot."""

import base64
import copy
import importlib.util
import json
import os
import socket
import stat
import struct
import sys
import tempfile
import time
import unittest
from pathlib import Path
from typing import TypedDict

source = Path(sys.argv.pop(1))
spec = importlib.util.spec_from_file_location("runtime", source / "runtime.py")
if spec is None or spec.loader is None:
    raise RuntimeError("runtime helper unavailable")
runtime = importlib.util.module_from_spec(spec)
sys.modules["runtime"] = runtime
spec.loader.exec_module(runtime)
SetupError = runtime.SetupError
observations_spec = importlib.util.spec_from_file_location(
    "observations", source / "observations.py"
)
if observations_spec is None or observations_spec.loader is None:
    raise RuntimeError("observations helper unavailable")
observations = importlib.util.module_from_spec(observations_spec)
sys.modules["observations"] = observations
observations_spec.loader.exec_module(observations)

PROOF = base64.urlsafe_b64encode(bytes(32)).decode().rstrip("=")
ID = "11111111-1111-4111-8111-111111111111"


class Value(TypedDict):
    binding: dict[str, object]
    generation: int
    request_id: str
    public: dict[str, object]


class Evidence(TypedDict):
    request_id: str
    records: list[dict[str, object]]


class Query(TypedDict):
    version: int
    binding: dict[str, object]
    generation: int
    label: str
    proofs: list[str]


class QueryResult(TypedDict):
    version: int
    ttl_ms: int


class ObservationTest(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.shared = self.root / "shared"
        self.shared.mkdir(mode=0o750)
        self.shared.chmod(0o750)
        self.value: Value = {
            "binding": {"placement_id": ID, "execution_epoch": 1, "boot_challenge": "a" * 64},
            "generation": 1,
            "request_id": ID,
            "public": {},
        }
        self.reply = {"ttl_ms": 4000, "records": [{"label": "control", "proofs": [PROOF]}]}
        self.evidence: Evidence = {
            "request_id": ID,
            "records": [{"label": "control", "proofs": [PROOF], "ttl_ms": 3000}],
        }
        observations.remember(self.value, self.reply, self.root, 1000)

    def accept(
        self,
        evidence: dict[str, object] | None = None,
        current: int = 2000,
        value: dict[str, object] | None = None,
    ) -> None:
        value = dict(
            self.value if value is None else value,
            observations=self.evidence if evidence is None else evidence,
        )
        observations.accept(value, self.root, self.shared, current=current)

    def test_delay_cannot_extend_original_offer_or_observed_ttl(self) -> None:
        self.accept()
        path = self.shared / "current.json"
        result = json.loads(path.read_bytes())
        self.assertEqual(result["binding"], self.value["binding"])
        self.assertEqual(result["generation"], 1)
        self.assertEqual(
            result["records"], [{"label": "control", "proofs": [PROOF], "expires_at_ms": 4000}]
        )
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o640)
        self.assertEqual(path.stat().st_uid, os.getuid())
        self.assertEqual(path.stat().st_gid, self.shared.stat().st_gid)
        with self.assertRaises(FileNotFoundError):
            self.accept(current=2100)
        self.assertEqual(json.loads(path.read_bytes()), result)

    def test_elapsed_observation_does_not_gain_time_from_receipt(self) -> None:
        self.accept(current=4100)
        self.assertEqual(json.loads((self.shared / "current.json").read_bytes())["records"], [])

    def test_observation_cannot_outlive_shorter_source_publication(self) -> None:
        self.reply["ttl_ms"] = 1000
        observations.remember(self.value, self.reply, self.root, 1000)
        self.accept(current=1500)
        self.assertEqual(
            json.loads((self.shared / "current.json").read_bytes())["records"][0]["expires_at_ms"],
            2000,
        )

    def test_expired_offer_wrong_boot_generation_and_proof_fail_without_publication(self) -> None:
        for key, invalid in [
            ("generation", 2),
            ("binding", dict(self.value["binding"], execution_epoch=2)),
            ("public", None),
        ]:
            with self.subTest(key=key), self.assertRaises(SetupError):
                self.accept(value=dict(self.value, **{key: invalid}))
        for invalid in [
            dict(self.evidence, request_id="22222222-2222-4222-8222-222222222222"),
            dict(
                self.evidence,
                records=[
                    {
                        "label": "control",
                        "proofs": [base64.urlsafe_b64encode(b"x" * 32).decode().rstrip("=")],
                        "ttl_ms": 3000,
                    }
                ],
            ),
        ]:
            with self.assertRaises(SetupError):
                self.accept(invalid)
        with self.assertRaises(SetupError):
            self.accept(current=5000)
        self.assertFalse((self.shared / "current.json").exists())

    def test_untrusted_shared_directory_cannot_publish_and_consumes_offer(self) -> None:
        self.shared.chmod(0o770)
        with self.assertRaises(SetupError):
            self.accept()
        self.assertFalse((self.shared / "current.json").exists())
        self.assertFalse((self.root / "proof-offer.json").exists())

    def test_real_unix_peer_proof_query_uses_the_writer_clock(self) -> None:
        current = time.monotonic_ns() // 1000000
        observations.remember(self.value, self.reply, self.root, current)
        self.accept(current=current)
        server = observations.Server(os.getuid(), self.shared)
        self.addCleanup(server.close)
        request: Query = {
            "version": 1,
            "binding": self.value["binding"],
            "generation": 1,
            "label": "control",
            "proofs": [PROOF],
        }
        result = self.query(json.dumps(request).encode())
        self.assertEqual(result["version"], 1)
        self.assertTrue(1 <= result["ttl_ms"] <= 3000)
        wrong = copy.deepcopy(request)
        wrong["binding"]["execution_epoch"] = True
        self.assertEqual(self.query(json.dumps(wrong).encode())["ttl_ms"], 0)
        wrong = dict(request, generation=2)
        self.assertEqual(self.query(json.dumps(wrong).encode())["ttl_ms"], 0)
        duplicate = json.dumps(request).encode()[:-1] + b',"version":1}'
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as peer:
            peer.settimeout(1)
            peer.connect(str(self.shared / "verify.sock"))
            peer.sendall(struct.pack("!I", len(duplicate)) + duplicate)
            self.assertEqual(peer.recv(1), b"")

    def test_real_unix_query_bounds_stall_and_oversized_frame(self) -> None:
        server = observations.Server(os.getuid(), self.shared)
        self.addCleanup(server.close)
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as peer:
            peer.settimeout(1)
            peer.connect(str(self.shared / "verify.sock"))
            peer.sendall(struct.pack("!I", 2049))
            self.assertEqual(peer.recv(1), b"")
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as peer:
            peer.settimeout(1)
            peer.connect(str(self.shared / "verify.sock"))
            started = time.monotonic()
            self.assertEqual(peer.recv(1), b"")
            self.assertLess(time.monotonic() - started, 0.9)

    def test_real_unix_other_uid_is_refused(self) -> None:
        if os.getuid() == 0:
            self.skipTest("root is an explicitly authorized broker caller")
        server = observations.Server(os.getuid() + 1, self.shared)
        self.addCleanup(server.close)
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as peer:
            peer.settimeout(1)
            peer.connect(str(self.shared / "verify.sock"))
            self.assertEqual(peer.recv(1), b"")

    def query(self, body: bytes) -> QueryResult:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as peer:
            peer.settimeout(1)
            peer.connect(str(self.shared / "verify.sock"))
            peer.sendall(struct.pack("!I", len(body)) + body)
            header = peer.recv(4)
            self.assertEqual(len(header), 4)
            (size,) = struct.unpack("!I", header)
            self.assertLessEqual(size, 256)
            payload = b""
            while len(payload) < size:
                chunk = peer.recv(size - len(payload))
                self.assertTrue(chunk)
                payload += chunk
            return json.loads(payload)

    def test_closed_observation_bounds(self) -> None:
        for field, bad in [
            ("ttl_ms", True),
            ("ttl_ms", 0),
            ("ttl_ms", 5001),
            ("label", "other.example"),
            ("proofs", []),
            ("proofs", [PROOF, PROOF]),
            ("proofs", [PROOF + "="]),
            ("address", "192.0.2.1"),
        ]:
            value = copy.deepcopy(self.evidence)
            value["records"][0][field] = bad
            with self.subTest(field=field), self.assertRaises(SetupError):
                observations.validate(value)
        for count in [2, 17]:
            with self.assertRaises(SetupError):
                observations.validate(dict(self.evidence, records=self.evidence["records"] * count))


unittest.main()
