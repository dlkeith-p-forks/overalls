"""Exercise actual native output plugins against isolated local provider fixtures."""

import json
import os
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

requests: list[tuple[str, str, bytes, str]] = []
rejection: dict[str, int] = {"tooNewLogEventStartIndex": 0}
lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    def do_POST(self) -> None:
        body = self.rfile.read(int(self.headers["Content-Length"]))
        target = self.headers.get("X-Amz-Target", "")
        with lock:
            requests.append((self.path, target, body, self.headers.get("Authorization", "")))
            count = sum("PutLogEvents" in row[1] for row in requests)
        response: dict[str, object] = {}
        if "PutLogEvents" in target and count == 1:
            response = {
                "rejectedLogEventsInfo": rejection,
                "fixture": "remote-response-private-sentinel",
            }
        encoded = json.dumps(response).encode()
        self.send_response(200)
        self.send_header("x-amzn-RequestId", "fixture-request")
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, format: str, *args: object) -> None:
        pass


def run(binary: str, kind: str, permanent: bool = False) -> None:
    global rejection
    rejection = {"tooOldLogEventEndIndex": 0} if permanent else {"tooNewLogEventStartIndex": 0}
    requests.clear()
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    with tempfile.TemporaryDirectory() as temporary:
        directory = Path(temporary)
        credentials = directory / "credentials"
        credentials.write_text(
            "[default]\naws_access_key_id = fixture-access\naws_secret_access_key = fixture-secret\naws_session_token = fixture-token\n"
        )
        credentials.chmod(0o600)
        output = {
            "name": kind,
            "match": "*",
            "tls": False,
            "port": server.server_port,
            "retry_limit": "no_limits",
        }
        if kind == "cloudwatch_logs":
            output.update(
                region="us-east-1",
                endpoint="127.0.0.1",
                log_group_name="/fixture/system",
                log_stream_prefix="fixture-host/",
                auto_create_group=False,
            )
        else:
            output.update(host="127.0.0.1", log_response_payload=False)
        config = {
            "service": {
                "flush": 1,
                "grace": 1,
                "log_level": "warn",
                "scheduler.base": 1,
                "scheduler.cap": 2,
                "http_server": True,
                "http_listen": "127.0.0.1",
                "http_port": 2020,
            },
            "pipeline": {
                "inputs": [
                    {
                        "name": "dummy",
                        "tag": "fixture",
                        "samples": 1,
                        "dummy": '{"event":"native-transport-fixture"}',
                    }
                ],
                "outputs": [output],
            },
        }
        path = directory / "config.yaml"
        path.write_text(json.dumps(config))
        env = {key: value for key, value in os.environ.items() if not key.startswith("AWS_")}
        env.update(
            OVERALLS_AWS_MODE="file",
            AWS_ACCESS_KEY_ID="ambient-fixture",
            AWS_SECRET_ACCESS_KEY="ambient-fixture-secret",
            AWS_CONFIG_FILE="/dev/null",
            AWS_SHARED_CREDENTIALS_FILE=str(credentials),
            AWS_EC2_METADATA_DISABLED="true",
        )
        with (directory / "stderr").open("w+") as errors:
            process = subprocess.Popen(
                [binary, "-c", str(path)], env=env, stdout=subprocess.DEVNULL, stderr=errors
            )
            try:
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline:
                    with lock:
                        delivered = (
                            sum("PutLogEvents" in row[1] for row in requests)
                            >= (1 if permanent else 2)
                            if kind == "cloudwatch_logs"
                            else any(row[0] == "/v1/logs" for row in requests)
                        )
                    if delivered:
                        if permanent:
                            import urllib.request

                            try:
                                metrics = (
                                    urllib.request.build_opener(urllib.request.ProxyHandler({}))
                                    .open(
                                        "http://127.0.0.1:2020/api/v1/metrics/prometheus", timeout=1
                                    )
                                    .read()
                                )
                                import re

                                if not re.search(
                                    rb"fluentbit_output_dropped_records_total[^\n]* 1(?:\.0)?(?:\n|$)",
                                    metrics,
                                ):
                                    time.sleep(0.1)
                                    continue
                            except OSError:
                                continue
                        break
                    if process.poll() is not None:
                        raise AssertionError("native collector exited")
                    time.sleep(0.1)
                assert delivered, "native transport did not deliver/retry"
            finally:
                process.terminate()
                try:
                    process.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            errors.seek(0)
            diagnostics = errors.read()
            assert "remote-response-private-sentinel" not in diagnostics
            if kind == "cloudwatch_logs":
                assert (
                    "cloudwatch.partial_rejection retry_future=" + ("0" if permanent else "1")
                ) in diagnostics
                puts = [
                    json.loads(body) for _, target, body, _ in requests if "PutLogEvents" in target
                ]
                assert all(value["logStreamName"].startswith("fixture-host/") for value in puts)
                assert all("Credential=fixture-access/" in auth for _, _, _, auth in requests)
                if permanent:
                    assert len(puts) == 1, "expired records must not retry forever"
            else:
                assert any(
                    b"native-transport-fixture" in body
                    for path, _, body, _ in requests
                    if path == "/v1/logs"
                )
    server.shutdown()
    server.server_close()


run(sys.argv[1], "cloudwatch_logs")
run(sys.argv[1], "cloudwatch_logs", permanent=True)
run(sys.argv[1], "opentelemetry")
print("CloudWatch partial-rejection retry, response privacy and native OTLP delivery passed")
