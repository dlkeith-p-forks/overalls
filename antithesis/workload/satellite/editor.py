"""Editor login-code redemption through Audi's public callback, raced and reply-lost.

The positive path needs a current running VM on the Audi gateway's host, an
editor-capable image release, an issued editor wildcard and a real browser
login. When any prerequisite is missing the command records an unexercised
history and evaluates no assertion: an all-refusal run is not a passing one.
"""

from __future__ import annotations

import hashlib
import http.client
import ipaddress
import logging
import os
import secrets
import socket
import ssl
import threading
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import parse_qs, urlparse
from uuid import UUID

from antithesis.assertions import always, reachable, sometimes

from access.fixture import read_access_fixture
from access.mail import MailLinks
from access.oracle import AccessOracle
from access.session import Login, login_fixture, verify_fixture_login
from core.config import Config
from core.interesting import choice
from core.outcome import Observation, State
from core.sql import SqlOracle

LOG = logging.getLogger(__name__)

STATE_COOKIE = "__Host-audi_editor_state"
RETURN_COOKIE = "__Host-audi_editor_return"
SESSION_COOKIE = "__Host-audi_editor_session"
_TICKET_PREFIX = "audi_editor_login_"
_CODE_PREFIX = "audi_editor_code_"


@dataclass(frozen=True)
class AudiReply:
    status: int
    location: str | None
    cookies: dict[str, str]


@dataclass(frozen=True)
class Redemption:
    """Committed login status and credential count for one ticket."""

    status: str
    credentials: int


@dataclass(frozen=True)
class Gateway:
    address: str
    ca_file: Path


def _token(value: str, prefix: str) -> bool:
    body = value.removeprefix(prefix)
    return (
        value.startswith(prefix)
        and len(body) == 43
        and all(character.isalnum() or character in "-_" for character in body)
    )


def callback_tokens(location: str, hostname: str) -> tuple[int, str, str] | None:
    """Return the exact callback port, ticket and code from Marshall's redirect."""
    parsed = urlparse(location)
    if (
        parsed.scheme != "https"
        or parsed.hostname != hostname
        or parsed.path != "/_editor/callback"
        or parsed.username
        or parsed.password
        or parsed.fragment
    ):
        return None
    query = parse_qs(parsed.query, strict_parsing=True)
    tickets, codes = query.get("ticket", []), query.get("code", [])
    if set(query) != {"ticket", "code"} or len(tickets) != 1 or len(codes) != 1:
        return None
    if not _token(tickets[0], _TICKET_PREFIX) or not _token(codes[0], _CODE_PREFIX):
        return None
    return parsed.port or 443, tickets[0], codes[0]


def authorize_ticket(location: str | None, browser_origin: str) -> str | None:
    """Extract the login ticket from Audi's sign-in redirect to Marshall."""
    prefix = browser_origin.rstrip("/") + "/editor/authorize/"
    if location is None or not location.startswith(prefix):
        return None
    ticket = location.removeprefix(prefix)
    return ticket if _token(ticket, _TICKET_PREFIX) else None


def classify(before: Redemption | None, after: Redemption) -> bool:
    """@cc [owner:ghuntley,label:security;verification] editor-redemption-cardinality
    One ticket MUST have at most one credential, and its login MUST be consumed
    exactly when that credential exists. Replays MUST NOT add a credential.
    """
    single = after.credentials <= 1 and (after.status == "consumed") == (after.credentials == 1)
    return single and (before is None or after.credentials == before.credentials)


class AudiCallback:
    """Private raw HTTPS client pinned to Audi's gateway address with exact SNI."""

    def __init__(self, gateway: Gateway, hostname: str) -> None:
        self._gateway = gateway
        self._hostname = hostname
        self._context = ssl.create_default_context(cafile=str(gateway.ca_file))

    def get(
        self, port: int, target: str, cookies: dict[str, str], *, read_reply: bool = True
    ) -> Observation[AudiReply]:
        """@cc [owner:ghuntley,label:security;verification] editor-callback-reply-loss
        A reply-loss request MUST be fully sent before the client closes without
        reading. Its outcome stays unavailable; only SQL can classify its effect.
        Cookie, ticket and code bytes MUST NOT enter diagnostics.
        """
        if not target.startswith("/") or not 0 < port <= 65_535:
            raise ValueError("invalid Audi callback target")
        try:
            raw = socket.create_connection((self._gateway.address, port), timeout=10)
        except OSError:
            return Observation.unavailable()
        try:
            secured = self._context.wrap_socket(raw, server_hostname=self._hostname)
        except (OSError, ssl.SSLError):
            raw.close()
            return Observation.unavailable()
        connection = http.client.HTTPConnection(self._hostname, port, timeout=10)
        connection.sock = secured
        try:
            header = "; ".join(f"{name}={value}" for name, value in cookies.items())
            connection.request(
                "GET", target, headers={"Host": self._hostname, "Cookie": header} if header else {}
            )
            if not read_reply:
                return Observation.unavailable()
            response = connection.getresponse()
            response.read(65_536)
            jar: dict[str, str] = {}
            for value in response.msg.get_all("Set-Cookie") or []:
                name, _, rest = value.partition("=")
                jar[name.strip()] = rest.split(";", 1)[0]
            return Observation.observed(
                AudiReply(response.status, response.getheader("Location"), jar)
            )
        except (OSError, http.client.HTTPException):
            return Observation.unavailable()
        finally:
            connection.close()


def redemption(sql: SqlOracle, ticket: str) -> Observation[Redemption]:
    rows = sql.select(
        "SELECT l.status, (SELECT count(*) FROM editor_credentials c "
        "WHERE c.login_jti = l.login_jti AND c.label = l.label "
        "AND c.inserted_at >= l.inserted_at) FROM editor_logins l WHERE l.token_hash = %s",
        (hashlib.sha256(ticket.encode("ascii")).digest(),),
        maximum_rows=2,
    )
    if rows.state is not State.OBSERVED or rows.value is None or len(rows.value) != 1:
        return Observation.unavailable()
    status, count = rows.value[0]
    if not isinstance(status, str) or type(count) is not int:
        return Observation.unavailable()
    return Observation.observed(Redemption(status, count))


def _gateway() -> Gateway | None:
    address = os.getenv("ANTITHESIS_EDITOR_GATEWAY_ADDRESS")
    ca_file = os.getenv("ANTITHESIS_EDITOR_CA_FILE")
    if address is None or ca_file is None:
        return None
    ipaddress.IPv4Address(address)
    return Gateway(address, Path(ca_file))


def _login(config: Config) -> Login | None:
    fixture = read_access_fixture(Path("/run/overalls-control-secrets/fixture.json"))
    links = MailLinks.from_environment(config.ca_file)
    login = login_fixture(config, links, fixture.admin_a, config.marshall_urls[0])
    account = AccessOracle(SqlOracle(config)).account(fixture.admin_a.email)
    if login is None or account.state is not State.OBSERVED or account.value is None:
        return None
    if account.value.mfa_enabled and not verify_fixture_login(
        config, login, fixture.admin_a, fixture.webauthn_origin
    ):
        return None
    return login


def run_login_code_reply_loss(config: Config, vm_id: UUID) -> int:
    """@cc [owner:ghuntley,label:security;verification] editor-login-through-audi
    The history MUST use a real browser login, Marshall's editor launch and
    approval, and Audi's public callback with the exact host-only state cookie.
    Cardinality MUST come from committed SQL rows keyed by the ticket digest,
    never from callback replies. Missing prerequisites stay unexercised.
    """
    try:
        gateway = _gateway()
    except ValueError:
        gateway = None
    if gateway is None:
        LOG.info("editor login unexercised: Audi editor gateway is not selected")
        return 0
    try:
        login = _login(config)
    except (OSError, ValueError):
        login = None
    if login is None:
        LOG.info("editor login unexercised: browser login unavailable")
        return 0
    launch = login.browser.request("GET", f"{login.origin}/machines/{vm_id}/code")
    if launch.state is not State.OBSERVED or launch.value is None or launch.value.status != 302:
        LOG.info("editor login unexercised: editor launch unavailable for this VM")
        return 0
    editor = urlparse(launch.value.location or "")
    if editor.scheme != "https" or editor.hostname is None or editor.path not in ("", "/"):
        return 0
    hostname = editor.hostname
    audi = AudiCallback(gateway, hostname)
    started = audi.get(editor.port or 443, "/", {})
    if started.state is not State.OBSERVED or started.value is None:
        return 0
    ticket = authorize_ticket(started.value.location, login.origin)
    state = started.value.cookies.get(STATE_COOKIE)
    if started.value.status != 303 or ticket is None or state is None:
        LOG.info("editor login unexercised: Audi sign-in redirect unavailable")
        return 0
    approved = login.browser.request("GET", f"{login.origin}/editor/authorize/{ticket}")
    if approved.state is not State.OBSERVED or approved.value is None:
        return 0
    tokens = callback_tokens(approved.value.location or "", hostname)
    if approved.value.status != 302 or tokens is None or tokens[1] != ticket:
        LOG.info("editor login unexercised: approval redirect unavailable")
        return 0
    port, _, code = tokens
    target = f"/_editor/callback?ticket={ticket}&code={code}"
    cookies = {STATE_COOKIE: state}
    lose_reply = choice((True, False))
    replies: list[Observation[AudiReply]] = []

    def redeem(read_reply: bool) -> None:
        replies.append(audi.get(port, target, cookies, read_reply=read_reply))

    racers = [
        threading.Thread(target=redeem, args=(not lose_reply,)),
        threading.Thread(target=redeem, args=(True,)),
    ]
    for racer in racers:
        racer.start()
    for racer in racers:
        racer.join(timeout=30)
    sql = SqlOracle(config)
    raced = redemption(sql, ticket)
    if raced.state is not State.OBSERVED or raced.value is None:
        LOG.info("editor login unexercised: committed redemption unreadable")
        return 0
    winners = [
        reply.value
        for reply in replies
        if reply.state is State.OBSERVED
        and reply.value is not None
        and reply.value.status == 303
        and SESSION_COOKIE in reply.value.cookies
    ]
    if lose_reply and raced.value.credentials == 1 and not winners:
        reachable("Editor login code committed while its only callback reply was lost")
    audi.get(port, target, cookies)
    audi.get(port, target, {STATE_COOKIE: secrets.token_urlsafe(32)})
    replayed = redemption(sql, ticket)
    if replayed.state is not State.OBSERVED or replayed.value is None:
        LOG.info("editor login replay unexercised: committed redemption unreadable")
        return 0
    always(
        classify(raced.value, replayed.value) and len(winners) <= 1,
        "Editor login code creates at most one credential after reply loss",
    )
    sometimes(
        replayed.value.credentials == 1 and len(winners) == 1,
        "Editor login code exchange issued one session through Audi",
    )
    return 0
