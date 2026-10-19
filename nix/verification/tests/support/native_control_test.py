"""Exercise the isolated authority's real TLS/signing and closed wire boundary."""

from __future__ import annotations

import json
import socket
import ssl
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

import native_control as control


class ArtifactStreamFailureTest(unittest.TestCase):
    def test_closed_categories_do_not_include_exception_text(self) -> None:
        cases: tuple[
            tuple[OSError | ValueError | subprocess.SubprocessError, control.ArtifactStreamFailure],
            ...,
        ] = (
            (TimeoutError("sensitive"), control.ArtifactStreamFailure.TIMEOUT),
            (ssl.SSLError("sensitive"), control.ArtifactStreamFailure.TLS),
            (BrokenPipeError("sensitive"), control.ArtifactStreamFailure.PEER),
            (ConnectionResetError("sensitive"), control.ArtifactStreamFailure.PEER),
            (OSError("sensitive"), control.ArtifactStreamFailure.OS),
            (ValueError("sensitive"), control.ArtifactStreamFailure.INVALID),
            (subprocess.SubprocessError("sensitive"), control.ArtifactStreamFailure.PROCESS),
        )
        for error, expected in cases:
            with self.subTest(category=expected):
                self.assertEqual(control.artifact_stream_failure(error), expected)
                self.assertNotIn("sensitive", expected.value)


class AuthorityTest(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory(prefix="native-control-test-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.ca = self.root / "ssh-ca"
        self.user = self.root / "user"
        for path in (self.ca, self.user):
            subprocess.run(
                ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "", "-f", str(path)],
                check=True,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=5,
            )
        self.public = self.user.with_suffix(".pub").read_text().strip()
        self.receipt = self.root / "receipt.json"
        self.authority = control.Authority(
            control.Config(
                self.ca,
                "native.fixture.test",
                frozenset({"127.0.0.1"}),
                self.public,
                execution_probe=True,
                receipt=self.receipt,
            )
        )

    def rpc(self, path: str, body: object, *, ssh: bool = False) -> dict[str, object]:
        return self.authority.dispatch(
            "POST",
            "ssh.integration.internal" if ssh else "llm.internal",
            path,
            json.dumps(body).encode(),
        )

    def register(self) -> dict[str, object]:
        registration = self.rpc(
            "/agent/v1/register",
            {
                "digest": "a" * 64,
                "capabilities": ["context-v1", "skills-v1"],
            },
        )
        return {name: registration[name] for name in ("executor_id", "fence_epoch")}

    def transition(
        self, lease: dict[str, object], identifier: str, status: str, result: object
    ) -> dict[str, object]:
        return self.rpc(
            "/agent/v1/transition",
            {**lease, "command_id": identifier, "status": status, "result": result},
        )

    def start_withdrawal(self) -> dict[str, object]:
        lease = self.register()
        self.rpc("/agent/v1/claim", lease)
        self.transition(lease, control.COMMAND_ID, "started", {})
        self.transition(
            lease,
            control.COMMAND_ID,
            "completed",
            {"exit_code": 0, "stdout": control.PROOF, "stderr": ""},
        )
        self.authority.arm_withdrawal()
        self.rpc("/agent/v1/claim", lease)
        self.transition(lease, control.WITHDRAW_COMMAND_ID, "started", {})
        return lease

    def reject_heartbeat(self, lease: dict[str, object]) -> control.Fence:
        self.authority.request_withdrawal()
        with self.assertRaises(control.Withdrawn) as rejected:
            self.rpc("/agent/v1/heartbeat", lease)
        return rejected.exception.fence

    def test_long_command_requires_explicit_runner_gate_after_fixed_completion(self) -> None:
        with self.assertRaises(control.Refused):
            self.authority.arm_withdrawal()
        lease = self.register()
        self.rpc("/agent/v1/claim", lease)
        self.assertEqual(self.rpc("/agent/v1/claim", lease), {"command": None})
        with self.assertRaises(control.Refused):
            self.authority.request_withdrawal()
        self.transition(lease, control.COMMAND_ID, "started", {})
        self.transition(
            lease,
            control.COMMAND_ID,
            "completed",
            {"exit_code": 0, "stdout": control.PROOF, "stderr": ""},
        )
        self.assertEqual(self.rpc("/agent/v1/claim", lease), {"command": None})
        self.authority.arm_withdrawal()
        with self.assertRaises(control.Refused):
            self.authority.arm_withdrawal()
        claimed = control.object_value(self.rpc("/agent/v1/claim", lease)["command"])
        self.assertEqual(claimed["id"], control.WITHDRAW_COMMAND_ID)
        self.assertEqual(self.rpc("/agent/v1/claim", lease), {"command": None})
        with self.assertRaises(control.Refused):
            self.authority.request_withdrawal()

    def test_matching_heartbeat_requires_actual_response_ack_and_fresh_fence(self) -> None:
        with patch.object(control.time, "monotonic", return_value=100.0):
            old = self.start_withdrawal()
            self.authority.request_withdrawal()
            with self.assertRaises(control.Refused):
                self.rpc("/agent/v1/heartbeat", {**old, "fence_epoch": True})
            self.assertEqual(self.authority.snapshot().phase, control.WithdrawalPhase.REQUESTED)
            self.assertEqual(self.authority.count("withdrawal_heartbeat_403"), 0)
            with self.assertRaises(control.Withdrawn) as rejected:
                self.rpc("/agent/v1/heartbeat", old)
            self.assertEqual(self.authority.snapshot().phase, control.WithdrawalPhase.REVOKED)
            with self.assertRaises(control.Refused):
                self.authority.confirm_group_dead()
            with self.assertRaises(control.Refused):
                self.authority.heartbeat_refusal_sent(control.Fence("foreign", 1))
            self.authority.heartbeat_refusal_sent(rejected.exception.fence)
            new = self.register()
            self.assertEqual(self.rpc("/agent/v1/claim", new), {"command": None})
            with self.assertRaises(control.Refused):
                self.rpc("/agent/v1/heartbeat", old)
            self.authority.confirm_group_dead()
            claimed = control.object_value(self.rpc("/agent/v1/claim", new)["command"])
            self.assertEqual(claimed["id"], control.RECOVERY_COMMAND_ID)
            self.assertNotEqual(old["executor_id"], new["executor_id"])
            self.assertEqual(
                self.authority.snapshot().phase, control.WithdrawalPhase.RECOVERY_CLAIMED
            )
            with self.assertRaises(control.Refused):
                self.transition(
                    new,
                    control.RECOVERY_COMMAND_ID,
                    "completed",
                    {"exit_code": 0, "stdout": control.RECOVERY_PROOF, "stderr": ""},
                )
            self.transition(new, control.RECOVERY_COMMAND_ID, "started", {})
            for result in (
                {"exit_code": False, "stdout": control.RECOVERY_PROOF, "stderr": ""},
                {"exit_code": 0, "stdout": control.PROOF, "stderr": ""},
            ):
                with self.assertRaises(control.Refused):
                    self.transition(new, control.RECOVERY_COMMAND_ID, "completed", result)
            self.transition(
                new,
                control.RECOVERY_COMMAND_ID,
                "completed",
                {"exit_code": 0, "stdout": control.RECOVERY_PROOF, "stderr": ""},
            )
            self.assertEqual(self.authority.snapshot().phase, control.WithdrawalPhase.COMPLETE)
            receipt = self.receipt.read_text()
            for sensitive in (
                str(old["executor_id"]),
                str(new["executor_id"]),
                control.WITHDRAW_COMMAND_ID,
                control.RECOVERY_COMMAND_ID,
                control.RECOVERY_PROOF,
                control.LEASE_PROBE_COMMAND,
            ):
                self.assertNotIn(sensitive, receipt)

    def test_every_cancelled_result_attempt_counts_before_lease_and_shape_refusal(self) -> None:
        old = self.start_withdrawal()
        fence = self.reject_heartbeat(old)
        self.authority.heartbeat_refusal_sent(fence)
        for index, change in enumerate(
            (
                {"status": "completed"},
                {"status": "failed", "executor_id": "foreign"},
                {"status": "completed", "fence_epoch": True},
                {"status": "failed", "extra": 1},
                {"status": "started", "result": {"unexpected": True}},
            ),
            1,
        ):
            with self.assertRaises(control.Refused):
                self.rpc(
                    "/agent/v1/transition",
                    {
                        **old,
                        "command_id": control.WITHDRAW_COMMAND_ID,
                        "status": "completed",
                        "result": {},
                        **change,
                    },
                )
            self.assertEqual(self.authority.snapshot().terminal_attempts, index)
        with self.assertRaises(control.Refused):
            self.authority.confirm_group_dead()

    def test_group_death_at_command_start_plus_fifteen_seconds_refuses(self) -> None:
        with patch.object(control.time, "monotonic", return_value=100.0):
            old = self.start_withdrawal()
            fence = self.reject_heartbeat(old)
            self.authority.heartbeat_refusal_sent(fence)
        for now in (99.0, 115.0, 120.0):
            with (
                patch.object(control.time, "monotonic", return_value=now),
                self.assertRaises(control.Refused),
            ):
                self.authority.confirm_group_dead()
        with patch.object(control.time, "monotonic", return_value=114.999):
            self.authority.confirm_group_dead()
        elapsed = self.authority.snapshot().death_elapsed_ms
        if elapsed is None:
            self.fail("group death must record a closed elapsed duration")
        self.assertGreaterEqual(elapsed, 14900)
        self.assertLess(elapsed, 15000)

    def test_higher_epoch_with_reused_executor_identity_cannot_receive_fresh_proof(self) -> None:
        old = self.start_withdrawal()
        fence = self.reject_heartbeat(old)
        self.authority.heartbeat_refusal_sent(fence)
        self.authority.confirm_group_dead()
        with patch.object(control.uuid, "uuid4", return_value=control.uuid.UUID(fence.executor_id)):
            reused = self.register()
        self.assertEqual(self.rpc("/agent/v1/claim", reused), {"command": None})
        new = self.register()
        self.assertIsNotNone(self.rpc("/agent/v1/claim", new)["command"])

    def test_concurrent_claims_issue_one_ordinary_command(self) -> None:
        lease = self.register()
        barrier = threading.Barrier(3)
        claimed: list[bool] = []

        def claim() -> None:
            barrier.wait(timeout=3)
            claimed.append(self.rpc("/agent/v1/claim", lease)["command"] is not None)

        threads = [threading.Thread(target=claim) for _ in range(2)]
        for thread in threads:
            thread.start()
        barrier.wait(timeout=3)
        for thread in threads:
            thread.join(timeout=3)
            self.assertFalse(thread.is_alive())
        self.assertEqual(sorted(claimed), [False, True])

    def test_real_host_certificate_and_exact_roster(self) -> None:
        roster = self.authority.dispatch("GET", "ssh.integration.internal", "/ssh/v1/roster", b"")
        self.assertEqual(
            roster, {"version": 1, "accounts": [{"username": "u200000", "uid": 200000}]}
        )
        signed = self.rpc("/ssh/v1/host-certificate", {"public_key": self.public}, ssh=True)
        certificate = signed["certificate"]
        self.assertIsInstance(certificate, str)
        if not isinstance(certificate, str):
            self.fail("certificate must be text")
        leaf = self.root / "host-cert.pub"
        leaf.write_text(certificate)
        report = subprocess.run(
            ["ssh-keygen", "-L", "-f", str(leaf)],
            check=True,
            capture_output=True,
            text=True,
            timeout=5,
        ).stdout
        fingerprint = subprocess.run(
            ["ssh-keygen", "-lf", str(self.ca.with_suffix(".pub"))],
            check=True,
            capture_output=True,
            text=True,
            timeout=5,
        ).stdout.split()[1]
        self.assertIn("host certificate", report)
        self.assertIn("native.fixture.test", report)
        self.assertIn(fingerprint, report)
        self.assertEqual(signed["ca"], self.ca.with_suffix(".pub").read_text().strip())
        self.assertEqual(
            self.rpc(
                "/ssh/v1/authorize",
                {
                    "username": "u200000",
                    "public_key": self.public,
                },
                ssh=True,
            ),
            {"public_key": self.public},
        )

    def test_execution_order_exact_result_and_receipt(self) -> None:
        lease = self.register()
        self.assertIsNotNone(self.rpc("/agent/v1/claim", lease)["command"])
        self.assertEqual(self.rpc("/agent/v1/claim", lease), {"command": None})
        transition = {
            **lease,
            "command_id": control.COMMAND_ID,
            "status": "completed",
            "result": {"exit_code": 0, "stdout": control.PROOF, "stderr": ""},
        }
        with self.assertRaises(control.Refused):
            self.rpc("/agent/v1/transition", transition)
        self.rpc("/agent/v1/transition", {**transition, "status": "started", "result": {}})
        with self.assertRaises(control.Refused):
            self.rpc(
                "/agent/v1/transition",
                {
                    **transition,
                    "result": {
                        "exit_code": False,
                        "stdout": control.PROOF,
                        "stderr": "",
                    },
                },
            )
        self.rpc("/agent/v1/transition", transition)
        with self.assertRaises(control.Refused):
            self.rpc("/agent/v1/transition", transition)
        receipt = self.receipt.read_text()
        self.assertIn('"execution_completed": true', receipt)
        self.assertIn('"native_admission": false', receipt)
        for sensitive in (
            self.public,
            control.PROOF,
            str(lease["executor_id"]),
            control.COMMAND_ID,
        ):
            self.assertNotIn(sensitive, receipt)

    def test_login_refusal_does_not_turn_key_authorization_into_login_authority(self) -> None:
        self.authority.set_login_allowed(False)
        identity = {"username": "u200000", "public_key": self.public}
        self.assertEqual(
            self.rpc("/ssh/v1/authorize", identity, ssh=True), {"public_key": self.public}
        )
        with self.assertRaisesRegex(control.Refused, "login refused"):
            self.rpc("/ssh/v1/login", identity, ssh=True)
        self.assertNotIn("login", self.authority.counters)
        self.assertEqual(self.authority.counters["login_refused"], 1)

    def test_stale_foreign_expired_and_restarted_execution_refused(self) -> None:
        old = self.register()
        self.rpc("/agent/v1/claim", old)
        new = self.register()
        for lease in (old, {**new, "executor_id": "foreign"}, {**new, "fence_epoch": True}):
            with self.assertRaises(control.Refused):
                self.rpc("/agent/v1/heartbeat", lease)
        with self.assertRaises(control.Refused):
            self.rpc(
                "/agent/v1/transition",
                {**new, "command_id": control.COMMAND_ID, "status": "started", "result": {}},
            )
        self.authority.lease_deadline = time.monotonic() - 1
        with self.assertRaises(control.Refused):
            self.rpc("/agent/v1/claim", new)

    def test_unknown_fields_hosts_and_keys_refused(self) -> None:
        for body in (
            b'{"public_key":"a","public_key":"b"}',
            b"[]",
            b'{"public_key":null}',
            json.dumps({"public_key": self.public, "extra": 1}).encode(),
        ):
            with self.assertRaises(control.Refused):
                self.authority.dispatch(
                    "POST", "ssh.integration.internal", "/ssh/v1/host-certificate", body
                )
        for public in (
            self.public + " comment",
            "ssh-ed25519 AAAA",
            self.public.replace("ssh-ed25519", "ssh-rsa"),
        ):
            with self.assertRaises(control.Refused):
                control.key(public)
        for host in (
            "foreign.internal",
            "ssh.integration.internal:443",
            "SSH.integration.internal",
        ):
            with self.assertRaises(control.Refused):
                self.authority.dispatch("GET", host, "/ssh/v1/roster", b"")

    def test_transport_metrics_keep_concurrent_gauges_and_closed_overlap_counts(self) -> None:
        entered = threading.Barrier(9, timeout=3)
        finished = threading.Barrier(9, timeout=3)

        def handler() -> None:
            self.authority.transport(control.TransportEvent.HANDLER_OPEN)
            entered.wait()
            finished.wait()
            self.authority.transport(control.TransportEvent.HANDLER_CLOSE)

        threads = [threading.Thread(target=handler) for _ in range(8)]
        for thread in threads:
            thread.start()
        entered.wait()
        self.assertEqual(self.authority.count("transport_handlers_active"), 8)
        self.assertEqual(self.authority.count("transport_handlers_highwater"), 8)
        self.authority.transport(control.TransportEvent.ARTIFACT_OPEN)
        self.authority.transport(control.TransportEvent.HEARTBEAT_HEADERS)
        self.authority.transport(control.TransportEvent.HEARTBEAT_RESPONSE)
        self.authority.transport(control.TransportEvent.ARTIFACT_CLOSE)
        self.authority.transport(control.TransportEvent.HEARTBEAT_HEADERS)
        self.assertEqual(self.authority.count("transport_heartbeat_headers"), 2)
        self.assertEqual(self.authority.count("transport_heartbeat_headers_during_artifact"), 1)
        self.assertEqual(self.authority.count("transport_heartbeat_response_during_artifact"), 1)
        finished.wait()
        for thread in threads:
            thread.join(timeout=3)
            self.assertFalse(thread.is_alive())
        self.assertEqual(self.authority.count("transport_handlers_active"), 0)
        self.assertEqual(self.authority.count("transport_artifacts_active"), 0)
        self.assertEqual(self.authority.count("transport_artifacts_highwater"), 1)

    def test_tls_verifies_hostname_and_refuses_foreign_roots(self) -> None:
        cert, private = self.root / "tls.pem", self.root / "tls.key"
        subprocess.run(
            [
                "openssl",
                "req",
                "-x509",
                "-newkey",
                "rsa:2048",
                "-nodes",
                "-days",
                "1",
                "-subj",
                "/CN=ssh.integration.internal",
                "-addext",
                "subjectAltName=DNS:ssh.integration.internal,DNS:llm.internal",
                "-keyout",
                str(private),
                "-out",
                str(cert),
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=10,
        )
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, private)
        with control.Server(("127.0.0.1", 0), context, self.authority) as server:
            address = ("127.0.0.1", server.server_address[1])
            thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01})
            thread.start()
            try:
                trusted = ssl.create_default_context(cafile=cert)
                with (
                    socket.create_connection(address, timeout=3) as raw,
                    trusted.wrap_socket(raw, server_hostname="ssh.integration.internal") as stream,
                ):
                    stream.sendall(
                        b"GET /ssh/v1/roster HTTP/1.1\r\nHost: ssh.integration.internal\r\n\r\n"
                    )
                    response = bytearray()
                    while part := stream.recv(4096):
                        response.extend(part)
                self.assertIn(b"200 OK", response)
                self.assertIn(b'"username": "u200000"', response)
                lease = self.start_withdrawal()
                self.authority.request_withdrawal()
                payload = json.dumps(lease).encode()
                with (
                    socket.create_connection(address, timeout=3) as stalled_raw,
                    trusted.wrap_socket(stalled_raw, server_hostname="llm.internal") as stalled,
                    socket.create_connection(address, timeout=1) as raw,
                    trusted.wrap_socket(raw, server_hostname="llm.internal") as stream,
                ):
                    # A verified peer blocked mid-request must not prevent an
                    # independent lease RPC (as a streaming artifact once did).
                    stalled.sendall(b"POST /agent/v1/heartbeat HTTP/1.1\r\n")
                    stream.sendall(
                        b"POST /agent/v1/heartbeat HTTP/1.1\r\nHost: llm.internal\r\nContent-Length: "
                        + str(len(payload)).encode()
                        + b"\r\n\r\n"
                        + payload
                    )
                    response = bytearray()
                    while part := stream.recv(4096):
                        response.extend(part)
                self.assertIn(b"403 Forbidden", response)
                self.assertEqual(self.authority.count("withdrawal_heartbeat_403"), 1)
                self.assertEqual(self.authority.count("heartbeat_response_sent"), 1)
                self.assertEqual(self.authority.count("heartbeat_response_failed"), 0)
                self.assertEqual(self.authority.count("transport_heartbeat_headers"), 1)
                self.assertEqual(self.authority.count("transport_heartbeat_response"), 1)
                self.assertGreaterEqual(self.authority.count("transport_handlers_highwater"), 2)
                self.assertEqual(self.authority.count("transport_handshake_succeeded"), 3)
                self.assertEqual(self.authority.snapshot().phase, control.WithdrawalPhase.REJECTED)
                for context, hostname in (
                    (trusted, "foreign.internal"),
                    (ssl.create_default_context(), "ssh.integration.internal"),
                ):
                    with (
                        socket.create_connection(address, timeout=3) as raw,
                        self.assertRaises(ssl.SSLCertVerificationError),
                    ):
                        context.wrap_socket(raw, server_hostname=hostname)
            finally:
                server.shutdown()
                thread.join(timeout=5)
                self.assertFalse(thread.is_alive())


class ParserTest(unittest.TestCase):
    def parse(self, payload: bytes) -> tuple[str, str, str, bytes]:
        left, right = socket.socketpair()
        with left, right:
            left.sendall(payload)
            left.shutdown(socket.SHUT_WR)
            return control.request(right)

    def test_framing_bounds_duplicates_chunking_and_pipelining_refused(self) -> None:
        for payload in (
            b"POST / HTTP/1.1\r\nHost: llm.internal\r\nContent-Length: 16385\r\n\r\n",
            b"POST / HTTP/1.1\r\nHost: llm.internal\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
            b"GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n",
            b"GET / HTTP/1.1\r\nHost: a\r\n\r\nGET / HTTP/1.1\r\n\r\n",
            b"GET / HTTP/1.1\r\nHost: " + b"a" * 8192,
            b"POST / HTTP/1.1\r\nContent-Length: 2\r\n\r\nx",
        ):
            with self.assertRaises(control.Refused):
                self.parse(payload)

    def test_one_absolute_deadline_applies_to_partial_header(self) -> None:
        left, right = socket.socketpair()
        with left, right, patch.object(control, "DEADLINE", 0.05):
            left.sendall(b"GET / HTTP/1.1\r\n")
            start = time.monotonic()
            with self.assertRaises(TimeoutError):
                control.request(right)
            self.assertLess(time.monotonic() - start, 1)


if __name__ == "__main__":
    unittest.main()
