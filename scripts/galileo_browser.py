#!/usr/bin/env python3
"""Opt-in browser acceptance using a private, disposable fixture login receipt."""

import argparse
from pathlib import Path

from galileo_acceptance import Acceptance, fields, read, text
from playwright.sync_api import Dialog, expect, sync_playwright


def run(directory: Path, executable: Path) -> None:
    """@cc [owner:ghuntley,label:verification;security] galileo-browser-fixture-boundary
    Browser mutations MUST use the disposable account identified by the retained
    fixture receipt and only this run's browser integration. Secrets MUST clear
    after successful and failed submissions and never appear in rendered HTML.
    Tokens, traces, screenshots and raw browser diagnostics MUST NOT be printed.
    """
    acceptance = Acceptance(directory)
    fixture = read(directory / "foreign-fixture.json")
    authentication = read(directory / "browser-auth.json")
    if authentication.get("user_id") != fixture.get("user_id"):
        raise ValueError("Browser account does not match the disposable fixture")
    source = acceptance.owned("source")
    target = acceptance.owned("target")
    name = acceptance.prefix + "-browser"
    origin = "https://" + acceptance.config["host"]
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            executable_path=str(executable), headless=True, args=["--no-sandbox"]
        )
        state = directory / "browser-state.json"
        context = browser.new_context(storage_state=str(state) if state.exists() else None)
        page = context.new_page()
        try:
            if not state.exists():
                acceptance.save("browser-phase.json", {"phase": "sign-in"})
                response = page.goto(origin + "/magic_link/" + text(authentication["token"]))
                acceptance.save(
                    "browser-phase.json",
                    {"phase": "sign-in", "status": None if response is None else response.status},
                )
                assert response is not None and response.status == 200
                page.wait_for_url("**/overview", timeout=30000)
                context.storage_state(path=str(state))
            page.goto(origin + "/integrations")
            expect(page.locator("[data-phx-main].phx-connected")).to_be_visible(timeout=30000)
            expect(page.locator(".account-email").first).to_have_text(
                acceptance.prefix + "-fixture@example.test"
            )
            form = page.locator("#integration-form")
            acceptance.save("browser-phase.json", {"phase": "invalid-submission"})
            form.get_by_label("Name", exact=True).fill(name)
            form.get_by_label("HTTPS target", exact=True).fill("http://invalid.example.test")
            form.get_by_label("Bearer token (write-only)", exact=True).fill("galileo-synthetic")
            form.get_by_label("Basic user:pass (write-only)", exact=True).fill("galileo:synthetic")
            form.get_by_label("Static header name (optional)", exact=True).fill("x-galileo-fixture")
            form.get_by_label("Static header value (optional)", exact=True).fill(
                "galileo-synthetic"
            )
            form.get_by_role("button", name="Save integration", exact=True).click()
            expect(
                page.get_by_text("Could not save this integration.", exact=False)
            ).to_be_visible()
            acceptance.save(
                "browser-phase.json",
                {
                    "phase": "invalid-secret-reset",
                    "cleared": form.get_by_label(
                        "Bearer token (write-only)", exact=True
                    ).input_value()
                    == "",
                    "html_redacted": "galileo-synthetic" not in page.content(),
                },
            )
            for label in (
                "Bearer token (write-only)",
                "Basic user:pass (write-only)",
                "Static header value (optional)",
            ):
                expect(form.get_by_label(label, exact=True)).to_have_value("")
            assert "galileo-synthetic" not in page.content()
            assert "galileo:synthetic" not in page.content()
            acceptance.save("browser-phase.json", {"phase": "valid-submission"})
            form.get_by_label("Name", exact=True).fill(name)
            form.get_by_label("HTTPS target", exact=True).fill(
                "https://" + text(target["ssh_host"])
            )
            form.get_by_label("Static header name (optional)", exact=True).fill("")
            form.get_by_label("Bearer token (write-only)", exact=True).fill("galileo-synthetic")
            form.get_by_role("button", name="Save integration", exact=True).click()
            article = page.locator("#integrations article").filter(
                has_text=name + ".integration.internal"
            )
            expect(article).to_be_visible()
            expect(form.get_by_label("Bearer token (write-only)", exact=True)).to_have_value("")
            assert "galileo-synthetic" not in page.content()
            element_id = article.get_attribute("id")
            assert element_id is not None and element_id.startswith("integration-")
            integration_id = element_id.removeprefix("integration-")
            acceptance.save(
                "browser-integration.json",
                {"result": {"id": integration_id, "name": name}, "owner_id": fixture["user_id"]},
            )
            acceptance.save("browser-phase.json", {"phase": "attachment"})
            attachment = article.locator("form")
            attachment.locator("input[name='attachment[vm_id]']").fill(text(source["id"]))
            attachment.get_by_role("button", name="Attach", exact=True).click()
            expect(article.locator("[phx-click='detach']")).to_be_visible()
            acceptance.probe("source", name, "probe", "bearer")
            article.locator("[phx-click='detach']").click()
            expect(article.locator("[phx-click='detach']")).to_have_count(0)

            def confirm_removal(dialog: Dialog) -> None:
                if dialog.message == "Remove this integration?":
                    dialog.accept()
                else:
                    dialog.dismiss()

            page.on("dialog", confirm_removal)
            article.get_by_role("button", name="Remove", exact=True).click()
            expect(article).to_have_count(0)
            acceptance.save(
                "browser-result.json",
                fields(
                    {
                        "secret_reset": True,
                        "redacted": True,
                        "attached_probe": True,
                        "removed": True,
                    }
                ),
            )
        finally:
            context.close()
            browser.close()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("executable", type=Path)
    arguments = parser.parse_args()
    try:
        run(arguments.directory, arguments.executable)
    except Exception as error:
        # Library errors can contain the sign-in URL: retain only the closed class.
        raise SystemExit("Browser acceptance failed: " + type(error).__name__) from None
    print("Browser integration acceptance passed")


if __name__ == "__main__":
    main()
