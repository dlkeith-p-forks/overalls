"""@cc [owner:ghuntley,label:security;verification] audi-browser-bounded-diagnostics
Browser failure diagnostics MUST contain only a fixed fixture stage and numeric
HTTP status, never exception text, URLs, cookies or page content.
"""

import json
import sys
from pathlib import Path
from urllib.parse import urlsplit

# Fixed fixture stages and numeric HTTP status only.
stage = "startup"
http_status: int | None = None
from playwright.sync_api import Request, expect, sync_playwright


def main() -> None:
    global stage, http_status
    root = Path("/var/lib/fleet-audi")
    users = json.loads((root / "users.json").read_text())
    hostname = json.loads((root / "target.json").read_text())["hostname"]
    assert isinstance(hostname, str) and "." in hostname
    label, zone = hostname.split(".", 1)
    alternate = "p3000-" + label + "." + zone
    with sync_playwright() as p:
        browser = p.chromium.launch(
            executable_path="/run/current-system/sw/bin/chromium",
            headless=True,
            args=["--no-sandbox"],
        )
        try:
            for role in ("owner", "stranger"):
                stage = role + ":login"
                context = browser.new_context()
                page = context.new_page()
                first_cookie_counts = {}

                def observe_navigation(
                    request: Request, first_cookie_counts: dict[str, int] = first_cookie_counts
                ) -> None:
                    target = urlsplit(request.url)
                    requested = target.hostname
                    if (
                        request.is_navigation_request()
                        and target.path == "/"
                        and requested is not None
                        and requested in (hostname, alternate)
                        and requested not in first_cookie_counts
                    ):
                        # Store counts only, never credential values or headers.
                        value = request.all_headers().get("cookie", "")
                        first_cookie_counts[requested] = sum(
                            item.split("=", 1)[0].strip() == "__Host-audi_session"
                            for item in value.split(";")
                        )

                page.on("request", observe_navigation)
                page.goto("https://control.example.test/magic_link/" + users[role + "_token"])
                expect(page.locator("[data-phx-main].phx-connected")).to_be_visible(timeout=20000)
                page.wait_for_url("**/overview")
                for index, host in enumerate((hostname, alternate)):
                    stage = role + (":primary-http" if index == 0 else ":alternate-http")
                    http_status = None
                    response = page.goto("https://" + host + "/")
                    http_status = response.status if response is not None else None
                    if role == "stranger":
                        expect(page.locator("body")).not_to_contain_text("audi-guest")
                        continue
                    expect(page.locator("body")).to_contain_text("audi-guest", timeout=20000)
                    stage = role + (":primary-cookie" if index == 0 else ":alternate-cookie")
                    # Playwright's URL cookie filter suffix-matches host-only
                    # domains too. Inspect exact stored domains and actual requests.
                    assert first_cookie_counts[host] == 0
                    cookies = [
                        c
                        for c in context.cookies()
                        if c["name"] == "__Host-audi_session" and c["domain"] == host
                    ]
                    assert len(cookies) == 1 and cookies[0]["domain"] == host
                    assert (
                        cookies[0]["httpOnly"]
                        and cookies[0]["secure"]
                        and cookies[0]["path"] == "/"
                    )
                    stage = role + (":primary-websocket" if index == 0 else ":alternate-websocket")
                    echo = page.evaluate("""() => new Promise((resolve, reject) => {
                      const ws = new WebSocket('wss://' + location.host + '/ws');
                      const timer = setTimeout(() => { ws.close(); reject(new Error('timeout')); }, 10000);
                      ws.onopen = () => ws.send('audi-websocket');
                      ws.onmessage = event => { clearTimeout(timer); ws.close(); resolve(event.data); };
                      ws.onerror = () => { clearTimeout(timer); reject(new Error('websocket')); };
                    })""")
                    assert echo == "audi-websocket"
                context.close()
        finally:
            browser.close()


try:
    main()
    print("Audi browser, host-only cookies and WebSocket assertions passed")
except Exception:
    print(
        "Audi browser assertion failed at " + stage + "; HTTP status " + str(http_status),
        file=sys.stderr,
    )
    sys.exit(1)
