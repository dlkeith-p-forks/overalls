"""Repository capture, new-tab sign-in continuation and real browser launches."""

import json
import sys
import uuid
from pathlib import Path
from urllib.parse import urlsplit

from playwright.sync_api import Browser, BrowserContext, CDPSession, Page, expect, sync_playwright

ROOT = Path("/var/lib/fleet-default-oss")
ORIGIN = "https://control.example.test"
FORMS = ("default", "branch", "commit", "pull")
stage = "launch"


class LaunchRefused(RuntimeError):
    """Fixed failure category for a terminal admission refusal."""


def string_fields(path: Path, required: tuple[str, ...]) -> dict[str, str]:
    """@cc [owner:ghuntley,label:verification] repository-launch-fixture-field-types
    Fixture JSON MUST be an object whose required fields are strings; a missing
    or non-string required field fails the journey before a browser starts.
    """
    value: object = json.loads(path.read_text())
    assert isinstance(value, dict)
    fields: dict[str, object] = {}
    for name, item in value.items():
        assert isinstance(name, str)
        fields[name] = item
    result: dict[str, str] = {}
    for key in required:
        field = fields.get(key)
        assert isinstance(field, str)
        result[key] = field
    return result


def connected(page: Page) -> None:
    expect(page.locator("[data-phx-main].phx-connected")).to_be_visible(timeout=20000)


def machine_id(page: Page) -> str:
    """@cc [owner:ghuntley,label:verification;privacy] repository-launch-terminal-refusal
    Waiting for machine navigation MUST stop at a terminal launch refusal. Its
    failure category MUST remain fixed and MUST NOT include submitted sources,
    provider responses, authentication URLs or browser document contents.
    """
    page.wait_for_function(
        """() => {
          const path = window.location.pathname;
          return (path.startsWith('/machines/') && path !== '/machines/new') ||
            document.querySelector('#repository-launch[data-status="refused"]') !== null;
        }""",
        timeout=120000,
    ).dispose()
    if page.locator('#repository-launch[data-status="refused"]').count() > 0:
        raise LaunchRefused
    page.wait_for_url(
        lambda url: (
            urlsplit(url).path.startswith("/machines/") and urlsplit(url).path != "/machines/new"
        ),
        timeout=120000,
    )
    vm_id = urlsplit(page.url).path.split("/")[2]
    assert str(uuid.UUID(vm_id)) == vm_id
    assert urlsplit(page.url).fragment == ""
    return vm_id


def launch(page: Page, url: str) -> str:
    page.goto(ORIGIN + "/#" + url)
    return machine_id(page)


def signed_in(
    browser: Browser, users: dict[str, str], source: str
) -> tuple[BrowserContext, Page, str]:
    global stage
    stage = "unsigned repository capture"
    context = browser.new_context()
    page = context.new_page()
    page.goto(ORIGIN + "/#" + source)
    page.wait_for_url("**/sign-in**", timeout=60000)
    assert urlsplit(page.url).fragment == ""
    stage = "new tab owner login resumes pending launch"
    login_page = context.new_page()
    login_page.goto(ORIGIN + "/magic_link/" + users["owner_token"])
    vm_id = machine_id(login_page)
    login_page.close()
    stage = "owner key registration"
    page.goto(ORIGIN + "/settings")
    connected(page)
    page.get_by_label("Public key", exact=True).fill((ROOT / "owner.pub").read_text())
    page.get_by_label("Label (optional)", exact=True).fill("repository-launch-owner")
    page.locator("#add-ssh-key").click()
    expect(page.locator("article")).to_contain_text("repository-launch-owner")
    return context, page, vm_id


def enrolled_launch(page: Page, token: str, source: str) -> str:
    """@cc [owner:ghuntley,label:verification;security] repository-launch-native-mfa
    A normal subsequent magic-link login for an enrolled account MUST resume
    its staged repository without passkey verification. Registration MUST use
    a real WebAuthn ceremony; this helper MUST NOT seed passkey authority.
    """
    global stage
    stage = "register launch owner passkey"
    session: CDPSession = page.context.new_cdp_session(page)
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
    page.goto(ORIGIN + "/settings")
    connected(page)
    page.locator("#add-passkey").click()
    expect(page.locator("#passkey-list > div")).to_have_count(1)
    stage = "sign out after passkey enrollment"
    page.goto(ORIGIN + "/sign-out")
    page.get_by_role("button", name="Sign out", exact=True).click()
    page.wait_for_url("**/sign-in**", timeout=60000)
    stage = "capture branch while signed out"
    page.goto(ORIGIN + "/#" + source)
    page.wait_for_url("**/sign-in**", timeout=60000)
    stage = "subsequent enrolled login resumes launch without elevation"
    page.goto(ORIGIN + "/magic_link/" + token)
    return machine_id(page)


def run() -> None:
    """@cc [owner:ghuntley,label:verification;security] repository-launch-browser-entry
    Launch links MUST be opened as real `/#<url>` navigations. Reload, back and a
    repeated visit in the same tab MUST return the same machine; a fresh browser
    session MUST create a new one. Anonymous capture MUST reach sign-in, and a
    magic link in another tab of the same context MUST resume its launch. A
    subsequent enrolled login MUST resume without requiring passkey elevation.
    Unsupported hosts MUST be refused before admission. Tokens stay in this helper.
    """
    global stage
    users = string_fields(ROOT / "users.json", ("owner_token", "owner_mfa_token"))
    urls = string_fields(ROOT / "launch-urls.json", FORMS)
    created: dict[str, str] = {}
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            executable_path="/run/current-system/sw/bin/chromium", headless=True
        )
        try:
            context, page, created["default"] = signed_in(browser, users, urls["default"])
            created["branch"] = enrolled_launch(page, users["owner_mfa_token"], urls["branch"])
            for form in FORMS[2:]:
                stage = form + " launch"
                created[form] = launch(page, urls[form])
            stage = "reload keeps machine"
            page.reload()
            assert machine_id(page) == created["pull"]
            stage = "back does not relaunch"
            page.go_back()
            page.wait_for_url(
                lambda url: urlsplit(url).path in ("/overview",) or "/machines/" in url,
                timeout=60000,
            )
            stage = "same tab revisit reuses machine"
            assert launch(page, urls["default"]) == created["default"]
            stage = "unsupported host refused"
            page.goto(ORIGIN + "/#https://unsupported.example.test/overalls/fixture")
            expect(
                page.get_by_text("This repository link could not be launched.", exact=False)
            ).to_be_visible(timeout=20000)
            assert urlsplit(page.url).path == "/launch/pending"
            context.storage_state(path=str(ROOT / "browser-state.json"))
            context.close()
            stage = "anonymous visitor sees sign-in"
            anonymous = browser.new_context()
            anonymous_page = anonymous.new_page()
            anonymous_page.goto(ORIGIN + "/#" + urls["default"])
            anonymous_page.wait_for_url("**/sign-in**", timeout=60000)
            anonymous.close()
        finally:
            browser.close()
    (ROOT / "launched.json").write_text(json.dumps(created))


def fresh() -> None:
    """@cc [owner:ghuntley,label:verification] repository-launch-fresh-session
    A new browser session of the same signed-in user MUST create a new machine
    for a link it has not visited, distinct from every earlier launch.
    """
    global stage
    urls = string_fields(ROOT / "launch-urls.json", FORMS)
    earlier = string_fields(ROOT / "launched.json", FORMS)
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            executable_path="/run/current-system/sw/bin/chromium", headless=True
        )
        try:
            stage = "fresh session creates a new machine"
            context = browser.new_context(storage_state=str(ROOT / "browser-state.json"))
            vm_id = launch(context.new_page(), urls["default"])
            assert vm_id not in earlier.values()
            context.close()
        finally:
            browser.close()
    (ROOT / "fresh-vm").write_text(vm_id)


def provider(key: str) -> None:
    """@cc [owner:ghuntley,label:verification] repository-provider-browser-entry
    Each provider/ref case MUST navigate through the real capture, session,
    admission and matched-clear flow. The driver validates its guest checkout
    and removes it before the next case, keeping capacity bounded.
    """
    global stage
    urls = string_fields(ROOT / "launch-urls.json", (key,))
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            executable_path="/run/current-system/sw/bin/chromium", headless=True
        )
        try:
            stage = "provider " + key
            context = browser.new_context(storage_state=str(ROOT / "browser-state.json"))
            vm_id = launch(context.new_page(), urls[key])
            context.close()
        finally:
            browser.close()
    (ROOT / "provider-vm").write_text(vm_id)


mode = sys.argv[1] if len(sys.argv) > 1 else "launch"

try:
    if mode == "fresh":
        fresh()
    elif mode == "provider":
        assert len(sys.argv) == 3
        provider(sys.argv[2])
    else:
        run()
except Exception as error:
    print(
        json.dumps(
            {
                "event": "repository_launch_browser_failed",
                "mode": mode,
                "stage": stage,
                "category": type(error).__name__,
            }
        ),
        file=sys.stderr,
    )
    sys.exit(1)
