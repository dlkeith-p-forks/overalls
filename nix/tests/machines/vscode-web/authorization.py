"""Native Audi origin refusals and editor revocation through browser sign-out."""

import argparse
import sys
import time
from pathlib import Path
from urllib.parse import urlsplit

from browser_journey import Fixture, load_fixture
from playwright.sync_api import WebSocket, expect, sync_playwright


def run(fixture: Fixture, chromium: Path) -> None:
    """@cc [owner:ghuntley,label:verification;security] editor-native-browser-revocation
    Origin refusals MUST reach actual Audi with the current editor cookie.
    Ordinary browser sign-out MUST revoke that stored login: its established
    editor WebSockets MUST close within thirty seconds and HTTP MUST begin fresh
    authentication through a 303 to the configured Marshall origin.
    Credentials, WebSocket URLs and frames MUST NOT enter diagnostics.
    """
    received: set[int] = set()
    closed: set[int] = set()

    def opened(socket: WebSocket) -> None:
        if urlsplit(socket.url).netloc != urlsplit(fixture.expected_editor_origin).netloc:
            return

        def frame(_: object) -> None:
            received.add(id(socket))

        def close(_: object = None) -> None:
            closed.add(id(socket))

        socket.on("framereceived", frame)
        socket.on("close", close)

    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            executable_path=str(chromium), args=["--no-sandbox", "--disable-dev-shm-usage"]
        )
        context = browser.new_context(storage_state=fixture.storage_state_path)
        context.set_default_timeout(15000)
        context.set_default_navigation_timeout(30000)
        editor = context.new_page()
        editor.on("websocket", opened)
        try:
            print("Editor authorization stage: admission", flush=True)
            editor.goto(f"{fixture.marshall_origin}/machines/{fixture.machine_id}/code")
            editor.wait_for_url(fixture.expected_editor_origin + "/**")
            expect(editor.locator(".monaco-workbench")).to_be_visible(timeout=60000)
            deadline = time.monotonic() + 30
            while not received and time.monotonic() < deadline:
                editor.wait_for_timeout(100)
            assert received - closed
            current = received - closed
            response = context.request.get(
                fixture.expected_editor_origin + "/version", max_redirects=0
            )
            assert response.status == 200
            print("Editor authorization stage: origin refusals", flush=True)
            sibling = fixture.marshall_origin
            for headers in ({}, {"Origin": sibling}, {"Origin": "null"}):
                response = context.request.post(
                    fixture.expected_editor_origin + "/", headers=headers, max_redirects=0
                )
                assert response.status == 403
                upgrade = {
                    "Connection": "Upgrade",
                    "Upgrade": "websocket",
                    "Sec-WebSocket-Version": "13",
                    "Sec-WebSocket-Key": "dGhlIHNhbXBsZSBub25jZQ==",
                    **headers,
                }
                response = context.request.get(
                    fixture.expected_editor_origin + "/", headers=upgrade, max_redirects=0
                )
                assert response.status == 403
            print("Editor authorization stage: ordinary sign-out", flush=True)
            control = context.new_page()
            control.goto(fixture.marshall_origin + "/sign-out")
            control.get_by_role("button", name="Sign out", exact=True).click()
            control.wait_for_url(lambda url: urlsplit(url).path != "/sign-out")
            print("Editor authorization stage: current transport refusal", flush=True)
            deadline = time.monotonic() + 30
            while not current.issubset(closed) and time.monotonic() < deadline:
                editor.wait_for_timeout(100)
            assert current.issubset(closed)
            response = context.request.get(
                fixture.expected_editor_origin + "/version", max_redirects=0
            )
            assert response.status == 303
            assert response.headers["location"].startswith(
                fixture.marshall_origin + "/editor/authorize/"
            )
            control.goto(response.headers["location"])
            control.wait_for_url(fixture.marshall_origin + "/sign-in**")
            expect(control.locator(".monaco-workbench")).to_have_count(0)
        finally:
            context.close()
            browser.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("fixture", type=Path)
    parser.add_argument("--chromium", required=True, type=Path)
    arguments = parser.parse_args()
    try:
        run(load_fixture(arguments.fixture), arguments.chromium)
    except Exception:
        print(
            "Editor native authorization assertions failed; browser details withheld",
            file=sys.stderr,
        )
        return 1
    print("Editor native authorization assertions passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
