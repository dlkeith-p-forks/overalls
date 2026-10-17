"""Exercise committed team authority through three real browser login sessions."""

import shlex
import subprocess
from pathlib import Path

from playwright.sync_api import Browser, Page, expect, sync_playwright

ORIGIN = "https://localhost:4443"


def login(browser: Browser, name: str) -> Page:
    page = browser.new_context(viewport={"width": 1440, "height": 1000}).new_page()
    token = Path(f"/run/overalls-test/team-{name}-token").read_text().strip()
    page.goto(ORIGIN + "/magic_link/" + token)
    expect(page.locator("[data-phx-main].phx-connected")).to_be_visible()
    page.wait_for_url("**/overview")
    teams(page)
    return page


def teams(page: Page) -> None:
    page.goto(ORIGIN + "/teams")
    expect(page.locator("[data-phx-main].phx-connected")).to_be_visible()


def create(page: Page, name: str, *, allowed: bool = True) -> None:
    page.locator("#team-form input[name='team[name]']").fill(name)
    page.locator("#team-form button").click()
    message = f"Team {name} created." if allowed else "Could not create this team."
    expect(page.get_by_text(message, exact=True)).to_be_visible()
    if not allowed:
        expect(page.get_by_text(f"Team {name} created.", exact=True)).to_have_count(0)


def member(page: Page, name: str, role: str, *, allowed: bool = True) -> None:
    form = page.locator("#member-form")
    form.locator("input[name='member[email]']").fill(f"team-{name}@example.test")
    form.locator("select").select_option(role)
    form.locator("button[type='submit']").click()
    if allowed:
        if role == "removed":
            expect(
                page.locator("#teams").get_by_text(f"team-{name}@example.test", exact=True)
            ).to_have_count(0)
        else:
            assert_role(page, name, role)
    message = "Membership updated." if allowed else "Could not update this membership."
    expect(page.get_by_text(message, exact=True)).to_be_visible()


def offer(page: Page, name: str, *, allowed: bool = True) -> None:
    form = page.locator("#transfer-offer-form")
    form.locator("input[name='transfer[email]']").fill(f"team-{name}@example.test")
    form.locator("button").click()
    message = "Ownership offer sent." if allowed else "Could not offer ownership."
    expect(page.get_by_text(message, exact=True)).to_be_visible()


def assert_role(page: Page, name: str, role: str) -> None:
    row = page.locator("#teams").get_by_text(f"team-{name}@example.test", exact=True).locator("..")
    expect(row.get_by_text(role, exact=True)).to_be_visible()


def assert_ordinary_accounts() -> None:
    """@cc [owner:ghuntley,label:verification] teams-post-login-ordinary-authority
    All three browser accounts MUST have persisted administrator=false after login
    and after team operations; a seeded ordinary flag alone is insufficient proof.
    """
    query = (
        "SELECT count(*), count(*) FILTER (WHERE administrator) FROM users "
        "WHERE email IN ('team-owner@example.test', 'team-target@example.test', "
        "'team-admin@example.test')"
    )
    result = subprocess.run(
        [
            "su",
            "-s",
            "/bin/sh",
            "postgres",
            "-c",
            "psql --no-psqlrc -d marshall -Atc " + shlex.quote(query),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    assert result.stdout.strip() == "3|0", "browser accounts must remain ordinary"


def main() -> None:
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            executable_path="/run/current-system/sw/bin/chromium", args=["--no-sandbox"]
        )
        owner = login(browser, "owner")
        target = login(browser, "target")
        admin = login(browser, "admin")
        assert_ordinary_accounts()
        create(owner, "native-authority")
        expect(owner.locator("#member-form")).to_be_visible()
        teams(owner)
        create(owner, "native-authority")
        assert_role(owner, "owner", "owner")
        # Creation collision refusals must leave the caller without a team.
        create(target, "native-authority", allowed=False)
        expect(target.locator("#teams")).to_have_count(0)
        teams(target)
        expect(target.locator("#teams")).to_have_count(0)
        member(owner, "target", "member")
        member(owner, "admin", "admin")
        teams(admin)
        member(admin, "owner", "removed", allowed=False)
        assert_role(admin, "owner", "owner")

        stale_owner = owner.context.new_page()
        teams(stale_owner)
        expect(stale_owner.locator("#transfer-offer-form")).to_be_visible()
        offer(owner, "target")
        teams(target)
        target.locator("#accept-transfer").click()
        expect(target.locator("#transfer-offer-form")).to_be_visible()
        assert_role(target, "target", "owner")
        assert_role(target, "owner", "admin")

        # This page predates the transfer: its visible form carries no authority.
        offer(stale_owner, "admin", allowed=False)
        member(target, "owner", "removed")
        member(owner, "admin", "member", allowed=False)
        teams(target)
        assert_role(target, "admin", "admin")
        expect(target.get_by_text("team-owner@example.test", exact=True)).to_have_count(0)
        teams(owner)
        expect(owner.locator("#teams")).to_have_count(0)
        # Neither former nor current ownership turns creation into a new claim.
        create(owner, "native-authority", allowed=False)
        expect(owner.locator("#teams")).to_have_count(0)
        teams(target)
        create(target, "native-authority", allowed=False)
        assert_role(target, "target", "owner")
        create(owner, "native-created-after-collision")
        assert_role(owner, "owner", "owner")
        assert_ordinary_accounts()
        owner.screenshot(path="/tmp/teams-creation.png")
        target.screenshot(path="/tmp/teams-authority.png")
        browser.close()


if __name__ == "__main__":
    main()
