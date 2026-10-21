"""Private synthetic fleet credentials and probes; never display secret diagnostics."""

import base64
import ipaddress
import json
import os
import secrets
import shlex
import socket
import ssl
import struct
import subprocess
import sys
import urllib.error
import urllib.request
import uuid
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import IO
from urllib.parse import urlsplit

ROOT = Path("/var/lib/overalls-fleet")


def run(arguments: Sequence[str], **kwargs: object) -> bytes:
    result = subprocess.run(
        arguments, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=60, **kwargs
    )
    if result.returncode:
        raise ValueError("fixture command failed")
    return result.stdout


def read_environment(path: Path) -> dict[str, str]:
    return dict(item.split("=", 1) for item in shlex.split(path.read_text()))


# @cc [owner:ghuntley,label:verification;security] fleet-rotation-private-documents
# Each phase MUST encrypt runtime-generated values to authenticated fixture host
# recipients and an independent recovery recipient. Plaintext/private keys MUST
# stay in private fixture storage; failures MUST expose only fixed diagnostics.
def seal(phase: str) -> None:
    current = ROOT / "rotation-values.json"
    if phase == "initial":
        values: dict[str, object] = dict(read_environment(ROOT / "marshall.env"))
        run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(ROOT / "recovery.ssh")])
        run(
            [
                "ssh-to-age",
                "-private-key",
                "-i",
                str(ROOT / "recovery.ssh"),
                "-o",
                str(ROOT / "recovery.age"),
            ]
        )
        (ROOT / "initial-values.json").write_text(json.dumps(values))
    else:
        values = json.loads(current.read_text())
    ring: list[object] = json.loads(values["MARSHALL_CLOAK_KEYS"])
    if phase == "stage":
        assert [entry["id"] for entry in ring] == ["fleet"]
        ring.append({"id": "rotation", "key": base64.b64encode(os.urandom(32)).decode()})
    elif phase == "promote":
        assert [entry["id"] for entry in ring] == ["fleet", "rotation"]
        ring.reverse()
    elif phase == "cutover":
        values["DATABASE_URL"] = "postgresql://marshall:" + secrets.token_hex(32) + "@db/marshall"
        values["TOKEN_SIGNING_SECRET"] = secrets.token_hex(64)
        values["SECRET_KEY_BASE"] = secrets.token_hex(64)
        password = urlsplit(values["DATABASE_URL"]).password
        (ROOT / "database-rotate.sql").write_text(
            f"ALTER ROLE marshall WITH LOGIN PASSWORD '{password}';\n"
        )
    elif phase == "update-add":
        ring.append({"id": "update", "key": base64.b64encode(os.urandom(32)).decode()})
    elif phase == "update-promote":
        ring.reverse()
    elif phase in {"DATABASE_URL", "TOKEN_SIGNING_SECRET", "SECRET_KEY_BASE"}:
        values[phase] = "incompatible-fixture-value"
    assert phase in {
        "initial",
        "stage",
        "promote",
        "cutover",
        "update-add",
        "update-promote",
        "DATABASE_URL",
        "TOKEN_SIGNING_SECRET",
        "SECRET_KEY_BASE",
    }
    values["MARSHALL_CLOAK_KEYS"] = json.dumps(ring)
    current.write_text(json.dumps(values))
    recovery = run(["ssh-to-age", "-i", str(ROOT / "recovery.ssh.pub")]).decode().strip()
    for name in ("m1", "m2", "m3"):
        host = run(["ssh-to-age", "-i", str(ROOT / f"{name}.pub")]).decode().strip()
        assert host != recovery
        payload = {"overalls-marshall": {"production": values}}
        cipher = run(
            [
                "sops",
                "--encrypt",
                "--age",
                host + "," + recovery,
                "--input-type",
                "json",
                "--output-type",
                "json",
                "/dev/stdin",
            ],
            input=json.dumps(payload).encode(),
        )
        document = ROOT / name / "marshall.enc.json"
        document.write_bytes(cipher)
        restored = run(
            ["sops", "--decrypt", "--output-type", "json", str(document)],
            env={
                "PATH": os.environ["PATH"],
                "XDG_CONFIG_HOME": str(ROOT),
                "SOPS_AGE_KEY_FILE": str(ROOT / "recovery.age"),
                "SOPS_AGE_SSH_PRIVATE_KEY_FILE": "/dev/null",
            },
        )
        assert json.loads(restored) == payload


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(
        self,
        req: urllib.request.Request,
        fp: IO[bytes] | None,
        code: int,
        msg: str,
        headers: Mapping[str, str],
        newurl: str,
    ) -> None:
        return None


def http(request: urllib.request.Request) -> tuple[int, bytes]:
    context = ssl.create_default_context(cafile=str(ROOT / "ca.crt"))
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}), NoRedirect(), urllib.request.HTTPSHandler(context=context)
    )
    try:
        with opener.open(request, timeout=15) as response:
            return response.status, response.read(1048576)
    except urllib.error.HTTPError as error:
        return error.code, error.read(1048576)


class ControlStage(Exception):
    """A control-socket probe failure named only by a closed stage label."""


def exact(stream: ssl.SSLSocket, size: int) -> bytes:
    data = b""
    while len(data) < size:
        chunk = stream.recv(size - len(data))
        if not chunk:
            raise ControlStage("socket_closed")
        data += chunk
    return data


def send_text(stream: ssl.SSLSocket, document: dict[str, object]) -> None:
    payload = json.dumps(document).encode()
    mask = secrets.token_bytes(4)
    size = len(payload)
    short = size < 126
    header = bytes([0x81, 0x80 | size]) if short else bytes([0x81, 0xFE]) + struct.pack("!H", size)
    masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
    stream.sendall(header + mask + masked)


def receive_text(stream: ssl.SSLSocket) -> dict[str, object]:
    """Returns the next welcome or response, skipping pings and hints."""
    while True:
        first, second = exact(stream, 2)
        size = second & 0x7F
        if size == 126:
            size = struct.unpack("!H", exact(stream, 2))[0]
        elif size == 127:
            size = struct.unpack("!Q", exact(stream, 8))[0]
        payload = exact(stream, size)
        if first & 0x0F == 0x8:
            raise ControlStage("closed_by_marshall")
        if first & 0x0F == 0x1:
            document: object = json.loads(payload)
            if not isinstance(document, dict):
                raise ControlStage("frame_shape")
            if document.get("k") in {"welcome", "res"}:
                return document


def control_session(node: str, token: str, host_id: str, machine_id: str) -> dict[str, object]:
    """Opens one execution session over Lilly's control WebSocket (ADR-0142)."""
    context = ssl.create_default_context(cafile=str(ROOT / "ca.crt"))
    with (
        socket.create_connection((node, 5443), timeout=15) as raw,
        context.wrap_socket(raw, server_hostname=node) as stream,
    ):
        key = base64.b64encode(secrets.token_bytes(16)).decode()
        stream.sendall(
            (
                f"GET /api/control/v1 HTTP/1.1\r\nHost: {node}:5443\r\n"
                "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
                f"Sec-WebSocket-Key: {key}\r\noveralls-control: 1\r\noveralls-service: lilly\r\n"
                f"Authorization: Bearer {token}\r\n\r\n"
            ).encode()
        )
        head = b""
        while b"\r\n\r\n" not in head:
            head += exact(stream, 1)
        if not head.startswith(b"HTTP/1.1 101 "):
            status = head[9:12].decode("ascii", "replace")
            raise ControlStage("upgrade_" + (status if status.isdigit() else "invalid"))
        send_text(stream, {"k": "hello", "v": 1, "service": "lilly", "bind": {"host_id": host_id}})
        if receive_text(stream)["k"] != "welcome":
            raise ControlStage("no_welcome")
        body = {"version": 4, "session_id": str(uuid.uuid4()), "machine_id": machine_id}
        send_text(stream, {"k": "req", "id": 1, "op": "lilly.sessions", "body": body})
        response = receive_text(stream)
        if response.get("ok") is not True:
            error = response.get("error")
            name = (
                error if isinstance(error, str) and error.replace("_", "").isalpha() else "invalid"
            )
            raise ControlStage("session_" + name)
        session = response["body"]
        if not isinstance(session, dict):
            raise ControlStage("session_shape")
        return session


def verify_http(node: str, state_name: str, expected: str) -> None:
    state: dict[str, object] = json.loads((ROOT / f"{state_name}.json").read_text())
    credentials = state["credentials"]
    assert isinstance(credentials, list)
    for token in credentials:
        session = control_session(node, str(token), str(state["host_id"]), str(state["machine_id"]))
        if session.get("version") != 4:
            raise ControlStage("session_version")
    # The release names its own session cookie (__Host-marshall in production
    # builds); the probe records that name beside the forged value.
    cookie_name = state["cookie_name"]
    cookie = state["cookie"]
    if not isinstance(cookie_name, str) or not isinstance(cookie, str):
        raise ControlStage("state_cookie")
    status, body = http(
        urllib.request.Request(
            f"https://{node}:4443/machines", headers={"Cookie": f"{cookie_name}={cookie}"}
        )
    )
    if status != (200 if expected == "accept" else 302):
        raise ControlStage("browser_status_" + str(status))
    if expected == "accept" and not (b'id="machines"' in body or b'id="provision-form"' in body):
        raise ControlStage("browser_page")


def verify_running(node: str) -> None:
    values = read_environment(Path("/run/overalls-secrets/marshall/environment"))
    pid = (
        run(["systemctl", "show", "-p", "MainPID", "--value", f"marshall-{node}.service"])
        .decode()
        .strip()
    )
    actual = dict(
        entry.split(b"=", 1)
        for entry in Path("/proc", pid, "environ").read_bytes().split(b"\0")
        if b"=" in entry
    )
    assert all(actual.get(key.encode()) == value.encode() for key, value in values.items())
    journal = run(
        [
            "journalctl",
            "--no-pager",
            "--output=cat",
            "-u",
            f"marshall-{node}",
            "-u",
            "overalls-secrets-marshall",
            "-u",
            "rotation-probe",
            "-u",
            "overalls-auto-update",
            "-u",
            "overalls-auto-update-migrate",
        ]
    )
    private = [
        values[key]
        for key in (
            "DATABASE_URL",
            "MARSHALL_CLOAK_KEYS",
            "SECRET_KEY_BASE",
            "TOKEN_SIGNING_SECRET",
            "MARSHALL_SMTP_PASSWORD",
        )
    ]
    private += [entry["key"] for entry in json.loads(values["MARSHALL_CLOAK_KEYS"])]
    seen = ROOT / "seen-private-values.json"
    if seen.exists():
        private.extend(json.loads(seen.read_text()))
    private = list(dict.fromkeys(private))
    seen.write_text(json.dumps(private))
    for path in ROOT.glob("state-*.json"):
        state: dict[str, object] = json.loads(path.read_text())
        private.extend(state["credentials"] + [state["cookie"], state["token"]])
        private.extend(token.split(":", 1)[1] for token in state["credentials"])
    assert not any(value.encode() in journal for value in private)
    assert b"AGE-SECRET-KEY-" not in journal and b"BEGIN OPENSSH PRIVATE KEY" not in journal


def database_passwords(phase: str) -> None:
    assert phase in {"initial", "cutover"}
    address = Path("/etc/rotation-db-address").read_text().strip()
    parsed = ipaddress.ip_address(address)
    assert parsed.version == 4 and not parsed.is_loopback
    passwords = []
    for name, accepted in [
        ("initial-values.json", phase == "initial"),
        ("rotation-values.json", True),
    ]:
        values = json.loads((ROOT / name).read_text())
        uri = urlsplit(values["DATABASE_URL"])
        passwords.append(uri.password)
        result = subprocess.run(
            ["psql", "--no-psqlrc", "-Atc", "SELECT 1"],
            env={
                "PATH": os.environ["PATH"],
                "PGHOST": "db",
                "PGDATABASE": "marshall",
                "PGUSER": "marshall",
                # Match the configured test-network hostssl rule while retaining db
                # for TLS. Resolving this machine's own hostname can select loopback.
                "PGHOSTADDR": address,
                "PGPASSWORD": uri.password,
                "PGSSLMODE": "verify-full",
                "PGSSLROOTCERT": str(ROOT / "ca.crt"),
                "PGCONNECT_TIMEOUT": "10",
            },
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=15,
        )
        assert (result.returncode == 0) == accepted
        if accepted:
            assert result.stdout.strip() == b"1"
    journal = run(["journalctl", "--no-pager", "--output=cat", "-u", "postgresql"])
    assert not any(password.encode() in journal for password in passwords)


def main() -> None:
    os.umask(0o077)
    action, *arguments = sys.argv[1:]
    if action == "seal":
        seal(*arguments)
    elif action == "http":
        verify_http(*arguments)
    elif action == "running":
        verify_running(*arguments)
    elif action == "database-passwords":
        database_passwords(*arguments)
    else:
        raise ValueError("unknown fixture action")


if __name__ == "__main__":
    try:
        main()
    except ControlStage as stage:
        # Stage labels are closed names; they never carry credentials.
        print("Credential rotation fixture failed: " + str(stage), file=sys.stderr)
        sys.exit(1)
    except Exception as error:
        # The exception type is a closed name; its message may carry secrets.
        print("Credential rotation fixture failed: " + type(error).__name__, file=sys.stderr)
        sys.exit(1)
