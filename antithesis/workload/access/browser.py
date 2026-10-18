"""Real HTTPS and LiveView browser authority journeys against Marshall replicas."""

from __future__ import annotations

import json
import logging
import os
import stat
import time
from pathlib import Path
from urllib.parse import urlparse
from uuid import UUID, uuid4

from antithesis.assertions import always, reachable

from access.fixture import AccessFixture, Actor, read_access_fixture
from access.http import BrowserClient, hidden_form
from access.liveview import LiveView, parse_live_page
from access.oracle import AccessOracle
from access.session import (
    LinkSource,
    Login,
    _jwt_jti,
    _magic_page,
    _request_and_page,
    _submit_magic,
    _value,
    login_fixture,
    verify_fixture_login,
)
from core.config import Config
from core.outcome import State
from core.sql import SqlOracle

LOG = logging.getLogger(__name__)


def pending_read_ok(
    status: int, live_main: bool, login_verified: bool, logins_unchanged: bool
) -> bool:
    """@cc [owner:ghuntley,label:verification;security] pending-mfa-ordinary-read
    Under ADR-0160 a pending-MFA login's protected read MUST be served as a
    rendered LiveView page while its stored login remains unverified and no
    further stored login is issued. A redirect is not the expected contract.
    """
    return status == 200 and live_main and not login_verified and logins_unchanged


def pending_mutation_refused(
    passkeys_unchanged: bool, login_verified: bool, logins_unchanged: bool
) -> bool:
    """A privileged credential change from an unverified login commits nothing."""
    return passkeys_unchanged and not login_verified and logins_unchanged


def _pending_rename_refused(
    config: Config, context: BrowserClient, origin: str, actor: Actor, login_jti: str
) -> bool | None:
    """@cc [owner:ghuntley,label:verification;security] pending-mfa-mutation-refusal
    The privileged probe MUST use the copied pending-login session on the given
    replica, send a real AccountLive credential rename with a fresh label for
    the actor's existing passkey, and compare the stored passkey inventory,
    verification and login rows. A missing page, mount, reply or SQL read MUST
    return None (unexercised), never a refusal.
    """
    oracle = AccessOracle(SqlOracle(config))
    before = _value(oracle.passkeys(actor.user_id))
    tokens_before = _value(oracle.tokens(actor.user_id))
    if before is None or tokens_before is None or not before:
        return None
    response = _value(context.request("GET", f"{origin}/settings"))
    # ADR-0160 keeps Security reachable for a signed-in login so setup is not
    # circular; any other reply sends no mutation and proves nothing.
    if response is None or response.status != 200:
        return None
    page = parse_live_page(response.body)
    if page is None:
        return None
    mounted = _value(LiveView.mount(context, origin, "/settings", page, config.ca_file))
    if mounted is None:
        return None
    try:
        credential_id, _label = min(before)
        replied = mounted.event(
            "credential",
            {
                "operation": "rename",
                "id": str(credential_id),
                "label": f"pending-{uuid4().hex[:12]}",
            },
        )
    finally:
        mounted.close()
    if replied.state is not State.OBSERVED:
        return None
    after = _value(oracle.passkeys(actor.user_id))
    completed = _value(oracle.completed_verifications(actor.user_id))
    tokens_after = _value(oracle.tokens(actor.user_id))
    if after is None or completed is None or tokens_after is None:
        return None
    return pending_mutation_refused(
        before == after, login_jti in completed, tokens_before.user == tokens_after.user
    )


def run_magic_preview(config: Config, links: LinkSource, fixture: AccessFixture) -> int:
    """@cc [owner:ghuntley,label:verification] magic-preview-independent-authority
    The preview assertion MUST require SMTP link capture and a stored valid
    magic token, then compare stored login/remember rows and the browser cookie
    before and after a repeated GET. Pending-MFA claims MUST require an
    enrolled account and compare the exact new login's verification state:
    per ADR-0160 its ordinary read is served without elevation, while a
    privileged passkey change is refused with no stored effect.
    Unavailable HTTP or SQL MUST leave those checkpoints unexercised.
    """
    actor = fixture.target
    origin_a, origin_b = config.marshall_urls[:2]
    oracle = AccessOracle(SqlOracle(config))
    actor_state = _value(oracle.account(actor.email))
    if actor_state is None or not actor_state.mfa_enabled:
        return 0
    before = _value(oracle.tokens(actor.user_id))
    if before is None:
        return 0
    obtained = _request_and_page(config, links, actor.email, origin_a)
    if obtained is None:
        return 0
    browser, path, token, page = obtained
    token_id = _jwt_jti(token)
    if token_id is None:
        return 0
    valid_before = _value(oracle.token_jti(token_id, "magic_link"))
    if valid_before is not True:
        return 0
    second = _magic_page(browser, origin_a, path)
    valid_after = _value(oracle.token_jti(token_id, "magic_link"))
    after_preview = _value(oracle.tokens(actor.user_id))
    if valid_before is None or valid_after is None or after_preview is None or second is None:
        return 0
    preview_ok = (
        valid_after
        and before.user == after_preview.user
        and before.remember == after_preview.remember
        and not browser.has_cookie("remember")
    )
    always(
        preview_ok,
        "Magic-link preview and pending MFA cannot grant browser work authority",
        {"stage": "repeated_get_preview", "replica": "a"},
    )
    if not preview_ok:
        return 0
    host_b = urlparse(origin_b).hostname
    replay_context = browser.copied_session(host_b) if host_b is not None else None
    posted = _submit_magic(browser, origin_a, page)
    if posted is None or posted.status != 302:
        return 0
    after_post = _value(oracle.tokens(actor.user_id))
    if after_post is None:
        return 0
    issued = after_post.user - after_preview.user
    if len(issued) != 1:
        return 0
    login_jti = next(iter(issued))
    reachable("Magic-link CSRF POST created one stored login before MFA")
    if replay_context is not None:
        replay_form = hidden_form(page.body, "/auth/user/magic_link")
        if replay_form is not None:
            replayed = _value(
                replay_context.request("POST", f"{origin_b}/auth/user/magic_link", form=replay_form)
            )
            replay_tokens = _value(oracle.tokens(actor.user_id))
            if replayed is not None and replay_tokens is not None:
                always(
                    replay_tokens.user == after_post.user,
                    "Replayed magic-link POST creates no second stored browser login",
                    {"replica": "b"},
                )
    pending_context = browser.copied_session(host_b) if host_b is not None else None
    if pending_context is None:
        return 0
    # ADR-0160: email authentication establishes the ordinary signed-in session
    # even for an enrolled account; passkey step-up gates privileged mutations
    # only. The superseded ADR-0123/ADR-0131 read-boundary redirect is not the
    # contract, so the read must be served and must mint no authority.
    pending = _value(pending_context.request("GET", f"{origin_b}/overview"))
    completed = _value(oracle.completed_verifications(actor.user_id))
    pending_tokens = _value(oracle.tokens(actor.user_id))
    if pending is None or completed is None or pending_tokens is None or pending.status >= 500:
        # A server error is unavailable evidence, not a classified refusal.
        return 0
    read_ok = pending_read_ok(
        pending.status,
        parse_live_page(pending.body) is not None,
        login_jti in completed,
        pending_tokens.user == after_post.user,
    )
    always(
        read_ok,
        "Magic-link pending MFA login serves ordinary reads on another replica without elevation",
        {"stage": "pending_mfa_read", "replica": "b"},
    )
    if not read_ok:
        return 0
    refused = _pending_rename_refused(config, pending_context, origin_b, actor, login_jti)
    if refused is None:
        return 0
    always(
        refused,
        "Magic-link pending MFA login cannot change a passkey on another replica before step-up",
        {"stage": "pending_mfa_mutation", "replica": "b", "event": "credential-rename"},
    )
    if refused and origin_a == fixture.webauthn_origin:
        pending_login = Login(browser, actor.user_id, login_jti, origin_a)
        if verify_fixture_login(config, pending_login, actor, fixture.webauthn_origin):
            reachable("Same-login WebAuthn verification completed after pending-MFA probes")
    return 0


def _sign_out(browser: BrowserClient, origin: str) -> bool:
    page = _value(browser.request("GET", f"{origin}/sign-out"))
    if page is None or page.status != 200:
        return False
    form = hidden_form(page.body, "/sign-out")
    if form is None:
        return False
    response = _value(browser.request("POST", f"{origin}/sign-out", form=form))
    return response is not None and response.status in (302, 303)


def run_remembered_revocation(config: Config, links: LinkSource) -> int:
    """@cc [owner:ghuntley,label:verification] remember-replay-committed-fence
    The revocation assertion MUST follow a real successful exchange on B and
    definite A sign-out, then compare stored login/remember JTI sets before
    and after a fresh replay on B. Unavailable reads or replies MUST NOT be
    interpreted as a refused replay.
    """
    if len(config.marshall_urls) < 2:
        return 0
    origin_a, origin_b = config.marshall_urls[:2]
    host_b = urlparse(origin_b).hostname
    if host_b is None:
        return 0
    email = f"remember-{uuid4().hex}@example.test"
    obtained = _request_and_page(config, links, email, origin_a)
    if obtained is None:
        return 0
    browser, _path, _token, page = obtained
    signed_in = _submit_magic(browser, origin_a, page)
    if signed_in is None or signed_in.status != 302:
        return 0
    oracle = AccessOracle(SqlOracle(config))
    account = _value(oracle.account(email))
    if account is None or account.mfa_enabled:
        return 0
    first = _value(oracle.tokens(account.user_id))
    if first is None or len(first.remember) != 1 or len(first.user) != 1:
        return 0
    before_context = browser.copied_cookie("remember", host_b)
    replay_context = browser.copied_cookie("remember", host_b)
    if before_context is None or replay_context is None:
        return 0
    exchanged = _value(before_context.request("GET", f"{origin_b}/overview"))
    after_exchange = _value(oracle.tokens(account.user_id))
    if exchanged is None or after_exchange is None or exchanged.status != 200:
        return 0
    if len(after_exchange.user - first.user) != 1:
        return 0
    reachable("Remembered cookie exchanged through second Marshall before sign-out")
    if not _sign_out(browser, origin_a):
        return 0
    fenced = _value(oracle.tokens(account.user_id))
    if fenced is None or fenced.remember:
        return 0
    replay = _value(replay_context.request("GET", f"{origin_b}/overview"))
    after_replay = _value(oracle.tokens(account.user_id))
    if replay is None or after_replay is None:
        return 0
    unchanged = after_replay.user == fenced.user and after_replay.remember == fenced.remember
    redirected = (
        replay.status in (302, 303)
        and replay.location is not None
        and replay.location.startswith("/sign-in")
    )
    # A 5xx (B cannot reach PostgreSQL under a partition) is Marshall's
    # inconclusive refusal (live_user_auth.ex revoked-login-halts-operation
    # raises on mount when the Repo does not answer): it must commit nothing,
    # but it cannot redirect.
    refused = (redirected or replay.status >= 500) and unchanged
    always(
        refused,
        "Revoked remembered cookie cannot mint or use browser authority across Marshall replicas",
        {"fence": "ordinary_sign_out", "replica": "b", "status_class": replay.status // 100},
    )
    blocked = redirected and unchanged
    if blocked:
        reachable("Copied remembered cookie was refused on second Marshall after sign-out")
    return 0


class AccessOperator:
    def __init__(self, requests: Path, results: Path) -> None:
        self._requests = requests
        self._results = results

    def demote_admin_b(self, user_id: UUID) -> bool:
        """Use the fixture's closed Ash action, never direct database mutation."""
        request_id = uuid4()
        body = {
            "version": 1,
            "operation": "demote_admin_b",
            "request_id": str(request_id),
            "expected_user_id": str(user_id),
        }
        temporary = self._requests / f".{request_id}.tmp"
        final = self._requests / f"{request_id}.json"
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            with os.fdopen(descriptor, "w", encoding="ascii") as stream:
                json.dump(body, stream, separators=(",", ":"))
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.link(temporary, final)
            temporary.unlink()
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise
        result_path = self._results / f"{request_id}.json"
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            try:
                metadata = result_path.lstat()
                if not stat.S_ISREG(metadata.st_mode) or metadata.st_mode & 0o077:
                    return False
                parsed: object = json.loads(result_path.read_text(encoding="ascii"))
            except FileNotFoundError:
                time.sleep(0.1)
                continue
            except (OSError, ValueError, UnicodeError):
                return False
            return (
                isinstance(parsed, dict)
                and parsed.get("version") == 1
                and parsed.get("request_id") == str(request_id)
                and parsed.get("status") == "applied"
                and parsed.get("operation") == "demote_admin_b"
                and parsed.get("user_id") == str(user_id)
            )
        return False


def run_stale_admin(
    config: Config, links: LinkSource, fixture: AccessFixture, operator: AccessOperator
) -> int:
    """@cc [owner:ghuntley,label:verification] stale-admin-effect-inventory
    The stale-event assertion MUST require a real mounted B tab, current
    verified login, definite Ash demotion by A, an acknowledged post-fence
    LiveView event and unchanged target/audit inventory. A missing reply or
    database result MUST remain unexercised.
    """
    if len(config.marshall_urls) < 2:
        return 0
    origin_b = config.marshall_urls[1]
    if fixture.webauthn_origin not in config.marshall_urls:
        return 0
    actor = fixture.admin_b
    login = login_fixture(config, links, actor, fixture.webauthn_origin)
    if login is None or not verify_fixture_login(config, login, actor, fixture.webauthn_origin):
        return 0
    host_b = urlparse(origin_b).hostname
    browser_b = login.browser.copied_session(host_b) if host_b is not None else None
    if browser_b is None:
        return 0
    oracle = AccessOracle(SqlOracle(config))
    actor_state = _value(oracle.account(actor.email))
    elevated = _value(oracle.elevated_verifications(actor.user_id))
    if (
        actor_state is None
        or not actor_state.administrator
        or elevated is None
        or login.user_jti not in elevated
    ):
        return 0
    page = _value(browser_b.request("GET", f"{origin_b}/admin/users"))
    if page is None or page.status != 200:
        return 0
    live_page = parse_live_page(page.body)
    if live_page is None:
        return 0
    mounted = _value(LiveView.mount(browser_b, origin_b, "/admin/users", live_page, config.ca_file))
    if mounted is None:
        return 0
    try:
        before = _value(oracle.admin_inventory(actor.user_id, fixture.target.email))
        if before is None:
            return 0
        desired = not before.target.administrator
        authorized = mounted.event(
            "set-role",
            {"id": str(fixture.target.user_id), "enabled": str(desired).lower()},
        )
        changed = _value(oracle.admin_inventory(actor.user_id, fixture.target.email))
        if (
            authorized.state is not State.OBSERVED
            or changed is None
            or changed.target.administrator != desired
            or len(changed.audit_ids - before.audit_ids) != 1
        ):
            return 0
        reachable("Authorized Control room set-role committed target and audit before demotion")
        if not operator.demote_admin_b(actor.user_id):
            return 0
        demoted = _value(oracle.account(actor.email))
        if demoted is None or demoted.administrator:
            return 0
        attempted = mounted.event(
            "set-role",
            {"id": str(fixture.target.user_id), "enabled": str(not desired).lower()},
        )
        after = _value(oracle.admin_inventory(actor.user_id, fixture.target.email))
        if attempted.state is not State.OBSERVED or after is None:
            return 0
        always(
            changed == after,
            "Stale Control room tab cannot commit an admin mutation after authority withdrawal",
            {"fence": "committed_demotion", "event": "set-role"},
        )
        if changed == after:
            reachable("Stale admin LiveView event was processed after committed demotion")
    finally:
        mounted.close()
    return 0


def main_magic() -> int:
    from access.mail import MailLinks

    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    try:
        config = Config.from_environment()
        fixture = read_access_fixture(Path("/run/overalls-control-secrets/fixture.json"))
        return run_magic_preview(config, MailLinks.from_environment(config.ca_file), fixture)
    except (OSError, ValueError, UnicodeError):
        LOG.info("Magic-link browser prerequisite unavailable")
        return 0


def main_remember() -> int:
    from access.mail import MailLinks

    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    try:
        config = Config.from_environment()
        return run_remembered_revocation(config, MailLinks.from_environment(config.ca_file))
    except (OSError, ValueError, UnicodeError):
        LOG.info("Remembered-cookie browser prerequisite unavailable")
        return 0


def main_admin() -> int:
    from access.mail import MailLinks

    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    try:
        config = Config.from_environment()
        fixture = read_access_fixture(Path("/run/overalls-control-secrets/fixture.json"))
        operator = AccessOperator(
            Path("/run/overalls-control-requests/requests"),
            Path("/run/overalls-control-requests/results"),
        )
        return run_stale_admin(
            config, MailLinks.from_environment(config.ca_file), fixture, operator
        )
    except (OSError, ValueError, UnicodeError):
        LOG.info("Stale-admin browser prerequisite unavailable")
        return 0
