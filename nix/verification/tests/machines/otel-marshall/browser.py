"""Exercise browser authority after diagnostic views move to Grafana."""

import shlex
import subprocess
from pathlib import Path

from playwright.sync_api import Page, expect, sync_playwright


def sql(query: str) -> str:
    result = subprocess.run(
        [
            "su",
            "-s",
            "/bin/sh",
            "postgres",
            "-c",
            "psql --no-psqlrc -v ON_ERROR_STOP=1 -d marshall -Atc " + shlex.quote(query),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def sign_in(page: Page, origin: str, token_path: Path) -> None:
    """@cc [owner:ghuntley,label:security] slo-browser-token-custody
    Token-bearing URLs and Playwright call logs MUST NOT enter failure output.
    """
    try:
        page.goto(origin + "/magic_link/" + token_path.read_text().strip())
        expect(page.locator("[data-phx-main].phx-connected")).to_be_visible()
        page.wait_for_url("**/overview")
    except Exception:
        raise RuntimeError("SLO reader sign-in failed") from None


def revoke_reader() -> None:
    """@cc [owner:ghuntley,label:security] slo-browser-revocation
    Only the isolated reader's login and remembered token may be revoked;
    exactly one of each MUST change before browser refusal is asserted.
    """
    assert (
        sql(
            "WITH revoked AS (UPDATE tokens t SET purpose = 'revocation' "
            "FROM users u WHERE t.subject = 'user?id=' || u.id::text "
            "AND u.email = 'slo-reader@example.test' "
            "AND t.purpose IN ('user', 'remember_me') "
            "RETURNING 1) SELECT count(*) FROM revoked"
        )
        == "2"
    ), "exactly the SLO reader login and remembered credential must be revoked"


def main() -> None:
    origin = "https://localhost:4443"
    token_path = Path("/run/overalls-test/otel-slo-token")
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            executable_path="/run/current-system/sw/bin/chromium", args=["--no-sandbox"]
        )
        context = browser.new_context()
        page = context.new_page()
        for removed in ("/admin/slos", "/admin/logs"):
            assert page.request.get(origin + removed).status == 404
        sign_in(page, origin, token_path)
        assert (
            sql(
                "SELECT count(*), count(*) FILTER (WHERE administrator) FROM users "
                "WHERE email = 'slo-reader@example.test'"
            )
            == "1|0"
        ), "SLO reader must remain ordinary"
        page.goto(origin + "/overview")
        expect(page.locator("[data-phx-main].phx-connected")).to_be_visible()
        for removed in ("/admin/slos", "/admin/logs"):
            assert page.request.get(origin + removed).status == 404
            assert page.locator(f'a[href="{removed}"]').count() == 0
        stale_context = browser.new_context(storage_state=context.storage_state())
        revoke_reader()
        page.reload()
        expect(page).to_have_url(origin + "/sign-in")
        stale_page = stale_context.new_page()
        stale_page.goto(origin + "/overview")
        expect(stale_page).to_have_url(origin + "/sign-in")
        browser.close()


if __name__ == "__main__":
    main()
