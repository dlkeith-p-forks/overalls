"""Disposable terminal v2 acceptance; private login links arrive only on stdin."""

import json
import sys
import uuid

from playwright.sync_api import Dialog, Page, expect, sync_playwright

stage = "startup"
ACTIVE = "#terminal-pane-holder > div:not(.hidden) "


def command(page: Page, text: str) -> None:
    """Require an executed marker that cannot occur in the echoed command."""
    suffix = uuid.uuid4().hex
    page.bring_to_front()
    expect(page.locator("#terminal-status")).to_have_attribute("data-status", "live", timeout=30000)
    page.locator(ACTIVE + ".xterm-helper-textarea").focus()
    page.keyboard.type("(" + text + ") && printf '\\nCHECK_%s\\n' '" + suffix + "'", delay=2)
    page.keyboard.press("Enter")
    expect(page.locator(ACTIVE + ".xterm-accessibility-tree")).to_contain_text(
        "CHECK_" + suffix, timeout=30000
    )


def context(value: object) -> dict[str, str]:
    if not isinstance(value, dict):
        raise ValueError("invalid fixture context")
    required = ("base_url", "vm_id", "owner_url", "member_url", "member_email")
    result: dict[str, str] = {}
    for key in required:
        item: object = value.get(key)
        if not isinstance(item, str) or not item:
            raise ValueError("invalid fixture context")
        result[key] = item
    return result


def run(ctx: dict[str, str]) -> None:
    global stage
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(headless=True, args=["--no-sandbox"])
        try:
            # This optional disposable local harness may use its generated
            # self-signed backend. The fleet harness verifies its real fixture CA.
            owner = browser.new_context(
                ignore_https_errors=True, permissions=["clipboard-read", "clipboard-write"]
            )
            member = browser.new_context(ignore_https_errors=True)
            page, viewer = owner.new_page(), member.new_page()
            errors: list[str] = []
            machine_url = ctx["base_url"] + "/machines/" + ctx["vm_id"]
            stage = "sign-in"
            for tab, key in ((page, "owner_url"), (viewer, "member_url")):
                tab.on("pageerror", lambda _: errors.append("browser error"))
                tab.goto(ctx[key])
                expect(tab.locator("[data-phx-main].phx-connected")).to_be_visible()
                tab.wait_for_url("**/overview")
            stage = "create persistent PTY"
            page.goto(machine_url)
            expect(page.locator("[data-phx-main].phx-connected")).to_be_visible()
            expect(page.locator("[data-terminal-select]")).to_have_count(1, timeout=30000)
            session = page.locator("[data-terminal-select]").get_attribute("data-terminal-select")
            assert session is not None
            path = "browser-terminal-" + uuid.uuid4().hex
            command(
                page,
                'test "$(id -un)" != root && test "$HOME" = "/home/$(id -un)" && test "$PWD" = "$HOME"',
            )
            command(page, "printf 'one\\n' >" + path)
            stage = "explicit terminal sharing"
            page.locator(f"[data-terminal-share='{session}']").click()
            page.locator("#terminal-share-email").fill(ctx["member_email"])
            page.locator("[data-terminal-tool='share-submit']").click()
            expect(page.locator("#terminal-share-result")).to_have_text("Viewing access updated.")
            page.locator("[data-terminal-tool='share-close']").click()
            viewer.goto(machine_url + "/terminals")
            expect(viewer.locator("#terminal-status")).to_have_attribute(
                "data-status", "readonly", timeout=30000
            )
            viewer.locator(ACTIVE + ".xterm-helper-textarea").focus()
            viewer.keyboard.type("printf 'forbidden\\n' >>" + path)
            viewer.keyboard.press("Enter")
            command(page, 'test "$(wc -l <' + path + ')" = 1')
            stage = "title and clipboard consent"
            page.evaluate("navigator.clipboard.writeText('unchanged')")

            def refuse(dialog: Dialog) -> None:
                dialog.dismiss()

            page.on("dialog", refuse)
            command(page, "printf '\\033]52;c;cmVwbGFjZWQ=\\007\\033]2;native-title\\007'")
            command(page, "(sleep 1; printf '\\033]2;native-title\\007' >/dev/tty) &")
            expect(page).to_have_title("native-title · Terminals")
            assert page.evaluate("navigator.clipboard.readText()") == "unchanged"
            page.remove_listener("dialog", refuse)
            stage = "terminal-specific revocation"
            page.locator(f"[data-terminal-share='{session}']").click()
            page.locator("#terminal-share-email").fill(ctx["member_email"])
            page.locator("[data-terminal-tool='share-revoke']").click()
            expect(page.locator("#terminal-share-result")).to_have_text("Viewing access updated.")
            page.locator("[data-terminal-tool='share-close']").click()
            expect(viewer.locator("[data-terminal-select]")).to_have_count(0, timeout=20000)
            stage = "reattach without repeated input"
            page.evaluate("window.liveSocket.disconnect()")
            expect(page.locator("#terminal-status")).to_have_attribute(
                "data-status", "reconnecting"
            )
            page.evaluate("window.liveSocket.connect()")
            command(page, 'test "$(wc -l <' + path + ')" = 1 && rm -f ' + path)
            stage = "mobile layout and login revocation"
            page.set_viewport_size({"width": 390, "height": 844})
            assert page.evaluate("document.documentElement.scrollWidth <= window.innerWidth")
            admin = owner.new_page()
            admin.goto(ctx["base_url"] + "/sign-out")
            admin.locator("form[action='/sign-out'] button[type=submit]").click()
            page.wait_for_url("**/sign-in", timeout=20000)
            assert not errors
        finally:
            browser.close()


def main() -> int:
    try:
        value: object = json.loads(sys.stdin.readline())
        run(context(value))
        print("PASS: Chromium terminal v2 acceptance", flush=True)
        return 0
    except Exception as error:
        print(
            "FAIL: Chromium terminal v2 acceptance at " + stage + " (" + type(error).__name__ + ")",
            flush=True,
        )
        return 1


if __name__ == "__main__":
    sys.exit(main())
