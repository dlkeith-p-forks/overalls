"""Ordinary users register their own keys through the shipped settings page."""

import json
import sys
from pathlib import Path

from playwright.sync_api import expect, sync_playwright

ROOT = Path("/var/lib/fleet-team-resources")
ORIGIN = "https://control.example.test"
stage = "launch"


def fields() -> dict[str, str]:
    value: object = json.loads((ROOT / "users.json").read_text())
    assert isinstance(value, dict)
    checked: dict[str, object] = {}
    for raw_key, raw_value in value.items():
        assert isinstance(raw_key, str)
        checked[raw_key] = raw_value
    result: dict[str, str] = {}
    for key in ("owner_token", "member_token", "stranger_token"):
        selected = checked.get(key)
        assert isinstance(selected, str)
        result[key] = selected
    return result


def run() -> None:
    """@cc [owner:ghuntley,label:verification;security] team-resource-browser-identities
    Each ordinary account MUST register its own real public key through the
    settings UI. Authentication stays on verified HTTPS; token-bearing URLs,
    assertion details and unfiltered browser exceptions MUST remain private.
    """
    global stage
    users = fields()
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            executable_path="/run/current-system/sw/bin/chromium", headless=True
        )
        try:
            for role in ("owner", "member", "stranger"):
                stage = role + " login"
                context = browser.new_context()
                page = context.new_page()
                page.goto(ORIGIN + "/magic_link/" + users[role + "_token"])
                stage = role + " login connection"
                expect(page.locator("[data-phx-main].phx-connected")).to_be_visible()
                stage = role + " login landing"
                page.wait_for_url("**/overview")
                stage = role + " key registration"
                page.goto(ORIGIN + "/settings")
                expect(page.locator("[data-phx-main].phx-connected")).to_be_visible()
                page.get_by_label("Public key", exact=True).fill(
                    (ROOT / (role + ".pub")).read_text()
                )
                page.get_by_label("Label (optional)", exact=True).fill("team-resource-" + role)
                page.locator("#add-ssh-key").click()
                expect(page.locator("article")).to_contain_text("team-resource-" + role)
                context.close()
        finally:
            browser.close()


try:
    run()
except Exception as error:
    print(
        json.dumps(
            {
                "event": "team_resource_browser_failed",
                "stage": stage,
                "category": type(error).__name__,
            }
        ),
        file=sys.stderr,
    )
    sys.exit(1)
