"""Assertion-free fixture login shared by access, terminal and satellite drivers.

It holds no SDK assertion callsites, so importing it does not add access
properties to another profile's frozen assertion roster.
"""

from __future__ import annotations

import base64
import json
import logging
from collections.abc import Sequence
from dataclasses import dataclass
from typing import Protocol
from urllib.parse import urlparse
from uuid import UUID

from access.fixture import Actor
from access.http import BrowserClient, BrowserResponse, hidden_form
from access.liveview import LiveView, parse_live_page
from access.oracle import AccessOracle
from access.passkey import assertion
from core.config import Config
from core.outcome import Observation, State
from core.sql import SqlOracle

LOG = logging.getLogger(__name__)


class LinkSource(Protocol):
    def sequence(self) -> Observation[int]: ...

    def wait_link(self, email: str, after: int, timeout_seconds: float) -> Observation[str]: ...


@dataclass(frozen=True)
class Login:
    browser: BrowserClient
    user_id: UUID
    user_jti: str
    origin: str


def _value[T](result: Observation[T]) -> T | None:
    return result.value if result.state is State.OBSERVED else None


def _jwt_jti(token: str) -> str | None:
    try:
        middle = token.split(".")[1]
        data: object = json.loads(base64.urlsafe_b64decode(middle + "=" * (-len(middle) % 4)))
    except (IndexError, ValueError, UnicodeError):
        return None
    if isinstance(data, dict) and isinstance(data.get("jti"), str):
        return data["jti"]
    return None


def _token_path(link: str, marshall_origins: Sequence[str]) -> tuple[str, str] | None:
    """The delivering Oban node may be either replica, so the link's host may be
    any configured Marshall origin; the token path is replayed on the requester."""
    parsed = urlparse(link)
    if (
        parsed.scheme != "https"
        or parsed.netloc not in {urlparse(origin).netloc for origin in marshall_origins}
        or not parsed.path.startswith("/magic_link/")
    ):
        return None
    token = parsed.path.removeprefix("/magic_link/")
    if not token or "/" in token or parsed.query or parsed.fragment:
        return None
    return parsed.path, token


def _request_link(browser: BrowserClient, origin: str, email: str) -> bool:
    page = _value(browser.request("GET", f"{origin}/sign-in"))
    if page is None or page.status != 200:
        return False
    form = hidden_form(page.body, "/auth/user/magic_link/request")
    if form is None:
        return False
    form["user[email]"] = email
    response = _value(browser.request("POST", f"{origin}/auth/user/magic_link/request", form=form))
    return response is not None and response.status == 302


def _magic_page(browser: BrowserClient, origin: str, path: str) -> BrowserResponse | None:
    response = _value(browser.request("GET", f"{origin}{path}"))
    return response if response is not None and response.status == 200 else None


def _submit_magic(
    browser: BrowserClient, origin: str, page: BrowserResponse
) -> BrowserResponse | None:
    form = hidden_form(page.body, "/auth/user/magic_link")
    if form is None or form.get("user[remember_me]") != "true":
        return None
    return _value(browser.request("POST", f"{origin}/auth/user/magic_link", form=form))


def _request_and_page(
    config: Config, links: LinkSource, email: str, origin: str
) -> tuple[BrowserClient, str, str, BrowserResponse] | None:
    browser = BrowserClient(config.ca_file)
    cursor = _value(links.sequence())
    if cursor is None:
        return None
    if not _request_link(browser, origin, email):
        return None
    link = _value(links.wait_link(email, cursor, 30))
    if link is None:
        return None
    parsed = _token_path(link, config.marshall_urls)
    if parsed is None:
        return None
    path, token = parsed
    page = _magic_page(browser, origin, path)
    if page is None:
        return None
    return browser, path, token, page


def login_fixture(config: Config, links: LinkSource, actor: Actor, origin: str) -> Login | None:
    """Create a real login via public SMTP request, GET preview and CSRF POST."""
    result = _request_and_page(config, links, actor.email, origin)
    if result is None:
        return None
    browser, _path, _token, page = result
    oracle = AccessOracle(SqlOracle(config))
    before = _value(oracle.tokens(actor.user_id))
    if before is None:
        return None
    posted = _submit_magic(browser, origin, page)
    if posted is None or posted.status != 302:
        return None
    after = _value(oracle.tokens(actor.user_id))
    if after is None:
        return None
    issued = after.user - before.user
    if len(issued) != 1 or not browser.has_cookie("remember"):
        return None
    return Login(browser, actor.user_id, next(iter(issued)), origin)


def verify_fixture_login(config: Config, login: Login, actor: Actor, webauthn_origin: str) -> bool:
    """Complete a real WebAuthn ceremony for this login over the sign-in section of /settings."""
    if login.origin != webauthn_origin:
        # A virtual authenticator must obey the same origin restriction as a
        # browser. A signed assertion for another URL would be false evidence.
        LOG.info("WebAuthn verification unexercised: login origin is not the RP origin")
        return False
    response = _value(login.browser.request("GET", f"{login.origin}/settings"))
    if response is None or response.status != 200:
        LOG.info("WebAuthn verification unexercised: security page unavailable")
        return False
    page = parse_live_page(response.body)
    if page is None:
        LOG.info("WebAuthn verification unexercised: security page is not a LiveView")
        return False
    mounted = _value(LiveView.mount(login.browser, login.origin, "/settings", page, config.ca_file))
    if mounted is None:
        LOG.info("WebAuthn verification unexercised: security LiveView mount failed")
        return False
    try:
        begun = _value(mounted.event("begin", {"kind": "verify"}))
        if begun is None or begun.get("ok") is not True:
            LOG.info("WebAuthn verification unexercised: begin reply missing ok challenge")
            return False
        signed = assertion(begun.get("challenge"), actor.authenticator, webauthn_origin)
        if signed is None:
            LOG.info("WebAuthn verification unexercised: challenge did not name the passkey")
            return False
        finished = mounted.event("finish", {"kind": "verify", "payload": signed})
        if finished.state is not State.OBSERVED:
            LOG.info("WebAuthn verification unexercised: finish reply unavailable")
            return False
        completed = _value(AccessOracle(SqlOracle(config)).completed_verifications(actor.user_id))
        if completed is None or login.user_jti not in completed:
            LOG.info("WebAuthn verification unexercised: no verification row for the login")
            return False
        return True
    finally:
        mounted.close()
