"""Exercise the real release and browser; no guest or hardware-MFA claim."""

import os
import shlex
import subprocess
import traceback
from pathlib import Path

from playwright.sync_api import Page, Route, expect, sync_playwright


def sign_in_reader(page: Page, origin: str, token_path: Path) -> None:
    """@cc [owner:ghuntley,label:security] handbook-login-failure-custody
    Failures throughout token-bearing navigation and sign-in MUST remain fatal
    without exposing the bearer URL or Playwright's credential-bearing call log.
    """
    try:
        page.goto(origin + "/magic_link/" + token_path.read_text().strip())
        expect(page.locator("[data-phx-main].phx-connected")).to_be_visible()
        page.wait_for_url("**/overview")
        expect(page.locator("[data-phx-main].phx-connected")).to_be_visible()
    except Exception:
        raise RuntimeError("Handbook reader sign-in failed") from None


def check_login_failure_custody(page: Page, origin: str, token_path: Path) -> None:
    """@cc [owner:ghuntley,label:verification] handbook-login-error-redaction
    A real aborted token-bearing navigation MUST fail with the fixed diagnostic;
    formatted exception output MUST contain neither the token nor its login URL.
    """

    def abort_login(route: Route) -> None:
        route.abort()

    pattern = origin + "/magic_link/**"
    page.route(pattern, abort_login)
    try:
        try:
            sign_in_reader(page, origin, token_path)
        except Exception as error:
            rendered = "".join(traceback.format_exception(error))
            if (
                type(error) is not RuntimeError
                or str(error) != "Handbook reader sign-in failed"
                or token_path.read_text().strip() in rendered
                or origin + "/magic_link/" in rendered
            ):
                raise AssertionError("Handbook login failure redaction failed") from None
        else:
            raise AssertionError("Aborted handbook login unexpectedly succeeded")
    finally:
        page.unroute(pattern, abort_login)


def check_reference_navigation(page: Page) -> None:
    """@cc [owner:ghuntley,label:verification] handbook-source-code-navigation
    Both signed-in navigation contexts MUST place the Source code link immediately
    after HLDD with the exact repository destination and ordinary href navigation.
    Verification MUST NOT require an external GitHub request.
    """
    source = page.locator("#nav-hldd + a#nav-source-code")
    expect(source).to_be_visible()
    expect(source).to_contain_text("Source code")
    expect(source).to_have_attribute("href", "https://github.com/antithesishq/kittens")
    expect(page.locator("#nav-source-code[data-phx-link]")).to_have_count(0)


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


def assert_ordinary_reader() -> None:
    """@cc [owner:ghuntley,label:verification] handbook-post-login-ordinary-reader
    The persisted browser reader MUST exist with administrator=false immediately
    after login and at journey completion; the initial seed alone is insufficient.
    """
    assert (
        sql(
            "SELECT count(*), count(*) FILTER (WHERE administrator) FROM users "
            "WHERE email = 'handbook-reader@example.test'"
        )
        == "1|0"
    ), "handbook reader must remain ordinary"


def revoke_reader() -> None:
    """@cc [owner:ghuntley,label:verification] handbook-revoked-reader-refusal
    Revocation MUST change the actual stored user login and remembered credential
    before browser refusal is asserted. Only the isolated reader's token purpose may change; no token or
    subject identifiers may enter diagnostics.
    """
    assert (
        sql(
            "WITH revoked AS (UPDATE tokens t SET purpose = 'revocation' "
            "FROM users u WHERE t.subject = 'user?id=' || u.id::text "
            "AND u.email = 'handbook-reader@example.test' "
            "AND t.purpose IN ('user', 'remember_me') "
            "RETURNING 1) SELECT count(*) FROM revoked"
        )
        == "2"
    ), "exactly the reader login and remembered credential must be revoked"


def check_section(page: Page, section: str) -> int:
    article = page.locator(f"[data-hldd-section='{section}']")
    expect(article).to_be_attached()
    expect(page.locator("[data-hldd-section]")).to_have_count(1)
    expect(page.locator(".hldd-prose > section")).to_have_count(1)
    count = article.locator("pre:has(code.mermaid), pre.hldd-diagram").count()
    expect(article.locator("pre.hldd-diagram svg")).to_have_count(count, timeout=60000)
    expect(page.locator("pre.hldd-diagram svg")).to_have_count(count)
    assert "Diagram unavailable" not in article.inner_text()
    return count


def main() -> None:
    origin = os.environ.get("HLDD_TEST_ORIGIN", "https://localhost:4443")
    token_path = Path(os.environ.get("HLDD_TEST_TOKEN", "/run/overalls-test/hldd-token"))
    chromium = os.environ.get("HLDD_TEST_CHROMIUM", "/run/current-system/sw/bin/chromium")
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(executable_path=chromium, args=["--no-sandbox"])
        context = browser.new_context(viewport={"width": 1440, "height": 1000})
        page = context.new_page()
        page.goto(origin + "/hldd/security")
        expect(page).to_have_url(origin + "/sign-in")
        check_login_failure_custody(page, origin, token_path)
        sign_in_reader(page, origin, token_path)
        assert_ordinary_reader()
        check_reference_navigation(page)
        page.locator("#nav-hldd").click()
        expect(page.locator("#hldd-index")).to_be_visible()
        expect(
            page.locator("[data-hldd-section], pre code.mermaid, pre.hldd-diagram")
        ).to_have_count(0)
        sections: object = page.locator("#hldd-index a").evaluate_all(
            "links => links.map(link => link.getAttribute('href'))"
        )
        assert isinstance(sections, list) and len(sections) >= 22
        assert "/hldd/domains" in sections and "/hldd/topology" in sections
        total_diagrams = 0
        for path in sections:
            assert isinstance(path, str) and path.startswith("/hldd/")
            page.locator(f"nav[aria-label='Handbook contents'] a[href='{path}']").click()
            expect(page).to_have_url(origin + path)
            total_diagrams += check_section(page, path.removeprefix("/hldd/"))
        assert total_diagrams >= 14

        for section in ["domains", "topology"]:
            page.goto(origin + "/hldd/" + section)
            assert check_section(page, section) >= 2
            page.screenshot(path=f"/tmp/hldd-{section}.png", full_page=True)

        page.goto(origin + "/hldd/system")
        check_section(page, "system")
        page.screenshot(path="/tmp/hldd-desktop.png")
        page.locator("a[rel='next']").click()
        check_section(page, "control-plane")
        page.go_back()
        check_section(page, "system")
        page.evaluate("document.documentElement.dataset.theme = 'dark'")
        expect(page.locator("#hldd-content-system")).to_have_attribute(
            "data-hldd-rendered-theme", "dark", timeout=60000
        )
        check_section(page, "system")
        page.screenshot(path="/tmp/hldd-dark.png")
        page.goto(origin + "/admin/nodes")
        expect(page.locator("[data-phx-main].phx-connected")).to_be_visible()
        check_reference_navigation(page)
        expect(page.locator("#nav-hldd")).to_be_visible()
        page.locator("#nav-hldd").click()
        expect(page.locator("#hldd-index")).to_be_visible()
        expect(page.locator("[data-hldd-section], pre.hldd-diagram")).to_have_count(0)
        page.set_viewport_size({"width": 390, "height": 844})
        page.locator("#hldd-index a[href='/hldd/security']").click()
        expect(page).to_have_url(origin + "/hldd/security")
        check_section(page, "security")
        page.locator("#security").scroll_into_view_if_needed()
        assert page.evaluate("document.documentElement.scrollWidth <= window.innerWidth")
        security_diagram = page.locator("#security pre.hldd-diagram")
        assert security_diagram.evaluate("el => el.scrollWidth > el.clientWidth")
        assert security_diagram.locator("svg").evaluate(
            "el => el.getBoundingClientRect().width >= 576"
        )
        page.screenshot(path="/tmp/hldd-mobile.png")
        page.emulate_media(media="print")
        expect(page.locator(".hldd-contents")).to_be_hidden()
        expect(page.locator(".hldd-pagination")).to_be_hidden()
        page.emulate_media(media="screen")
        page.goto(origin + "/hldd/not-a-section")
        expect(page).to_have_url(origin + "/hldd")
        expect(page.locator("[data-hldd-section]")).to_have_count(0)
        for path in ["/docs/hldd", "/docs/hldd.md", "/hldd.md"]:
            response = page.goto(origin + path)
            assert response is not None and response.status == 404

        page.goto(origin + "/hldd/system")
        expect(page.locator("[data-phx-main].phx-connected")).to_be_visible()
        check_section(page, "system")
        # Preserve the still-authenticated cookie before the mounted page is
        # redirected; a fresh request must reject that same stale authority.
        stale_context = browser.new_context(storage_state=context.storage_state())
        revoke_reader()
        page.locator("a[rel='next']").click()
        expect(page).to_have_url(origin + "/sign-in")
        expect(page.locator("[data-hldd-section], #hldd-index")).to_have_count(0)
        stale_page = stale_context.new_page()
        stale_page.goto(origin + "/hldd/security")
        expect(stale_page).to_have_url(origin + "/sign-in")
        expect(stale_page.locator("[data-hldd-section], #hldd-index")).to_have_count(0)
        assert_ordinary_reader()
        browser.close()


if __name__ == "__main__":
    main()
