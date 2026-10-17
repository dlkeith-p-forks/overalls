"""Packaged workbench initialization over a private TLS-to-Unix fixture bridge."""

import argparse
import ctypes
import os
import select
import signal
import socket
import socketserver
import ssl
import threading
import time
from contextlib import suppress
from pathlib import Path
from tempfile import TemporaryDirectory
from types import FrameType
from urllib.parse import urlsplit

from playwright.sync_api import (
    ConsoleMessage,
    Error,
    Request,
    Response,
    WebSocket,
    expect,
    sync_playwright,
)


def expire(_signal: int, _frame: FrameType | None) -> None:
    raise TimeoutError("Packaged browser startup deadline exceeded")


def cleanup_children() -> None:
    """Kill and reap only children owned or adopted by this fixture supervisor."""
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        children: set[int] = set()
        for task in list(Path("/proc/self/task").iterdir())[:64]:
            try:
                children.update(int(pid) for pid in (task / "children").read_text().split())
            except FileNotFoundError:
                continue
        if not children:
            return
        for pid in children:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                continue
        for pid in children:
            try:
                os.waitpid(pid, os.WNOHANG)
            except ChildProcessError:
                continue
        time.sleep(0.01)
    raise RuntimeError("Packaged browser fixture descendants did not settle")


def main() -> None:
    """@cc [owner:ghuntley,label:verification] packaged-browser-initialization
    The installed bundle MUST initialize a visible workbench with its actual
    no-agent product, fail eager page errors, and remove the startup fallback.
    This private fixture MUST bound its lifetime and reap browser descendants;
    its synthetic TLS bridge MUST NOT establish SSO, gateway or VM acceptance.
    """
    parser = argparse.ArgumentParser()
    for name in ("socket", "origin", "chromium", "certificate", "key"):
        parser.add_argument("--" + name, required=True)
    arguments = parser.parse_args()
    unix_path = str(arguments.socket)
    origin = str(arguments.origin)
    authority = urlsplit(origin)
    assert authority.scheme == "https" and authority.hostname and authority.port
    hostname, port = authority.hostname, authority.port

    libc = ctypes.CDLL(None, use_errno=True)
    libc.prctl.argtypes = [
        ctypes.c_int,
        ctypes.c_ulong,
        ctypes.c_ulong,
        ctypes.c_ulong,
        ctypes.c_ulong,
    ]
    libc.prctl.restype = ctypes.c_int
    if libc.prctl(36, 1, 0, 0, 0) != 0:
        raise RuntimeError("Packaged browser subreaper unavailable")
    signal.signal(signal.SIGALRM, expire)
    signal.signal(signal.SIGTERM, expire)
    signal.alarm(35)

    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(str(arguments.certificate), str(arguments.key))

    class Bridge(socketserver.BaseRequestHandler):
        def handle(self) -> None:
            if not isinstance(self.request, socket.socket):
                raise TypeError("Invalid fixture transport")
            with (
                tls.wrap_socket(self.request, server_side=True) as browser,
                socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as guest,
            ):
                guest.settimeout(5)
                guest.connect(unix_path)
                browser.settimeout(5)
                while True:
                    if browser.pending():
                        readable = [browser]
                    else:
                        readable, _, _ = select.select([browser, guest], [], [], 15)
                    if not readable:
                        return
                    for source in readable:
                        data = source.recv(65536)
                        if not data:
                            return
                        destination = guest if source is browser else browser
                        destination.sendall(data)

    class Server(socketserver.ThreadingTCPServer):
        daemon_threads = True

        def handle_error(
            self, request: socket.socket | tuple[bytes, socket.socket], client_address: object
        ) -> None:
            # Fixture transport failures must not echo request or socket bytes.
            return

    try:
        with (
            TemporaryDirectory(prefix="overalls-browser-profile-") as profile,
            Server(("127.0.0.1", port), Bridge) as server,
        ):
            threading.Thread(target=server.serve_forever, daemon=True).start()
            try:
                with sync_playwright() as playwright:
                    browser = playwright.chromium.launch(
                        executable_path=str(arguments.chromium),
                        headless=True,
                        timeout=10000,
                        env={
                            **os.environ,
                            "XDG_CONFIG_HOME": profile,
                            "XDG_CACHE_HOME": profile,
                            "XDG_DATA_HOME": profile,
                        },
                        args=[
                            "--no-sandbox",
                            "--disable-dev-shm-usage",
                            "--ignore-certificate-errors",
                            "--proxy-server=direct://",
                            "--proxy-bypass-list=*",
                            "--host-resolver-rules=MAP " + hostname + " 127.0.0.1",
                        ],
                    )
                    try:
                        page = browser.new_page()
                        errors: list[str] = []
                        diagnostics: list[str] = []
                        started = time.monotonic()

                        def on_error(error: Error) -> None:
                            if len(errors) < 16:
                                errors.append(error.message[:256])

                        def on_console(message: ConsoleMessage) -> None:
                            if message.type in {"warning", "error"} and len(diagnostics) < 32:
                                diagnostics.append("console: " + message.text[:256])

                        def on_response(response: Response) -> None:
                            if len(diagnostics) < 64:
                                diagnostics.append(
                                    f"HTTP {response.status}: {urlsplit(response.url).path[:128]}"
                                )

                        def on_request(request: Request) -> None:
                            if len(diagnostics) < 64:
                                address = urlsplit(request.url)
                                diagnostics.append(
                                    "request: "
                                    + (address.hostname or "unknown")[:128]
                                    + address.path[:128]
                                )

                        def on_websocket(web_socket: WebSocket) -> None:
                            path = urlsplit(web_socket.url).path[:128]
                            if len(diagnostics) < 64:
                                diagnostics.append("websocket opened: " + path)

                            def on_close(_socket: WebSocket) -> None:
                                if len(diagnostics) < 64:
                                    diagnostics.append("websocket closed: " + path)

                            web_socket.on("close", on_close)

                        def on_failure(request: Request) -> None:
                            if len(diagnostics) < 64:
                                diagnostics.append(
                                    "failed: "
                                    + urlsplit(request.url).path[:128]
                                    + ": "
                                    + (request.failure or "unknown")[:128]
                                )

                        page.on("pageerror", on_error)
                        page.on("console", on_console)
                        page.on("response", on_response)
                        page.on("request", on_request)
                        page.on("websocket", on_websocket)
                        page.on("requestfailed", on_failure)
                        try:
                            page.goto(origin, timeout=15000)
                            expect(page.locator(".monaco-workbench")).to_be_visible(timeout=15000)
                            expect(page.locator("#vscode-startup-fallback")).to_have_count(0)
                            if errors:
                                raise RuntimeError("Packaged workbench emitted an eager page error")
                        except (Error, AssertionError, RuntimeError, TimeoutError) as error:
                            # This fixture has no accounts, credentials, workspace or terminal.
                            # Bound diagnostic text and strip query/fragment from request paths.
                            print("Private packaged startup errors:", errors, flush=True)
                            print(
                                "Private packaged startup failure:", str(error)[:1024], flush=True
                            )
                            print(
                                "Private packaged startup state:",
                                {
                                    "closed": page.is_closed(),
                                    "elapsed_seconds": round(time.monotonic() - started, 3),
                                },
                                flush=True,
                            )
                            print("Private packaged startup transport:", diagnostics, flush=True)
                            if not page.is_closed():
                                with suppress(Error):
                                    print(
                                        "Private packaged startup DOM:",
                                        page.locator("body").inner_text(timeout=1000)[:256],
                                        flush=True,
                                    )
                            raise
                    finally:
                        browser.close()
            finally:
                server.shutdown()
    finally:
        signal.alarm(0)
        cleanup_children()


if __name__ == "__main__":
    main()
