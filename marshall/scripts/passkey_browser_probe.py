"""Exercise real LiveView WebAuthn with Chromium's virtual authenticator.

Requires a private context from passkey_browser_fixture.exs, Playwright and
CHROMIUM_EXECUTABLE. Never records traces, screenshots or token-bearing URLs.
"""

import json
import os
import sys
import traceback
from typing import TypedDict

from playwright.sync_api import expect, sync_playwright


class Fixture(TypedDict):
    """Private passkey_browser_fixture.exs context file."""

    origin: str
    admin_token: str
    victim_id: str
    victim_email: str
    second_token: str


def run(context_file: str) -> None:
    with open(context_file) as source:
        fixture: Fixture = json.load(source)
    origin = fixture["origin"]
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            executable_path=os.environ["CHROMIUM_EXECUTABLE"], headless=True, args=["--no-sandbox"]
        )
        context = browser.new_context()
        page = context.new_page()
        page.on("dialog", lambda dialog: dialog.accept())
        cdp = context.new_cdp_session(page)
        cdp.send("WebAuthn.enable")
        authenticator = cdp.send(
            "WebAuthn.addVirtualAuthenticator",
            {
                "options": {
                    "protocol": "ctap2",
                    "transport": "internal",
                    "hasResidentKey": True,
                    "hasUserVerification": True,
                    "isUserVerified": True,
                    "automaticPresenceSimulation": True,
                }
            },
        )["authenticatorId"]

        def connected() -> None:
            page.locator("[data-phx-main].phx-connected").wait_for()

        def login(token: str) -> None:
            page.goto(origin + "/magic_link/" + token)
            connected()
            page.wait_for_url(lambda url: "/magic_link/" not in url)
            connected()

        def verify() -> None:
            page.locator("#verify-passkey").click()
            expect(page.locator("#verification-status")).to_contain_text("seconds remaining")

        login(fixture["admin_token"])
        page.goto(origin + "/settings")
        connected()
        page.locator("#add-passkey").click()
        expect(page.locator("#passkey-list > div")).to_have_count(1)
        expect(page.locator("#security-continue")).to_have_count(0)
        verify()
        page.locator("#passkey-list input[name=label]").fill("Browser fixture key")
        page.locator("#passkey-list button", has_text="Rename").click()
        expect(page.locator("#passkey-list input[name=label]")).to_have_value("Browser fixture key")
        page.locator("#passkey-list button", has_text="Remove").click()
        expect(page.locator("#flash-group")).to_contain_text("at least one passkey")
        expect(page.locator("#passkey-list > div")).to_have_count(1)
        page.locator("#lock-elevation").click()
        expect(page.locator("#lock-elevation")).to_have_count(0)
        page.goto(origin + "/admin/users")
        connected()
        role = "#role-" + fixture["victim_id"]
        page.locator(role).click()
        page.wait_for_url("**/settings?**")
        connected()
        verify()
        page.locator("#security-continue").click()
        connected()
        expect(page.locator(role)).to_have_text("Make administrator")
        page.locator(role).click()
        expect(page.locator(role)).to_have_text("Remove administrator")
        page.locator(role).click()
        expect(page.locator(role)).to_have_text("Make administrator")
        form = page.locator("#delete-user-" + fixture["victim_id"])
        form.locator("input[name=confirmation]").fill(fixture["victim_email"])
        form.locator("button").click()
        expect(page.locator(role)).to_have_count(0)

        # A second email login must prove MFA independently of the first session.
        context.clear_cookies()
        login(fixture["second_token"])
        expect(page).to_have_url(origin + "/settings")
        expect(page.locator("#security-continue")).to_have_count(0)
        verify()
        expect(page.locator("#security-continue")).to_have_count(1)
        credentials = cdp.send("WebAuthn.getCredentials", {"authenticatorId": authenticator})
        assert len(credentials["credentials"]) == 1
        browser.close()
    print(
        "Passkey browser acceptance passed: enrollment, assertion, rename, last-key guard, lock, step-up, role changes, deletion and fresh-session MFA."
    )


if __name__ == "__main__":
    try:
        run(sys.argv[1])
    except Exception:
        # Playwright exceptions can contain a token-bearing navigation URL.
        frame = traceback.extract_tb(sys.exc_info()[2])
        own = [entry for entry in frame if entry.filename == __file__]
        print(
            "Passkey browser acceptance failed at probe line " + str(own[-1].lineno),
            file=sys.stderr,
        )
        sys.exit(1)
