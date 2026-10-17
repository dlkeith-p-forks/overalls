# Real browser login for Audi withdrawal refusal classes; credential custody stays in files.
#
# @cc [owner:ghuntley,label:verification;security] audi-withdrawal-browser-custody
# Browser sign-in and sign-out MUST traverse the real control UI and SSO exchange.
# The session cookie MUST leave this process only through an owner-only Netscape
# jar for the exact host; stages and statuses, never cookie values or page
# content, may be reported.

import json
import os
import sys
from pathlib import Path

stage = "startup"
from playwright.sync_api import expect, sync_playwright

ORIGIN = "https://control.example.test"


def login_cookie(role: str, hostname: str, jar: Path, *, signout: bool) -> None:
    global stage
    users = json.loads(Path("/var/lib/fleet-audi/users.json").read_text())
    token = users[role + "_token"]
    with sync_playwright() as p:
        browser = p.chromium.launch(
            executable_path="/run/current-system/sw/bin/chromium",
            headless=True,
            args=["--no-sandbox"],
        )
        try:
            context = browser.new_context()
            page = context.new_page()
            stage = role + ":login"
            page.goto(ORIGIN + "/magic_link/" + token)
            expect(page.locator("[data-phx-main].phx-connected")).to_be_visible(timeout=20000)
            page.wait_for_url("**/overview")
            stage = role + ":admission"
            page.goto("https://" + hostname + "/")
            expect(page.locator("body")).to_contain_text("audi-guest", timeout=30000)
            stage = role + ":cookie"
            cookies = [
                c
                for c in context.cookies()
                if c["name"] == "__Host-audi_session" and c["domain"] == hostname
            ]
            assert len(cookies) == 1 and cookies[0]["httpOnly"] and cookies[0]["secure"]
            assert cookies[0]["path"] == "/" and cookies[0]["sameSite"] == "Lax"
            expiry = int(cookies[0]["expires"])
            with open(jar, "x", opener=lambda name, flags: os.open(name, flags, 0o600)) as target:
                target.write(
                    hostname
                    + "\tFALSE\t/\tTRUE\t"
                    + str(expiry)
                    + "\t__Host-audi_session\t"
                    + cookies[0]["value"]
                    + "\n"
                )
            if signout:
                stage = role + ":sign-out"
                page.goto(ORIGIN + "/sign-out")
                page.locator("form[action='/sign-out'] button[type=submit]").click()
                page.wait_for_url("**/sign-in", timeout=20000)
            context.close()
        finally:
            browser.close()


def main() -> int:
    global stage
    mode, role, hostname, jar = sys.argv[1:5]
    assert mode in ("login-cookie", "signout-cookie")
    assert role in ("owner", "member", "stranger")
    assert Path(jar).parent == Path("/var/lib/fleet-audi")
    assert not Path(jar).exists()
    try:
        login_cookie(role, hostname, Path(jar), signout=mode == "signout-cookie")
        print("Audi withdrawal browser stage completed: " + mode)
        return 0
    except Exception:
        print(
            "Audi withdrawal browser failed at " + stage + "; private data withheld",
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    sys.exit(main())
