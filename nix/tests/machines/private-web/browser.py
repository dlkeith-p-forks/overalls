"""Real browser identity, original traffic closure and fresh request recovery."""

import json
import sys
import time
from pathlib import Path
from typing import TypedDict

from playwright.sync_api import Page, expect, sync_playwright

ROOT = Path("/var/lib/fleet-team-resources")
stage = "launch"


class Traffic(TypedDict):
    chunks: int
    echoes: int
    httpClosed: bool
    wsClosed: bool


def strings(path: Path) -> dict[str, str]:
    parsed: object = json.loads(path.read_text())
    assert isinstance(parsed, dict)
    result: dict[str, str] = {}
    for key, value in parsed.items():
        assert isinstance(key, str)
        if isinstance(value, str):
            result[key] = value
    return result


def traffic(page: Page) -> Traffic:
    parsed: object = page.evaluate("() => ({...privateWebState})")
    assert isinstance(parsed, dict)
    fields: dict[str, object] = {}
    for name, value in parsed.items():
        assert isinstance(name, str)
        fields[name] = value
    assert set(fields) == {"chunks", "echoes", "httpClosed", "wsClosed"}
    chunks, echoes = fields["chunks"], fields["echoes"]
    http_closed, ws_closed = fields["httpClosed"], fields["wsClosed"]
    assert type(chunks) is int and chunks > 0
    assert type(echoes) is int and echoes > 0
    assert isinstance(http_closed, bool) and isinstance(ws_closed, bool)
    return {"chunks": chunks, "echoes": echoes, "httpClosed": http_closed, "wsClosed": ws_closed}


def signal(page: Page, name: str) -> None:
    deadline = time.monotonic() + 90
    while not (ROOT / name).exists():
        assert time.monotonic() < deadline, "Private browser coordination timed out"
        page.wait_for_timeout(100)


def main() -> None:
    """@cc [owner:ghuntley,label:verification;security] private-web-browser-withdrawal
    The ordinary member MUST sign in over trusted HTTPS and obtain host-only Audi
    cookies through its actual browser exchange. Existing traffic MUST terminate
    without navigation, manual cancellation or reconnect. Fresh denied requests
    MUST have explicit HTTP refusal; re-addition MUST admit fresh traffic while
    original closed counters stay fixed. Diagnostics carry closed stages only.
    """
    global stage
    users = strings(ROOT / "private-users.json")
    hostname = strings(ROOT / "private-target.json")["hostname"]
    assert hostname.endswith(".apps.example.test")
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            executable_path="/run/current-system/sw/bin/chromium", headless=True
        )
        try:
            context = browser.new_context()
            page = context.new_page()
            stage = "member sign in"
            page.goto("https://control.example.test/magic_link/" + users["member_token"])
            expect(page.locator("[data-phx-main].phx-connected")).to_be_visible()
            page.wait_for_url("**/overview")
            stage = "private primary"
            page.goto("https://" + hostname + "/")
            expect(page.locator("body")).to_contain_text("private-web-ready")
            cookies = [
                cookie for cookie in context.cookies() if cookie["name"] == "__Host-audi_session"
            ]
            assert len(cookies) == 1 and cookies[0]["domain"] == hostname
            assert cookies[0]["secure"] and cookies[0]["httpOnly"] and cookies[0]["path"] == "/"
            # The old page remains loaded for the entire removal/re-addition.
            page.add_script_tag(path=str(Path(__file__).with_name("browser.js")))
            page.wait_for_function("privateWebState.chunks > 2 && privateWebState.echoes > 2")
            before = traffic(page)
            assert not before["httpClosed"] and not before["wsClosed"]
            (ROOT / "private-open").touch()
            stage = "original closure"
            signal(page, "private-withdrawn")
            page.wait_for_function(
                "privateWebState.httpClosed && privateWebState.wsClosed", timeout=12000
            )
            closed = traffic(page)
            assert closed["chunks"] >= before["chunks"] and closed["echoes"] >= before["echoes"]
            stage = "fresh refusal"
            status: object = page.evaluate("privateWebFreshStatus()")
            assert status == 403
            (ROOT / "private-refused").touch()
            signal(page, "private-restored")
            stage = "fresh recovery"
            fresh = context.new_page()
            fresh.goto("https://" + hostname + "/")
            expect(fresh.locator("body")).to_contain_text("private-web-ready")
            assert traffic(page) == closed
            (ROOT / "private-complete").touch()
            context.close()
        finally:
            browser.close()


try:
    main()
except Exception:
    print(json.dumps({"event": "private_web_browser_failed", "stage": stage}), file=sys.stderr)
    sys.exit(1)
