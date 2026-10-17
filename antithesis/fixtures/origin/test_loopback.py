"""Real local HTTP boundary checks for the inner provider fixture."""

import http.client
import http.server
import json
import tempfile
import threading
import unittest
from pathlib import Path

from origin.loopback import LoopbackHandler
from origin.server import State


class LoopbackTests(unittest.TestCase):
    def test_provider_discovery_requires_exact_synthetic_authority(self) -> None:
        with tempfile.TemporaryDirectory() as directory:

            class Handler(LoopbackHandler):
                authorization = "Bearer fixture-loopback-test-authority"

            Handler.state = State(Path(directory))
            with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
                worker = threading.Thread(target=server.serve_forever, daemon=True)
                worker.start()
                try:
                    for host, authorization, expected in (
                        ("127.0.0.1:8080", "Bearer incorrect-authority", 401),
                        ("api.openai.com", Handler.authorization, 401),
                        ("127.0.0.1:8080", Handler.authorization, 200),
                    ):
                        connection = http.client.HTTPConnection(
                            "127.0.0.1", server.server_address[1], timeout=3
                        )
                        try:
                            connection.request(
                                "GET",
                                "/v1/models",
                                headers={"Host": host, "Authorization": authorization},
                            )
                            response = connection.getresponse()
                            self.assertEqual(response.status, expected)
                            body = response.read()
                            if expected == 200:
                                self.assertEqual(json.loads(body)["data"][0]["id"], "fixture-model")
                        finally:
                            connection.close()
                    receipts = Handler.state.journal.read_text().splitlines()
                    self.assertEqual(len(receipts), 1)
                    self.assertNotIn(Handler.authorization, receipts[0])
                finally:
                    server.shutdown()
                    worker.join(timeout=3)


if __name__ == "__main__":
    unittest.main()
