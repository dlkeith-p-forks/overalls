"""Real browser consent joins the packaged CLI to the isolated fleet."""

import json
import os
import re
import subprocess
import sys
import time
import uuid
from pathlib import Path

from playwright.sync_api import Page, expect, sync_playwright

ROOT = Path("/var/lib/fleet-agent-cli")
ORIGIN = "https://control.example.test"
stage = "launch"


def fields() -> dict[str, str]:
    value: object = json.loads((ROOT / "users.json").read_text())
    assert isinstance(value, dict)
    fields: dict[str, object] = {}
    for key, item in value.items():
        assert isinstance(key, str)
        fields[key] = item
    result: dict[str, str] = {}
    for key in ("owner_token", "member_token", "member_email"):
        field = fields.get(key)
        assert isinstance(field, str)
        result[key] = field
    return result


def connected(page: Page) -> None:
    expect(page.locator("[data-phx-main].phx-connected")).to_be_visible(timeout=20000)


def checkpoint(name: str) -> None:
    (ROOT / (name + ".ready")).touch()
    deadline = time.monotonic() + 600
    while not (ROOT / (name + ".continue")).exists():
        assert time.monotonic() < deadline, "coordination deadline"
        time.sleep(0.2)


def share(page: Page, vm: str, email: str, role: str) -> None:
    page.goto(ORIGIN + "/machines/" + vm + "/access")
    connected(page)
    page.locator("#sharing-form input[type=email]").fill(email)
    page.locator("#sharing-form select").select_option(role)
    page.locator("#share-submit").click()
    expect(page.locator("#flash-info")).to_contain_text("Access updated.")


def invocation(
    page: Page, vm: str, name: str, prompt: str, approve: bool, owner: Page | None = None
) -> None:
    """@cc [owner:ghuntley,label:verification;security] native-cli-real-consent
    The unmodified packaged CLI MUST generate and retain its own random secret.
    Only its parsed digest URL may enter the browser; neither setup nor the driver
    may manufacture an approved session or turn result. Process output stays in
    private fixture files and only closed stages enter diagnostics.
    """
    global stage
    stdout = ROOT / (name + ".stdout")
    stderr = ROOT / (name + ".stderr")
    source = ROOT / (name + ".stdin")
    source.write_text(prompt + "\n")
    environment = dict(os.environ)
    environment["SSL_CERT_FILE"] = str(ROOT / "ca.crt")
    with source.open("rb") as input_file, stdout.open("wb") as output, stderr.open("wb") as errors:
        process = subprocess.Popen(
            ["overalls", "agent", "--machine", vm],
            stdin=input_file,
            stdout=output,
            stderr=errors,
            env=environment,
        )
        try:
            deadline = time.monotonic() + 30
            approval: re.Match[str] | None = None
            while approval is None:
                assert process.poll() is None, "CLI exited before approval"
                assert time.monotonic() < deadline, "CLI approval deadline"
                approval = re.fullmatch(
                    re.escape("Open " + ORIGIN + "/agents/cli/approve/" + vm + "/")
                    + r"([0-9a-f]{64}) and approve code ([0-9a-f]{12})\n",
                    stderr.read_text(),
                )
                time.sleep(0.1)
            code = approval.group(1)
            assert code[:12] == approval.group(2)
            prior_codes = (
                (ROOT / "digests").read_text().splitlines() if (ROOT / "digests").exists() else []
            )
            assert code not in prior_codes
            with (ROOT / "digests").open("a") as history:
                history.write(code + "\n")
            stage = name + " approval GET"
            page.goto(ORIGIN + "/agents/cli/approve/" + vm + "/" + code)
            connected(page)
            expect(page.locator("#agent-cli-approval")).to_be_visible()
            expect(page.locator("strong.font-mono")).to_have_text(code[:12])
            checkpoint(name + "-get")
            if owner is not None:
                stage = "ordinary sharing withdrawal"
                owner.locator("#share-submit").click()
                expect(owner.locator("#flash-info")).to_contain_text("Access updated.")
                checkpoint("withdrawn")
            stage = name + " explicit approval"
            page.locator("#agent-cli-approval button").click()
            if approve:
                page.wait_for_url("**/machines/" + vm + "/threads")
                stage = name + " CLI completion"
                code_status = process.wait(timeout=600)
                stage = name + " CLI exit status"
                if name == "retry":
                    assert code_status == 0
                    stage = name + " CLI final response"
                    assert stdout.read_text() == "fixture agent reply\n"
                else:
                    assert code_status == 1
                    stage = name + " CLI failure reason"
                    assert stderr.read_text().endswith("Agent turn failed: tool_uncertain\n")
                checkpoint(name)
            else:
                expect(page.locator("#flash-error")).to_contain_text(
                    "This agent CLI approval is unavailable."
                )
                expect(page.locator("#agent-cli-approval")).to_have_count(0)
                assert stdout.read_bytes() == b""
                checkpoint("refused")
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=10)


def run() -> None:
    global stage
    os.umask(0o077)
    users = fields()
    vm = (ROOT / "vm-id").read_text().strip()
    assert str(uuid.UUID(vm)) == vm
    config = Path.home() / ".config/overalls"
    config.mkdir(mode=0o700, parents=True, exist_ok=True)
    (config / "config.json").write_text(json.dumps({"origin": ORIGIN, "zone": "apps.example.test"}))
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            executable_path="/run/current-system/sw/bin/chromium", headless=True
        )
        try:
            pages: dict[str, Page] = {}
            for role in ("owner", "member"):
                stage = role + " login"
                page = browser.new_context().new_page()
                page.goto(ORIGIN + "/magic_link/" + users[role + "_token"])
                connected(page)
                page.wait_for_url("**/overview")
                pages[role] = page
            stage = "ordinary sharing"
            share(pages["owner"], vm, users["member_email"], "operator")
            checkpoint("shared")
            invocation(pages["member"], vm, "lost", "Perform interruptible effect", True)
            invocation(pages["member"], vm, "retry", "Explicitly retry effect", True)
            # A second owner page remains live while the member waits at its
            # third approval form. The driver asks this page to remove access.
            owner = pages["owner"]
            owner.goto(ORIGIN + "/machines/" + vm + "/access")
            connected(owner)
            owner.locator("#sharing-form input[type=email]").fill(users["member_email"])
            owner.locator("#sharing-form select").select_option("revoked")
            invocation(pages["member"], vm, "stale", "Explicitly retry effect", False, owner)
        finally:
            browser.close()


try:
    run()
except Exception as error:
    print(
        json.dumps(
            {"event": "agent_cli_browser_failed", "stage": stage, "category": type(error).__name__}
        ),
        file=sys.stderr,
    )
    sys.exit(1)
