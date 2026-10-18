"""Isolated, bounded HTTPS authority fixture for actual native guest helpers.

This fixture has synthetic identities only. It does not implement Marshall or
Audi authorization, and its receipts never grant native catalog admission.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import ipaddress
import json
import re
import socket
import socketserver
import ssl
import struct
import subprocess
import tempfile
import threading
import time
import uuid
from dataclasses import dataclass, field, replace
from enum import StrEnum
from pathlib import Path

from native_git_fixture import Repository
from native_github_fixture import GitHub

MAX_HEADERS = 8192
MAX_BODY = 16_384
DEADLINE = 3.0
COMMAND_ID = "dddddddd-dddd-4ddd-8ddd-000000000301"
CALL_ID = "native-execution-fixture"
PROOF = "native-executor-proof"
WITHDRAW_COMMAND_ID = "dddddddd-dddd-4ddd-8ddd-000000000303"
RECOVERY_COMMAND_ID = "dddddddd-dddd-4ddd-8ddd-000000000304"
RECOVERY_PROOF = "native-fresh-executor-proof"
LEASE_PROBE_ROOT = "/var/run/overalls/native-lease-probe"
LEASE_PROBE_COMMAND = (
    "set -eu; umask 077; "
    f"test -d {LEASE_PROBE_ROOT}; test ! -e {LEASE_PROBE_ROOT}/pids; "
    "sleep 60 & descendant=$!; "
    f'printf \'%s %s\\n\' "$$" "$descendant" > {LEASE_PROBE_ROOT}/pids.tmp; '
    f'mv {LEASE_PROBE_ROOT}/pids.tmp {LEASE_PROBE_ROOT}/pids; wait "$descendant"'
)
WITHDRAWAL_SECONDS = 15.0


class Refused(ValueError):
    """A closed diagnostic containing no request data."""


@dataclass(frozen=True, repr=False)
class Fence:
    executor_id: str
    epoch: int


class WithdrawalPhase(StrEnum):
    IDLE = "idle"
    ARMED = "armed"
    CLAIMED = "claimed"
    STARTED = "started"
    REQUESTED = "requested"
    REVOKED = "revoked"
    REJECTED = "rejected"
    DEAD = "dead"
    RECOVERY_CLAIMED = "recovery_claimed"
    RECOVERY_STARTED = "recovery_started"
    COMPLETE = "complete"


@dataclass(repr=False)
class Withdrawal:
    phase: WithdrawalPhase = WithdrawalPhase.IDLE
    fence: Fence | None = None
    recovery_fence: Fence | None = None
    started_at: float | None = None
    terminal_attempts: int = 0
    heartbeat_403: int = 0
    death_elapsed_ms: int | None = None


@dataclass(frozen=True, repr=False)
class Snapshot:
    execution_completed: bool
    phase: WithdrawalPhase
    started_at: float | None
    terminal_attempts: int
    heartbeat_403: int
    death_elapsed_ms: int | None


class Withdrawn(Refused):
    """Matching heartbeat refusal, acknowledged only after the HTTP 403 is sent."""

    def __init__(self, fence: Fence) -> None:
        super().__init__("fixture executor withdrawn")
        self.fence = fence


def key(value: object) -> str:
    """Accept one canonical, comment-free Ed25519 public key only."""
    if not isinstance(value, str) or len(value) > 256:
        raise Refused("invalid fixture public key")
    fields = value.split(" ")
    if len(fields) != 2 or fields[0] != "ssh-ed25519":
        raise Refused("invalid fixture public key")
    try:
        blob = base64.b64decode(fields[1], validate=True)
    except (ValueError, binascii.Error):
        raise Refused("invalid fixture public key") from None
    prefix = struct.pack(">I", 11) + b"ssh-ed25519" + struct.pack(">I", 32)
    if (
        len(blob) != len(prefix) + 32
        or not blob.startswith(prefix)
        or base64.b64encode(blob).decode("ascii") != fields[1]
    ):
        raise Refused("invalid fixture public key")
    return value


def object_body(body: bytes) -> dict[str, object]:
    """Refuse duplicate keys and non-object request JSON before dispatch."""

    def unique(pairs: list[tuple[str, object]]) -> dict[str, object]:
        result: dict[str, object] = {}
        for name, value in pairs:
            if name in result:
                raise Refused("duplicate fixture field")
            result[name] = value
        return result

    try:
        value: object = json.loads(body, object_pairs_hook=unique)
    except (ValueError, UnicodeError, RecursionError):
        raise Refused("invalid fixture object") from None
    return object_value(value)


def object_value(value: object) -> dict[str, object]:
    """Validate each object boundary independently, including nested results."""
    if not isinstance(value, dict):
        raise Refused("invalid fixture object")
    result: dict[str, object] = {}
    for name, item in value.items():
        if not isinstance(name, str):
            raise Refused("invalid fixture object")
        result[name] = item
    return result


@dataclass(frozen=True)
class Config:
    ssh_ca: Path
    principal: str
    client_ips: frozenset[str]
    user_key: str | None = None
    uid: int = 200_000
    execution_probe: bool = False
    receipt: Path | None = None
    allow_login: bool = True

    def __post_init__(self) -> None:
        if (
            len(self.principal) > 190
            or not self.principal.endswith(".test")
            or any(
                re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label) is None
                for label in self.principal.split(".")
            )
            or not self.client_ips
            or not 200_000 <= self.uid <= 999_999
        ):
            raise Refused("invalid isolated fixture configuration")
        for address in self.client_ips:
            parsed = ipaddress.IPv4Address(address)
            if str(parsed) != address or not (parsed.is_loopback or parsed.is_private):
                raise Refused("invalid isolated fixture client")
        if self.user_key is not None:
            key(self.user_key)


@dataclass(repr=False)
class Authority:
    config: Config
    counters: dict[str, int] = field(default_factory=dict)
    executor_id: str = ""
    fence_epoch: int = 0
    lease_deadline: float = 0.0
    command_fence: int = 0
    claimed: bool = False
    started: bool = False
    execution_completed: bool = False
    withdrawal: Withdrawal = field(default_factory=Withdrawal, init=False, repr=False)
    github: GitHub | None = field(default=None, repr=False)
    _lock: threading.RLock = field(default_factory=threading.RLock, init=False, repr=False)

    def snapshot(self) -> Snapshot:
        with self._lock:
            state = self.withdrawal
            return Snapshot(
                self.execution_completed,
                state.phase,
                state.started_at,
                state.terminal_attempts,
                state.heartbeat_403,
                state.death_elapsed_ms,
            )

    def count(self, event: str) -> int:
        with self._lock:
            return self.counters.get(event, 0)

    def set_login_allowed(self, allowed: bool) -> None:
        with self._lock:
            self.config = replace(self.config, allow_login=allowed)

    def arm_withdrawal(self) -> None:
        """Issue no long command until the certified-SSH runner explicitly arms it."""
        with self._lock:
            if not self.config.execution_probe or not self.execution_completed:
                raise Refused("ordinary fixture execution must complete first")
            if self.withdrawal.phase != WithdrawalPhase.IDLE:
                raise Refused("fixture withdrawal already armed")
            self.withdrawal.phase = WithdrawalPhase.ARMED
            self.record("withdrawal_armed")

    def request_withdrawal(self) -> None:
        with self._lock:
            if self.withdrawal.phase != WithdrawalPhase.STARTED:
                raise Refused("fixture withdrawal requires a started command")
            if self.withdrawal.terminal_attempts:
                raise Refused("fixture withdrawal observed a result attempt")
            self.withdrawal.phase = WithdrawalPhase.REQUESTED
            self.record("withdrawal_requested")

    def heartbeat_refusal_sent(self, fence: Fence) -> None:
        with self._lock:
            state = self.withdrawal
            if state.phase != WithdrawalPhase.REVOKED or state.fence != fence:
                raise Refused("fixture withdrawal response identity differs")
            state.phase = WithdrawalPhase.REJECTED
            state.heartbeat_403 += 1
            self.record("withdrawal_heartbeat_403")

    def confirm_group_dead(self) -> None:
        """@cc [owner:ghuntley,label:verification;security] native-withdrawal-recovery-gate
        Fresh proof work MUST remain withheld until the runner observes the old
        whole process group absent before accepted-start plus fifteen seconds,
        after a matching heartbeat HTTP 403 and with zero result attempts.
        Only a strictly newer, different executor fence may receive that proof.
        """
        with self._lock:
            state = self.withdrawal
            elapsed = time.monotonic() - state.started_at if state.started_at is not None else -1.0
            if (
                state.phase != WithdrawalPhase.REJECTED
                or state.started_at is None
                or state.heartbeat_403 != 1
                or state.terminal_attempts
                or not 0 <= elapsed < WITHDRAWAL_SECONDS
            ):
                raise Refused("fixture group-death confirmation refused")
            state.death_elapsed_ms = int(elapsed * 1000)
            state.phase = WithdrawalPhase.DEAD
            self.record("withdrawal_group_dead")

    def record(self, event: str) -> None:
        """Persist bounded event counts; never request, key, token or result bytes."""
        with self._lock:
            self.counters[event] = min(self.counters.get(event, 0) + 1, 1_000_000)
            if self.config.receipt is not None:
                state = self.withdrawal
                receipt: dict[str, object] = {
                    "version": 1,
                    "fixture": "isolated-native-control",
                    "events": self.counters,
                    "execution_completed": self.execution_completed,
                    "withdrawal": {
                        "phase": state.phase.value,
                        "terminal_attempts": state.terminal_attempts,
                        "heartbeat_403": state.heartbeat_403,
                        "death_elapsed_ms": state.death_elapsed_ms,
                    },
                    "native_admission": False,
                }
                temporary = self.config.receipt.with_suffix(".tmp")
                temporary.write_text(json.dumps(receipt, sort_keys=True) + "\n")
                temporary.replace(self.config.receipt)

    def certificate(self, public: object) -> dict[str, object]:
        public_key = key(public)
        if self.counters.get("host_certificate", 0) >= 128:
            raise Refused("fixture signing limit exceeded")
        ca = (
            subprocess.run(
                ["ssh-keygen", "-y", "-f", str(self.config.ssh_ca)],
                stdin=subprocess.DEVNULL,
                capture_output=True,
                check=True,
                timeout=3,
            )
            .stdout.decode("ascii")
            .strip()
        )
        ca = key(ca)
        with tempfile.TemporaryDirectory(prefix="native-certificate-") as directory:
            leaf = Path(directory) / "leaf.pub"
            leaf.write_text(public_key + "\n")
            subprocess.run(
                [
                    "ssh-keygen",
                    "-q",
                    "-s",
                    str(self.config.ssh_ca),
                    "-h",
                    "-I",
                    "native-machine-fixture",
                    "-n",
                    self.config.principal,
                    "-V",
                    "-5m:+45d",
                    str(leaf),
                ],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=True,
                timeout=3,
            )
            certificate = leaf.with_name("leaf-cert.pub").read_text()
        if len(certificate) > MAX_BODY:
            raise Refused("oversized fixture certificate")
        self.record("host_certificate")
        return {
            "version": 1,
            "certificate": certificate,
            "ca": ca,
            "principal": self.config.principal,
        }

    def lease(self, request: dict[str, object]) -> None:
        if (
            not self.executor_id
            or request.get("executor_id") != self.executor_id
            or type(request.get("fence_epoch")) is not int
            or request.get("fence_epoch") != self.fence_epoch
            or time.monotonic() >= self.lease_deadline
        ):
            raise Refused("stale fixture executor")

    def dispatch(self, method: str, host: str, path: str, body: bytes) -> dict[str, object]:
        """@cc [owner:ghuntley,label:verification;security] native-control-fixture-boundary
        The fixture MUST serve only exact synthetic SSH/executor routes, refuse
        unknown fields and stale fences, and issue only the ordinary fixed probe,
        explicitly armed withdrawal probe and newer-fence recovery probe. State
        changes and runner observations MUST synchronize. Signing MUST use the
        supplied isolated CA without a shell. Closed
        counters MUST NOT contain request bodies, keys, commands or tool output.
        """
        with self._lock:
            return self._dispatch(method, host, path, body)

    def _dispatch(self, method: str, host: str, path: str, body: bytes) -> dict[str, object]:
        if (
            host == "ssh.integration.internal"
            and method == "GET"
            and path == "/ssh/v1/roster"
            and not body
        ):
            self.record("roster")
            accounts: list[dict[str, object]] = []
            if self.config.user_key is not None:
                accounts.append({"username": f"u{self.config.uid}", "uid": self.config.uid})
            return {"version": 1, "accounts": accounts}
        if method != "POST":
            raise Refused("unknown fixture route")
        request = object_body(body)
        if (
            host == "llm.internal"
            and path == "/agent/v1/transition"
            and request.get("command_id") == WITHDRAW_COMMAND_ID
            and (request.get("status") != "started" or request.get("result") != {})
        ):
            # Count attempts before route shape, executor identity or lease validation.
            self.withdrawal.terminal_attempts = min(
                self.withdrawal.terminal_attempts + 1, 1_000_000
            )
            self.record("withdrawal_result_attempt")
        if host == "ssh.integration.internal":
            if path == "/ssh/v1/host-certificate" and request.keys() == {"public_key"}:
                return self.certificate(request["public_key"])
            if path in ("/ssh/v1/authorize", "/ssh/v1/login") and request.keys() == {
                "username",
                "public_key",
            }:
                if self.config.user_key is None or request != {
                    "username": f"u{self.config.uid}",
                    "public_key": self.config.user_key,
                }:
                    raise Refused("fixture SSH identity refused")
                if path.endswith("/login") and not self.config.allow_login:
                    self.record("login_refused")
                    raise Refused("fixture SSH login refused")
                self.record("authorize" if path.endswith("/authorize") else "login")
                return (
                    {"public_key": self.config.user_key}
                    if path.endswith("/authorize")
                    else {"login_id": "dddddddd-dddd-4ddd-8ddd-000000000302"}
                )
        if host != "llm.internal":
            raise Refused("unknown fixture route")
        if path == "/agent/v1/register" and request.keys() == {"digest", "capabilities"}:
            digest = request["digest"]
            if (
                not isinstance(digest, str)
                or re.fullmatch(r"[0-9a-f]{64}", digest) is None
                or request["capabilities"]
                not in (["context-v1", "skills-v1"], ["context-v1", "skills-v1", "github-tools-v1"])
            ):
                raise Refused("invalid fixture registration")
            self.fence_epoch += 1
            self.executor_id = str(uuid.uuid4())
            self.lease_deadline = time.monotonic() + 60
            self.record("register")
            return {
                "executor_id": self.executor_id,
                "fence_epoch": self.fence_epoch,
                "expires_at_ms": int(time.time() * 1000) + 60_000,
            }
        if path == "/agent/v1/maintenance/claim" and request.keys() == {
            "executor_id",
            "fence_epoch",
        }:
            self.lease(request)
            return {"maintenance": None}
        if path in ("/agent/v1/heartbeat", "/agent/v1/claim") and request.keys() == {
            "executor_id",
            "fence_epoch",
        }:
            self.lease(request)
            if path.endswith("/heartbeat"):
                state = self.withdrawal
                current = Fence(self.executor_id, self.fence_epoch)
                if state.phase == WithdrawalPhase.REQUESTED and state.fence == current:
                    state.phase = WithdrawalPhase.REVOKED
                    self.lease_deadline = 0.0
                    raise Withdrawn(current)
                self.lease_deadline = time.monotonic() + 60
                self.record("heartbeat")
                return {}
            self.record("claim")
            if self.config.execution_probe and not self.claimed:
                self.claimed = True
                self.command_fence = self.fence_epoch
                return {
                    "command": {
                        "id": COMMAND_ID,
                        "call_id": CALL_ID,
                        "tool": "exec_command",
                        "arguments": {"cmd": "printf native-executor-proof", "workdir": "/"},
                    }
                }
            state = self.withdrawal
            current = Fence(self.executor_id, self.fence_epoch)
            if state.phase == WithdrawalPhase.ARMED:
                state.phase = WithdrawalPhase.CLAIMED
                state.fence = current
                self.record("withdrawal_claimed")
                return self.probe(
                    WITHDRAW_COMMAND_ID, "native-lease-withdrawal", LEASE_PROBE_COMMAND
                )
            if (
                state.phase == WithdrawalPhase.DEAD
                and state.fence is not None
                and current.epoch > state.fence.epoch
                and current.executor_id != state.fence.executor_id
            ):
                state.phase = WithdrawalPhase.RECOVERY_CLAIMED
                state.recovery_fence = current
                self.record("withdrawal_recovery_claimed")
                return self.probe(
                    RECOVERY_COMMAND_ID, "native-lease-recovered", f"printf {RECOVERY_PROOF}"
                )
            return {"command": None}
        if path == "/agent/v1/transition" and request.keys() == {
            "executor_id",
            "fence_epoch",
            "command_id",
            "status",
            "result",
        }:
            self.lease(request)
            if request["command_id"] in (WITHDRAW_COMMAND_ID, RECOVERY_COMMAND_ID):
                return self.withdrawal_transition(request)
            if (
                not self.claimed
                or request["command_id"] != COMMAND_ID
                or self.command_fence != self.fence_epoch
                or self.execution_completed
            ):
                raise Refused("invalid fixture command")
            if request["status"] == "started" and request["result"] == {} and not self.started:
                self.started = True
                self.record("started")
                return {}
            result = object_value(request["result"])
            if (
                self.started
                and request["status"] == "completed"
                and type(result.get("exit_code")) is int
                and result == {"exit_code": 0, "stdout": PROOF, "stderr": ""}
            ):
                self.execution_completed = True
                self.record("completed")
                return {}
            raise Refused("invalid fixture command transition")
        raise Refused("unknown fixture route")

    @staticmethod
    def probe(identifier: str, call_id: str, command: str) -> dict[str, object]:
        return {
            "command": {
                "id": identifier,
                "call_id": call_id,
                "tool": "exec_command",
                "arguments": {"cmd": command, "workdir": "/"},
            }
        }

    def withdrawal_transition(self, request: dict[str, object]) -> dict[str, object]:
        state = self.withdrawal
        current = Fence(self.executor_id, self.fence_epoch)
        if request["command_id"] == WITHDRAW_COMMAND_ID:
            if (
                state.phase == WithdrawalPhase.CLAIMED
                and state.fence == current
                and request["status"] == "started"
                and request["result"] == {}
            ):
                state.started_at = time.monotonic()
                state.phase = WithdrawalPhase.STARTED
                self.record("withdrawal_started")
                return {}
        elif state.recovery_fence == current and state.fence is not None:
            if (
                current.epoch <= state.fence.epoch
                or current.executor_id == state.fence.executor_id
                or state.terminal_attempts
            ):
                raise Refused("fixture recovery fence refused")
            if (
                state.phase == WithdrawalPhase.RECOVERY_CLAIMED
                and request["status"] == "started"
                and request["result"] == {}
            ):
                state.phase = WithdrawalPhase.RECOVERY_STARTED
                self.record("withdrawal_recovery_started")
                return {}
            result = object_value(request["result"])
            if (
                state.phase == WithdrawalPhase.RECOVERY_STARTED
                and request["status"] == "completed"
                and type(result.get("exit_code")) is int
                and result == {"exit_code": 0, "stdout": RECOVERY_PROOF, "stderr": ""}
            ):
                state.phase = WithdrawalPhase.COMPLETE
                self.record("withdrawal_recovery_completed")
                return {}
        raise Refused("invalid fixture withdrawal transition")


def receive(stream: socket.socket, size: int, deadline: float) -> bytes:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError("fixture request deadline exceeded")
    stream.settimeout(remaining)
    part = stream.recv(size)
    if not part:
        raise Refused("truncated fixture request")
    return part


def request(stream: socket.socket) -> tuple[str, str, str, bytes]:
    """Read one bounded HTTP request with a shared absolute deadline."""
    deadline = time.monotonic() + DEADLINE
    data = bytearray()
    while b"\r\n\r\n" not in data:
        if len(data) >= MAX_HEADERS:
            raise Refused("oversized fixture headers")
        data.extend(receive(stream, min(1024, MAX_HEADERS - len(data)), deadline))
    head, body = bytes(data).split(b"\r\n\r\n", 1)
    lines = head.decode("ascii").split("\r\n")
    words = lines[0].split(" ")
    if len(words) != 3 or words[2] not in ("HTTP/1.0", "HTTP/1.1"):
        raise Refused("invalid fixture request line")
    headers: dict[str, str] = {}
    for line in lines[1:]:
        name, separator, value = line.partition(":")
        name = name.lower()
        if (
            not separator
            or re.fullmatch(r"[a-z0-9-]+", name) is None
            or name in headers
            or any(ord(character) < 32 for character in value)
        ):
            raise Refused("invalid fixture headers")
        headers[name] = value.strip()
    size = headers.get("content-length", "0")
    if (
        "transfer-encoding" in headers
        or re.fullmatch(r"[0-9]{1,5}", size) is None
        or int(size) > MAX_BODY
    ):
        raise Refused("invalid fixture body bound")
    expected = int(size)
    while len(body) < expected:
        body += receive(stream, expected - len(body), deadline)
    if len(body) != expected:
        raise Refused("excess fixture request body")
    return words[0], headers.get("host", ""), words[1], body


class Handler(socketserver.BaseRequestHandler):
    def handle(self) -> None:
        if not isinstance(self.request, ssl.SSLSocket) or not isinstance(self.server, Server):
            return
        stream = self.request
        withdrawal: Withdrawn | None = None
        try:
            stream.do_handshake()
            method, host, path, body = request(stream)
            github = self.server.authority.github
            artifact = None
            extra = None
            if github is not None:
                with self.server.authority._lock:
                    artifact = github.file(method, host, path, self.server.authority)
                    if artifact is None:
                        extra = github.route(method, host, path, body, self.server.authority)
            if artifact is not None:
                deadline = time.monotonic() + 8
                stream.sendall(
                    b"HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nConnection: close\r\nContent-Length: "
                    + str(artifact.bytes).encode()
                    + b"\r\n\r\n"
                )
                with artifact.path.open("rb") as source:
                    while chunk := source.read(65536):
                        remaining = deadline - time.monotonic()
                        if remaining <= 0:
                            raise TimeoutError("native artifact deadline exceeded")
                        stream.settimeout(remaining)
                        stream.sendall(chunk)
                return
            git = (
                extra
                if extra is not None
                else (
                    self.server.repository.response(method, host, path, body)
                    if self.server.repository is not None
                    else None
                )
            )
            if git is not None:
                content_type, payload = git.content_type, git.body
            else:
                response = self.server.authority.dispatch(method, host, path, body)
                content_type, payload = (
                    b"application/json",
                    json.dumps(response, allow_nan=False).encode(),
                )
            status = b"200 OK"
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            if isinstance(error, Withdrawn):
                withdrawal = error
            status, content_type, payload = (
                b"403 Forbidden",
                b"application/json",
                b'{"error":"fixture_refused"}',
            )
        if len(payload) > MAX_BODY:
            return
        try:
            stream.settimeout(DEADLINE)
            stream.sendall(
                b"HTTP/1.1 "
                + status
                + b"\r\nContent-Type: "
                + content_type
                + b"\r\nConnection: close\r\nContent-Length: "
                + str(len(payload)).encode()
                + b"\r\n\r\n"
                + payload
            )
            if withdrawal is not None:
                self.server.authority.heartbeat_refusal_sent(withdrawal.fence)
        except OSError:
            return


class Server(socketserver.TCPServer):
    allow_reuse_address = True
    request_queue_size = 4

    def __init__(
        self,
        address: tuple[str, int],
        context: ssl.SSLContext,
        authority: Authority,
        repository: Repository | None = None,
    ) -> None:
        self.context = context
        self.authority = authority
        self.repository = repository
        super().__init__(address, Handler)

    def get_request(self) -> tuple[socket.socket, tuple[str, int]]:
        stream, address = self.socket.accept()
        if address[0] not in self.authority.config.client_ips:
            stream.close()
            raise OSError("foreign fixture client")
        stream.settimeout(DEADLINE)
        try:
            wrapped = self.context.wrap_socket(
                stream, server_side=True, do_handshake_on_connect=False
            )
        except BaseException:
            stream.close()
            raise
        return wrapped, address

    def handle_error(self, request: object, client_address: object) -> None:
        """Never print request data or exception details from this authority."""


class Options(argparse.Namespace):
    """CLI schema; argparse converts paths and integers before construction."""

    bind: str
    port: int
    tls_cert: Path
    tls_key: Path
    ssh_ca: Path
    principal: str
    client_ip: list[str]
    user_key: Path | None
    uid: int
    execution_probe: bool
    receipt: Path | None
    deny_login: bool


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bind", default="169.254.254.1")
    parser.add_argument("--port", type=int, default=443)
    parser.add_argument("--tls-cert", type=Path, required=True)
    parser.add_argument("--tls-key", type=Path, required=True)
    parser.add_argument("--ssh-ca", type=Path, required=True)
    parser.add_argument("--principal", default="native.fixture.test")
    parser.add_argument("--client-ip", action="append", required=True)
    parser.add_argument("--user-key", type=Path)
    parser.add_argument("--uid", type=int, default=200_000)
    parser.add_argument("--execution-probe", action="store_true")
    parser.add_argument("--receipt", type=Path)
    parser.add_argument("--deny-login", action="store_true")
    args = parser.parse_args(namespace=Options())
    if not 1 <= args.port <= 65535:
        raise Refused("invalid fixture listener port")
    if args.bind != "169.254.254.1" and not ipaddress.IPv4Address(args.bind).is_loopback:
        raise Refused("invalid fixture listener")
    config = Config(
        args.ssh_ca,
        args.principal,
        frozenset(args.client_ip),
        key(args.user_key.read_text().strip()) if args.user_key else None,
        args.uid,
        args.execution_probe,
        args.receipt,
        allow_login=not args.deny_login,
    )
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(args.tls_cert, args.tls_key)
    authority = Authority(config)
    with Server((args.bind, args.port), context, authority) as server:
        authority.record("listening")
        server.serve_forever(poll_interval=0.1)


if __name__ == "__main__":
    main()
