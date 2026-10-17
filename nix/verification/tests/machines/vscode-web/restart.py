"""Live editor WebSockets survive lilly-hostd and Lilly restarts (ADR-0192)."""

import argparse
import sys
import time
from collections.abc import Callable
from pathlib import Path
from urllib.parse import urlsplit

from browser_journey import Fixture, load_fixture
from playwright.sync_api import Page, WebSocket, expect, sync_playwright


def wait_for(page: Page, condition: Callable[[], bool], seconds: float) -> bool:
    """Poll a zero-argument predicate while the page keeps its event loop."""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if condition():
            return True
        page.wait_for_timeout(250)
    return condition()


def run(fixture: Fixture, chromium: Path, ready: Path, go: Path) -> None:
    """@cc [owner:ghuntley,label:verification;recovery] editor-websocket-survives-restarts
    Every editor WebSocket that carried frames before the driver restarts
    lilly-hostd and Lilly MUST still be open after both restarts and MUST
    receive further frames on the same socket, and a fresh editor HTTP request
    MUST succeed. The driver is told through `ready` and answers through `go`.
    Credentials, WebSocket URLs and frames MUST NOT enter diagnostics.
    """
    frames: dict[int, int] = {}
    closed: set[int] = set()

    def opened(socket: WebSocket) -> None:
        if urlsplit(socket.url).netloc != urlsplit(fixture.expected_editor_origin).netloc:
            return
        key = id(socket)
        frames[key] = 0

        def frame(_: object) -> None:
            frames[key] += 1

        def close(_: object = None) -> None:
            closed.add(key)

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
            print("Editor restart stage: admission", flush=True)
            editor.goto(f"{fixture.marshall_origin}/machines/{fixture.machine_id}/code")
            editor.wait_for_url(fixture.expected_editor_origin + "/**")
            expect(editor.locator(".monaco-workbench")).to_be_visible(timeout=60000)
            assert wait_for(editor, lambda: any(frames.values()), 30), "no editor WebSocket frames"
            live = {key for key, count in frames.items() if count} - closed
            assert live, "no live editor WebSocket"
            print(f"Editor restart stage: {len(live)} live sockets", flush=True)
            ready.write_text("ready\n")
            print("Editor restart stage: waiting for the restarts", flush=True)
            assert wait_for(editor, go.exists, 900), "driver never signalled go"
            print("Editor restart stage: continuity", flush=True)
            assert not live & closed, "an editor WebSocket closed across the restarts"
            before = {key: frames[key] for key in live}
            assert wait_for(editor, lambda: any(frames[key] > before[key] for key in live), 60), (
                "no further frames after the restarts"
            )
            assert not live & closed, "an editor WebSocket closed after the restarts"
            response = context.request.get(
                fixture.expected_editor_origin + "/version", max_redirects=0
            )
            assert response.status == 200, f"editor /version returned {response.status}"
        finally:
            context.close()
            browser.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("fixture", type=Path)
    parser.add_argument("--chromium", required=True, type=Path)
    parser.add_argument("--ready", required=True, type=Path)
    parser.add_argument("--go", required=True, type=Path)
    arguments = parser.parse_args()
    try:
        run(load_fixture(arguments.fixture), arguments.chromium, arguments.ready, arguments.go)
    except AssertionError as error:
        # Only the fixed assertion messages above are printed.
        print(f"Editor restart survival failed: {error}", file=sys.stderr)
        return 1
    except Exception:
        print("Editor restart survival failed; browser details withheld", file=sys.stderr)
        return 1
    print("Editor restart survival assertions passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
