"""Labelled guest stand-in: guest-side private Audi requests from Lilly's namespace.

The stand-in is a harness container that shares only Lilly's network namespace.
It is not a guest, owns no VM, boot, tap or placement, and Lilly binds no VM to
its source address. It speaks the real guest-side protocol (TLS to private Audi
at 169.254.254.1 with the private root and an internal service SNI) so the
workload can observe what private Audi does for a source that Lilly never bound.
Nothing it reports is evidence of guest execution, isolation or native routing.
"""

from __future__ import annotations

import http.client
import json
import logging
import os
import re
import socket
import ssl
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Literal
from uuid import UUID, uuid4

from core.outcome import Observation

LOG = logging.getLogger(__name__)

PRIVATE_AUDI = "169.254.254.1"
_MARKER = re.compile(r"fx-[0-9a-f]{32}\Z")
_NAME = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\Z")
type Family = Literal["inference", "integration"]
type Outcome = Literal["http", "tls_refused", "unreachable"]
_OUTCOMES: tuple[Outcome, ...] = ("http", "tls_refused", "unreachable")


@dataclass(frozen=True)
class StandInRequest:
    request_id: UUID
    family: Family
    marker: str
    name: str


@dataclass(frozen=True)
class StandInResult:
    request_id: UUID
    outcome: Outcome
    status: int | None


def _request(value: object) -> StandInRequest | None:
    if not isinstance(value, dict) or set(value) != {
        "version",
        "request_id",
        "family",
        "marker",
        "name",
    }:
        return None
    family, marker, name, raw_id = (
        value.get("family"),
        value.get("marker"),
        value.get("name"),
        value.get("request_id"),
    )
    if (
        value.get("version") != 1
        or not isinstance(raw_id, str)
        or not isinstance(marker, str)
        or _MARKER.fullmatch(marker) is None
        or not isinstance(name, str)
        or _NAME.fullmatch(name) is None
    ):
        return None
    try:
        request_id = UUID(raw_id)
    except ValueError:
        return None
    if family == "inference" and name == "llm":
        return StandInRequest(request_id, "inference", marker, name)
    if family == "integration" and name != "ssh":
        return StandInRequest(request_id, "integration", marker, name)
    return None


def parse_result(value: object, request_id: UUID) -> StandInResult | None:
    """Validate one stand-in result for exactly the requested ID."""
    if not isinstance(value, dict) or set(value) != {"version", "request_id", "outcome", "status"}:
        return None
    outcome = next((item for item in _OUTCOMES if item == value.get("outcome")), None)
    status = value.get("status")
    if (
        value.get("version") != 1
        or value.get("request_id") != str(request_id)
        or outcome is None
        or (outcome == "http") != (type(status) is int)
        or (type(status) is int and not 100 <= status <= 599)
        or (outcome != "http" and status is not None)
    ):
        return None
    return StandInResult(request_id, outcome, status if type(status) is int else None)


def _write_private(directory: Path, name: str, value: dict[str, object]) -> None:
    temporary = directory / f".{name}.tmp"
    temporary.unlink(missing_ok=True)
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        json.dump(value, stream, separators=(",", ":"))
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, directory / name)


class GuestStandIn:
    """Workload-side client for the stand-in's fixed request/result channel."""

    def __init__(self, root: Path) -> None:
        self._requests = root / "requests"
        self._results = root / "results"

    def send(
        self, family: Family, marker: str, name: str, timeout_seconds: float = 30
    ) -> Observation[StandInResult]:
        """@cc [owner:ghuntley,label:verification] guest-standin-request-channel
        The workload MUST submit only a fixed family, registered origin marker
        and service label. A missing, late or malformed result MUST remain
        unavailable; it never shows that private Audi refused or forwarded.
        """
        if _MARKER.fullmatch(marker) is None or _NAME.fullmatch(name) is None:
            raise ValueError("invalid stand-in request")
        request_id = uuid4()
        body: dict[str, object] = {
            "version": 1,
            "request_id": str(request_id),
            "family": family,
            "marker": marker,
            "name": name,
        }
        if _request(body) is None:
            raise ValueError("invalid stand-in request")
        try:
            _write_private(self._requests, f"{request_id}.json", body)
        except OSError:
            return Observation.unavailable()
        deadline = time.monotonic() + timeout_seconds
        path = self._results / f"{request_id}.json"
        while time.monotonic() < deadline:
            try:
                if path.is_file() and not path.is_symlink():
                    parsed = parse_result(json.loads(path.read_text(encoding="utf-8")), request_id)
                    return (
                        Observation.observed(parsed)
                        if parsed is not None
                        else Observation.unavailable()
                    )
            except (OSError, UnicodeError, ValueError):
                return Observation.unavailable()
            time.sleep(0.2)
        return Observation.unavailable()


def _context(root: Path) -> ssl.SSLContext:
    context = ssl.create_default_context(cafile=str(root))
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    return context


def _handshake(context: ssl.SSLContext, server_name: str) -> bool:
    try:
        with (
            socket.create_connection((PRIVATE_AUDI, 443), timeout=5) as raw,
            context.wrap_socket(raw, server_hostname=server_name),
        ):
            return True
    except (OSError, ssl.SSLError):
        return False


def perform(context: ssl.SSLContext, request: StandInRequest) -> StandInResult:
    """@cc [owner:ghuntley,label:security;verification] guest-standin-forged-identity
    Each stand-in request MUST carry forged VM identity, forwarding and provider
    credential headers so private Audi's transport-only attribution is tested.
    Only the HTTP status or a fixed transport outcome leaves this process.
    """
    if request.family == "inference":
        host, method, path = "llm.internal", "POST", "/v1/responses"
        body: bytes | None = json.dumps(
            {"model": "fixture-standin", "input": request.marker}, separators=(",", ":")
        ).encode()
    else:
        host, method, path = f"{request.name}.integration.internal", "GET", "/fixture/probe"
        body = None
    headers = {
        "Host": host,
        "Content-Type": "application/json",
        "X-Fixture-Operation-ID": request.marker,
        "Authorization": "Bearer standin-forgery",
        "X-Fixture-Static": "standin-forgery",
        "X-Overalls-VM-ID": "00000000-0000-4000-8000-000000000001",
        "X-Forwarded-For": "10.0.0.2",
        "Forwarded": "for=10.0.0.2",
    }
    try:
        raw = socket.create_connection((PRIVATE_AUDI, 443), timeout=20)
    except OSError:
        return StandInResult(request.request_id, "unreachable", None)
    try:
        # The guest names the internal service in SNI, not the listener IP.
        secured = context.wrap_socket(raw, server_hostname=host)
    except ssl.SSLError:
        raw.close()
        return StandInResult(request.request_id, "tls_refused", None)
    except OSError:
        raw.close()
        return StandInResult(request.request_id, "unreachable", None)
    connection = http.client.HTTPConnection(PRIVATE_AUDI, 443, timeout=20)
    connection.sock = secured
    try:
        connection.request(method, path, body=body, headers=headers)
        response = connection.getresponse()
        response.read(65_536)
        return StandInResult(request.request_id, "http", response.status)
    except (OSError, http.client.HTTPException):
        return StandInResult(request.request_id, "unreachable", None)
    finally:
        connection.close()


def serve(root: Path, roots_file: Path, stop_after: float | None = None) -> int:
    """Serve fixed requests forever, answering each request ID at most once."""
    requests, results = root / "requests", root / "results"
    started = time.monotonic()
    published = False
    while stop_after is None or time.monotonic() - started < stop_after:
        try:
            context = _context(roots_file)
        except (OSError, ssl.SSLError):
            time.sleep(1)
            continue
        if not published:
            verified = _handshake(context, "llm.internal")
            _write_private(
                results,
                "ready.json",
                {
                    "version": 1,
                    "role": "guest-standin",
                    "private_tls_verified": verified,
                    "server_name": "llm.internal",
                },
            )
            published = verified
        for path in sorted(requests.glob("*.json")):
            target = results / path.name
            if target.exists() or path.is_symlink():
                continue
            try:
                parsed = _request(json.loads(path.read_text(encoding="utf-8")))
            except (OSError, UnicodeError, ValueError):
                parsed = None
            if parsed is None or path.name != f"{parsed.request_id}.json":
                continue
            result = perform(context, parsed)
            _write_private(
                results,
                path.name,
                {
                    "version": 1,
                    "request_id": str(result.request_id),
                    "outcome": result.outcome,
                    "status": result.status,
                },
            )
            LOG.info("guest stand-in answered request: outcome=%s", result.outcome)
        time.sleep(0.2)
    return 0


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    root = Path(os.environ.get("ANTITHESIS_GUEST_STANDIN_ROOT", "/run/overalls-guest-standin"))
    roots = Path(
        os.environ.get(
            "ANTITHESIS_PRIVATE_ROOT_CA", "/run/overalls-satellite-public/private-root.pem"
        )
    )
    return serve(root, roots)


if __name__ == "__main__":
    raise SystemExit(main())
