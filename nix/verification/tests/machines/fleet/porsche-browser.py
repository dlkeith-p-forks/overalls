"""Real browser key registration; credentials and navigation stay private."""

import json
import subprocess
import sys
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

from playwright.sync_api import Response, expect, sync_playwright

stage = "startup"
navigation = []


def navigation_response(response: Response) -> None:
    if response.request.is_navigation_request():
        path = urlsplit(response.url).path
        route = (
            "magic-link"
            if path.startswith("/magic_link/")
            else "authentication"
            if path.startswith("/auth/")
            else "machines"
            if path == "/machines"
            else "overview"
            if path == "/overview"
            else "sign-in"
            if path == "/sign-in"
            else "other"
        )
        navigation.append({"route": route, "status": response.status})
        del navigation[:-12]


# @cc [owner:ghuntley,label:verification;security] fleet-porsche-browser-key-authority
# Keys MUST be added and removed through the authenticated production UI.
# Tokens, browser traces and screenshots MUST NOT enter fixture diagnostics.
def run() -> None:
    global stage
    root = Path("/var/lib/fleet-porsche")
    users = json.loads((root / "users.json").read_text())
    with sync_playwright() as playwright:
        stage = "browser launch"
        browser = playwright.chromium.launch(
            executable_path="/run/current-system/sw/bin/chromium",
            headless=True,
            args=["--no-sandbox"],
        )
        try:
            mode = sys.argv[1]
            assert mode in (
                "add",
                "remove",
                "remove-owner",
                "approve",
                "approve-owner",
                "clone",
                "provision",
            )
            for role in (
                ("stranger",)
                if mode == "approve"
                else ("owner",)
                if mode in ("clone", "provision", "remove-owner", "approve-owner")
                else ("owner", "member")
            ):
                context = browser.new_context()
                page = context.new_page()
                page.on("response", navigation_response)
                stage = role + " login navigation"
                page.goto("https://control.example.test/magic_link/" + users[role + "_token"])
                stage = role + " login connection"
                expect(page.locator("[data-phx-main].phx-connected")).to_be_visible(timeout=20000)
                stage = role + " login completion"
                page.wait_for_url("**/overview")
                if mode == "provision":
                    stage = "Ubuntu image selection and provisioning"
                    page.goto("https://control.example.test/machines/new")
                    expect(page.locator("[data-phx-main].phx-connected")).to_be_visible(
                        timeout=20000
                    )
                    expect(page.locator("#machine_image_id")).to_have_value(
                        users["alternative_image_id"]
                    )
                    page.locator("#machine_profile").select_option("standard")
                    page.wait_for_url(
                        lambda url: (
                            parse_qs(urlsplit(url).query).get("machine[profile]") == ["standard"]
                        )
                    )
                    page.locator("#machine_image_id").select_option(users["image_id"])
                    page.wait_for_url(
                        lambda url: (
                            parse_qs(urlsplit(url).query).get("machine[image_id]")
                            == [users["image_id"]]
                        )
                    )
                    page.locator("#provision-submit").click()
                    page.wait_for_url(
                        lambda url: (
                            urlsplit(url).path.startswith("/machines/")
                            and urlsplit(url).path != "/machines/new"
                        )
                    )
                    vm = urlsplit(page.url).path.split("/")[-1]
                    assert str(__import__("uuid").UUID(vm)) == vm
                    (root / "provisioned-vm").write_text(vm)
                    context.close()
                    continue
                if mode == "clone":
                    stage = "clone settings navigation"
                    vm = (root / "clone-source").read_text().strip()
                    page.goto("https://control.example.test/machines/" + vm + "/settings")
                    expect(page.locator("[data-phx-main].phx-connected")).to_be_visible(
                        timeout=20000
                    )
                    stage = "clone name and request identity"
                    page.get_by_label("New machine name (optional)", exact=True).fill(
                        "porsche-browser-copy"
                    )
                    page.wait_for_url("**/*porsche-browser-copy*")
                    key = page.locator("#clone_request_key").input_value()
                    stage = "clone refresh identity"
                    page.reload()
                    expect(page.locator("[data-phx-main].phx-connected")).to_be_visible(
                        timeout=20000
                    )
                    expect(page.locator("#clone_request_key")).to_have_value(key)
                    stage = "clone submission and receipt"
                    page.locator("#submit-clone").click()
                    expect(page.locator("#clone-requests")).to_contain_text("porsche-browser-copy")
                    context.close()
                    continue
                if mode in ("approve", "approve-owner"):
                    stage = role + " approval fingerprint comparison"
                    pending = json.loads((root / "pending.json").read_text())
                    assert pending["approval_url"].startswith(
                        "https://control.example.test/ssh/approve/"
                    )
                    fingerprint = subprocess.check_output(
                        ["ssh-keygen", "-lf", str(root / (role + ".pub"))], text=True
                    ).split()[1]
                    assert pending["fingerprint"] == fingerprint
                    stage = role + " approval navigation"
                    page.goto(pending["approval_url"])
                    expect(page.locator("[data-phx-main].phx-connected")).to_be_visible(
                        timeout=20000
                    )
                    stage = role + " live approval visibility"
                    expect(page.locator("#ssh-approval-fingerprint")).to_have_text(fingerprint)
                    stage = role + " approval submission"
                    page.locator("#approve-ssh-key").click()
                    page.wait_for_url("**/settings*")
                    expect(page.locator("article")).to_contain_text(fingerprint)
                    context.close()
                    continue
                stage = role + " keys navigation"
                page.goto("https://control.example.test/settings")
                stage = role + " keys connection"
                expect(page.locator("[data-phx-main].phx-connected")).to_be_visible(timeout=20000)
                if mode == "add":
                    stage = role + " public key input"
                    page.get_by_label("Public key", exact=True).fill(
                        (root / (role + ".pub")).read_text()
                    )
                    stage = role + " label input"
                    page.get_by_label("Label (optional)", exact=True).fill("fleet-" + role)
                    stage = role + " key submission"
                    page.locator("#add-ssh-key").click()
                    stage = role + " registered key visibility"
                    expect(page.locator("article")).to_contain_text("fleet-" + role)
                else:
                    page.on("dialog", lambda dialog: dialog.accept())
                    page.get_by_role("button", name="Remove", exact=True).click()
                    expect(page.locator("#ssh-keys-empty")).to_be_visible()
                context.close()
        finally:
            browser.close()


try:
    run()
except Exception as error:
    print(
        json.dumps(
            {
                "event": "porsche_browser_failed",
                "stage": stage,
                "category": type(error).__name__,
                "navigation": navigation,
            }
        ),
        file=sys.stderr,
    )
    sys.exit(1)
