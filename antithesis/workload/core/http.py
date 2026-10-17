"""Bounded HTTPS client for real Marshall interfaces."""

import ssl
from collections.abc import Mapping
from dataclasses import dataclass
from http.client import HTTPMessage, IncompleteRead
from pathlib import Path
from typing import IO
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import HTTPRedirectHandler, HTTPSHandler, Request, build_opener

from core.outcome import Observation


@dataclass(frozen=True)
class HttpResponse:
    body: bytes
    status: int


class _NoRedirect(HTTPRedirectHandler):
    def redirect_request(
        self, req: Request, fp: IO[bytes], code: int, msg: str, headers: HTTPMessage, newurl: str
    ) -> None:
        return None


class HttpClient:
    def __init__(self, ca_file: Path, timeout_seconds: float = 5.0) -> None:
        context = ssl.create_default_context(cafile=str(ca_file))
        self._opener = build_opener(HTTPSHandler(context=context), _NoRedirect())
        self._timeout = timeout_seconds

    def request(
        self,
        method: str,
        url: str,
        *,
        body: bytes | None = None,
        headers: Mapping[str, str] | None = None,
    ) -> Observation[HttpResponse]:
        """@cc [owner:ghuntley,label:security;verification] http-result-three-way
        Only a reviewed terminal 4xx HTTP status MUST be a definite refusal.
        Redirects, transient statuses, TLS, socket, timeout or truncated-read
        failure MUST be UNAVAILABLE, never evidence that a mutation did not commit.
        """
        if method not in ("GET", "HEAD", "POST", "PUT", "DELETE"):
            raise ValueError("unsupported HTTP method")
        if urlparse(url).scheme != "https":
            raise ValueError("HTTP client requires HTTPS")
        request = Request(url, data=body, headers=dict(headers or {}), method=method)
        try:
            with self._opener.open(request, timeout=self._timeout) as response:
                payload = response.read(1_048_577)
                if len(payload) > 1_048_576:
                    return Observation.unavailable()
                status = response.status
                return Observation.observed(HttpResponse(payload, status), status)
        except HTTPError as error:
            if error.code in (400, 401, 403, 404, 410, 422, 426):
                return Observation.refused(error.code)
            return Observation.unavailable()
        except (OSError, URLError, TimeoutError, IncompleteRead):
            return Observation.unavailable()
