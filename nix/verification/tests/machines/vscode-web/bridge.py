"""Disposable raw transport adapter for the real guest editor broker."""

import argparse
import json
import selectors
import socket
import socketserver
import struct
from html.parser import HTMLParser
from http.client import HTTPConnection
from pathlib import Path
from urllib.parse import urlsplit


def mapping(value: object) -> dict[str, object]:
    assert isinstance(value, dict)
    result: dict[str, object] = {}
    for key, item in value.items():
        assert isinstance(key, str)
        result[key] = item
    return result


def preface(path: Path, mutation: str | None = None) -> bytes:
    parsed: object = json.loads(path.read_text())
    document = mapping(parsed)
    assert set(document) == {"version", "binding"} and document["version"] == 1
    binding = mapping(document["binding"])
    assert len(binding) == 17
    if mutation == "epoch":
        binding["execution_epoch"] = 8
    elif mutation == "placement":
        binding["placement_id"] = "22222222-2222-4222-8222-222222222222"
    elif mutation == "release":
        binding["editor_release"] = "0" * 64
    elif mutation == "account":
        binding["uid"] = 200002
    elif mutation == "name":
        binding["username"] = "bob"
    elif mutation is not None:
        raise ValueError("unknown refusal fixture")
    document["binding"] = binding
    body = json.dumps(document, separators=(",", ":")).encode()
    assert 0 < len(body) <= 2048
    return struct.pack("!I", len(body)) + body


def read_exact(stream: socket.socket, length: int) -> bytes:
    result = bytearray()
    while len(result) < length:
        block = stream.recv(length - len(result))
        if not block:
            raise EOFError("broker closed before readiness")
        result.extend(block)
    return bytes(result)


def connect(body: bytes, source: str = "10.10.0.1") -> socket.socket:
    stream = socket.create_connection(("10.10.0.2", 4444), timeout=25, source_address=(source, 0))
    try:
        stream.sendall(body)
        length = struct.unpack("!I", read_exact(stream, 4))[0]
        assert 0 < length <= 128
        result: object = json.loads(read_exact(stream, length))
        assert mapping(result) == {"version": 1, "ready": True}
        stream.settimeout(None)
        return stream
    except BaseException:
        stream.close()
        raise


class Relay(socketserver.BaseRequestHandler):
    frame: bytes

    def handle(self) -> None:
        assert isinstance(self.request, socket.socket)
        try:
            with connect(self.frame) as worker, selectors.DefaultSelector() as selector:
                selector.register(self.request, selectors.EVENT_READ, worker)
                selector.register(worker, selectors.EVENT_READ, self.request)
                while True:
                    for key, _ in selector.select():
                        assert isinstance(key.fileobj, socket.socket)
                        assert isinstance(key.data, socket.socket)
                        block = key.fileobj.recv(65536)
                        if not block:
                            return
                        key.data.sendall(block)
        except (OSError, EOFError, AssertionError):
            # Fixed diagnostic only: request headers and bytes never enter logs.
            print("editor.fixture_transport_closed", flush=True)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


class WorkbenchConfiguration(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.settings: str | None = None

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attributes = dict(attrs)
        if tag == "meta" and attributes.get("id") == "vscode-workbench-web-configuration":
            assert self.settings is None
            settings = attributes.get("data-settings")
            assert isinstance(settings, str)
            self.settings = settings


def probe_workbench(body: bytes, configuration: Path) -> None:
    """@cc [owner:ghuntley,label:verification;security] editor-admitted-launch-origin
    The actual worker's bounded workbench HTML MUST advertise the admitted
    authority and its exact release-pinned webview endpoint. Probe diagnostics
    MUST NOT emit response bodies, request headers or configuration values.
    """
    document: object = json.loads(configuration.read_text())
    binding = mapping(mapping(document)["binding"])
    origin, label, release = binding["editor_origin"], binding["label"], binding["editor_release"]
    assert isinstance(origin, str) and isinstance(label, str) and isinstance(release, str)
    parsed = urlsplit(origin)
    assert parsed.scheme == "https" and isinstance(parsed.hostname, str)
    assert parsed.hostname.startswith(label + ".")
    zone = parsed.hostname.removeprefix(label + ".")
    port = "" if parsed.port is None else ":" + str(parsed.port)
    endpoint = (
        "https://{{uuid}}."
        + zone
        + port
        + "/code-assets/"
        + release
        + "/out/vs/workbench/contrib/webview/browser/pre/"
    )
    with connect(body) as stream:
        stream.settimeout(10)
        connection = HTTPConnection(parsed.netloc, timeout=10)
        connection.sock = stream
        try:
            connection.request("GET", "/", headers={"Host": parsed.netloc, "Connection": "close"})
            response = connection.getresponse()
            assert response.status == 200
            html = response.read(131073)
            assert 0 < len(html) <= 131072
            parser = WorkbenchConfiguration()
            parser.feed(html.decode("utf-8"))
            assert isinstance(parser.settings, str)
            settings_value: object = json.loads(parser.settings)
            settings = mapping(settings_value)
            assert settings["remoteAuthority"] == parsed.netloc
            assert settings["webviewEndpoint"] == endpoint
            assert settings["enableWorkspaceTrust"] is False
        finally:
            connection.close()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("configuration", type=Path)
    parser.add_argument(
        "--refuse",
        choices=("epoch", "placement", "release", "account", "name", "gateway", "custody"),
    )
    parser.add_argument("--probe", action="store_true")
    parser.add_argument("--probe-workbench", action="store_true")
    parser.add_argument("--port", type=int, default=8080)
    arguments = parser.parse_args()
    configuration = arguments.configuration
    assert isinstance(configuration, Path)
    assert isinstance(arguments.port, int) and arguments.port in {8080, 8081}
    refusal = arguments.refuse
    assert refusal is None or isinstance(refusal, str)
    body = preface(configuration, None if refusal in {"gateway", "custody"} else refusal)
    if refusal is not None:
        try:
            with connect(body, "10.10.0.3" if refusal == "gateway" else "10.10.0.1"):
                raise AssertionError("foreign authority admitted")
        except (EOFError, ConnectionResetError, BrokenPipeError):
            return
    if arguments.probe_workbench:
        probe_workbench(body, configuration)
        return
    if arguments.probe:
        with connect(body) as stream:
            document: object = json.loads(configuration.read_text())
            binding = mapping(mapping(document)["binding"])
            origin = binding["editor_origin"]
            commit = binding["editor_commit"]
            assert isinstance(origin, str) and isinstance(commit, str)
            stream.sendall(f"GET /version HTTP/1.0\r\nHost: {origin[8:]}\r\n\r\n".encode())
            stream.settimeout(5)
            result = bytearray()
            while block := stream.recv(1024):
                result.extend(block)
                assert len(result) <= 16384
            assert bytes(result).split(b"\r\n\r\n", 1)[1] == commit.encode()
        return
    Relay.frame = body
    with Server(("127.0.0.1", arguments.port), Relay) as server:
        server.serve_forever()


if __name__ == "__main__":
    try:
        main()
    except Exception:
        print("editor.fixture_assertion_failed", flush=True)
        raise SystemExit(1) from None
