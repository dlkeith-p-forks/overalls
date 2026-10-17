"""Closed client probes for the real Marshall fleet Control listener."""

from urllib.parse import urlparse

from core.http import HttpClient, HttpResponse
from core.outcome import Observation


class ControlClient:
    """@cc [owner:ghuntley,label:security;verification] control-smoke-closed-fixture
    Smoke probes MUST target the fleet HTTPS listener and use only fixed
    unsupported-version and synthetic-invalid-credential inputs. They MUST NOT
    borrow Lilly's live credential or claim an authenticated socket session.
    """

    def __init__(self, http: HttpClient, marshall_origin: str) -> None:
        parsed = urlparse(marshall_origin)
        if parsed.scheme != "https" or parsed.hostname is None:
            raise ValueError("Control client requires a Marshall HTTPS origin")
        self._http = http
        self._url = f"https://{parsed.hostname}:5443/api/control/v1"

    def wrong_version(self) -> Observation[HttpResponse]:
        """Ask the real fleet listener for an unsupported outer Control version."""
        return self._http.request(
            "GET",
            self._url,
            headers={"overalls-control": "2", "overalls-service": "lilly"},
        )

    def invalid_credential(self) -> Observation[HttpResponse]:
        """Ask for v1 with a fixed synthetic invalid credential and no upgrade."""
        return self._http.request(
            "GET",
            self._url,
            headers={
                "overalls-control": "1",
                "overalls-service": "lilly",
                "authorization": "Bearer synthetic-invalid",
            },
        )
