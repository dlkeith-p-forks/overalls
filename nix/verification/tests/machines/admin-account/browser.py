"""Real browser/WebAuthn account reset and stale mounted mutation refusals."""

import subprocess
from pathlib import Path
from uuid import UUID

from playwright.sync_api import (
    Browser,
    BrowserContext,
    Dialog,
    Error,
    Page,
    expect,
    sync_playwright,
)

ORIGIN = "https://localhost"
PUSH_EVENT = Path(__file__).with_suffix(".js").read_text()


def sql(statement: str) -> str:
    """Read disposable VM state without printing credentials or row contents."""
    return subprocess.run(
        ["runuser", "-u", "postgres", "--", "psql", "-XAt", "-v", "ON_ERROR_STOP=1", "marshall"],
        input=statement,
        text=True,
        capture_output=True,
        check=True,
    ).stdout.strip()


def identity(name: str) -> str:
    assert name in {"operator", "admin", "target"}
    return str(UUID(sql(f"SELECT id FROM users WHERE email = '{name}@example.test';")))


def accept_dialog(dialog: Dialog) -> None:
    dialog.accept()


def visit(page: Page, path: str) -> None:
    page.goto(ORIGIN + path)
    expect(page).to_have_url(ORIGIN + path)
    expect(page.locator("[data-phx-main].phx-connected")).to_be_visible()


def enrolled(browser: Browser, name: str) -> tuple[BrowserContext, Page]:
    context = browser.new_context()
    page = context.new_page()
    page.on("dialog", accept_dialog)
    cdp = context.new_cdp_session(page)
    cdp.send("WebAuthn.enable")
    cdp.send(
        "WebAuthn.addVirtualAuthenticator",
        {
            "options": {
                "protocol": "ctap2",
                "transport": "internal",
                "hasResidentKey": True,
                "hasUserVerification": True,
                "isUserVerified": True,
                "automaticPresenceSimulation": True,
            }
        },
    )
    token = Path(f"/run/overalls-test/admin-account-{name}").read_text().strip()
    try:
        page.goto(ORIGIN + "/magic_link/" + token)
        expect(page.locator("[data-phx-main].phx-connected")).to_be_visible()
        page.wait_for_url("**/overview")
    except (Error, AssertionError):
        raise AssertionError("Fixture sign-in navigation failed") from None
    visit(page, "/settings")
    page.locator("#add-passkey").click()
    expect(page.locator("#passkey-list > div")).to_have_count(1)
    page.locator("#verify-passkey").click()
    expect(page.locator("#verification-status")).to_contain_text("Passkey verified")
    return context, page


def inventory(actor: str, target: str) -> str:
    """Hash complete fixture rows; comparisons include hidden credential state."""
    return sql(f"""
      SELECT md5(jsonb_build_object(
        'user', (SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM users t WHERE id = '{target}'),
        'passkeys', (SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM account_passkeys t WHERE user_id = '{target}'),
        'tokens', (SELECT jsonb_agg(to_jsonb(t) ORDER BY jti) FROM tokens t),
        'proofs', (SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM account_verifications t WHERE user_id = '{target}'),
        'audit', (SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM account_admin_events t WHERE actor_id = '{actor}'),
        'deletions', (SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM account_user_deletions t),
        'outbox', (SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM account_auth_emails t)
      )::text);
    """)


def send_event(page: Page, name: str, payload: dict[str, str]) -> None:
    page.evaluate("(" + PUSH_EVENT + ")", {"name": name, "payload": payload})


def main() -> None:
    """@cc [owner:ghuntley,label:verification] native-admin-account-authority
    Actual browser lock MUST prompt inline verification without changing target,
    credential, outbox, retirement or audit state. Cancellation MUST leave the
    action unexecuted; verification MUST resume that exact reset once and revoke
    the target's mounted login. Role demotion MUST refuse stale mutations.
    Virtual WebAuthn does not establish hardware acceptance.
    """
    actor_id, target_id = identity("admin"), identity("target")
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            executable_path="/run/current-system/sw/bin/chromium", args=["--no-sandbox"]
        )
        actor_context, mounted = enrolled(browser, "admin")
        _, operator = enrolled(browser, "operator")
        _, target = enrolled(browser, "target")
        security = actor_context.new_page()
        visit(security, "/settings")
        visit(mounted, "/admin/users")
        expect(mounted.locator(f"#reset-mfa-{target_id}")).to_be_visible()

        security.locator("#lock-elevation").click()
        expect(security.locator("#verification-status")).not_to_contain_text("Passkey verified")
        before = inventory(actor_id, target_id)
        mounted.locator(f"#reset-mfa-{target_id}").click()
        expect(mounted.locator("#admin-elevation-modal")).to_be_visible()
        expect(mounted.locator("#admin-elevation-verify")).to_be_focused()
        expect(mounted).to_have_url(ORIGIN + "/admin/users")
        assert inventory(actor_id, target_id) == before
        mounted.locator("#admin-elevation-cancel").click()
        expect(mounted.locator("#admin-elevation-modal")).not_to_be_visible()
        expect(mounted.locator(f"#reset-mfa-{target_id}")).to_be_focused()
        assert inventory(actor_id, target_id) == before
        mounted.locator(f"#reset-mfa-{target_id}").click()
        expect(mounted.locator("#admin-elevation-modal")).to_be_visible()
        mounted.locator("#admin-elevation-verify").click()
        expect(mounted.locator("#admin-elevation-modal")).not_to_be_visible()
        expect(mounted.locator("#flash-info")).to_contain_text("Account request accepted")
        assert (
            sql(
                f"SELECT mfa_reset_required AND mfa_generation = 1 FROM users WHERE id = '{target_id}';"
            )
            == "t"
        )
        assert sql(f"SELECT count(*) FROM account_passkeys WHERE user_id = '{target_id}';") == "0"
        assert (
            sql(
                f"SELECT count(*) FROM account_admin_events WHERE actor_id = '{actor_id}' AND target_id = '{target_id}' AND kind = 'mfa_reset';"
            )
            == "1"
        )
        expect(target).to_have_url(ORIGIN + "/sign-in", timeout=15000)
        stale_views = [mounted]
        for _ in range(4):
            stale = actor_context.new_page()
            visit(stale, "/admin/users")
            stale_views.append(stale)
        visit(operator, "/admin/users")
        operator.locator(f"#role-{actor_id}").click()
        expect(operator.locator(f"#role-{actor_id}")).to_have_text("Make administrator")

        # This view was mounted while elevated. Every event now needs current role.
        before = inventory(actor_id, target_id)
        events: list[tuple[str, dict[str, str]]] = [
            ("set-role", {"id": target_id, "enabled": "true"}),
            ("revoke-sessions", {"id": target_id}),
            ("reset-mfa", {"id": target_id}),
            ("invite", {"email": "target@example.test"}),
            ("delete-user", {"user_id": target_id, "confirmation": "target@example.test"}),
        ]
        for stale, (name, payload) in zip(stale_views, events, strict=True):
            send_event(stale, name, payload)
            expect(stale.locator("#flash-error")).to_contain_text(
                "Administrative changes require an administrator"
            )
            assert inventory(actor_id, target_id) == before
        visit(mounted, "/admin/users")
        expect(mounted.locator("#invite-user")).to_have_count(0)
        browser.close()


if __name__ == "__main__":
    main()
