"""Portable refusal checks; these do not establish Windows native acceptance."""

import json
import socket
import ssl
import struct
import tempfile
import threading
import unittest
from copy import deepcopy
from pathlib import Path

# isort: split
from browser import local_tls

# isort: split
from relay import Admission, RelayServer, object_mapping, read_exact


def document() -> dict[str, object]:
    label = "e-" + "a" * 26 + "-" + "a" * 26
    return {
        "version": 1,
        "binding": {
            **{
                key: "00000000-0000-0000-0000-000000000000"
                for key in (
                    "vm_id",
                    "host_id",
                    "placement_id",
                    "session_id",
                    "user_id",
                    "guest_account_id",
                )
            },
            "execution_epoch": 1,
            "generation": 1,
            "label": label,
            "service": "editor",
            "port": 4444,
            "uid": 200001,
            "username": "u200001",
            "editor_protocol": 1,
            "editor_commit": "a" * 40,
            "editor_release": "b" * 64,
            "editor_origin": f"https://{label}.fixture.test",
        },
    }


class AdmissionBoundary(unittest.TestCase):
    def test_complete_binding(self) -> None:
        result = Admission.parse(json.dumps(document()).encode())
        self.assertEqual(result.uid, 200001)
        self.assertEqual(int.from_bytes(result.frame[:4], "big"), len(result.frame[4:]))

    def test_foreign_and_credential_origins_refused(self) -> None:
        original = document()
        for origin in (
            "http://foreign.test",
            "https://foreign.test",
            "https://user:password@foreign.test",
            "https://foreign.test/",
            "https://foreign.test?token=value",
            "https://127.0.0.1",
        ):
            value = deepcopy(original)
            binding = object_mapping(value["binding"])
            binding["editor_origin"] = origin
            value["binding"] = binding
            with self.subTest(origin=origin), self.assertRaises(ValueError):
                Admission.parse(json.dumps(value).encode())

    def test_missing_unknown_and_boolean_fields_refused(self) -> None:
        for key, replacement in (
            ("uid", True),
            ("generation", False),
            ("editor_protocol", True),
            ("username", "Administrator"),
        ):
            value = document()
            binding = object_mapping(value["binding"])
            binding[key] = replacement
            value["binding"] = binding
            with self.subTest(key=key), self.assertRaises(ValueError):
                Admission.parse(json.dumps(value).encode())
        for mutation in ("missing", "unknown"):
            value = document()
            binding = object_mapping(value["binding"])
            if mutation == "missing":
                del binding["session_id"]
            else:
                binding["token"] = "refused"
            value["binding"] = binding
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                Admission.parse(json.dumps(value).encode())

    def test_frame_bound(self) -> None:
        with self.assertRaises(ValueError):
            Admission.parse(b" " * 2049)

    def test_duplicate_fields_refused(self) -> None:
        raw = (
            json.dumps(document())
            .encode()
            .replace(b'"version": 1,', b'"version": 1, "version": 1,')
        )
        with self.assertRaises(ValueError):
            Admission.parse(raw)


class RelayBoundary(unittest.TestCase):
    def test_pinned_tls_and_exact_readiness_before_http(self) -> None:
        """A real local TLS exchange must consume readiness before HTTP bytes."""
        admission = Admission.parse(json.dumps(document()).encode())
        failures: list[str] = []
        with tempfile.TemporaryDirectory(prefix="windows-editor-local-test-") as temporary:
            directory = Path(temporary)
            tls, pin = local_tls(directory, admission.hostname)
            self.assertTrue(pin)
            client_tls = ssl.create_default_context(cafile=str(directory / "certificate.pem"))
            with socket.socket() as gateway:
                gateway.bind(("127.0.0.1", 0))
                gateway.listen(1)
                gateway.settimeout(5)

                def broker() -> None:
                    try:
                        stream, _ = gateway.accept()
                        with stream:
                            stream.settimeout(5)
                            frame = read_exact(stream, len(admission.frame))
                            if frame != admission.frame:
                                raise ValueError("fixture preface changed")
                            stream.settimeout(0.1)
                            try:
                                stream.recv(1)
                            except TimeoutError:
                                pass
                            else:
                                raise ValueError("fixture HTTP preceded readiness")
                            stream.settimeout(5)
                            ready = b'{"version":1,"ready":true}'
                            stream.sendall(struct.pack("!I", len(ready)) + ready)
                            request = bytearray()
                            while b"\r\n\r\n" not in request:
                                request.extend(stream.recv(4096))
                            stream.sendall(
                                b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
                            )
                    except Exception:
                        failures.append("fixture local broker failed")

                broker_thread = threading.Thread(target=broker, daemon=True)
                broker_thread.start()
                with RelayServer(admission, gateway.getsockname()[1], tls) as relay:
                    thread = threading.Thread(target=relay.serve_forever, daemon=True)
                    thread.start()
                    try:
                        with (
                            socket.create_connection(
                                ("127.0.0.1", relay.socket.getsockname()[1]), timeout=5
                            ) as raw,
                            client_tls.wrap_socket(
                                raw, server_hostname=admission.hostname
                            ) as browser,
                        ):
                            browser.sendall(
                                (
                                    "GET / HTTP/1.1\r\nHost: "
                                    + admission.authority
                                    + "\r\nConnection: close\r\n\r\n"
                                ).encode()
                            )
                            response = bytearray()
                            while block := browser.recv(4096):
                                response.extend(block)
                            self.assertTrue(response.endswith(b"\r\n\r\nok"))
                    finally:
                        relay.shutdown()
                        thread.join(timeout=5)
                broker_thread.join(timeout=5)
                self.assertFalse(broker_thread.is_alive())
        self.assertEqual(failures, [])


if __name__ == "__main__":
    unittest.main()
