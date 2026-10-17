"""Small HTTPS browser client with private cookie custody and no automatic redirects."""

from __future__ import annotations

import copy
import http.cookiejar
import ssl
from collections.abc import Mapping
from dataclasses import dataclass
from html.parser import HTMLParser
from http.client import HTTPMessage, IncompleteRead
from pathlib import Path
from typing import IO
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlparse
from urllib.request import (
    HTTPCookieProcessor,
    HTTPRedirectHandler,
    HTTPSHandler,
    Request,
    build_opener,
)

from core.outcome import Observation


@dataclass(frozen=True)
class BrowserResponse:
    body: bytes
    status: int
    location: str | None


class _NoRedirect(HTTPRedirectHandler):
    def redirect_request(
        self, req: Request, fp: IO[bytes], code: int, msg: str, headers: HTTPMessage, newurl: str
    ) -> None:
        return None


class BrowserClient:
    """Keep cookies in memory; a request never follows a token-bearing redirect."""

    def __init__(self, ca_file: Path, timeout_seconds: float = 5.0) -> None:
        self._ca_file = ca_file
        self.cookies = http.cookiejar.CookieJar()
        context = ssl.create_default_context(cafile=str(ca_file))
        self._opener = build_opener(
            HTTPSHandler(context=context), HTTPCookieProcessor(self.cookies), _NoRedirect()
        )
        self._timeout = timeout_seconds

    def request(
        self,
        method: str,
        url: str,
        *,
        form: Mapping[str, str] | None = None,
    ) -> Observation[BrowserResponse]:
        """@cc [owner:ghuntley,label:security;verification] browser-response-uncertainty
        Transport and truncated-body failure MUST remain unavailable. A redirect
        is only an observed response, never proof that its requested effect did
        or did not commit. Cookie and token bytes MUST stay out of diagnostics.
        """
        parsed = urlparse(url)
        if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
            raise ValueError("browser requests require a credential-free HTTPS URL")
        if method not in {"GET", "POST", "DELETE"} or (method == "GET" and form is not None):
            raise ValueError("unsupported browser request")
        body = urlencode(form).encode("ascii") if form is not None else None
        headers = {"Content-Type": "application/x-www-form-urlencoded"} if form else {}
        request = Request(url, data=body, headers=headers, method=method)
        try:
            with self._opener.open(request, timeout=self._timeout) as reply:
                content = reply.read(1_048_577)
                if len(content) > 1_048_576:
                    return Observation.unavailable()
                return Observation.observed(
                    BrowserResponse(content, reply.status, reply.headers.get("Location"))
                )
        except HTTPError as error:
            try:
                content = error.read(1_048_577)
            except (OSError, IncompleteRead):
                return Observation.unavailable()
            if len(content) > 1_048_576:
                return Observation.unavailable()
            return Observation.observed(
                BrowserResponse(content, error.code, error.headers.get("Location"))
            )
        except (OSError, URLError, TimeoutError, IncompleteRead):
            return Observation.unavailable()

    def copied_cookie(self, name_part: str, destination_host: str) -> BrowserClient | None:
        """Copy exactly one credential to a fresh context pinned to another replica."""
        matches = [cookie for cookie in self.cookies if name_part in cookie.name]
        if len(matches) != 1:
            return None
        copied = BrowserClient(self._ca_file, self._timeout)
        cookie = copy.copy(matches[0])
        cookie.domain = destination_host
        cookie.domain_specified = False
        cookie.domain_initial_dot = False
        copied.cookies.set_cookie(cookie)
        return copied

    def copied_session(self, destination_host: str) -> BrowserClient | None:
        """Copy signed session cookies without the persistent remember credential."""
        session = [cookie for cookie in self.cookies if "remember" not in cookie.name]
        if not session:
            return None
        copied = BrowserClient(self._ca_file, self._timeout)
        for original in session:
            cookie = copy.copy(original)
            cookie.domain = destination_host
            cookie.domain_specified = False
            cookie.domain_initial_dot = False
            copied.cookies.set_cookie(cookie)
        return copied

    def cookie_header(self, url: str) -> str:
        request = Request(url)
        self.cookies.add_cookie_header(request)
        return request.get_header("Cookie", "")

    def has_cookie(self, name_part: str) -> bool:
        return any(name_part in cookie.name for cookie in self.cookies)


class _Form(HTMLParser):
    def __init__(self, action: str) -> None:
        super().__init__()
        self.action = action
        self.in_form = False
        self.fields: dict[str, str] = {}

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attributes = dict(attrs)
        if tag == "form" and attributes.get("action") == self.action:
            self.in_form = True
        elif self.in_form and tag == "input":
            name = attributes.get("name")
            value = attributes.get("value")
            if name is not None and value is not None:
                self.fields[name] = value

    def handle_endtag(self, tag: str) -> None:
        if tag == "form":
            self.in_form = False


def hidden_form(body: bytes, action: str) -> dict[str, str] | None:
    """Read exact submitted fields from Marshall's rendered CSRF-protected form."""
    try:
        parser = _Form(action)
        parser.feed(body.decode("utf-8"))
    except UnicodeError:
        return None
    return parser.fields if parser.fields.get("_csrf_token") else None
