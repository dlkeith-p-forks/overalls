"""Real Marshall sessions, WebAuthn enrollment, OAuth consent and owner controls."""

import json
import sys
import uuid
from pathlib import Path
from urllib.parse import urlsplit

from playwright.sync_api import Page, expect, sync_playwright

ROOT = Path("/var/lib/fleet-default-oss")
ORIGIN = "https://control.example.test"
stage = "arguments"


def fields(path: Path) -> dict[str, str]:
    value: object = json.loads(path.read_text())
    assert isinstance(value, dict)
    result: dict[str, str] = {}
    for key, item in value.items():
        if isinstance(key, str) and isinstance(item, str):
            result[key] = item
    return result


def connected(page: Page) -> None:
    expect(page.locator("[data-phx-main].phx-connected")).to_be_visible(timeout=30000)


def run(*, create: bool = True) -> None:
    """@cc [owner:ghuntley,label:verification;security] github-fleet-browser-ceremony
    Each owner MUST sign in through the real magic-link handler, register its
    key and passkey through settings, and submit OAuth through Integrations and
    the synthetic provider consent page. Only browser-produced state/callbacks
    may create the connection; no fixture may write domain credentials.
    """
    global stage
    users = fields(ROOT / "users.json")
    machines: dict[str, str] = {}
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            executable_path="/run/current-system/sw/bin/chromium", headless=True
        )
        try:
            for role, owner in (("owner", "1"), ("member", "2")):
                context = browser.new_context()
                page = context.new_page()
                stage = role + " sign in"
                page.goto(ORIGIN + "/magic_link/" + users[role + "_token"])
                page.wait_for_url("**/overview", timeout=60000)
                page.goto(ORIGIN + "/settings")
                connected(page)
                stage = role + " register public key"
                page.get_by_label("Public key", exact=True).fill(
                    (ROOT / (role + ".pub")).read_text()
                )
                page.get_by_label("Label (optional)", exact=True).fill("github-fleet-" + role)
                page.locator("#add-ssh-key").click()
                expect(page.locator("article")).to_contain_text("github-fleet-" + role)
                stage = role + " enroll passkey"
                session = context.new_cdp_session(page)
                session.send("WebAuthn.enable")
                session.send(
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
                page.locator("#add-passkey").click()
                expect(page.locator("#passkey-list > div")).to_have_count(1)
                stage = role + " start OAuth"
                page.goto(ORIGIN + "/integrations")
                connected(page)
                page.locator("#github-com-connect button").click()
                page.wait_for_url("https://github.com/login/oauth/authorize?**", timeout=30000)
                stage = role + " provider consent and callback"
                page.get_by_label("Fixture owner", exact=True).fill(owner)
                page.locator("#authorize").click()
                page.wait_for_url(ORIGIN + "/integrations", timeout=60000)
                connected(page)
                expect(page.locator("#github-com-state")).to_have_text("Connected", timeout=30000)
                expect(page.locator("#github-com-identity")).to_contain_text("owner-" + owner)
                assert urlsplit(page.url).query == ""
                if not create:
                    context.storage_state(path=str(ROOT / (role + "-github-session.json")))
                    context.close()
                    continue
                stage = role + " create real machine"
                page.goto(ORIGIN + "/machines/new")
                connected(page)
                expect(page.locator("#machine_profile")).to_have_value("oss")
                expect(page.locator("#machine_image_id")).to_have_value(users["image_id"])
                page.locator("#provision-submit").click()
                page.wait_for_url(
                    lambda url: (
                        urlsplit(url).path.startswith("/machines/")
                        and urlsplit(url).path != "/machines/new"
                    ),
                    timeout=120000,
                )
                identifier = urlsplit(page.url).path.split("/")[-1]
                assert str(uuid.UUID(identifier)) == identifier
                machines[role] = identifier
                context.storage_state(path=str(ROOT / (role + "-github-session.json")))
                context.close()
        finally:
            browser.close()
    (ROOT / "github-machines.json").write_text(json.dumps(machines))


def control(mode: str) -> None:
    """@cc [owner:ghuntley,label:verification;security] github-fleet-browser-withdrawal
    Detach, reattach and disconnect MUST use the signed-in owner's visible
    controls. This helper MUST NOT mutate SQL, jobs, generations or credentials.
    Browser URLs/documents and raw exceptions MUST stay inside the client VM.
    """
    global stage
    machines = fields(ROOT / "github-machines.json")
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            executable_path="/run/current-system/sw/bin/chromium", headless=True
        )
        try:
            context = browser.new_context(storage_state=str(ROOT / "owner-github-session.json"))
            page = context.new_page()
            stage = mode + " owner controls"
            page.goto(ORIGIN + "/integrations")
            connected(page)
            if mode == "detach":
                page.locator("#github-com-machines").evaluate("element => element.open = true")
                page.locator('#github-com-detach input[name="github_machine[vm_id]"]').fill(
                    machines["owner"]
                )
                page.locator("#github-com-detach button").click()
                expect(page.locator("#github-com-excluded-" + machines["owner"])).to_be_visible()
            elif mode == "attach":
                page.locator("#github-com-machines").evaluate("element => element.open = true")
                row = page.locator("#github-com-excluded-" + machines["owner"])
                row.locator("button").click()
                expect(row).to_have_count(0)
            else:
                assert mode == "disconnect"
                page.on("dialog", lambda dialog: dialog.accept())
                page.locator("#github-com-disconnect").click()
                expect(page.locator("#github-com-state")).to_have_text(
                    "Disconnected", timeout=90000
                )
            context.close()
        finally:
            browser.close()


try:
    mode = sys.argv[1] if len(sys.argv) == 2 else "create"
    if mode in {"create", "connect"}:
        run(create=mode == "create")
    else:
        control(mode)
except Exception as error:
    print(
        json.dumps(
            {
                "event": "github_fleet_browser_failed",
                "stage": stage,
                "category": type(error).__name__,
            }
        ),
        file=sys.stderr,
    )
    sys.exit(1)
