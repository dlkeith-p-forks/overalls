"""Public browser authentication and LiveView WebSocket checks for two inner deployments."""

import json
import re
import sys
from functools import partial
from pathlib import Path
from typing import TypedDict
from urllib.parse import urlsplit

from playwright.sync_api import WebSocket, expect, sync_playwright


class BrowserTarget(TypedDict):
    hostname: str
    token: str


def load_target(hostname: str, path: Path) -> BrowserTarget:
    assert re.fullmatch(r"[a-z0-9-]+(?:\.[a-z0-9-]+)+", hostname)
    value: object = json.loads(path.read_text())
    assert isinstance(value, dict)
    fields: dict[str, object] = {}
    for name, item in value.items():
        assert isinstance(name, str)
        fields[name] = item
    assert set(fields) == {"token"}
    token = fields.get("token")
    assert isinstance(token, str) and 32 <= len(token) <= 4096
    assert re.fullmatch(r"[!-~]+", token)
    return {"hostname": hostname, "token": token}


def record_socket(sockets: list[str], socket: WebSocket) -> None:
    sockets.append(socket.url)


# @cc [owner:ghuntley,label:verification;security] inception-public-browser-independence
# Both inner control hosts MUST accept only their own magic-link identity over
# real browser TLS routing and establish a LiveView WebSocket. A token from one
# deployment MUST NOT authenticate to the other's control plane. Credentials,
# URLs, page contents and browser traces MUST NOT enter diagnostics.
def check_browser(first: BrowserTarget, second: BrowserTarget) -> None:
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            executable_path="/run/current-system/sw/bin/chromium",
            headless=True,
            args=["--no-sandbox"],
        )
        try:
            for target in (first, second):
                # The preceding curl phase validates each certificate chain
                # against the isolated public root. Browser contexts test
                # routing, authentication and WebSocket behavior.
                context = browser.new_context(ignore_https_errors=True)
                page = context.new_page()
                sockets: list[str] = []

                page.on("websocket", partial(record_socket, sockets))
                response = page.goto(
                    "https://" + target["hostname"] + "/magic_link/" + target["token"]
                )
                assert response is not None and response.status == 200
                expect(page.locator("[data-phx-main].phx-connected")).to_be_visible(timeout=30000)
                page.wait_for_url("**/machines")
                assert any(
                    urlsplit(url).hostname == target["hostname"]
                    and urlsplit(url).path == "/live/websocket"
                    for url in sockets
                )
                context.close()

            wrong = browser.new_context(ignore_https_errors=True)
            page = wrong.new_page()
            page.goto("https://" + first["hostname"] + "/magic_link/" + second["token"])
            page.wait_for_timeout(1000)
            assert urlsplit(page.url).path != "/machines"
            wrong.close()
        finally:
            browser.close()


def main() -> None:
    assert len(sys.argv) == 3
    first = load_target(sys.argv[1], Path("/run/inception-browser/first.json"))
    second = load_target(sys.argv[2], Path("/run/inception-browser/second.json"))
    assert first["hostname"] != second["hostname"]
    check_browser(first, second)


if __name__ == "__main__":
    try:
        main()
        print("Independent Inception browser authentication and WebSockets passed")
    except Exception:
        print("Inception browser check failed; credentials and URLs withheld", file=sys.stderr)
        sys.exit(1)
