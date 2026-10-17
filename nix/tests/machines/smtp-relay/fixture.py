"""Private, runtime-generated SMTP credentials and TLS upstream fixture."""

import base64
import contextlib
import email
import importlib.util
import json
import os
import secrets
import smtplib
import socketserver
import ssl
import subprocess
import sys
import threading
import time
from collections.abc import Sequence
from pathlib import Path

ROOT = Path("/run/overalls-smtp-fixture")


def run(args: Sequence[str], **kwargs: object) -> bytes:
    result = subprocess.run(args, capture_output=True, timeout=60, **kwargs)
    if result.returncode:
        raise ValueError("fixture command failed")
    return result.stdout


def seal(missing: bool = False) -> None:
    values: dict[str, object] = json.loads((ROOT / "values.json").read_text())
    if missing:
        values.pop("SMTP_PASSWORD")
    recipient = run(["ssh-to-age", "-i", "/etc/ssh/ssh_host_ed25519_key.pub"]).decode().strip()
    encrypted = run(
        [
            "sops",
            "--encrypt",
            "--age",
            recipient,
            "--input-type",
            "json",
            "--output-type",
            "json",
            "/dev/stdin",
        ],
        input=json.dumps({"overalls-smtp": {"production": values}}).encode(),
    )
    (ROOT / "smtp.enc.json").write_bytes(encrypted)


def initialize() -> None:
    ROOT.mkdir(mode=0o700, exist_ok=True)
    (ROOT / "values.json").write_text(
        json.dumps({"SMTP_USERNAME": secrets.token_hex(12), "SMTP_PASSWORD": secrets.token_hex(32)})
    )
    (ROOT / "behavior").write_text("accept")
    seal()


class SMTP(socketserver.StreamRequestHandler):
    def setup(self) -> None:
        self.request.settimeout(12)
        self.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.context.load_cert_chain("/run/overalls-test/tls.crt", "/run/overalls-test/tls.key")
        self.secure = self.server.server_address[1] == 1465
        if self.secure:
            self.request = self.context.wrap_socket(self.request, server_side=True)
        super().setup()

    def reply(self, message: str) -> None:
        self.wfile.write(message.encode() + b"\r\n")
        self.wfile.flush()

    def handle(self) -> None:
        with contextlib.suppress(OSError, ValueError):
            self.session()

    def session(self) -> None:
        self.reply("220 localhost fixture")
        authenticated = False
        while True:
            line = self.rfile.readline(8192).strip()
            if not line:
                return
            command = line.split(b" ")[0].upper()
            if command in (b"EHLO", b"HELO"):
                self.reply("250-localhost")
                self.reply("250 AUTH PLAIN LOGIN" if self.secure else "250 STARTTLS")
            elif command == b"STARTTLS":
                self.reply("220 TLS")
                self.request = self.context.wrap_socket(self.request, server_side=True)
                self.rfile = self.request.makefile("rb")
                self.wfile = self.request.makefile("wb")
                self.secure = True
            elif command == b"AUTH" and self.secure:
                fields = line.split()
                if fields[1] == b"PLAIN":
                    supplied = base64.b64decode(fields[2]).split(b"\0")[-2:]
                else:
                    self.reply("334 VXNlcm5hbWU6")
                    user = base64.b64decode(self.rfile.readline().strip())
                    self.reply("334 UGFzc3dvcmQ6")
                    supplied = [user, base64.b64decode(self.rfile.readline().strip())]
                values = json.loads((ROOT / "values.json").read_text())
                authenticated = supplied == [
                    values["SMTP_USERNAME"].encode(),
                    values["SMTP_PASSWORD"].encode(),
                ]
                self.reply("235 Authenticated" if authenticated else "535 Failed")
            elif command in (b"MAIL", b"RCPT"):
                self.reply("250 OK" if authenticated else "530 Authenticate")
            elif command == b"DATA" and authenticated:
                self.reply("354 Data")
                data = bytearray()
                while True:
                    chunk = self.rfile.readline(1048577)
                    if not chunk or chunk == b".\r\n":
                        break
                    data.extend(chunk)
                    if len(data) > 1048576:
                        return
                (ROOT / "last-message").write_bytes(data)
                behavior = (ROOT / "behavior").read_text().strip()
                if behavior == "reject":
                    values = json.loads((ROOT / "values.json").read_text())
                    self.reply("451 reflected-" + values["SMTP_PASSWORD"])
                elif behavior == "stall":
                    time.sleep(10)
                    return
                elif behavior == "delay":
                    (ROOT / "waiting").touch()
                    deadline = time.monotonic() + 6
                    while not (ROOT / "release").exists() and time.monotonic() < deadline:
                        time.sleep(0.02)
                    self.reply("250 Accepted")
                else:
                    self.reply("250 Accepted")
            elif command == b"QUIT":
                self.reply("221 Bye")
                return
            else:
                self.reply("250 OK")


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def handle_error(self, request: object, client_address: object) -> None:
        pass


def serve() -> None:
    servers = [Server(("127.0.0.1", port), SMTP) for port in (1465, 1587)]
    for server in servers:
        threading.Thread(target=server.serve_forever, daemon=True).start()
    threading.Event().wait()


def check() -> None:
    values: dict[str, object] = json.loads((ROOT / "values.json").read_text())
    pid = (
        run(["systemctl", "show", "-p", "MainPID", "--value", "overalls-smtprelay"])
        .decode()
        .strip()
    )
    marshall_pid = (
        run(["systemctl", "show", "-p", "MainPID", "--value", "marshall-primary"]).decode().strip()
    )
    if marshall_pid != "0":
        app_environment = Path("/proc", marshall_pid, "environ").read_bytes().split(b"\0")
        assert b"MARSHALL_MAIL_TRANSPORT=local_relay" in app_environment
        assert not any(
            entry.startswith((b"MARSHALL_SMTP_PASSWORD=", b"MARSHALL_SMTP_USERNAME="))
            for entry in app_environment
        )
    argv = Path("/proc", pid, "cmdline").read_bytes()
    environment = Path("/proc", pid, "environ").read_bytes()
    journal = run(
        [
            "journalctl",
            "--no-pager",
            "-o",
            "cat",
            "-u",
            "overalls-smtprelay",
            "-u",
            "overalls-secrets-smtp",
            "-u",
            "overalls-test-mail",
        ]
    )
    for value in values.values():
        if value.encode() in argv + environment + journal:
            raise ValueError("secret leaked")
    if (ROOT / "token").exists() and (ROOT / "token").read_bytes() in journal:
        raise ValueError("token leaked")
    if b"reflected-" in journal or b"AGE-SECRET-KEY-" in journal:
        raise ValueError("private diagnostic leaked")
    if (ROOT / "last-message").exists():
        message = email.message_from_bytes((ROOT / "last-message").read_bytes())
        for part in message.walk():
            body = part.get_payload(decode=True)
            if body and b"/magic_link/" in body and body in journal:
                raise ValueError("payload leaked")
    if Path("/run/overalls-secrets-smtp/identity").exists():
        raise ValueError("identity retained")


def staged(action: str) -> None:
    runtime = Path("/run/overalls-auto-update")
    runtime.mkdir(mode=0o700, exist_ok=True)
    manifest: dict[str, object] = json.loads(
        Path("/run/current-system/overalls-deployment.json").read_text()
    )
    assert "overalls-smtprelay.service" in manifest["consumers"]
    assert "overalls-smtprelay.service" in manifest["healthUnits"]
    assert (
        "MARSHALL_MAIL_TRANSPORT=local_relay" in Path(manifest["marshall"]["migrate"]).read_text()
    )
    if action == "stage":
        spec = importlib.util.spec_from_file_location("updater", sys.argv[2])
        if spec is None or spec.loader is None:
            raise RuntimeError("updater helper unavailable")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        deployment = module.Deployment({"secretHelper": sys.argv[3]})
        deployment.candidate = manifest
        deployment.stage()
        (ROOT / "handoff.json").write_text(json.dumps(deployment.handoff))
    elif action == "handoff":
        (runtime / "handoff.json").write_bytes((ROOT / "handoff.json").read_bytes())
    elif action == "check-staged":
        handoff: dict[str, object] = json.loads((ROOT / "handoff.json").read_text())
        selected = Path(next(iter(handoff.values())))
        assert (selected / "password").read_bytes() == Path(
            "/run/overalls-secrets/smtp/password"
        ).read_bytes()
        assert (selected / "password").read_bytes() != json.loads(
            (ROOT / "values.json").read_text()
        )["SMTP_PASSWORD"].encode()
    elif action == "migration":
        run(
            [
                "systemd-run",
                "--quiet",
                "--wait",
                "--collect",
                "--pipe",
                "--unit=overalls-smtp-migration",
                "--property=Type=oneshot",
                "--property=RuntimeDirectory=overalls-migration",
                "--property=DynamicUser=yes",
                "--property=EnvironmentFile=" + manifest["marshall"]["environmentFile"],
                "--property=LoadCredential=database-ca.crt:"
                + manifest["marshall"]["databaseCAFile"],
                manifest["marshall"]["migrate"],
            ]
        )


def delayed() -> None:
    for name in ("waiting", "release"):
        (ROOT / name).unlink(missing_ok=True)
    (ROOT / "behavior").write_text("delay")
    outcome: list[bool] = []

    def send() -> None:
        try:
            with smtplib.SMTP("127.0.0.1", 2525, timeout=10) as client:
                client.sendmail(
                    "noreply@example.test",
                    ["recipient@example.test"],
                    "Subject: fixture\r\n\r\nfixture",
                )
            outcome.append(True)
        except Exception:
            outcome.append(False)

    worker = threading.Thread(target=send)
    worker.start()
    deadline = time.monotonic() + 4
    while not (ROOT / "waiting").exists() and time.monotonic() < deadline:
        time.sleep(0.02)
    assert (ROOT / "waiting").exists() and not outcome
    (ROOT / "release").touch()
    worker.join(timeout=5)
    assert outcome == [True]
    (ROOT / "behavior").write_text("accept")


if __name__ == "__main__":
    os.umask(0o077)
    try:
        action = sys.argv[1]
        if action in ("stage", "handoff", "check-staged", "migration"):
            staged(action)
        elif action == "initialize":
            initialize()
        elif action == "serve":
            serve()
        elif action == "rotate":
            values: dict[str, object] = json.loads((ROOT / "values.json").read_text())
            values["SMTP_PASSWORD"] = secrets.token_hex(32)
            (ROOT / "values.json").write_text(json.dumps(values))
            seal()
        elif action == "missing":
            seal(True)
        elif action == "seal":
            seal()
        elif action == "check":
            check()
        elif action == "delayed":
            delayed()
        else:
            raise ValueError("invalid fixture action")
    except Exception:
        print("SMTP fixture failed", file=sys.stderr)
        sys.exit(1)
