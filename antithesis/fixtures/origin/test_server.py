"""Socket tests for real Git fetches and independently retained receipts."""

from __future__ import annotations

import http.client
import http.server
import json
import os
import socket
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path
from sys import executable

from origin.server import MAX_RECEIPTS, AdminHandler, OriginHandler, State


class OriginTest(unittest.TestCase):
    temporary: tempfile.TemporaryDirectory[str]
    state: State
    admin: http.server.ThreadingHTTPServer
    origin: http.server.ThreadingHTTPServer

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.state = State(Path(self.temporary.name))
        AdminHandler.state = self.state
        OriginHandler.state = self.state
        self.admin = http.server.ThreadingHTTPServer(("127.0.0.1", 0), AdminHandler)
        self.origin = http.server.ThreadingHTTPServer(("127.0.0.1", 0), OriginHandler)
        threading.Thread(target=self.admin.serve_forever, daemon=True).start()
        threading.Thread(target=self.origin.serve_forever, daemon=True).start()

    def tearDown(self) -> None:
        self.admin.shutdown()
        self.origin.shutdown()
        self.admin.server_close()
        self.origin.server_close()
        self.temporary.cleanup()

    def admin_post(self, path: str, value: dict[str, object]) -> tuple[int, bytes]:
        connection = http.client.HTTPConnection("127.0.0.1", self.admin.server_port, timeout=3)
        connection.request(
            "POST",
            path,
            body=json.dumps(value).encode(),
            headers={
                "X-Fixture-Admin-Token": self.state.admin_token,
                "Content-Type": "application/json",
            },
        )
        response = connection.getresponse()
        result = response.status, response.read()
        connection.close()
        return result

    def admin_get(self, path: str) -> tuple[int, bytes]:
        connection = http.client.HTTPConnection("127.0.0.1", self.admin.server_port, timeout=3)
        connection.request("GET", path, headers={"X-Fixture-Admin-Token": self.state.admin_token})
        response = connection.getresponse()
        result = response.status, response.read()
        connection.close()
        return result

    def origin_request(self, path: str, operation_id: str) -> tuple[int, bytes]:
        connection = http.client.HTTPConnection("127.0.0.1", self.origin.server_port, timeout=3)
        connection.request(
            "POST",
            path,
            body=b'{"model":"fixture-model","private":"never-persist-this"}',
            headers={"Host": "api.openai.com", "X-Fixture-Operation-ID": operation_id},
        )
        response = connection.getresponse()
        result = response.status, response.read()
        connection.close()
        return result

    def test_receipts_persist_across_lost_reply_and_restart(self) -> None:
        self.assertEqual(self.origin_request("/v1/responses", "attempt-1")[0], 200)
        self.assertEqual(
            self.admin_post("/v1/fault", {"family": "openai", "mode": "lost_reply"})[0], 200
        )
        with self.assertRaises(http.client.RemoteDisconnected):
            self.origin_request("/v1/responses", "attempt-1")
        status, body = self.admin_get("/v1/receipts?after=0&limit=10")
        self.assertEqual(status, 200)
        raw = json.loads(body)
        self.assertEqual([entry["seq"] for entry in raw["receipts"]], [1, 2])
        self.assertEqual([entry["mode"] for entry in raw["receipts"]], ["normal", "lost_reply"])
        self.assertEqual(
            [entry["operation_id"] for entry in raw["receipts"]], ["fixture-1", "fixture-2"]
        )
        self.assertNotIn(b"never-persist-this", self.state.journal.read_bytes())
        self.assertNotIn(b"attempt-1", self.state.journal.read_bytes())
        restarted = State(Path(self.temporary.name))
        self.assertEqual(restarted.seq, 2)
        self.assertEqual(restarted.faults["openai"].mode, "lost_reply")

    def test_real_git_fetch_and_force_push_generation(self) -> None:
        mirror = Path(self.temporary.name) / "mirror.git"
        url = f"http://127.0.0.1:{self.origin.server_port}/fixture/demo.git"
        subprocess.run(
            [
                "git",
                "-c",
                "http.extraHeader=Host: github.com",
                "clone",
                "--mirror",
                url,
                str(mirror),
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=15,
        )
        initial = (
            subprocess.check_output(["git", f"--git-dir={mirror}", "rev-parse", "HEAD"])
            .decode()
            .strip()
        )
        initial_tags = subprocess.check_output(["git", f"--git-dir={mirror}", "tag", "--list"])
        self.assertEqual(initial_tags, b"")
        _, body = self.admin_post("/v1/git/generation", {"generation": 2})
        second = json.loads(body)["head"]
        self.assertNotEqual(initial, second)
        subprocess.run(
            [
                "git",
                "-c",
                "http.extraHeader=Host: github.com",
                f"--git-dir={mirror}",
                "fetch",
                "--prune",
                url,
                "+refs/heads/*:refs/heads/*",
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=15,
        )
        actual = (
            subprocess.check_output(["git", f"--git-dir={mirror}", "rev-parse", "HEAD"])
            .decode()
            .strip()
        )
        self.assertEqual(actual, second)
        content = subprocess.check_output(["git", f"--git-dir={mirror}", "show", "HEAD:README.md"])
        self.assertEqual(content, b"fixture-generation-2\n")
        _, body = self.admin_post("/v1/git/generation", {"generation": 3})
        third = json.loads(body)["head"]
        self.assertNotEqual(third, second)
        advertised = subprocess.check_output(
            ["git", "-c", "http.extraHeader=Host: github.com", "ls-remote", url],
            timeout=15,
        )
        self.assertIn(third.encode(), advertised)
        self.assertNotIn(initial.encode(), advertised)
        self.assertNotIn(b"refs/tags/", advertised)
        restarted = State(Path(self.temporary.name))
        self.assertEqual(restarted.generation()[0], 3)
        self.assertEqual(
            subprocess.check_output(
                [
                    "git",
                    f"--git-dir={self.state.root / 'git' / 'fixture/demo.git'}",
                    "tag",
                    "--list",
                ]
            ),
            b"",
        )
        self.assertGreaterEqual(restarted.seq, 3)

    def test_unknown_routes_and_unbounded_controls_refuse_without_effect(self) -> None:
        self.assertEqual(self.origin_request("/v1/unknown", "attempt-1")[0], 404)
        self.assertEqual(
            self.admin_post("/v1/fault", {"family": "git", "mode": "delay", "delay_ms": 9000})[0],
            400,
        )
        self.assertEqual(self.admin_post("/v1/git/generation", {"generation": 4})[0], 400)
        self.assertEqual(self.state.seq, 0)
        self.state.seq = MAX_RECEIPTS
        self.assertEqual(self.origin_request("/v1/responses", "full-1")[0], 507)
        self.assertEqual(self.state.journal.read_bytes(), b"")

    def test_provider_stream_error_and_integration_effect_shapes(self) -> None:
        connection = http.client.HTTPConnection("127.0.0.1", self.origin.server_port, timeout=3)
        connection.request(
            "POST",
            "/v1/messages",
            body=b'{"model":"fixture-model","stream":true}',
            headers={"Host": "api.anthropic.com"},
        )
        response = connection.getresponse()
        self.assertEqual(response.status, 200)
        self.assertEqual(response.getheader("Content-Type"), "text/event-stream")
        self.assertIn(b'"type":"message_delta"', response.read())
        connection.close()
        self.assertEqual(
            self.admin_post("/v1/fault", {"family": "openai", "mode": "error", "status": 429})[0],
            200,
        )
        self.assertEqual(self.origin_request("/v1/responses", "error-1")[0], 429)
        connection = http.client.HTTPConnection("127.0.0.1", self.origin.server_port, timeout=3)
        connection.request("GET", "/probe", headers={"Host": "integration.fixture.test"})
        response = connection.getresponse()
        self.assertEqual(response.status, 200)
        self.assertEqual(response.read(), b"fixture-integration-response\n")
        connection.close()
        self.assertEqual(
            [(entry["family"], entry["route"]) for entry in self.state.receipts(0, 10)],
            [("anthropic", "messages"), ("openai", "responses"), ("integration", "probe")],
        )

    def test_torn_tail_does_not_erase_confirmed_receipt(self) -> None:
        self.assertEqual(self.origin_request("/v1/responses", "private-header")[0], 200)
        with self.state.journal.open("ab") as stream:
            stream.write(b'{"seq":2')
            stream.flush()
        restarted = State(Path(self.temporary.name))
        self.assertEqual(restarted.seq, 1)
        self.assertEqual(len(restarted.receipts(0, 10)), 1)
        self.assertTrue(restarted.journal.read_bytes().endswith(b"\n"))

    def test_registered_markers_and_integration_credential_rotation(self) -> None:
        status, body = self.admin_post("/v1/markers", {})
        self.assertEqual(status, 200)
        marker = json.loads(body)["marker"]
        for host, token, expected in (
            ("integration-a.fixture.test", self.state.integration_auth, True),
            ("integration-b.fixture.test", "invalid-token", False),
        ):
            connection = http.client.HTTPConnection("127.0.0.1", self.origin.server_port)
            connection.request(
                "POST",
                "/probe",
                body=b"{}",
                headers={
                    "Host": host,
                    "X-Fixture-Operation-ID": marker,
                    "Authorization": "Bearer " + token,
                    "X-Fixture-Static": self.state.integration_static,
                },
            )
            response = connection.getresponse()
            self.assertEqual(response.status, 200)
            response.read()
            connection.close()
            receipt = self.state.receipts(0, 10)[-1]
            self.assertEqual(receipt["target_is_a"], host == "integration-a.fixture.test")
            self.assertEqual(receipt["authorization_matches"], expected)
            self.assertTrue(receipt["static_header_matches"])
            self.assertEqual(receipt["operation_id"], marker)
        self.assertEqual(self.admin_post("/v1/integration/credential", {"generation": 2})[0], 200)
        connection = http.client.HTTPConnection("127.0.0.1", self.origin.server_port)
        connection.request(
            "POST",
            "/probe",
            body=b"{}",
            headers={
                "Host": "integration-a.fixture.test",
                "Authorization": "Bearer " + self.state.integration_auth_next,
                "X-Fixture-Static": "wrong-static-value",
            },
        )
        response = connection.getresponse()
        self.assertEqual(response.status, 200)
        response.read()
        connection.close()
        latest = self.state.receipts(0, 10)[-1]
        self.assertTrue(latest["authorization_matches"])
        self.assertFalse(latest["static_header_matches"])
        self.assertNotIn(self.state.integration_auth.encode(), self.state.journal.read_bytes())
        self.assertNotIn(self.state.integration_static.encode(), self.state.journal.read_bytes())
        restarted = State(Path(self.temporary.name))
        self.assertEqual(restarted.integration_generation, 2)

        connection = http.client.HTTPConnection("127.0.0.1", self.origin.server_port)
        connection.request(
            "POST",
            "/v1/responses",
            body=json.dumps({"input": [{"text": "prefix " + marker}]}).encode(),
            headers={"Host": "api.openai.com"},
        )
        response = connection.getresponse()
        self.assertEqual(response.status, 200)
        response.read()
        connection.close()
        self.assertEqual(self.state.receipts(0, 10)[-1]["operation_id"], marker)

    def test_held_stream_release_and_client_eof(self) -> None:
        self.assertEqual(
            self.admin_post("/v1/fault", {"family": "integration", "mode": "hold"})[0], 200
        )
        for eof in (False, True):
            connection = http.client.HTTPConnection("127.0.0.1", self.origin.server_port, timeout=3)
            connection.request("GET", "/stream", headers={"Host": "integration-b.fixture.test"})
            response = connection.getresponse()
            self.assertEqual(response.status, 200)
            self.assertEqual(
                response.read(len(b"fixture-stream-start\n")), b"fixture-stream-start\n"
            )
            seq = self.state.seq
            status, body = self.admin_get(f"/v1/holds?seq={seq}")
            self.assertEqual(status, 200)
            self.assertEqual(json.loads(body)["state"], "held")
            if eof:
                assert connection.sock is not None
                connection.sock.shutdown(socket.SHUT_WR)
            else:
                self.assertEqual(self.admin_post("/v1/holds/release", {"seq": seq})[0], 200)
            for _ in range(40):
                _, body = self.admin_get(f"/v1/holds?seq={seq}")
                if json.loads(body)["state"] != "held":
                    break
                time.sleep(0.025)
            final = json.loads(body)
            self.assertEqual(final["state"], "eof" if eof else "released")
            self.assertIsInstance(final["closed_at_ns"], int)
            self.assertEqual(final["eof_observed"], eof)
            connection.close()
        restarted = State(Path(self.temporary.name))
        recovered_hold = restarted.hold_view(1)
        self.assertIsNotNone(recovered_hold)
        assert recovered_hold is not None
        self.assertEqual(recovered_hold["state"], "unknown")

    def test_server_exits_on_sigterm(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            process = subprocess.Popen(
                [executable, "-m", "origin", "serve"],
                env=os.environ
                | {
                    "ORIGIN_STATE_DIR": temporary,
                    "ORIGIN_ADMIN_PORT": "0",
                    "ORIGIN_TLS_PORT": "0",
                },
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            try:
                for _ in range(100):
                    if (Path(temporary) / "ca.pem").exists():
                        break
                    self.assertIsNone(process.poll())
                    time.sleep(0.02)
                self.assertTrue((Path(temporary) / "ca.pem").exists())
                time.sleep(0.1)
                process.terminate()
                self.assertEqual(process.wait(timeout=3), 0)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=3)


if __name__ == "__main__":
    unittest.main()
