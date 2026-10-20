"""Disposable public Git mirror journey through packaged Marshall and Enrico."""

import subprocess
import time
from pathlib import Path
from uuid import UUID

from playwright.sync_api import CDPSession, Dialog, Error, Page, expect, sync_playwright

ORIGIN = "https://localhost"
SOURCE = "/tmp/git-mirror-source"
REMOTE = "/var/lib/git-fixture/fixture/sample.git"
REPOSITORY = "/git/github/fixture/sample"


def run(arguments: list[str]) -> str:
    return subprocess.run(arguments, text=True, capture_output=True, check=True).stdout.strip()


def sql(statement: str) -> str:
    """Read independent durable state in the disposable machine only."""
    return subprocess.run(
        ["runuser", "-u", "postgres", "--", "psql", "-XAt", "-v", "ON_ERROR_STOP=1", "marshall"],
        input=statement,
        text=True,
        capture_output=True,
        check=True,
    ).stdout.strip()


def wait_sql(statement: str, expected: str) -> None:
    deadline = time.monotonic() + 70
    while time.monotonic() < deadline:
        if sql(statement) == expected:
            return
        time.sleep(0.1)
    raise AssertionError("Git catalog did not reach the expected committed state")


def visit(page: Page, path: str) -> None:
    page.goto(ORIGIN + path)
    expect(page.locator("[data-phx-main].phx-connected")).to_be_visible()


def sign_in(page: Page, name: str) -> None:
    assert name in {"admin", "reader"}
    token = Path(f"/run/overalls-test/git-{name}").read_text().strip()
    try:
        page.goto(ORIGIN + "/magic_link/" + token)
        expect(page.locator("[data-phx-main].phx-connected")).to_be_visible()
        page.wait_for_url("**/overview")
    except (Error, AssertionError):
        raise AssertionError("Disposable Git fixture sign-in failed") from None


def enable_authenticator(session: CDPSession) -> None:
    session.send("WebAuthn.enable")
    session.send(
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


def download(page: Page, path: str) -> tuple[int, str]:
    result: object = page.evaluate(
        """async path => {
          const response = await fetch(path);
          return [response.status, await response.text()];
        }""",
        path,
    )
    assert isinstance(result, list) and len(result) == 2
    code: object = result[0]
    body: object = result[1]
    assert isinstance(code, int) and isinstance(body, str)
    return code, body


def accept(dialog: Dialog) -> None:
    dialog.accept()


def commit(contents: str) -> str:
    Path(SOURCE, "hello.txt").write_text(contents)
    run(["git", "-C", SOURCE, "add", "hello.txt"])
    run(
        [
            "git",
            "-C",
            SOURCE,
            "-c",
            "user.email=fixture@example.test",
            "-c",
            "user.name=Fixture",
            "commit",
            "-qm",
            contents,
        ]
    )
    return run(["git", "-C", SOURCE, "rev-parse", "HEAD"])


def main() -> None:
    """@cc [owner:ghuntley,label:verification] git-browser-current-authority
    Real browser elevation MUST admit catalog mutations. Ordinary authenticated
    tree, file, history and raw reads MUST use published content; source failure
    MUST retain it. Removal MUST refuse stale-page/raw requests and delete cache.
    Login tokens MUST never enter output; TLS verification MUST remain enabled.
    """
    run(["git", "init", "-q", SOURCE])
    first = commit("first")
    Path(REMOTE).parent.mkdir(parents=True, exist_ok=True)
    run(["git", "clone", "-q", "--bare", SOURCE, REMOTE])
    run(["git", "--git-dir=" + REMOTE, "update-server-info"])

    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            executable_path="/run/current-system/sw/bin/chromium", args=["--no-sandbox"]
        )
        admin_context = browser.new_context()
        admin = admin_context.new_page()
        admin.on("dialog", accept)
        enable_authenticator(admin_context.new_cdp_session(admin))
        sign_in(admin, "admin")
        visit(admin, "/admin/git")
        inventory = """SELECT
          (SELECT count(*) FROM enrico_repositories),
          (SELECT count(*) FROM enrico_audit_events),
          (SELECT count(*) FROM oban_jobs
           WHERE worker='Marshall.Enrico.Worker' AND args ? 'id');"""
        before = sql(inventory)
        assert before == "0|0|0"
        admin.locator('input[name="git[owner]"]').fill("Fixture")
        admin.locator('input[name="git[repo]"]').fill("sample")
        admin.get_by_role("button", name="Add mirror", exact=True).click()
        admin.wait_for_url("**/settings**")
        expect(admin.locator("[data-phx-main].phx-connected")).to_be_visible()
        assert sql(inventory) == before
        visit(admin, "/settings")
        admin.locator("#add-passkey").click()
        expect(admin.locator("#passkey-list > div")).to_have_count(1)
        admin.locator("#verify-passkey").click()
        expect(admin.locator("#verification-status")).to_contain_text("Passkey verified")
        visit(admin, "/admin/git")
        admin.locator('input[name="git[owner]"]').fill("Fixture")
        admin.locator('input[name="git[repo]"]').fill("sample")
        admin.get_by_role("button", name="Add mirror", exact=True).click()
        expect(admin.locator("#flash-info")).to_contain_text("Repository registered")
        wait_sql(
            "SELECT phase || '|' || head FROM enrico_repositories WHERE owner='fixture' AND name='sample';",
            "ready|" + first,
        )
        repository_id = str(
            UUID(sql("SELECT id FROM enrico_repositories WHERE owner='fixture' AND name='sample';"))
        )
        admin_id = str(UUID(sql("SELECT id FROM users WHERE email='admin@example.test';")))
        assert (
            sql(
                f"SELECT count(*) FROM enrico_audit_events WHERE repository_id='{repository_id}' AND kind='registered' AND actor_id='{admin_id}';"
            )
            == "1"
        )

        reader = browser.new_page()
        sign_in(reader, "reader")
        assert sql("SELECT administrator FROM users WHERE email='reader@example.test';") == "f"
        visit(reader, "/admin/git")
        for action in ["Add mirror", "Refresh", "Remove"]:
            expect(reader.get_by_role("button", name=action, exact=True)).to_have_count(0)
        visit(reader, "/git")
        reader.get_by_role("link", name="github/fixture/sample", exact=True).click()
        reader.get_by_role("link", name="hello.txt", exact=True).click()
        expect(reader.locator("pre")).to_have_text("first")
        first_raw = reader.get_by_role("link", name="Download raw file").get_attribute("href")
        assert first_raw is not None and first in first_raw
        assert download(reader, first_raw) == (200, "first")
        visit(reader, REPOSITORY + "?view=history&path=hello.txt")
        expect(reader.get_by_text("first", exact=True)).to_be_visible()

        second = commit("second")
        run(["git", "-C", SOURCE, "push", "-q", REMOTE, "HEAD"])
        run(["git", "--git-dir=" + REMOTE, "update-server-info"])
        visit(admin, "/admin/git")
        admin.get_by_role("button", name="Refresh", exact=True).click()
        wait_sql(
            f"SELECT phase || '|' || head FROM enrico_repositories WHERE id='{repository_id}';",
            "ready|" + second,
        )
        assert download(reader, first_raw) == (200, "first")
        visit(reader, REPOSITORY)
        reader.get_by_role("link", name="hello.txt", exact=True).click()
        expect(reader.locator("pre")).to_have_text("second")
        second_raw = reader.get_by_role("link", name="Download raw file").get_attribute("href")
        assert second_raw is not None and second in second_raw
        assert download(reader, second_raw) == (200, "second")

        run(["systemctl", "stop", "nginx.service"])
        visit(admin, "/admin/git")
        admin.get_by_role("button", name="Refresh", exact=True).click()
        wait_sql(
            f"SELECT phase || '|' || head FROM enrico_repositories WHERE id='{repository_id}';",
            "failed|" + second,
        )
        assert (
            int(
                sql(
                    f"SELECT count(*) FROM enrico_audit_events WHERE repository_id='{repository_id}' AND kind='refresh_failed' AND failure_reason='git_failed';"
                )
            )
            >= 1
        )
        assert download(reader, second_raw) == (200, "second")
        assert (
            run(
                [
                    "git",
                    "--git-dir=/var/lib/enrico/" + repository_id + ".git",
                    "show",
                    second + ":hello.txt",
                ]
            )
            == "second"
        )

        anonymous = browser.new_page()
        visit(anonymous, "/sign-in")
        assert download(anonymous, second_raw)[0] == 404
        visit(admin, "/admin/git")
        admin.get_by_role("button", name="Remove", exact=True).click()
        expect(admin.locator("#flash-info")).to_contain_text("Removal queued")
        assert download(reader, second_raw)[0] == 404
        visit(reader, REPOSITORY + "?view=history&path=hello.txt")
        expect(reader.get_by_role("alert")).to_have_text("Repository unavailable.")
        expect(reader.locator("pre")).to_have_count(0)
        wait_sql(f"SELECT count(*) FROM enrico_repositories WHERE id='{repository_id}';", "0")
        assert not Path("/var/lib/enrico", repository_id + ".git").exists()
        assert (
            sql(
                f"SELECT count(*) FROM enrico_audit_events WHERE repository_id='{repository_id}' AND kind='remove_requested' AND actor_id='{admin_id}';"
            )
            == "1"
        )
        assert (
            sql(
                f"SELECT count(*) FROM enrico_audit_events WHERE repository_id='{repository_id}' AND kind='removed' AND actor_id IS NULL;"
            )
            == "1"
        )
        browser.close()
        print("Git mirror browser registration, reads, refresh, source failure and removal passed")


if __name__ == "__main__":
    main()
