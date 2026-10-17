"""Native editor policy, immutable defaults and independent personal controls."""

import argparse
import hashlib
import re
from pathlib import Path
from urllib.parse import urlencode

from browser_journey import trust_workspace  # ty: ignore[unresolved-import] # copied shared helper
from playwright.sync_api import Page, expect, sync_playwright

from browser import (  # ty: ignore[unresolved-import] # copied native browser.py
    ai_controls,
    command,
    notice,
)


def run_fixture(page: Page, name: str, marker: str) -> None:
    command(page, "Overalls Fixture: Native " + name)
    notice(page, "Native fixture " + marker + " passed")
    if name == "Policy":
        ai_controls(page)


def editorconfig_controls(page: Page) -> None:
    """@cc [owner:ghuntley,label:verification] editor-personal-builtin-disable
    The immutable EditorConfig default MUST remain disableable through the real
    extension editor. This fixture MUST reload and prove absence through the
    extension host API, leaving another account's independent state untouched.
    """
    command(page, "Extensions: Show Built-in Extensions")
    entry = page.locator(".extensions-search-container .monaco-editor").first
    expect(entry).to_be_visible()
    entry.click()
    page.keyboard.press("Control+a")
    page.keyboard.insert_text("@builtin EditorConfig")
    item = page.locator(".extension-list-item").filter(has_text="EditorConfig").first
    expect(item).to_be_visible(timeout=30000)
    item.click()
    editor = page.locator(".extension-editor")
    expect(editor).to_contain_text("EditorConfig")
    editor.get_by_role("button", name="Disable this extension", exact=True).click()
    expect(editor.get_by_role("button", name="Enable this extension", exact=True)).to_be_visible()
    # The workbench reload awaits its IndexedDB shutdown flush; raw browser
    # navigation cannot guarantee that asynchronous beforeunload writes finish.
    with page.expect_navigation(wait_until="domcontentloaded"):
        command(page, "Developer: Reload Window")
    expect(page.locator(".monaco-workbench")).to_be_visible(timeout=60000)
    trust_workspace(page)
    run_fixture(page, "Disabled", "native-disabled")


def main() -> None:
    """@cc [owner:ghuntley,label:verification;privacy] editor-personal-browser-profile
    Repeated policy journeys MUST use one private, persistent browser profile
    per fixture origin. A new browser profile MUST NOT be mistaken for retained
    user enablement state, and another origin MUST retain independent state.
    """
    parser = argparse.ArgumentParser()
    parser.add_argument("origin")
    parser.add_argument("folder")
    parser.add_argument(
        "mode",
        choices=(
            "defaults",
            "direnv",
            "disable",
            "disabled",
            "overrides",
            "rust",
            "elixir",
            "version",
        ),
    )
    arguments = parser.parse_args()
    origin, folder, mode = arguments.origin, arguments.folder, arguments.mode
    assert isinstance(origin, str) and origin in {
        "https://e-ceirceircfardairceirceirce-ceirceircfardairceirceirce.apps.example.test",
        "https://e-ceirceircfardairceirceirce-eirceircejbcfarceirceircei.apps.example.test",
    }
    assert isinstance(folder, str) and re.fullmatch(
        r"/(?:home/(?:alice|bob)/workspace|opt/overalls-editor-(?:alice|bob|rust|elixir))",
        folder,
    )
    assert isinstance(mode, str)
    profile_root = Path("/tmp/overalls-editor-policy")
    profile_root.mkdir(mode=0o700, exist_ok=True)
    profile_root.chmod(0o700)
    profile = profile_root / hashlib.sha256(origin.encode()).hexdigest()
    profile.mkdir(mode=0o700, exist_ok=True)
    profile.chmod(0o700)
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch_persistent_context(
            user_data_dir=profile,
            executable_path="/run/current-system/sw/bin/chromium",
            headless=True,
            args=["--no-sandbox", "--disable-dev-shm-usage"],
        )
        try:
            page = browser.new_page()
            page.goto(origin + "/?" + urlencode({"folder": folder}))
            expect(page.locator(".monaco-workbench")).to_be_visible(timeout=60000)
            trust_workspace(page)
            if mode == "disable":
                editorconfig_controls(page)
            else:
                title, marker = {
                    "defaults": ("Policy", "native-policy"),
                    "direnv": ("Direnv", "native-direnv"),
                    "disabled": ("Disabled", "native-disabled"),
                    "overrides": ("Overrides", "native-overrides"),
                    "rust": ("Rust", "native-rust"),
                    "elixir": ("Elixir", "native-elixir"),
                    "version": ("Version", "native-version"),
                }[mode]
                run_fixture(page, title, marker)
            print("Editor native policy " + mode + " passed", flush=True)
        finally:
            browser.close()


if __name__ == "__main__":
    main()
