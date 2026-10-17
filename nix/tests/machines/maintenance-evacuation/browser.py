"""Real elevated browser evacuation controls with private native checkpoints."""

import json
import sys
import time
import traceback
from pathlib import Path
from uuid import UUID

from playwright.sync_api import Browser, Dialog, Page, expect, sync_playwright

ROOT = Path("/var/lib/fleet-evacuation")
ORIGIN = "https://control.example.test"
PUSH_EVENT = Path(__file__).with_suffix(".js").read_text()
stage = "launch"


def fields() -> dict[str, str]:
    value: object = json.loads((ROOT / "users.json").read_text())
    assert isinstance(value, dict)
    validated: dict[str, object] = {}
    for key, field in value.items():
        assert isinstance(key, str)
        validated[key] = field
    result: dict[str, str] = {}
    for key in ("owner_token", "admin_token", "source_host"):
        field = validated.get(key)
        assert isinstance(field, str)
        result[key] = field
    assert str(UUID(result["source_host"])) == result["source_host"]
    return result


def connected(page: Page) -> None:
    expect(page.locator("[data-phx-main].phx-connected")).to_be_visible(timeout=30000)


def barrier(page: Page, name: str) -> None:
    (ROOT / (name + ".ready")).touch()
    deadline = time.monotonic() + 1800
    while not (ROOT / (name + ".go")).exists():
        assert time.monotonic() < deadline, "Evacuation browser checkpoint timed out"
        page.wait_for_timeout(250)


def accept(dialog: Dialog) -> None:
    dialog.accept()


def login(browser: Browser, token: str, elevated: bool = False) -> Page:
    context = browser.new_context()
    page = context.new_page()
    page.on("dialog", accept)
    if elevated:
        cdp = context.new_cdp_session(page)
        cdp.send("WebAuthn.enable")
        cdp.send(
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
        )
    page.goto(ORIGIN + "/magic_link/" + token)
    connected(page)
    page.wait_for_url("**/overview")
    if elevated:
        page.goto(ORIGIN + "/settings/security")
        connected(page)
        page.locator("#add-passkey").click()
        expect(page.locator("#passkey-list > div")).to_have_count(1)
        page.locator("#verify-passkey").click()
        expect(page.locator("#verification-status")).to_contain_text("Passkey verified")
    return page


def run() -> None:
    """@cc [owner:ghuntley,label:verification;security] evacuation-real-admin-browser
    Campaign request, pause, continue and resume MUST use actual browser controls
    and real passkey elevation over verified HTTPS. Ordinary preview and forged
    mutation refusal MUST leave durable state unchanged. Tokens and arbitrary
    browser exceptions MUST stay private; virtual WebAuthn proves no hardware claim.
    """
    global stage
    users = fields()
    path = ORIGIN + "/admin/nodes/" + users["source_host"]
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            executable_path="/run/current-system/sw/bin/chromium", headless=True
        )
        try:
            stage = "ordinary signed-in preview"
            ordinary = login(browser, users["owner_token"])
            ordinary.goto(path)
            connected(ordinary)
            expect(ordinary.locator("#start-evacuation")).to_have_count(0)
            barrier(ordinary, "before-preview")
            ordinary.locator("#preview-evacuation").click()
            expect(ordinary.locator("#evacuation-preview-note")).to_contain_text("Advisory")
            ordinary.evaluate("(" + PUSH_EVENT + ")", {"name": "evacuate", "payload": {}})
            expect(ordinary.locator("#flash-error")).to_contain_text(
                "Administrative changes require an administrator"
            )
            barrier(ordinary, "preview-refused")

            stage = "real administrator passkey enrollment and elevation"
            admin = login(browser, users["admin_token"], elevated=True)
            admin.goto(path)
            connected(admin)
            stage = "fixed cohort request and pause"
            admin.locator("#start-evacuation").click()
            expect(admin.locator("#evacuation-campaign")).to_contain_text("Active")
            admin.locator("#pause-evacuation").click()
            expect(admin.locator("#evacuation-campaign")).to_contain_text("Paused")
            barrier(admin, "paused")

            # ADR-0155: every relocation stops a running guest for its single
            # copy, so the running workload needs explicit downtime approval.
            stage = "approve running-workload downtime"
            approve = admin.locator("[id^='approve-']")
            expect(approve).to_have_count(1)

            def accept_downtime(dialog: Dialog) -> None:
                dialog.accept()

            admin.once("dialog", accept_downtime)
            approve.click()
            expect(admin.locator("#evacuation-workloads")).to_contain_text("Downtime approved")

            stage = "continue native guest evacuation"
            admin.locator("#continue-evacuation").click()
            expect(admin.locator("#evacuation-campaign")).to_contain_text("Active")
            barrier(admin, "continued")

            # A long real copy can outlive elevation. Reverify the existing
            # authenticator through production UI before the final control.
            stage = "fresh elevation before restoring admission"
            admin.goto(ORIGIN + "/settings/security")
            connected(admin)
            admin.locator("#verify-passkey").click()
            expect(admin.locator("#verification-status")).to_contain_text("Passkey verified")
            admin.goto(path)
            connected(admin)
            expect(admin.locator("#evacuation-campaign")).to_contain_text("Ready")
            stage = "restore admission without moving guests back"
            admin.locator("#resume-node").click()
            expect(admin.locator("#evacuation-campaign")).to_have_count(0)
            expect(admin.locator("#start-evacuation")).to_be_visible()
            barrier(admin, "resumed")
            (ROOT / "done").touch()
        finally:
            browser.close()


def main() -> int:
    try:
        run()
        print("Native browser maintenance controls passed", flush=True)
        return 0
    except BaseException as error:
        print(
            "Evacuation browser failed at "
            + stage
            + " ("
            + type(error).__name__
            + "); private data withheld",
            flush=True,
        )
        for frame in traceback.extract_tb(error.__traceback__):
            if Path(frame.filename).resolve() == Path(__file__).resolve():
                print("Fixture location: " + frame.name + ":" + str(frame.lineno), flush=True)
        return 1


if __name__ == "__main__":
    sys.exit(main())
