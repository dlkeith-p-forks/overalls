"""Read-only witness transport checks using actual local sockets and files."""

import json
import socket
import tempfile
import threading
import unittest
from pathlib import Path

from fault_worker import read_object
from witness_worker import process, query, validate


class WitnessWorkerTest(unittest.TestCase):
    def test_control_operations_and_caller_paths_are_refused(self) -> None:
        for request in (
            {"operation": "stop"},
            {"operation": []},
            {"operation": "identity", "socket": "/tmp/other"},
            {"operation": "witness", "placement_id": "../other"},
        ):
            with self.assertRaises(ValueError):
                validate(request)

    def test_spool_transports_read_only_reply(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name in ("witness_requests", "witness_results"):
                (root / name).mkdir()
            selected = root / "w.sock"
            request_id = "11111111-1111-4111-8111-111111111111"
            path = root / "witness_requests" / (request_id + ".json")
            path.write_text(
                json.dumps({"request_id": request_id, "request": {"operation": "identity"}})
            )
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
                listener.bind(str(selected))
                listener.listen(1)
                listener.settimeout(2)

                def answer() -> None:
                    connection, _ = listener.accept()
                    with connection:
                        connection.settimeout(2)
                        connection.recv(4096)
                        connection.sendall(b'{"state":"ok","image_id":"sha256:fixture"}\n')

                thread = threading.Thread(target=answer, daemon=True)
                thread.start()
                process(root, selected, path)
                thread.join(timeout=3)
            self.assertFalse(path.exists())
            self.assertEqual(
                read_object(root / "witness_results" / path.name),
                {
                    "request_id": request_id,
                    "response": {"state": "ok", "image_id": "sha256:fixture"},
                },
            )

    def test_unavailable_socket_does_not_become_empty_observation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary, self.assertRaises(OSError):
            query(Path(temporary) / "missing.sock", {"operation": "identity"})


if __name__ == "__main__":
    unittest.main()
