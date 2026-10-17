"""One ordinary member simultaneously holding a shared terminal, SSH and private web."""

import json
import os
import sys
import time
import traceback
import uuid
from pathlib import Path
from typing import TypedDict

from playwright.sync_api import Page, expect, sync_playwright

ROOT = Path("/var/lib/fleet-sharing")
stage = "startup"
# The private page's HTTP status (a closed number, never its text) separates a
# guest refusal (400), an Audi refusal or outage and an unexpected body.
web_status: int | None = None


class SharingState(TypedDict):
    phase: str
    terminal_ms: int | None
    fresh_status: int | None
    session: str | None
    web_closed: bool


def publish(state: SharingState) -> None:
    temporary = ROOT / "state.tmp"
    temporary.write_text(json.dumps(state))
    temporary.replace(ROOT / "state.json")


def strings(path: Path, keys: tuple[str, ...]) -> dict[str, str]:
    """The required string fields only; other fixture fields may be null."""
    parsed: object = json.loads(path.read_text())
    assert isinstance(parsed, dict)
    fields: dict[str, object] = {
        name: value for name, value in parsed.items() if isinstance(name, str)
    }
    result: dict[str, str] = {}
    for key in keys:
        value = fields.get(key)
        assert isinstance(value, str)
        result[key] = value
    return result


def login(tab: Page, token: str) -> None:
    """:meta private:"""
    response = tab.goto("https://control.example.test/magic_link/" + token)
    assert response is not None and response.status == 200
    expect(tab.locator("[data-phx-main].phx-connected")).to_be_visible(timeout=20000)
    tab.wait_for_url("**/overview")


def wait_terminal(tab: Page, origin: str, vm: str, writable: bool) -> str:
    tab.goto(origin + "/machines/" + vm + "/terminals")
    expect(tab.locator("#terminal-client")).to_be_visible(timeout=30000)
    expect(tab.locator("[data-phx-main].phx-connected")).to_be_visible(timeout=30000)
    item = tab.locator("[data-terminal-select]").first
    expect(item).to_be_visible(timeout=60000)
    session = item.get_attribute("data-terminal-select")
    assert session is not None and str(uuid.UUID(session)) == session
    expect(tab.locator("#terminal-status")).to_have_attribute(
        "data-status", "live" if writable else "readonly", timeout=30000
    )
    return session


def share_terminal(owner_tab: Page, session: str, member_email: str) -> None:
    owner_tab.locator(f"[data-terminal-share='{session}']").click()
    owner_tab.locator("#terminal-share-email").fill(member_email)
    owner_tab.locator("[data-terminal-tool='share-submit']").click()
    expect(owner_tab.locator("#terminal-share-result")).to_have_text(
        "Viewing access updated.", timeout=30000
    )
    owner_tab.locator("[data-terminal-tool='share-close']").click()


def await_marker(name: str) -> int:
    deadline = time.monotonic() + 120
    path = ROOT / name
    while not path.exists():
        assert time.monotonic() < deadline, "Sharing browser coordination timed out: " + name
        time.sleep(0.1)
    return os.stat(path).st_mtime_ns


def web_traffic(page: Page) -> dict[str, object]:
    parsed: object = page.evaluate("() => ({...sharingWebState})")
    assert isinstance(parsed, dict)
    fields: dict[str, object] = {}
    for name, value in parsed.items():
        assert isinstance(name, str)
        fields[name] = value
    assert set(fields) == {"chunks", "echoes", "httpClosed", "wsClosed"}
    return fields


def member_owner_command(owner_tab: Page) -> None:
    """A minimal owner proof the shared *session* survived: the pane stays live."""
    expect(owner_tab.locator("#terminal-status")).to_have_attribute(
        "data-status", "live", timeout=45000
    )


def main() -> None:
    """@cc [owner:ghuntley,label:verification;security] sharing-browser-one-member
    One ordinary member MUST sign in over verified HTTPS once and hold the
    shared terminal viewer and the private web transports with real browser
    state. Revocation MUST navigate the terminal away and close both original
    web transports without navigation or reconnect; fresh requests refuse with
    403. Re-sharing MUST admit only fresh pages and fresh attachments. Coaches,
    URLs, cookies and terminal bytes MUST stay inside the client machine; only
    closed phases and bounded counters may be published.
    """
    global stage, web_status
    users = strings(ROOT / "users.json", ("owner_token", "member_token", "member_email"))
    target = strings(ROOT / "target.json", ("hostname", "vm"))
    hostname = target["hostname"]
    vm = target["vm"]
    assert hostname.endswith(".apps.example.test")
    assert str(uuid.UUID(vm)) == vm
    state: SharingState = {
        "phase": "starting",
        "terminal_ms": None,
        "fresh_status": None,
        "session": None,
        "web_closed": False,
    }
    publish(state)
    origin = "https://control.example.test"
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            executable_path="/run/current-system/sw/bin/chromium",
            headless=True,
            args=["--no-sandbox"],
        )
        try:
            owner_context = browser.new_context()
            member_context = browser.new_context()
            owner_page, member_terminal = owner_context.new_page(), member_context.new_page()
            stage = "owner login"
            login(owner_page, users["owner_token"])
            stage = "owner terminal and share"
            session = wait_terminal(owner_page, origin, vm, writable=True)
            share_terminal(owner_page, session, users["member_email"])
            state["session"] = session
            stage = "member login and shared terminal attach"
            login(member_terminal, users["member_token"])
            attached = wait_terminal(member_terminal, origin, vm, writable=False)
            assert attached == session
            stage = "member private web"
            web_page = member_context.new_page()
            response = web_page.goto("https://" + hostname + "/")
            web_status = response.status if response else None
            expect(web_page.locator("body")).to_contain_text("private-web-ready", timeout=60000)
            web_page.add_script_tag(path=str(Path(__file__).with_name("browser.js")))
            web_page.wait_for_function(
                "sharingWebState.chunks > 2 && sharingWebState.echoes > 2", timeout=20000
            )
            state["phase"] = "open"
            publish(state)

            stage = "member revocation window"
            revoked_at_ns = await_marker("revoke-posted")
            member_terminal.wait_for_url("**/machines", timeout=20000)
            state["terminal_ms"] = (time.time_ns() - revoked_at_ns) // 1_000_000
            web_page.wait_for_function(
                "sharingWebState.httpClosed && sharingWebState.wsClosed", timeout=12000
            )
            closed = web_traffic(web_page)
            assert closed["httpClosed"] is True and closed["wsClosed"] is True
            status: object = web_page.evaluate("sharingWebFreshStatus()")
            assert status == 403
            state["fresh_status"] = 403
            state["web_closed"] = True
            state["phase"] = "closed"
            publish(state)

            stage = "member fresh admission after re-share"
            await_marker("reshared")
            fresh = member_context.new_page()
            fresh.goto("https://" + hostname + "/")
            expect(fresh.locator("body")).to_contain_text("private-web-ready", timeout=60000)
            # Fresh admission transports: a new fetch and WebSocket on the new
            # page; the revoked page's closed counters stay final.
            fresh.add_script_tag(path=str(Path(__file__).with_name("browser.js")))
            fresh.wait_for_function(
                "sharingWebState.chunks > 0 && sharingWebState.echoes > 0", timeout=20000
            )
            assert web_traffic(web_page) == closed
            member_terminal.goto(origin + "/machines/" + vm + "/terminals")
            expect(member_terminal.locator("[data-terminal-select]")).to_have_count(
                1, timeout=60000
            )
            expect(member_terminal.locator("#terminal-status")).to_have_attribute(
                "data-status", "readonly", timeout=30000
            )
            member_owner_command(owner_page)
            state["phase"] = "restored"
            publish(state)
            owner_context.close()
            member_context.close()
        except Exception:
            state["phase"] = "failed:" + stage
            publish(state)
            browser.close()
            raise
        browser.close()


try:
    main()
except Exception as error:
    # Closed diagnostics only: the stage, the exception class and the line in
    # this file where it surfaced; never messages, URLs, tokens or page text.
    lines = [
        frame.lineno
        for frame in traceback.extract_tb(error.__traceback__)
        if Path(frame.filename).resolve() == Path(__file__).resolve()
    ]
    print(
        json.dumps(
            {
                "event": "sharing_browser_failed",
                "stage": stage,
                "error": type(error).__name__,
                "line": lines[-1] if lines else None,
                "web_status": web_status,
            }
        ),
        file=sys.stderr,
    )
    sys.exit(1)
