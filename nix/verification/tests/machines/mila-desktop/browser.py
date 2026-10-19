"""Approves Mila's device key in a real browser; tokens and URLs stay private."""

import json
import sys
from pathlib import Path
from urllib.parse import urlsplit

from playwright.sync_api import expect, sync_playwright

stage = "startup"


# @cc [owner:ghuntley,label:verification;security] mila-desktop-browser-approval
# The key Mila presents MUST be approved through the authenticated production
# approval page, after the fingerprint shown there equals the one Mila shows.
# Tokens, approval URLs, traces and screenshots MUST NOT enter diagnostics.
def run(token_file: Path, url_file: Path, fingerprint: str) -> None:
    global stage
    token = token_file.read_text().strip()
    approval_url = url_file.read_text().strip()
    parts = urlsplit(approval_url)
    if parts.scheme != "https" or parts.netloc != "control.example.test":
        raise ValueError("approval link is not on the deployment origin")
    if not parts.path.startswith("/ssh/approve/"):
        raise ValueError("approval link is not an approval page")
    with sync_playwright() as playwright:
        stage = "browser launch"
        browser = playwright.chromium.launch(
            executable_path="/run/current-system/sw/bin/chromium",
            headless=True,
            args=["--no-sandbox"],
        )
        try:
            context = browser.new_context()
            page = context.new_page()
            stage = "login navigation"
            page.goto("https://control.example.test/magic_link/" + token)
            stage = "login connection"
            expect(page.locator("[data-phx-main].phx-connected")).to_be_visible(timeout=20000)
            stage = "login completion"
            page.wait_for_url("**/overview")
            stage = "approval navigation"
            page.goto(approval_url)
            expect(page.locator("[data-phx-main].phx-connected")).to_be_visible(timeout=20000)
            stage = "fingerprint comparison"
            expect(page.locator("#ssh-approval-fingerprint")).to_have_text(fingerprint)
            stage = "approval submission"
            page.locator("#approve-ssh-key").click()
            # Approval stays on the page and offers the Mila link.
            expect(page.locator("#ssh-approval-approved")).to_be_visible()
            expect(page.locator("#ssh-approval-open-mila")).to_be_visible()
            stage = "approved key visibility"
            page.goto(f"{parts.scheme}://{parts.netloc}/settings")
            expect(page.locator("article")).to_contain_text(fingerprint)
            context.close()
        finally:
            browser.close()


try:
    run(Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3])
except Exception as error:
    print(
        json.dumps(
            {
                "event": "mila_browser_failed",
                "stage": stage,
                "category": type(error).__name__,
            }
        ),
        file=sys.stderr,
    )
    sys.exit(1)
