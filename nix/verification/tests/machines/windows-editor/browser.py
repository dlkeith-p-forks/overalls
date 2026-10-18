"""Native Windows editor acceptance against an explicitly isolated candidate VM."""

import argparse
import base64
import gzip
import hashlib
import json
import os
import re
import secrets
import socket
import ssl
import subprocess
import tempfile
import threading
from dataclasses import dataclass
from pathlib import Path
from time import monotonic
from urllib.parse import urlencode, urlsplit

from playwright.sync_api import Page, Route, WebSocketRoute, expect, sync_playwright

# isort: split
# Both files are installed together; keep import classification stable when the
# artifact is checked outside the repository's nested machine-test tree.
from relay import Admission, RelayServer, object_mapping


@dataclass(frozen=True)
class NativeIdentity:
    pid: int
    created: int
    sid: str

    @staticmethod
    def parse(value: dict[str, object]) -> "NativeIdentity":
        pid, created, sid = value.get("worker_pid"), value.get("worker_created"), value.get("sid")
        if (
            type(pid) is not int
            or pid <= 0
            or type(created) is not int
            or created <= 0
            or not isinstance(sid, str)
            or re.fullmatch(r"S-1-5-21-(?:[0-9]+-){3}[0-9]+", sid) is None
        ):
            raise ValueError("fixture native process identity")
        return NativeIdentity(pid, created, sid)


@dataclass(frozen=True)
class Controller:
    configuration: Path
    target: str
    admission: Admission
    run_id: str
    fixture: Path
    identity: Path | None = None

    def powershell(self, script: str) -> bytes:
        # Windows OpenSSH's console adapter can leave stdin reads open. Keep
        # each fixture operation in a bounded in-memory compressed command.
        # The default OpenSSH cmd.exe wrapper has an 8191-character limit,
        # below CreateProcess's limit, so leave room for the fixed command.
        payload = base64.b64encode(gzip.compress(script.encode("utf-8"))).decode("ascii")
        bootstrap = (
            "$ErrorActionPreference='Stop'; "
            f"[byte[]]$Bytes=[Convert]::FromBase64String('{payload}'); "
            "$InputStream=New-Object IO.MemoryStream(,$Bytes); "
            "$Compressed=New-Object IO.Compression.GzipStream($InputStream,[IO.Compression.CompressionMode]::Decompress); "
            "$Reader=New-Object IO.StreamReader($Compressed,[Text.Encoding]::UTF8); "
            "$FixtureScript=$Reader.ReadToEnd(); $Reader.Dispose(); "
            "& ([ScriptBlock]::Create($FixtureScript))"
        )
        encoded = base64.b64encode(bootstrap.encode("utf-16le")).decode("ascii")
        if len(encoded) > 6000:
            raise ValueError("fixture compressed command bound")
        command = [
            "ssh",
            "-F",
            str(self.configuration),
            "-o",
            "BatchMode=yes",
            "-o",
            "LogLevel=ERROR",
        ]
        if self.identity is not None:
            command.extend(["-i", str(self.identity)])
        command.extend(
            [
                self.target,
                "powershell.exe",
                "-NoProfile",
                "-NonInteractive",
                "-ExecutionPolicy",
                "Bypass",
                "-EncodedCommand",
                encoded,
            ]
        )
        result = subprocess.run(
            command,
            check=False,
            capture_output=True,
            timeout=180,
        )
        if result.returncode != 0 or len(result.stdout) > 16384:
            raise RuntimeError("fixture native controller failed")
        return result.stdout

    def stage(self) -> None:
        """@cc [owner:ghuntley,label:verification;security] windows-editor-closed-fixture-staging
        Staging MUST require a fresh fixed run directory with administrator and
        SYSTEM-only writes. Only local packaged fixture files and the validated
        binding may enter it; the controller MUST NOT replace account authority.
        """
        root = rf"C:\overalls\editor-acceptance\{self.run_id}"
        script = (
            "$ErrorActionPreference='Stop'; "
            f"[string]$Root='{root}'; "
            "if (Test-Path -LiteralPath $Root) { throw 'fixture_directory_exists' }; "
            "[void](New-Item -ItemType Directory -Path $Root); "
            "& icacls.exe $Root /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' "
            "'*S-1-5-32-544:(OI)(CI)F' /q | Out-Null; "
            "if ($LASTEXITCODE -ne 0) { throw 'fixture_acl_failed' }; "
        )
        script += "Write-Output 'FIXTURE-STAGED'"
        if self.powershell(script).strip() != b"FIXTURE-STAGED":
            raise RuntimeError("fixture staging failed")
        files = {
            name: (self.fixture / name).read_bytes()
            for name in ("control.ps1", "extension.js", "package.json")
        }
        files["binding.json"] = self.admission.frame[4:]
        for name, content in files.items():
            # Independent small commands avoid both stdin behavior and the
            # command-line bound, including an unusually large compiled fixture.
            for offset in range(0, len(content), 768):
                encoded = base64.b64encode(content[offset : offset + 768]).decode("ascii")
                mode = "CreateNew" if offset == 0 else "Append"
                write = (
                    "$ErrorActionPreference='Stop'; "
                    f"$Stream=[IO.File]::Open('{root}\\{name}',[IO.FileMode]::{mode},[IO.FileAccess]::Write,[IO.FileShare]::None); "
                    f"try {{ $Bytes=[Convert]::FromBase64String('{encoded}'); $Stream.Write($Bytes,0,$Bytes.Length) }} finally {{ $Stream.Dispose() }}; "
                    "Write-Output 'FIXTURE-STAGED'"
                )
                if self.powershell(write).strip() != b"FIXTURE-STAGED":
                    raise RuntimeError("fixture file staging failed")

    def operation(self, operation: str) -> dict[str, object]:
        if operation not in {"setup", "snapshot", "kill-broker", "kill-worker"}:
            raise ValueError("fixture closed operation")
        script = (
            "$ErrorActionPreference='Stop'; "
            rf"& 'C:\overalls\editor-acceptance\{self.run_id}\control.ps1' "
            f"-Operation {operation} -Uid {self.admission.uid} -RunId {self.run_id}"
        )
        parsed: object = json.loads(self.powershell(script))
        result = object_mapping(parsed)
        if result.get("ok") is not True or result.get("operation") != operation:
            raise RuntimeError("fixture operation failed")
        return result


def command(page: Page) -> None:
    deadline = monotonic() + 60
    title = "Overalls Fixture: Windows Native Acceptance"
    while monotonic() < deadline:
        page.keyboard.press("Control+Shift+p")
        entry = page.locator(".quick-input-widget input")
        expect(entry).to_be_visible()
        entry.fill(">" + title)
        row = page.locator(".quick-input-widget .monaco-list-row").filter(has_text=title).first
        try:
            expect(row).to_be_visible(timeout=1000)
        except AssertionError:
            page.keyboard.press("Escape")
            continue
        row.click()
        expect(page.locator(".quick-input-widget")).not_to_be_visible()
        return
    raise AssertionError("fixture native command deadline")


def browser_stage(page: Page, origin: str, run_id: str) -> None:
    """@cc [owner:ghuntley,label:verification] windows-editor-native-browser-journey
    Each stage MUST load the real workbench without a trust prompt, discover the
    native contributed command, observe its exact success notification and see
    its real terminal marker in xterm. HTML or process presence alone MUST fail.
    """
    folder = rf"C:\workspace\overalls-editor-acceptance-{run_id}"
    page.goto(origin + "/?" + urlencode({"folder": folder}), wait_until="domcontentloaded")
    expect(page.locator(".monaco-workbench")).to_be_visible(timeout=120000)
    expect(
        page.get_by_text("Do you trust the authors of the files in this folder?", exact=True)
    ).to_have_count(0)
    command(page)
    expect(
        page.locator(".notifications-list-container")
        .filter(has_text="Windows native editor acceptance passed")
        .first
    ).to_contain_text("Windows native editor acceptance passed", timeout=60000)
    terminals = page.locator(".terminal-wrapper")
    expect(terminals.first).to_be_visible(timeout=30000)
    # The accessibility tree is the browser-observable PTY output, also used by
    # the production terminal probe. A screenshot or fixture file is insufficient.
    if page.locator(".xterm-accessibility-tree").count() == 0:
        page.keyboard.press("Control+Shift+p")
        entry = page.locator(".quick-input-widget input")
        entry.fill(">Toggle Screen Reader Accessibility Mode")
        row = (
            page.locator(".quick-input-widget .monaco-list-row")
            .filter(has_text="Toggle Screen Reader Accessibility Mode")
            .first
        )
        expect(row).to_be_visible()
        row.click()
    expect(page.locator(".xterm-accessibility-tree").last).to_contain_text(
        "WINDOWS-EDITOR-PTY-PASSED", timeout=30000
    )


def local_tls(directory: Path, hostname: str) -> tuple[ssl.SSLContext, str]:
    certificate, key = directory / "certificate.pem", directory / "key.pem"
    command = subprocess.run(
        [
            "openssl",
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-days",
            "1",
            "-subj",
            "/CN=Overalls Windows editor fixture",
            "-addext",
            "subjectAltName=DNS:" + hostname,
            "-keyout",
            str(key),
            "-out",
            str(certificate),
        ],
        check=False,
        capture_output=True,
        timeout=30,
    )
    if command.returncode != 0:
        raise RuntimeError("fixture TLS creation failed")
    public = subprocess.run(
        ["openssl", "x509", "-in", str(certificate), "-pubkey", "-noout"],
        check=True,
        capture_output=True,
        timeout=10,
    ).stdout
    der = subprocess.run(
        ["openssl", "pkey", "-pubin", "-outform", "DER"],
        input=public,
        check=True,
        capture_output=True,
        timeout=10,
    ).stdout
    pin = base64.b64encode(hashlib.sha256(der).digest()).decode("ascii")
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.minimum_version = ssl.TLSVersion.TLSv1_2
    tls.load_cert_chain(certificate, key)

    def servername(
        _stream: ssl.SSLSocket | ssl.SSLObject, name: str | None, _context: object
    ) -> int | None:
        return None if name == hostname else ssl.ALERT_DESCRIPTION_UNRECOGNIZED_NAME

    tls.set_servername_callback(servername)
    return tls, pin


@dataclass(frozen=True)
class Options:
    binding: Path
    ssh_config: Path
    ssh_target: str
    gateway_relay_port: int
    chromium: Path
    fixture: Path
    result: Path
    ssh_identity: Path | None

    @staticmethod
    def from_arguments(arguments: argparse.Namespace) -> "Options":
        def path(value: object) -> Path:
            if not isinstance(value, Path):
                raise ValueError("fixture path type")
            return value

        if arguments.isolated_vm is not True:
            raise ValueError("fixture isolated VM acknowledgement required")
        gateway_port: object = arguments.gateway_relay_port
        target: object = arguments.ssh_target
        if type(gateway_port) is not int or not 1 <= gateway_port <= 65535:
            raise ValueError("fixture loopback relay port")
        if (
            not isinstance(target, str)
            or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,252}", target) is None
        ):
            raise ValueError("fixture SSH target")
        return Options(
            path(arguments.binding),
            path(arguments.ssh_config),
            target,
            gateway_port,
            path(arguments.chromium),
            path(arguments.fixture),
            path(arguments.result),
            None if arguments.ssh_identity is None else path(arguments.ssh_identity),
        )


def run(options: Options) -> None:
    admission = Admission.parse(options.binding.read_bytes())
    run_id = secrets.token_hex(6)
    controller = Controller(
        options.ssh_config,
        options.ssh_target,
        admission,
        run_id,
        options.fixture,
        options.ssh_identity,
    )
    controller.stage()
    controller.operation("setup")
    print("windows_editor.fixture_setup_passed", flush=True)
    blocked = 0

    def route_request(route: Route) -> None:
        nonlocal blocked
        requested = urlsplit(route.request.url)
        if requested.scheme == "https" and "https://" + requested.netloc == admission.origin:
            route.continue_()
        else:
            blocked += 1
            route.abort()

    def route_socket(route: WebSocketRoute) -> None:
        nonlocal blocked
        blocked += 1
        route.close()

    with tempfile.TemporaryDirectory(prefix="windows-editor-tls-") as temporary:
        tls, pin = local_tls(Path(temporary), admission.hostname)
        with RelayServer(admission, options.gateway_relay_port, tls) as relay:
            if not isinstance(relay.socket, socket.socket):
                raise ValueError("fixture socket type")
            port = relay.socket.getsockname()[1]
            relay_thread = threading.Thread(target=relay.serve_forever, daemon=True)
            relay_thread.start()
            try:
                with sync_playwright() as playwright:
                    browser = playwright.chromium.launch(
                        executable_path=str(options.chromium),
                        args=[
                            "--no-sandbox",
                            "--disable-dev-shm-usage",
                            "--no-proxy-server",
                            f"--host-resolver-rules=MAP {admission.hostname} 127.0.0.1:{port},EXCLUDE localhost",
                            "--ignore-certificate-errors-spki-list=" + pin,
                        ],
                    )
                    context = browser.new_context(service_workers="block")
                    context.route("**/*", route_request)
                    # Leave the admitted sockets in Chromium's native network
                    # stack, where the TLS pin and loopback DNS mapping apply.
                    # Playwright intercepts and closes only foreign sockets.
                    context.route_web_socket(
                        re.compile(r"^(?!wss://" + re.escape(admission.authority) + r"(?:/|$))"),
                        route_socket,
                    )
                    context.set_default_timeout(15000)
                    context.set_default_navigation_timeout(120000)
                    page = context.new_page()
                    try:
                        browser_stage(page, admission.origin, run_id)
                        first = NativeIdentity.parse(controller.operation("snapshot"))
                        print("windows_editor.native_browser_passed", flush=True)
                        retained = NativeIdentity.parse(controller.operation("kill-broker"))
                        if retained != first:
                            raise AssertionError("fixture broker lost worker")
                        browser_stage(page, admission.origin, run_id)
                        if NativeIdentity.parse(controller.operation("snapshot")) != first:
                            raise AssertionError("fixture broker recovery changed custody")
                        print("windows_editor.broker_recovery_passed", flush=True)
                        killed = NativeIdentity.parse(controller.operation("kill-worker"))
                        if killed != first:
                            raise AssertionError("fixture worker kill custody changed")
                        browser_stage(page, admission.origin, run_id)
                        replacement = NativeIdentity.parse(controller.operation("snapshot"))
                        if replacement.sid != first.sid or (
                            replacement.pid,
                            replacement.created,
                        ) == (first.pid, first.created):
                            raise AssertionError("fixture worker recovery identity")
                        print("windows_editor.worker_recovery_passed", flush=True)
                    finally:
                        context.close()
                        browser.close()
            finally:
                relay.shutdown()
                relay_thread.join(timeout=5)
    options.result.write_text(
        json.dumps(
            {
                "version": 1,
                "native_windows": True,
                "native_terminal": True,
                "saved_data": True,
                "broker_recovery": True,
                "worker_recovery": True,
                "outside_home": True,
                "custody_acl_refusals": True,
                "external_requests_blocked": blocked,
                "ordinary_cli_acceptance": False,
                "capability_promotion": False,
                "binding_sha256": hashlib.sha256(admission.frame[4:]).hexdigest(),
                "extension_sha256": hashlib.sha256(
                    (options.fixture / "extension.js").read_bytes()
                ).hexdigest(),
            },
            sort_keys=True,
        )
        + "\n"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--isolated-vm", action="store_true", required=True)
    parser.add_argument("--binding", type=Path, required=True)
    parser.add_argument("--ssh-config", type=Path, required=True)
    parser.add_argument("--ssh-target", required=True)
    parser.add_argument("--ssh-identity", type=Path)
    parser.add_argument("--gateway-relay-port", type=int, required=True)
    parser.add_argument(
        "--chromium", type=Path, default=Path(os.environ.get("WINDOWS_EDITOR_CHROMIUM", "chromium"))
    )
    parser.add_argument("--fixture", type=Path, default=Path(__file__).parent)
    parser.add_argument("--result", type=Path, required=True)
    arguments = parser.parse_args()
    try:
        run(Options.from_arguments(arguments))
    except Exception:
        # Native/browser exceptions may contain URLs, command text or terminal
        # output. Only this fixed failure event is exposed.
        print("windows_editor.fixture_failed", flush=True)
        return 1
    print("windows_editor.fixture_passed", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
