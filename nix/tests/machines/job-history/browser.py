"""Packaged Oban mail failure, browser retry, and redacted retained history."""

import email
import json
import re
import subprocess
import sys
import time
import traceback
from pathlib import Path
from uuid import UUID

from playwright.sync_api import Browser, BrowserContext, Dialog, Page, expect, sync_playwright

ORIGIN = "https://localhost"
ROOT = Path("/run/overalls-smtp-fixture")
WORKER = "Marshall.Accounts.Workers.DeliverAuthEmail"
STAGE = "initialization"


def sql(statement: str) -> str:
    """Read or fault-inject only the disposable VM database; never echo values."""
    return subprocess.run(
        ["runuser", "-u", "postgres", "--", "psql", "-XqAt", "-v", "ON_ERROR_STOP=1", "marshall"],
        input=statement,
        text=True,
        capture_output=True,
        check=True,
    ).stdout.strip()


def wait_sql(statement: str, expected: str, timeout: float = 30) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if sql(statement) == expected:
            return
        time.sleep(0.1)
    raise AssertionError("Expected database outcome did not arrive")


def visit(page: Page, path: str) -> None:
    page.goto(ORIGIN + path)
    expect(page).to_have_url(ORIGIN + path)
    expect(page.locator("[data-phx-main].phx-connected")).to_be_visible()


def sign_in(page: Page, name: str) -> None:
    assert name in {"reader", "admin", "operator"}
    token = Path(f"/run/overalls-test/job-history-{name}").read_text().strip()
    page.goto(ORIGIN + "/magic_link/" + token)
    expect(page.locator("[data-phx-main].phx-connected")).to_be_visible()
    page.wait_for_url("**/overview")


def accept_dialog(dialog: Dialog) -> None:
    dialog.accept()


def administrator(browser: Browser, name: str) -> tuple[BrowserContext, Page]:
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
    sign_in(page, name)
    visit(page, "/settings/security")
    page.locator("#add-passkey").click()
    expect(page.locator("#passkey-list > div")).to_have_count(1)
    page.locator("#verify-passkey").click()
    expect(page.locator("#verification-status")).to_contain_text("Passkey verified")
    return context, page


def request_failed_job(page: Page, recipient: str) -> tuple[int, str]:
    """@cc [owner:ghuntley,label:verification] native-job-failure-before-deferral
    The real worker MUST reach retryable attempt one with a recorded error before
    a fixture delays its next automatic attempt. No fixture may set worker state.
    """
    assert recipient in {"delivery-first@example.test", "delivery-second@example.test"}
    previous = int(sql(f"SELECT COALESCE(max(id),0) FROM oban_jobs WHERE worker='{WORKER}';"))
    (ROOT / "behavior").write_text("reject")
    visit(page, "/sign-in")
    page.locator("input[type=email]").fill(recipient)
    page.locator("form").filter(has=page.locator("input[type=email]")).locator(
        "button[type=submit]"
    ).click()
    # Ash Authentication's public flash component has role=alert and no
    # application #flash-info ID. Inspect the actual feedback element.
    expect(
        page.get_by_role("alert").filter(has_text="Check your email for a sign-in link")
    ).to_be_visible()
    wait_sql(f"SELECT count(*) FROM oban_jobs WHERE worker='{WORKER}' AND id>{previous};", "1")
    job_id = int(sql(f"SELECT id FROM oban_jobs WHERE worker='{WORKER}' AND id>{previous};"))
    assert job_id > 0
    wait_sql(
        f"SELECT state::text || ':' || attempt || ':' || cardinality(errors) FROM oban_jobs WHERE id={job_id};",
        "retryable:1:1",
    )
    # Freeze only automatic timing, after the genuine SMTP failure. Manual Oban
    # retry must reset this schedule and write its own audited receipt.
    assert sql(
        f"UPDATE oban_jobs SET scheduled_at=clock_timestamp()+interval '1 day' "
        f"WHERE id={job_id} AND state='retryable' AND attempt=1 RETURNING id;"
    ) == str(job_id)
    outbox = str(UUID(sql(f"SELECT args->'primary_key'->>'id' FROM oban_jobs WHERE id={job_id};")))
    assert (
        sql(
            f"SELECT status::text || ':' || (encrypted_payload IS NOT NULL)::text FROM account_auth_emails WHERE id='{outbox}';"
        )
        == "pending:true"
    )
    message = (ROOT / "last-message").read_bytes()
    message_id = email.message_from_bytes(message)["Message-ID"]
    assert message_id == f"<{outbox}@example.test>"
    (ROOT / f"rejected-{job_id}").write_bytes(message)
    assert states(job_id) == "available,executing,retryable"
    return job_id, outbox


def states(job_id: int) -> str:
    return sql(
        f"SELECT string_agg(state,',' ORDER BY id) FROM admin_job_events WHERE job_id={job_id};"
    )


def stored_job(job_id: int) -> str:
    """Exact private snapshot oracle for unchanged refused and unrelated jobs."""
    return sql(
        f"SELECT jsonb_build_object('raw',(SELECT to_jsonb(j) FROM oban_jobs j WHERE id={job_id}),"
        f"'snapshot',(SELECT to_jsonb(s) FROM admin_job_snapshots s WHERE id={job_id}),"
        f"'events',(SELECT jsonb_agg(to_jsonb(e) ORDER BY id) FROM admin_job_events e WHERE job_id={job_id}),"
        f"'audit',(SELECT jsonb_agg(to_jsonb(a) ORDER BY id) FROM admin_audit_events a WHERE resource_id='{job_id}'));"
    )


def forge_retry(page: Page) -> None:
    page.evaluate(
        """() => window.liveSocket.main.pushHookEvent(
          document.querySelector('[data-phx-main]'), null, 'retry', {})"""
    )


def assert_redacted(page: Page, job_id: int) -> None:
    values: object = json.loads((ROOT / "values.json").read_text())
    assert isinstance(values, dict)
    fields: dict[str, object] = {
        key: value for key, value in values.items() if isinstance(key, str)
    }
    password = fields.get("SMTP_PASSWORD")
    assert isinstance(password, str) and len(password) > 20
    message = email.message_from_bytes((ROOT / f"rejected-{job_id}").read_bytes())
    bodies: list[str] = []
    for part in message.walk():
        body = part.get_payload(decode=True)
        if isinstance(body, bytes):
            bodies.append(body.decode())
    tokens = re.findall(r"/magic_link/([A-Za-z0-9._-]+)", "\n".join(bodies))
    assert tokens
    retained = sql(
        f"SELECT to_jsonb(s)::text FROM admin_job_snapshots s WHERE id={job_id} "
        f"UNION ALL SELECT to_jsonb(e)::text FROM admin_job_events e WHERE job_id={job_id};"
    )
    browser_text = page.content()
    for secret in [password, *tokens]:
        assert secret not in browser_text
        assert secret not in retained
    assert '"args"' not in retained and '"errors"' not in retained
    assert "encrypted_payload" not in retained


def main() -> None:
    """@cc [owner:ghuntley,label:verification] native-audited-job-retry
    Real signed-in browsing and WebAuthn elevation MUST gate retries of the displayed
    failed job. One receipt MUST bind its administrator and job before success;
    refused actions MUST preserve exact raw/history/audit rows. Pruning MUST retain
    read-only history, and revoked login MUST remove mounted and fresh access.
    """
    global STAGE
    admin_id = str(UUID(sql("SELECT id FROM users WHERE email='admin@example.test';")))
    reader_id = str(UUID(sql("SELECT id FROM users WHERE email='reader@example.test';")))
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            executable_path="/run/current-system/sw/bin/chromium", args=["--no-sandbox"]
        )
        request_context = browser.new_context()
        request = request_context.new_page()
        STAGE = "actual packaged worker failures"
        first, first_outbox = request_failed_job(request, "delivery-first@example.test")
        second, _ = request_failed_job(request, "delivery-second@example.test")
        unchanged_second = stored_job(second)

        STAGE = "ordinary reader filtering and refusal"
        reader_context = browser.new_context()
        reader = reader_context.new_page()
        sign_in(reader, "reader")
        visit(reader, "/admin/jobs")
        reader.locator("#job-filters select[name='filters[state]']").select_option("retryable")
        reader.locator("#job-filters input[name='filters[queue]']").fill("mail")
        reader.get_by_role("button", name="Filter jobs").click()
        expect(reader.locator(f"#jobs-{first}")).to_contain_text("Retrying")
        expect(reader.locator(f"#jobs-{second}")).to_be_visible()
        reader.locator(f"#jobs-{first} a").click()
        expect(reader.locator("#job-detail")).to_contain_text("Retrying")
        expect(reader.locator("#retry-job")).to_have_count(0)
        expect(reader.locator("#job-events")).to_contain_text("Running")
        assert_redacted(reader, first)
        before = stored_job(first)
        forge_retry(reader)
        expect(reader.locator("#flash-error")).to_contain_text("require an administrator")
        assert stored_job(first) == before

        STAGE = "elevated manual retry and actual SMTP acceptance"
        admin_context, admin = administrator(browser, "admin")
        visit(admin, f"/admin/jobs/{first}")
        expect(admin.locator("#retry-job")).to_be_visible()
        assert sql(f"SELECT count(*) FROM admin_audit_events WHERE resource_id='{first}';") == "0"
        (ROOT / "behavior").write_text("accept")
        admin.locator("#retry-job").click()
        expect(admin.locator("#flash-info")).to_contain_text("Retry queued")
        wait_sql(
            f"SELECT count(*) FROM admin_audit_events WHERE action='retry_job' AND actor_id='{admin_id}' AND resource_id='{first}';",
            "1",
        )
        wait_sql(
            f"SELECT state::text || ':' || attempt FROM oban_jobs WHERE id={first};", "completed:2"
        )
        assert states(first) == "available,executing,retryable,available,executing,completed"
        assert (
            sql(
                f"SELECT status::text || ':' || (encrypted_payload IS NULL)::text FROM account_auth_emails WHERE id='{first_outbox}';"
            )
            == "delivered:true"
        )
        assert (
            email.message_from_bytes((ROOT / "last-message").read_bytes())["Message-ID"]
            == f"<{first_outbox}@example.test>"
        )
        expect(admin.locator("#job-detail")).to_contain_text("Succeeded", timeout=15000)
        expect(admin.locator("#retry-job")).to_have_count(0)
        assert_redacted(admin, first)
        assert stored_job(second) == unchanged_second

        STAGE = "current elevation and role refusals"
        visit(admin, f"/admin/jobs/{second}")
        security = admin_context.new_page()
        visit(security, "/settings/security")
        security.locator("#lock-elevation").click()
        forge_retry(admin)
        expect(admin.locator("#admin-elevation-modal")).to_be_visible()
        expect(admin).to_have_url(ORIGIN + f"/admin/jobs/{second}")
        assert stored_job(second) == unchanged_second
        admin.locator("#admin-elevation-cancel").click()
        expect(admin.locator("#admin-elevation-modal")).not_to_be_visible()
        visit(admin, "/settings/security")
        admin.locator("#verify-passkey").click()
        expect(admin.locator("#verification-status")).to_contain_text("Passkey verified")
        visit(admin, f"/admin/jobs/{second}")
        operator_context, operator = administrator(browser, "operator")
        visit(operator, "/admin/users")
        operator.locator(f"#role-{admin_id}").click()
        expect(operator.locator(f"#role-{admin_id}")).to_have_text("Make administrator")
        forge_retry(admin)
        expect(admin.locator("#flash-error")).to_contain_text("require an administrator")
        assert stored_job(second) == unchanged_second
        assert sql(f"SELECT count(*) FROM admin_audit_events WHERE resource_id='{second}';") == "0"

        STAGE = "pruned history and current login revocation"
        events_before = states(first)
        assert sql(
            f"DELETE FROM oban_jobs WHERE id={first} AND state='completed' RETURNING id;"
        ) == str(first)
        visit(operator, f"/admin/jobs/{first}")
        expect(operator.locator("#job-detail")).to_contain_text("Archived history")
        expect(operator.locator("#retry-job")).to_have_count(0)
        before = stored_job(first)
        forge_retry(operator)
        expect(operator.locator("#flash-error")).to_contain_text("could not be retried")
        assert stored_job(first) == before
        assert states(first) == events_before
        visit(reader, f"/admin/jobs/{first}")
        expect(reader.locator("#job-detail")).to_contain_text("Archived history")
        assert_redacted(reader, first)
        visit(operator, "/admin/users")
        operator.locator(f"#sessions-{reader_id}").click()
        expect(operator.locator("#flash-info")).to_contain_text("Browser sessions revoked")
        expect(reader).to_have_url(ORIGIN + "/sign-in", timeout=15000)
        reader.goto(ORIGIN + f"/admin/jobs/{first}")
        expect(reader).to_have_url(ORIGIN + "/sign-in")
        assert stored_job(second) == unchanged_second
        operator_context.close()
        browser.close()


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # Only reviewed source coordinates and an exception class may escape;
        # Playwright exception messages can contain token-bearing URLs.
        frames = traceback.extract_tb(error.__traceback__)
        owned = [frame for frame in frames if Path(frame.filename).name == "browser.py"]
        location = f"{owned[-1].name}:{owned[-1].lineno}" if owned else "unknown"
        print(
            f"Job history browser failed during {STAGE}: {type(error).__name__} at {location}",
            file=sys.stderr,
        )
        raise SystemExit(1) from None
