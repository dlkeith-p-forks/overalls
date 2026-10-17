"""Policy assertions after the real fleet's first complete browser/terminal journey."""

import argparse
from enum import StrEnum
from pathlib import Path
from urllib.parse import urlencode

from browser_journey import (  # ty: ignore[unresolved-import] # copied shared helper
    failure_kind,
    load_fixture,
    trust_workspace,
)
from playwright.sync_api import expect, sync_playwright
from policy import (  # ty: ignore[unresolved-import] # copied policy.py
    editorconfig_controls,
    run_fixture,
)


class PolicyStage(StrEnum):
    LAUNCH = "launch"
    HOME_LOAD = "home-load"
    HOME_TRUST = "home-trust"
    HOME_POLICY = "home-policy"
    OUTSIDE_LOAD = "outside-load"
    OUTSIDE_TRUST = "outside-trust"
    OUTSIDE_POLICY = "outside-policy"
    DIRENV_LOAD = "direnv-load"
    DIRENV = "direnv"
    DISABLE = "disable"
    OVERRIDES = "overrides"
    CLEANUP = "cleanup"


def main() -> None:
    """@cc [owner:ghuntley,label:verification;security] editor-fleet-live-policy-acceptance
    Policy evidence MUST use the actual authorized guest origin and completed
    browser storage from the full fleet journey. HOME and outside-HOME trust,
    defaults, EditorConfig, direnv approval and personal extension controls MUST
    use real native APIs after the first terminal proof, with no trust injection.
    """
    parser = argparse.ArgumentParser()
    parser.add_argument("fixture", type=Path)
    parser.add_argument("--chromium", required=True, type=Path)
    arguments = parser.parse_args()
    fixture = load_fixture(arguments.fixture)
    stage = PolicyStage.LAUNCH
    try:
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(
                executable_path=str(arguments.chromium),
                headless=True,
                args=["--disable-dev-shm-usage"],
            )
            try:
                context = browser.new_context(storage_state=fixture.storage_state_path)
                page = context.new_page()
                home = str(Path(fixture.workspace_file).parent)
                outside = "/opt/overalls-editor-" + fixture.expected_username
                for folder, loading, trusting, policy in (
                    (home, PolicyStage.HOME_LOAD, PolicyStage.HOME_TRUST, PolicyStage.HOME_POLICY),
                    (
                        outside,
                        PolicyStage.OUTSIDE_LOAD,
                        PolicyStage.OUTSIDE_TRUST,
                        PolicyStage.OUTSIDE_POLICY,
                    ),
                ):
                    stage = loading
                    page.goto(fixture.expected_editor_origin + "/?" + urlencode({"folder": folder}))
                    expect(page.locator(".monaco-workbench")).to_be_visible(timeout=60000)
                    stage = trusting
                    trust_workspace(page)
                    stage = policy
                    run_fixture(page, "Policy", "native-policy")
                stage = PolicyStage.DIRENV_LOAD
                page.goto(fixture.expected_editor_origin + "/?" + urlencode({"folder": home}))
                expect(page.locator(".monaco-workbench")).to_be_visible(timeout=60000)
                stage = PolicyStage.DIRENV
                run_fixture(page, "Direnv", "native-direnv")
                stage = PolicyStage.DISABLE
                editorconfig_controls(page)
                stage = PolicyStage.OVERRIDES
                run_fixture(page, "Overrides", "native-overrides")
                stage = PolicyStage.CLEANUP
                context.close()
            finally:
                browser.close()
    except Exception as error:
        # @cc [owner:ghuntley,label:verification;privacy] editor-fleet-policy-finite-failure
        # Failure MUST publish only a closed policy stage and reviewed exception
        # category; exception text and authenticated browser state stay private.
        print(
            "Editor fleet policy assertion failed: "
            + stage.value
            + "/"
            + failure_kind(error).value
            + "; private state withheld",
            flush=True,
        )
        raise SystemExit(1) from None
    print("Editor fleet native policy assertions passed", flush=True)


if __name__ == "__main__":
    main()
