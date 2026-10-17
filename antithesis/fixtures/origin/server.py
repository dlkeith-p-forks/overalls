"""Closed HTTP/TLS/Git upstream with durable, content-free request receipts.

Only synthetic fixture routes are accepted. The journal is deliberately separate
from every SUT database and records an effect before a response is attempted.
"""

from __future__ import annotations

import http.server
import json
import os
import re
import secrets
import select
import signal
import ssl
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from types import FrameType
from typing import Literal, NoReturn, TypedDict
from urllib.parse import parse_qs, urlsplit

Family = Literal["openai", "anthropic", "integration", "git"]
Mode = Literal["normal", "stream", "error", "delay", "lost_reply", "partial", "hold"]
HOSTS = (
    "api.openai.com",
    "api.anthropic.com",
    "github.com",
    "integration.fixture.test",
    "integration-a.fixture.test",
    "integration-b.fixture.test",
    "smtp.fixture.test",
)
GIT_REPO = "Fixture/demo.git"
MAX_BODY = 16_777_216
MAX_JOURNAL = 33_554_432
MAX_RECEIPTS = 200_000
MAX_HOLDS = 128
HOLD_SECONDS = 120
MARKER_PATTERN = re.compile(rb"fx-[0-9a-f]{32}")


class Receipt(TypedDict):
    seq: int
    family: Family
    route: str
    method: str
    mode: Mode
    operation_id: str
    origin: str
    accepted_at_ns: int
    target_is_a: bool | None
    authorization_matches: bool | None
    static_header_matches: bool | None


HoldState = Literal["held", "released", "eof", "timed_out", "unknown"]


class HoldView(TypedDict):
    seq: int
    state: HoldState
    closed_at_ns: int | None
    eof_observed: bool | None


@dataclass
class Hold:
    seq: int
    event: threading.Event = field(default_factory=threading.Event)
    state: HoldState = "held"
    closed_at_ns: int | None = None
    eof_observed: bool | None = None


@dataclass(frozen=True)
class Fault:
    mode: Mode = "normal"
    status: int = 503
    delay_ms: int = 0


def _json_bytes(value: object) -> bytes:
    return json.dumps(value, separators=(",", ":"), sort_keys=True).encode("ascii")


def _contains_marker(value: object, marker: str, depth: int = 0) -> bool:
    if depth > 8:
        return False
    if isinstance(value, str):
        return marker in value
    if isinstance(value, list):
        return any(_contains_marker(item, marker, depth + 1) for item in value[:256])
    if isinstance(value, dict):
        return any(_contains_marker(item, marker, depth + 1) for item in list(value.values())[:256])
    return False


def _run(
    args: list[str], *, input_bytes: bytes | None = None, env: dict[str, str] | None = None
) -> bytes:
    result = subprocess.run(
        args,
        input=input_bytes,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        env=env,
        check=True,
        timeout=15,
    )
    return result.stdout


def _publish(path: Path, content: bytes, mode: int = 0o600) -> None:
    """@cc [owner:ghuntley,label:recovery] origin-atomic-publish
    Replacing fixture control state MUST fsync the new file and containing
    directory, so restart sees either complete old or complete new bytes.
    """
    descriptor, temporary = tempfile.mkstemp(prefix=".origin-", dir=path.parent)
    try:
        os.fchmod(descriptor, mode)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def _git(repo: Path, *args: str, input_bytes: bytes | None = None) -> str:
    env = os.environ.copy()
    env.update(
        {
            "GIT_AUTHOR_NAME": "Synthetic Fixture",
            "GIT_AUTHOR_EMAIL": "fixture@example.test",
            "GIT_COMMITTER_NAME": "Synthetic Fixture",
            "GIT_COMMITTER_EMAIL": "fixture@example.test",
            "GIT_AUTHOR_DATE": "1700000000 +0000",
            "GIT_COMMITTER_DATE": "1700000000 +0000",
        }
    )
    return (
        _run(["git", f"--git-dir={repo}", *args], input_bytes=input_bytes, env=env)
        .decode("ascii")
        .strip()
    )


def _prepare_git(root: Path) -> dict[int, str]:
    """Build three real immutable commits; mutable main selects the visible generation."""
    exec_path = Path(_run(["git", "--exec-path"]).decode("ascii").strip())
    if not (exec_path / "git-http-backend").is_file():
        raise RuntimeError("Git smart HTTP backend unavailable")
    repo = root / "git" / GIT_REPO
    repo.parent.mkdir(parents=True, exist_ok=True)
    _run(["git", "init", "--bare", "--initial-branch=main", str(repo)])
    _git(repo, "config", "http.uploadpack", "true")
    _git(repo, "config", "http.receivepack", "false")
    commits: dict[int, str] = {}
    for generation in (1, 2, 3):
        blob = _git(
            repo,
            "hash-object",
            "-w",
            "--stdin",
            input_bytes=f"fixture-generation-{generation}\n".encode(),
        )
        tree = _git(repo, "mktree", input_bytes=f"100644 blob {blob}\tREADME.md\n".encode())
        parents = ["-p", commits[1]] if generation == 2 else []
        commit = _git(
            repo,
            "commit-tree",
            tree,
            *parents,
            input_bytes=f"fixture generation {generation}\n".encode(),
        )
        commits[generation] = commit
    if not _git_ref_exists(repo, "refs/heads/main"):
        _git(repo, "update-ref", "refs/heads/main", commits[1])
    _clear_fixture_tags(repo)
    _git(repo, "symbolic-ref", "HEAD", "refs/heads/main")
    return commits


def _git_ref_exists(repo: Path, ref: str) -> bool:
    result = subprocess.run(
        ["git", f"--git-dir={repo}", "show-ref", "--verify", "--quiet", ref],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
        timeout=15,
    )
    return result.returncode == 0


def _clear_fixture_tags(repo: Path) -> None:
    """Remove tags from older fixture versions so only main advertises the source."""
    for generation in (1, 2, 3):
        tag = f"refs/tags/fixture-v{generation}"
        if _git_ref_exists(repo, tag):
            _git(repo, "update-ref", "-d", tag)


class State:
    """One lock serializes receipt sequence, fault changes and Git ref controls."""

    def __init__(self, root: Path) -> None:
        self.root = root
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.lock = threading.Lock()
        self.journal = root / "receipts.jsonl"
        self.fault_file = root / "faults.json"
        self.token_file = root / "admin-token"
        self.integration_auth_file = root / "integration-auth-token"
        self.integration_auth_next_file = root / "integration-auth-next-token"
        self.integration_static_file = root / "integration-static-value"
        self.integration_generation_file = root / "integration-generation.json"
        self.commits = _prepare_git(root)
        if not self.token_file.exists():
            _publish(self.token_file, (secrets.token_urlsafe(32) + "\n").encode())
        self.admin_token = self.token_file.read_text(encoding="ascii").strip()
        for path in (
            self.integration_auth_file,
            self.integration_auth_next_file,
            self.integration_static_file,
        ):
            if not path.exists():
                _publish(path, ("fixture-" + secrets.token_hex(16) + "\n").encode())
        self.integration_auth = self.integration_auth_file.read_text(encoding="ascii").strip()
        self.integration_auth_next = self.integration_auth_next_file.read_text(
            encoding="ascii"
        ).strip()
        self.integration_static = self.integration_static_file.read_text(encoding="ascii").strip()
        generation_raw: object = (
            json.loads(self.integration_generation_file.read_bytes())
            if self.integration_generation_file.exists()
            else 1
        )
        if type(generation_raw) is not int or generation_raw not in (1, 2):
            raise ValueError("invalid integration credential generation")
        self.integration_generation = generation_raw
        self.markers: set[str] = set()
        self.holds: dict[int, Hold] = {}
        self.hold_sequences: set[int] = set()
        self.seq = 0
        if self.journal.exists():
            if self.journal.stat().st_size > MAX_JOURNAL:
                raise ValueError("fixture journal exceeds configured bound")
            journal_bytes = self.journal.read_bytes()
            complete = journal_bytes.rfind(b"\n") + 1
            if complete != len(journal_bytes):
                with self.journal.open("r+b") as stream:
                    stream.truncate(complete)
                    stream.flush()
                    os.fsync(stream.fileno())
                journal_bytes = journal_bytes[:complete]
            for line in journal_bytes.splitlines():
                parsed: object = json.loads(line)
                if not isinstance(parsed, dict) or type(parsed.get("seq")) is not int:
                    raise ValueError("invalid fixture journal")
                if parsed["seq"] != self.seq + 1:
                    raise ValueError("noncontiguous fixture journal")
                self.seq += 1
                if parsed.get("mode") == "hold":
                    self.hold_sequences.add(self.seq)
        else:
            _publish(self.journal, b"")
        self.faults: dict[Family, Fault] = {
            family: Fault() for family in ("openai", "anthropic", "integration", "git")
        }
        if self.fault_file.exists():
            parsed = json.loads(self.fault_file.read_bytes())
            if not isinstance(parsed, dict):
                raise ValueError("invalid fixture fault state")
            for family in self.faults:
                raw = parsed.get(family)
                if isinstance(raw, dict):
                    self.faults[family] = validate_fault(raw)

    def record(
        self,
        family: Family,
        route: str,
        method: str,
        origin: str,
        marker: str | None,
        authorization: str | None,
        static_header: str | None,
    ) -> tuple[Receipt, Fault]:
        """@cc [owner:ghuntley,label:verification;security] origin-durable-effect-receipt
        Every accepted upstream attempt MUST append and fsync one bounded receipt
        before responding, including lost replies. Receipts MUST exclude request
        and response bodies, credentials, arbitrary paths and header values.
        """
        with self.lock:
            if self.seq >= MAX_RECEIPTS:
                raise OverflowError("fixture receipt capacity exhausted")
            fault = self.faults[family]
            if fault.mode == "hold" and len(self.holds) >= MAX_HOLDS:
                closed = [seq for seq, hold in self.holds.items() if hold.state != "held"]
                if not closed:
                    raise OverflowError("fixture hold capacity exhausted")
                self.holds.pop(min(closed))
            expected_auth = (
                self.integration_auth
                if self.integration_generation == 1
                else self.integration_auth_next
            )
            receipt: Receipt = {
                "seq": self.seq + 1,
                "family": family,
                "route": route,
                "method": method,
                "mode": fault.mode,
                "operation_id": marker or f"fixture-{self.seq + 1}",
                "origin": origin,
                "accepted_at_ns": time.time_ns(),
                "target_is_a": origin == "a" if family == "integration" else None,
                "authorization_matches": (
                    secrets.compare_digest(authorization or "", "Bearer " + expected_auth)
                    if family == "integration"
                    else None
                ),
                "static_header_matches": (
                    secrets.compare_digest(static_header or "", self.integration_static)
                    if family == "integration"
                    else None
                ),
            }
            encoded = _json_bytes(receipt) + b"\n"
            if self.journal.stat().st_size + len(encoded) > MAX_JOURNAL:
                raise OverflowError("fixture journal capacity exhausted")
            with self.journal.open("ab") as stream:
                stream.write(encoded)
                stream.flush()
                os.fsync(stream.fileno())
            self.seq += 1
            if fault.mode == "hold":
                self.holds[self.seq] = Hold(self.seq)
                self.hold_sequences.add(self.seq)
            return receipt, fault

    def register_marker(self) -> str:
        with self.lock:
            if len(self.markers) >= 128:
                raise OverflowError("marker capacity exhausted")
            marker = "fx-" + secrets.token_hex(16)
            self.markers.add(marker)
            return marker

    def matched_marker(self, family: Family, body: bytes, header: str | None) -> str | None:
        with self.lock:
            markers = self.markers.copy()
        if family == "integration":
            return header if header in markers else None
        if family not in ("openai", "anthropic"):
            return None
        try:
            parsed: object = json.loads(body)
        except (ValueError, UnicodeDecodeError):
            return None
        if not isinstance(parsed, dict):
            return None
        selected = (parsed.get("input"), parsed.get("messages"))
        for match in MARKER_PATTERN.finditer(body):
            marker = match.group().decode("ascii")
            if marker in markers and any(_contains_marker(value, marker) for value in selected):
                return marker
        return None

    def set_integration_generation(self, generation: int) -> None:
        with self.lock:
            _publish(self.integration_generation_file, _json_bytes(generation))
            self.integration_generation = generation

    def hold_view(self, seq: int) -> HoldView | None:
        with self.lock:
            hold = self.holds.get(seq)
            if hold is not None:
                return {
                    "seq": seq,
                    "state": hold.state,
                    "closed_at_ns": hold.closed_at_ns,
                    "eof_observed": hold.eof_observed,
                }
            if seq not in self.hold_sequences:
                return None
            # Runtime socket observations cannot be reconstructed from the journal.
            return {"seq": seq, "state": "unknown", "closed_at_ns": None, "eof_observed": None}

    def release_hold(self, seq: int) -> HoldView | None:
        with self.lock:
            hold = self.holds.get(seq)
            if hold is None:
                return None
            hold.event.set()
            return {
                "seq": seq,
                "state": hold.state,
                "closed_at_ns": hold.closed_at_ns,
                "eof_observed": hold.eof_observed,
            }

    def hold_event(self, seq: int) -> threading.Event | None:
        with self.lock:
            hold = self.holds.get(seq)
            return hold.event if hold is not None else None

    def close_hold(self, seq: int, state: HoldState, eof_observed: bool) -> None:
        with self.lock:
            hold = self.holds.get(seq)
            if hold is not None and hold.state == "held":
                hold.state = state
                hold.closed_at_ns = time.time_ns()
                hold.eof_observed = eof_observed
                hold.event.set()

    def receipts(self, after: int, limit: int) -> list[Receipt]:
        with self.lock:
            result: list[Receipt] = []
            with self.journal.open("rb") as stream:
                for line in stream:
                    raw = json.loads(line)
                    if (
                        isinstance(raw, dict)
                        and isinstance(raw.get("seq"), int)
                        and raw["seq"] > after
                    ):
                        result.append(raw)
                        if len(result) >= limit:
                            break
            return result

    def set_fault(self, family: Family, fault: Fault) -> None:
        with self.lock:
            updated = self.faults | {family: fault}
            encoded = {
                key: {"mode": value.mode, "status": value.status, "delay_ms": value.delay_ms}
                for key, value in updated.items()
            }
            _publish(self.fault_file, _json_bytes(encoded))
            self.faults = updated

    def generation(self) -> tuple[int, str]:
        with self.lock:
            current = _git(self.root / "git" / GIT_REPO, "rev-parse", "refs/heads/main")
            for generation, sha in self.commits.items():
                if sha == current:
                    return generation, sha
            raise ValueError("unexpected fixture Git ref")

    def advance(self, generation: int) -> str:
        with self.lock:
            sha = self.commits[generation]
            repo = self.root / "git" / GIT_REPO
            _clear_fixture_tags(repo)
            _git(repo, "update-ref", "refs/heads/main", sha)
            return sha


def validate_fault(raw: dict[str, object]) -> Fault:
    mode = raw.get("mode")
    status = raw.get("status", 503)
    delay_ms = raw.get("delay_ms", 0)
    if type(status) is not int or status not in (429, 500, 503):
        raise ValueError("unsupported error status")
    if type(delay_ms) is not int or not 0 <= delay_ms <= 3000:
        raise ValueError("invalid delay")
    if mode == "normal":
        return Fault("normal", status, delay_ms)
    if mode == "stream":
        return Fault("stream", status, delay_ms)
    if mode == "error":
        return Fault("error", status, delay_ms)
    if mode == "delay":
        return Fault("delay", status, delay_ms)
    if mode == "lost_reply":
        return Fault("lost_reply", status, delay_ms)
    if mode == "partial":
        return Fault("partial", status, delay_ms)
    if mode == "hold":
        return Fault("hold", status, delay_ms)
    raise ValueError("unsupported fault mode")


class BaseHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    state: State

    def log_message(self, format: str, *_args: object) -> None:
        _ = format
        pass

    def send_bytes(
        self,
        status: int,
        body: bytes,
        content_type: str = "application/json",
        extra: dict[str, str] | None = None,
    ) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        if extra:
            for key, value in extra.items():
                self.send_header(key, value)
        self.end_headers()
        if body:
            self.wfile.write(body)

    def read_body(self, max_bytes: int = MAX_BODY) -> bytes | None:
        raw = self.headers.get("Content-Length", "0")
        if not raw.isdecimal() or int(raw) > max_bytes:
            self.close_connection = True
            self.send_bytes(413, b"{}")
            return None
        return self.rfile.read(int(raw))


class AdminHandler(BaseHandler):
    def _authorized(self) -> bool:
        return secrets.compare_digest(
            self.headers.get("X-Fixture-Admin-Token", ""), self.state.admin_token
        )

    def do_GET(self) -> None:
        parsed = urlsplit(self.path)
        if parsed.path == "/healthz":
            self.send_bytes(200, b'{"ready":true}')
            return
        if not self._authorized():
            self.send_bytes(403, b"{}")
            return
        if parsed.path == "/v1/state":
            generation, sha = self.state.generation()
            self.send_bytes(
                200,
                _json_bytes(
                    {
                        "sequence": self.state.seq,
                        "git_generation": generation,
                        "git_head": sha,
                        "families": ["openai", "anthropic", "integration", "git"],
                    }
                ),
            )
            return
        if parsed.path == "/v1/receipts":
            query = parse_qs(parsed.query)
            try:
                after = int(query.get("after", ["0"])[0])
                limit = int(query.get("limit", ["100"])[0])
            except ValueError:
                self.send_bytes(400, b"{}")
                return
            if after < 0 or not 1 <= limit <= 500:
                self.send_bytes(400, b"{}")
                return
            self.send_bytes(
                200,
                _json_bytes(
                    {"receipts": self.state.receipts(after, limit), "sequence": self.state.seq}
                ),
            )
            return
        if parsed.path == "/v1/holds":
            query = parse_qs(parsed.query)
            try:
                seq = int(query["seq"][0])
            except (KeyError, IndexError, ValueError):
                self.send_bytes(400, b"{}")
                return
            view = self.state.hold_view(seq)
            if view is None:
                self.send_bytes(404, b"{}")
            else:
                self.send_bytes(200, _json_bytes(view))
            return
        self.send_bytes(404, b"{}")

    def do_POST(self) -> None:
        if not self._authorized():
            self.send_bytes(403, b"{}")
            return
        body = self.read_body(1024)
        if body is None:
            return
        try:
            raw: object = json.loads(body)
            if not isinstance(raw, dict):
                raise ValueError("expected object")
            if self.path == "/v1/fault":
                family = raw.get("family")
                if family not in ("openai", "anthropic", "integration", "git"):
                    raise ValueError("unsupported family")
                fault = validate_fault(raw)
                self.state.set_fault(family, fault)
                self.send_bytes(200, _json_bytes({"family": family, "mode": fault.mode}))
                return
            if self.path == "/v1/markers":
                if raw:
                    raise ValueError("marker registration takes no fields")
                marker = self.state.register_marker()
                self.send_bytes(200, _json_bytes({"marker": marker}))
                return
            if self.path == "/v1/integration/credential":
                generation = raw.get("generation")
                if type(generation) is not int or generation not in (1, 2):
                    raise ValueError("unsupported credential generation")
                self.state.set_integration_generation(generation)
                self.send_bytes(200, _json_bytes({"generation": generation}))
                return
            if self.path == "/v1/holds/release":
                seq = raw.get("seq")
                if type(seq) is not int or seq < 1:
                    raise ValueError("invalid hold sequence")
                view = self.state.release_hold(seq)
                if view is None:
                    self.send_bytes(404, b"{}")
                else:
                    self.send_bytes(200, _json_bytes(view))
                return
            if self.path == "/v1/git/generation":
                generation = raw.get("generation")
                if type(generation) is not int or generation not in (1, 2, 3):
                    raise ValueError("unsupported generation")
                sha = self.state.advance(generation)
                self.send_bytes(200, _json_bytes({"generation": generation, "head": sha}))
                return
        except OverflowError:
            self.send_bytes(507, b"{}")
            return
        except (ValueError, TypeError, json.JSONDecodeError):
            self.send_bytes(400, b"{}")
            return
        self.send_bytes(404, b"{}")


class OriginHandler(BaseHandler):
    def do_GET(self) -> None:
        self._serve()

    def do_POST(self) -> None:
        self._serve()

    def _serve(self) -> None:
        parsed = urlsplit(self.path)
        host = self.headers.get("Host", "").split(":", 1)[0].lower()
        route: str | None = None
        family: Family | None = None
        origin = "none"
        if host == "api.openai.com" and self.command == "GET" and parsed.path == "/v1/models":
            family, route = "openai", "models"
        elif host == "api.anthropic.com" and self.command == "GET" and parsed.path == "/v1/models":
            family, route = "anthropic", "models"
        elif (
            host == "api.openai.com"
            and self.command == "POST"
            and parsed.path in ("/v1/responses", "/v1/chat/completions")
        ):
            family, route = "openai", parsed.path.removeprefix("/v1/")
        elif (
            host == "api.anthropic.com"
            and self.command == "POST"
            and parsed.path in ("/v1/messages", "/v1/messages/count_tokens")
        ):
            family, route = "anthropic", parsed.path.removeprefix("/v1/")
        elif (
            host
            in (
                "integration.fixture.test",
                "integration-a.fixture.test",
                "integration-b.fixture.test",
            )
            and self.command in ("GET", "POST")
            and parsed.path in ("/probe", "/upload", "/stream")
        ):
            family, route = "integration", parsed.path.removeprefix("/")
            origin = "b" if host == "integration-b.fixture.test" else "a"
        elif host == "github.com" and (
            (
                self.command == "GET"
                and parsed.path == f"/{GIT_REPO}/info/refs"
                and parsed.query == "service=git-upload-pack"
            )
            or (self.command == "POST" and parsed.path == f"/{GIT_REPO}/git-upload-pack")
        ):
            family, route = "git", "info-refs" if self.command == "GET" else "upload-pack"
        if family is None or route is None:
            self.close_connection = True
            self.send_bytes(404, b"{}")
            return
        body = self.read_body()
        if body is None:
            return
        try:
            marker = self.state.matched_marker(
                family, body, self.headers.get("X-Fixture-Operation-ID")
            )
            receipt, fault = self.state.record(
                family,
                route,
                self.command,
                origin,
                marker,
                self.headers.get("Authorization"),
                self.headers.get("X-Fixture-Static"),
            )
        except OverflowError:
            self.send_bytes(507, b"{}")
            return
        if fault.delay_ms or fault.mode == "delay":
            time.sleep((fault.delay_ms or 500) / 1000)
        if fault.mode == "lost_reply":
            self.close_connection = True
            self.connection.shutdown(2)
            return
        if fault.mode == "hold":
            self._held_response(receipt["seq"])
            return
        if fault.mode == "error":
            self.send_bytes(fault.status, b'{"error":{"type":"fixture_error"}}')
            return
        if family == "git":
            self._git_response(parsed.path, parsed.query, body, fault)
        elif route == "models":
            self.send_bytes(
                200,
                _json_bytes(
                    {"data": [{"id": "fixture-model", "object": "model"}], "has_more": False}
                ),
            )
        elif family == "integration":
            payload = b"fixture-integration-response\n"
            self.send_bytes(
                200, payload, "text/plain", {"X-Fixture-Request-ID": str(receipt["seq"])}
            )
        else:
            stream_requested = False
            try:
                request: object = json.loads(body)
                stream_requested = isinstance(request, dict) and request.get("stream") is True
            except json.JSONDecodeError:
                pass
            self._provider_response(family, route, receipt["seq"], fault, stream_requested)

    def _held_response(self, seq: int) -> None:
        """Keep a response open until explicit release, client EOF, or a finite deadline."""
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", "16777216")
        self.send_header("X-Fixture-Request-ID", str(seq))
        self.end_headers()
        try:
            self.wfile.write(b"fixture-stream-start\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
            self.state.close_hold(seq, "eof", True)
            self.close_connection = True
            return
        deadline = time.monotonic() + HOLD_SECONDS
        while time.monotonic() < deadline:
            view = self.state.hold_view(seq)
            if view is None or view["state"] != "held":
                break
            hold = self.state.hold_event(seq)
            if hold is not None and hold.wait(0.1):
                break
            try:
                readable, _, _ = select.select([self.connection], [], [], 0)
                if readable:
                    previous_timeout = self.connection.gettimeout()
                    self.connection.settimeout(0.1)
                    try:
                        data = self.connection.recv(1)
                    finally:
                        self.connection.settimeout(previous_timeout)
                    if not data:
                        self.state.close_hold(seq, "eof", True)
                        break
            except (ConnectionResetError, BrokenPipeError, ssl.SSLEOFError):
                self.state.close_hold(seq, "eof", True)
                break
            except (TimeoutError, BlockingIOError, ssl.SSLWantReadError):
                continue
        else:
            self.state.close_hold(seq, "timed_out", False)
        final_view = self.state.hold_view(seq)
        if final_view is not None and final_view["state"] == "held":
            self.state.close_hold(seq, "released", False)
        self.close_connection = True

    def _provider_response(
        self, family: Family, route: str, seq: int, fault: Fault, stream_requested: bool
    ) -> None:
        if route == "messages/count_tokens":
            self.send_bytes(200, b'{"input_tokens":3}', extra={"request-id": f"fixture-{seq}"})
            return
        if fault.mode == "stream" or (stream_requested and fault.mode in ("normal", "partial")):
            if family == "anthropic":
                frames = (
                    b'event: message_start\ndata: {"type":"message_start","message":{"id":"fixture-message","type":"message","role":"assistant","model":"fixture-model","content":[],"usage":{"input_tokens":3,"output_tokens":0}}}\n\n',
                    b'event: message_delta\ndata: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}\n\n',
                )
            elif route == "chat/completions":
                frames = (
                    b'data: {"id":"fixture-chat","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"fixture-result"}}]}\n\n',
                    b'data: {"id":"fixture-chat","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5}}\n\ndata: [DONE]\n\n',
                )
            else:
                frames = (
                    b'event: response.in_progress\ndata: {"type":"response.in_progress","response":{"id":"fixture-response","status":"in_progress"}}\n\n',
                    b'event: response.completed\ndata: {"type":"response.completed","response":{"id":"fixture-response","status":"completed","usage":{"input_tokens":3,"output_tokens":2}}}\n\n',
                )
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("request-id", f"fixture-{seq}")
            selected = frames[:1] if fault.mode == "partial" else frames
            self.send_header("Content-Length", str(sum(map(len, frames))))
            self.end_headers()
            for frame in selected:
                self.wfile.write(frame)
                self.wfile.flush()
            if fault.mode == "partial":
                self.close_connection = True
            return
        if family == "anthropic":
            payload = {
                "id": f"fixture-{seq}",
                "type": "message",
                "role": "assistant",
                "model": "fixture-model",
                "stop_reason": "end_turn",
                "stop_sequence": None,
                "content": [{"type": "text", "text": "fixture-result"}],
                "usage": {"input_tokens": 3, "output_tokens": 2},
            }
        elif route == "chat/completions":
            payload = {
                "id": f"fixture-{seq}",
                "object": "chat.completion",
                "created": 1_700_000_000,
                "model": "fixture-model",
                "choices": [
                    {
                        "index": 0,
                        "message": {"role": "assistant", "content": "fixture-result"},
                        "finish_reason": "stop",
                    }
                ],
                "usage": {"prompt_tokens": 3, "completion_tokens": 2, "total_tokens": 5},
            }
        else:
            payload = {
                "id": f"fixture-{seq}",
                "object": "response",
                "created_at": 1_700_000_000,
                "status": "completed",
                "model": "fixture-model",
                "output": [
                    {
                        "type": "message",
                        "role": "assistant",
                        "content": [{"type": "output_text", "text": "fixture-result"}],
                    }
                ],
                "usage": {"input_tokens": 3, "output_tokens": 2, "total_tokens": 5},
            }
        data = _json_bytes(payload)
        if fault.mode == "partial":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data[: max(1, len(data) // 2)])
            self.wfile.flush()
            self.close_connection = True
            return
        self.send_bytes(200, data, extra={"request-id": f"fixture-{seq}"})

    def _git_response(self, path: str, query: str, body: bytes, fault: Fault) -> None:
        env = os.environ.copy()
        env.update(
            {
                "GIT_PROJECT_ROOT": str(self.state.root / "git"),
                "GIT_HTTP_EXPORT_ALL": "1",
                "PATH_INFO": path,
                "QUERY_STRING": query,
                "REQUEST_METHOD": self.command,
                "CONTENT_TYPE": self.headers.get("Content-Type", ""),
                "CONTENT_LENGTH": str(len(body)),
            }
        )
        try:
            result = _run(["git", "http-backend"], input_bytes=body, env=env)
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
            self.send_bytes(502, b"{}")
            return
        split = result.find(b"\r\n\r\n")
        width = 4
        if split < 0:
            split, width = result.find(b"\n\n"), 2
        if split < 0 or len(result) > 8_388_608:
            self.send_bytes(502, b"{}")
            return
        headers = result[:split].decode("latin-1").splitlines()
        payload = result[split + width :]
        status = 200
        content_type = "application/octet-stream"
        for header in headers:
            name, _, value = header.partition(":")
            if name.lower() == "status":
                status = int(value.strip().split(" ", 1)[0])
            if name.lower() == "content-type":
                content_type = value.strip()
        if fault.mode == "partial":
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload[: max(1, len(payload) // 2)])
            self.wfile.flush()
            self.close_connection = True
            return
        self.send_bytes(status, payload, content_type)


def prepare_tls(root: Path) -> None:
    """Generate the test CA and host certificate at runtime; keys never enter images."""
    if (
        (root / "server.pem").exists()
        and (root / "server.key").exists()
        and (root / "ca.pem").exists()
    ):
        return
    with tempfile.TemporaryDirectory(dir=root) as temporary:
        working = Path(temporary)
        _run(
            [
                "openssl",
                "req",
                "-x509",
                "-newkey",
                "ec",
                "-pkeyopt",
                "ec_paramgen_curve:P-256",
                "-nodes",
                "-days",
                "30",
                "-subj",
                "/CN=Overalls synthetic origin CA",
                "-addext",
                "basicConstraints=critical,CA:TRUE",
                "-addext",
                "keyUsage=critical,keyCertSign,cRLSign",
                "-keyout",
                str(working / "ca.key"),
                "-out",
                str(working / "ca.pem"),
            ]
        )
        _run(
            [
                "openssl",
                "req",
                "-new",
                "-newkey",
                "ec",
                "-pkeyopt",
                "ec_paramgen_curve:P-256",
                "-nodes",
                "-subj",
                "/CN=Overalls synthetic origin",
                "-keyout",
                str(working / "server.key"),
                "-out",
                str(working / "server.csr"),
            ]
        )
        extension = (
            "subjectAltName="
            + ",".join(f"DNS:{host}" for host in HOSTS)
            + "\nextendedKeyUsage=serverAuth\n"
        )
        (working / "extensions").write_text(extension, encoding="ascii")
        _run(
            [
                "openssl",
                "x509",
                "-req",
                "-in",
                str(working / "server.csr"),
                "-CA",
                str(working / "ca.pem"),
                "-CAkey",
                str(working / "ca.key"),
                "-CAcreateserial",
                "-days",
                "30",
                "-extfile",
                str(working / "extensions"),
                "-out",
                str(working / "server.pem"),
            ]
        )
        _publish(root / "ca.pem", (working / "ca.pem").read_bytes(), 0o644)
        _publish(root / "server.key", (working / "server.key").read_bytes())
        _publish(root / "server.pem", (working / "server.pem").read_bytes(), 0o644)


def publish_runtime_material(root: Path) -> None:
    """Export only selected runtime material into explicit shared volumes."""
    for variable, source, mode in (
        ("ORIGIN_CA_OUT", root / "ca.pem", 0o644),
        ("ORIGIN_ADMIN_TOKEN_OUT", root / "admin-token", 0o600),
        ("ORIGIN_INTEGRATION_AUTH_OUT", root / "integration-auth-token", 0o600),
        ("ORIGIN_INTEGRATION_AUTH_TOKEN_OUT", root / "integration-auth-token", 0o600),
        ("ORIGIN_INTEGRATION_AUTH_NEXT_OUT", root / "integration-auth-next-token", 0o600),
        ("ORIGIN_INTEGRATION_STATIC_OUT", root / "integration-static-value", 0o600),
        ("ORIGIN_INTEGRATION_STATIC_VALUE_OUT", root / "integration-static-value", 0o600),
    ):
        destination = os.environ.get(variable)
        if destination:
            target = Path(destination)
            target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            _publish(target, source.read_bytes(), mode)


def _terminate(_signum: int, _frame: FrameType | None) -> NoReturn:
    """Exit explicitly because Linux does not apply default SIGTERM to PID 1."""
    raise SystemExit(0)


def main() -> None:
    if sys.argv[1:] != ["serve"]:
        raise SystemExit("usage: python -m origin serve")
    signal.signal(signal.SIGTERM, _terminate)
    root = Path(os.environ.get("ORIGIN_STATE_DIR", "/var/lib/overalls-origin"))
    state = State(root)
    prepare_tls(root)
    publish_runtime_material(root)
    AdminHandler.state = state
    OriginHandler.state = state
    admin_port = int(os.environ.get("ORIGIN_ADMIN_PORT", "8080"))
    tls_port = int(os.environ.get("ORIGIN_TLS_PORT", "443"))
    admin = http.server.ThreadingHTTPServer(("0.0.0.0", admin_port), AdminHandler)
    tls = http.server.ThreadingHTTPServer(("0.0.0.0", tls_port), OriginHandler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(root / "server.pem", root / "server.key")
    tls.socket = context.wrap_socket(tls.socket, server_side=True)
    try:
        threading.Thread(target=admin.serve_forever, daemon=True).start()
        tls.serve_forever()
    finally:
        admin.server_close()
        tls.server_close()


if __name__ == "__main__":
    main()
