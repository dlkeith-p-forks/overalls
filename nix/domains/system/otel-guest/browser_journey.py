"""Perform the real signed-in guest browser editor journey without credential output."""

import argparse
import json
import os
import re
import shlex
import stat
import sys
import time
from contextlib import suppress
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path
from tempfile import TemporaryDirectory
from urllib.parse import urlencode, urlsplit
from uuid import UUID

from playwright.sync_api import (
    ConsoleMessage,
    ElementHandle,
    Page,
    Response,
    WebSocket,
    expect,
    sync_playwright,
)
from playwright.sync_api import (
    Error as PlaywrightError,
)
from playwright.sync_api import (
    TimeoutError as PlaywrightTimeoutError,
)


class GuestFamily(StrEnum):
    """@cc [owner:ghuntley,label:verification] browser-editor-family-oracle
    An accepted fixture family MUST equal the canonical /etc/os-release ID
    observed in its managed guest terminal. Unknown families MUST refuse before
    browser launch, rather than falling back to another family.
    """

    NIXOS = "nixos"
    UBUNTU = "ubuntu"
    ARCH = "arch"
    ALMALINUX = "almalinux"


@dataclass(frozen=True)
class Fixture:
    marshall_origin: str
    machine_id: str
    expected_editor_origin: str
    expected_guest: GuestFamily
    workspace_file: str
    expected_uid: int
    expected_username: str
    storage_state_path: str


class Stage(StrEnum):
    LAUNCH = "launch"
    HANDOFF = "authenticated handoff"
    WORKBENCH = "workbench"
    WORKSPACE_NAVIGATION = "workspace navigation"
    WORKSPACE_WORKBENCH = "workspace workbench"
    WORKSPACE_TRUST = "workspace trust"
    EDIT = "edit"
    SAVE = "save"
    READBACK = "readback"
    WEBVIEW = "webview"
    TERMINAL_CONTROLS = "terminal controls"
    TERMINAL_PALETTE = "terminal command palette"
    TERMINAL_SUBMISSION = "terminal command submission"
    TERMINAL_CREATION = "terminal creation"
    TERMINAL_ACCESSIBILITY = "terminal accessibility"
    TERMINAL = "terminal identity"
    TERMINAL_CLEANUP = "terminal cleanup"


class FailureKind(StrEnum):
    TIMEOUT = "timeout"
    ASSERTION = "assertion"
    BROWSER = "browser"
    CUSTODY = "custody"
    UNEXPECTED = "unexpected"


class DocumentStatus(StrEnum):
    UNSEEN = "unseen"
    SUCCESS = "success"
    AUTHENTICATION_REQUIRED = "authentication-required"
    FORBIDDEN = "forbidden"
    NOT_FOUND = "not-found"
    BAD_GATEWAY = "bad-gateway"
    UNAVAILABLE = "unavailable"
    GATEWAY_TIMEOUT = "gateway-timeout"
    OTHER = "other"


@dataclass
class StartupDiagnostic:
    document: DocumentStatus = DocumentStatus.UNSEEN
    console_error: bool = False
    page_error: bool = False
    websocket_seen: bool = False
    websocket_error: bool = False


def document_status(status: int) -> DocumentStatus:
    if 200 <= status < 300:
        return DocumentStatus.SUCCESS
    return {
        401: DocumentStatus.AUTHENTICATION_REQUIRED,
        403: DocumentStatus.FORBIDDEN,
        404: DocumentStatus.NOT_FOUND,
        502: DocumentStatus.BAD_GATEWAY,
        503: DocumentStatus.UNAVAILABLE,
        504: DocumentStatus.GATEWAY_TIMEOUT,
    }.get(status, DocumentStatus.OTHER)


def observe_startup(page: Page, editor_origin: str) -> StartupDiagnostic:
    """@cc [owner:ghuntley,label:verification;security] browser-startup-observation-custody
    Startup observation MUST retain only fixed document status and error/connection
    booleans for the exact editor origin. Callbacks MUST discard message bodies,
    URLs, headers, cookies and WebSocket payloads without logging them.
    """
    result = StartupDiagnostic()
    origin = urlsplit(editor_origin)

    def at_editor() -> bool:
        try:
            location = urlsplit(page.url)
            return (location.scheme, location.netloc) == (origin.scheme, origin.netloc)
        except (PlaywrightError, ValueError):
            return False

    def response_seen(response: Response) -> None:
        if response.request.resource_type != "document" or response.frame != page.main_frame:
            return
        location = urlsplit(response.url)
        if (location.scheme, location.netloc) == (origin.scheme, origin.netloc):
            result.document = document_status(response.status)

    def console_seen(message: ConsoleMessage) -> None:
        if at_editor() and message.type == "error":
            result.console_error = True

    def page_error_seen(_error: PlaywrightError) -> None:
        if at_editor():
            result.page_error = True

    def websocket_error_seen(_error: str) -> None:
        result.websocket_error = True

    def websocket_seen(socket: WebSocket) -> None:
        location = urlsplit(socket.url)
        if location.scheme == "wss" and location.netloc == origin.netloc:
            result.websocket_seen = True
            socket.on("socketerror", websocket_error_seen)

    page.on("response", response_seen)
    page.on("console", console_seen)
    page.on("pageerror", page_error_seen)
    page.on("websocket", websocket_seen)
    return result


def startup_diagnostic(page: Page, observed: StartupDiagnostic) -> None:
    """@cc [owner:ghuntley,label:verification;security] browser-failed-startup-finite-observations
    Failed startup diagnostics MUST contain only the fixed document category and
    validated boolean bootstrap/connection fields. They MUST NOT read document
    text, exception messages, request bodies, URLs or credentials. Observation
    MUST NOT retry navigation or extend an assertion's deadline; diagnostic
    failure MUST NOT replace the original journey failure.
    """
    print("Browser editor diagnostic document=" + observed.document.value, flush=True)
    for key, value in (
        ("console_error", observed.console_error),
        ("page_error", observed.page_error),
        ("websocket_seen", observed.websocket_seen),
        ("websocket_error", observed.websocket_error),
    ):
        print("Browser editor diagnostic " + key + "=" + str(value).lower(), flush=True)
    try:
        snapshot: object = page.evaluate("""() => {
            const workbench = document.querySelector('.monaco-workbench');
            const has = name => performance.getEntriesByName(name, 'mark').length > 0;
            return {
                configuration: !!document.querySelector('meta#vscode-workbench-web-configuration'),
                fallback: !!document.querySelector('#vscode-startup-fallback'),
                monaco_present: !!workbench,
                monaco_visible: !!workbench && workbench.getBoundingClientRect().width > 0 && workbench.getBoundingClientRect().height > 0 && getComputedStyle(workbench).visibility !== 'hidden',
                renderer_started: has('code/didStartRenderer'),
                main_loading: has('code/willLoadWorkbenchMain'),
                main_loaded: has('code/didLoadWorkbenchMain'),
                workbench_starting: has('code/willStartWorkbench')
            };
        }""")
        required = (
            "configuration",
            "fallback",
            "monaco_present",
            "monaco_visible",
            "renderer_started",
            "main_loading",
            "main_loaded",
            "workbench_starting",
        )
        values = fields(snapshot)
        if set(values) != set(required):
            raise ValueError("closed bootstrap diagnostic required")
        for key in required:
            value = values[key]
            if not isinstance(value, bool):
                raise ValueError("boolean bootstrap diagnostic required")
            print("Browser editor diagnostic " + key + "=" + str(value).lower(), flush=True)
    except Exception:
        print("Browser editor diagnostic bootstrap=unavailable", flush=True)


def failure_kind(error: Exception) -> FailureKind:
    """@cc [owner:ghuntley,label:security] browser-journey-finite-failures
    Failure diagnostics MUST contain only a fixed category, never exception text,
    URLs, browser state, credentials, workspace contents or terminal output.
    """
    if isinstance(error, PlaywrightTimeoutError):
        return FailureKind.TIMEOUT
    if isinstance(error, AssertionError):
        return FailureKind.ASSERTION
    if isinstance(error, PlaywrightError):
        return FailureKind.BROWSER
    if isinstance(error, OSError):
        return FailureKind.CUSTODY
    return FailureKind.UNEXPECTED


def stage(value: Stage) -> None:
    print("Browser editor journey stage: " + value.value, flush=True)


def fields(value: object) -> dict[str, object]:
    if not isinstance(value, dict):
        raise ValueError("fixture object required")
    result: dict[str, object] = {}
    for key, item in value.items():
        if not isinstance(key, str):
            raise ValueError("fixture keys must be strings")
        result[key] = item
    return result


def private_json(path: Path) -> object:
    """@cc [owner:ghuntley,label:security] browser-fixture-private-custody
    Browser credentials MUST come only from bounded private regular runtime files.
    Paths, tokens, cookies, browser logs and fixture bodies MUST NOT be printed.
    """
    descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as stream:
        metadata = os.fstat(stream.fileno())
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid not in {0, os.geteuid()}
            or metadata.st_mode & 0o077
            or metadata.st_size > 65_536
        ):
            raise ValueError("private browser fixture custody required")
        contents = stream.read(65_537)
        if len(contents) > 65_536:
            raise ValueError("browser fixture exceeds byte limit")
        result: object = json.loads(contents)
        return result


def text(value: object) -> str:
    if not isinstance(value, str) or not value or len(value) > 4096 or "\x00" in value:
        raise ValueError("bounded fixture string required")
    return value


def origin(value: object) -> str:
    candidate = text(value)
    parsed = urlsplit(candidate)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username
        or parsed.password
        or parsed.path
        or parsed.query
        or parsed.fragment
        or candidate != f"https://{parsed.netloc}"
    ):
        raise ValueError("canonical HTTPS fixture origin required")
    return candidate


def load_fixture(path: Path) -> Fixture:
    value = fields(private_json(path))
    required = {
        "marshall_origin",
        "machine_id",
        "expected_editor_origin",
        "expected_guest",
        "workspace_file",
        "expected_uid",
        "expected_username",
        "storage_state_path",
    }
    if value.keys() != required:
        raise ValueError("closed browser fixture schema required")
    machine_id = text(value["machine_id"])
    if str(UUID(machine_id)) != machine_id:
        raise ValueError("canonical fixture VM UUID required")
    guest = GuestFamily(text(value["expected_guest"]))
    uid = value["expected_uid"]
    if isinstance(uid, bool) or not isinstance(uid, int) or not 200_000 <= uid <= 999_999:
        raise ValueError("personal guest UID fixture required")
    username = text(value["expected_username"])
    if (
        not re.fullmatch(r"[a-z_](?:[a-z0-9_.-]{0,30}[a-z0-9_])?", username)
        or username
        in {
            "root",
            "daemon",
            "bin",
            "sys",
            "sync",
            "games",
            "man",
            "lp",
            "mail",
            "news",
            "uucp",
            "proxy",
            "www-data",
            "backup",
            "list",
            "irc",
            "gnats",
            "nobody",
            "ubuntu",
            "sshd",
            "sudo",
            "postgres",
        }
        or username.startswith(("systemd-", "nixbld"))
    ):
        raise ValueError("canonical personal guest username required")
    workspace_file = text(value["workspace_file"])
    if (
        not workspace_file.startswith("/")
        or ".." in Path(workspace_file).parts
        or not workspace_file.endswith(".md")
    ):
        raise ValueError("absolute fixture Markdown file required")
    state_path = text(value["storage_state_path"])
    if not state_path.startswith("/"):
        raise ValueError("absolute private storage-state path required")
    state = fields(private_json(Path(state_path)))
    if state.keys() != {"cookies", "origins"}:
        raise ValueError("Playwright storage-state schema required")
    for name, maximum in [("cookies", 64), ("origins", 16)]:
        values = state[name]
        if not isinstance(values, list) or len(values) > maximum:
            raise ValueError("bounded Playwright storage-state list required")
        for item in values:
            fields(item)
    return Fixture(
        origin(value["marshall_origin"]),
        machine_id,
        origin(value["expected_editor_origin"]),
        guest,
        workspace_file,
        uid,
        username,
        state_path,
    )


def select_command(page: Page, title: str) -> ElementHandle:
    """@cc [owner:ghuntley,label:verification;security] browser-command-prepare-only
    Palette preparation MUST be bounded to an eight-second retry window and MUST
    NOT submit any action. Success MUST return the captured palette input only
    after its matching command is visible; failure MUST fail the journey.
    """
    deadline = time.monotonic() + 8
    entry = page.locator(".quick-input-widget input").first

    def budget() -> int:
        return max(1, min(1000, int((deadline - time.monotonic()) * 1000)))

    # A webview can asynchronously reclaim focus and dismiss a newly opened
    # palette. Reopen only before submission; creation is never retried.
    while time.monotonic() < deadline:
        page.keyboard.press("Control+Shift+P")
        try:
            entry.wait_for(state="visible", timeout=budget())
            entry.fill(">" + title, timeout=budget())
            page.locator(".quick-input-widget .monaco-list-row").filter(
                has_text=title
            ).first.wait_for(state="visible", timeout=budget())
            selected = entry.element_handle(timeout=budget())
            if selected is not None:
                return selected
        except PlaywrightTimeoutError:
            pass
        page.keyboard.press("Escape")
    raise RuntimeError("workbench command unavailable")


def submit_command(page: Page, entry: ElementHandle) -> None:
    """@cc [owner:ghuntley,label:verification;security] browser-command-single-submit
    Submission MUST send Enter once through the captured palette input and confirm
    palette closure. Missing visible input or positive focus custody MUST refuse
    before dispatch. Failure MUST propagate, never retry a possibly executed
    action or send Enter through a different focused editor or terminal.
    """
    try:
        # Keep Enter attached to the palette input, so late iframe focus cannot
        # send it to the preview or to an existing terminal instead.
        entry.wait_for_element_state("visible", timeout=8000)
        entry.focus()
        focused: object = entry.evaluate(
            "element => element.isConnected && element.ownerDocument.activeElement === element"
        )
        if focused is not True:
            raise RuntimeError("command input focus custody unavailable")
        entry.press("Enter", timeout=8000)
    finally:
        entry.dispose()
    expect(page.locator(".quick-input-widget")).not_to_be_visible()


def command(page: Page, title: str) -> None:
    submit_command(page, select_command(page, title))


def open_file(page: Page, path: str) -> None:
    page.keyboard.press("Control+p")
    entry = page.locator(".quick-input-widget input").first
    expect(entry).to_be_visible()
    entry.fill(path)
    expect(
        page.locator(".quick-input-widget .monaco-list-row .label-name")
        .filter(has_text=re.compile(r"^" + re.escape(Path(path).name) + r"$"))
        .first
    ).to_be_visible()
    page.keyboard.press("Enter")
    expect(page.locator(".quick-input-widget")).not_to_be_visible()
    expect(page.locator(".editor-instance .monaco-editor").first).to_be_visible()


def trust_workspace(page: Page) -> None:
    """@cc [owner:ghuntley,label:verification] browser-probe-workspace-trust
    The probe MUST positively verify the server's unconditional trust-disabled
    bootstrap before using a workspace, with no trust-storage injection or trust
    UI action. Native extension acceptance separately proves workspace.isTrusted;
    absence of a Restricted Mode indicator alone MUST NOT establish trust.
    """
    disabled: object = page.evaluate("""() => {
        const element = document.getElementById('vscode-workbench-web-configuration');
        const settings = element?.getAttribute('data-settings');
        if (!settings) return false;
        const configuration = JSON.parse(settings);
        return configuration !== null && typeof configuration === 'object'
            && configuration.enableWorkspaceTrust === false;
    }""")
    if disabled is not True:
        raise RuntimeError("workspace trust policy unavailable")


def create_probe_terminal(page: Page) -> ElementHandle:
    """@cc [owner:ghuntley,label:security;verification] browser-probe-new-terminal
    The probe MUST create and capture a new terminal in the editor area, regardless
    of user default-location settings, never a preexisting terminal while creation
    is still pending. It MUST submit creation only once and wait at most 25 seconds
    for that new input, within the supervisor's independent 60-second deadline.
    """
    previous = page.locator(".terminal-wrapper").element_handles()
    try:
        stage(Stage.TERMINAL_PALETTE)
        entry = select_command(page, "Terminal: Create New Terminal in Editor Area")
        stage(Stage.TERMINAL_SUBMISSION)
        submit_command(page, entry)
        stage(Stage.TERMINAL_CREATION)
        # Upstream's first remote terminal profile discovery can legitimately
        # wait on its 20-second profilesReady barrier. Await the one submitted
        # action; retrying creation could leave multiple unowned terminals.
        created = page.wait_for_function(
            """previous => {
                const inputs = document.querySelectorAll(
                    '.terminal-editor .terminal-wrapper.active .xterm-helper-textarea'
                );
                return [...inputs].find(input =>
                    !previous.includes(input.closest('.terminal-wrapper'))
                ) || false;
            }""",
            arg=previous,
            timeout=25_000,
        ).as_element()
        if created is None:
            raise RuntimeError("new terminal custody unavailable")
        return created
    finally:
        for wrapper in previous:
            wrapper.dispose()


def close_probe_terminal(page: Page, terminal: ElementHandle) -> None:
    """@cc [owner:ghuntley,label:recovery;security] browser-probe-terminal-custody
    Cleanup MUST target only the terminal input captured after this probe's
    Create New Terminal in Editor Area action. It MUST confirm removal through
    the ordinary workbench UI, including after a failed assertion, before
    successful settlement.
    """
    connected: object = terminal.evaluate("element => element.isConnected")
    if connected is False:
        return
    if connected is not True:
        raise RuntimeError("terminal custody unavailable")
    in_editor: object = terminal.evaluate("element => element.closest('.terminal-editor') !== null")
    if in_editor is not True:
        raise RuntimeError("terminal editor custody unavailable")
    terminal.focus()
    command(page, "Terminal: Kill the Active Terminal in Editor Area")
    page.wait_for_function("element => !element.isConnected", arg=terminal)


def terminal_output_contains(page: Page, terminal: ElementHandle, expected: str) -> None:
    """@cc [owner:ghuntley,label:verification] browser-probe-owned-terminal-output
    Terminal assertions MUST observe the captured terminal's accessibility tree,
    never another visible terminal in a different editor group.
    """
    page.wait_for_function(
        """result => result.terminal.closest('.terminal-wrapper')
            ?.querySelector('.xterm-accessibility-tree')
            ?.textContent.includes(result.expected) === true""",
        arg={"terminal": terminal, "expected": expected},
    )


def run_journey(fixture: Fixture, chromium: Path) -> None:
    """@cc [owner:ghuntley,label:verification;security] browser-native-editor-journey
    Success MUST require real Marshall authentication, the expected editor origin,
    guest edit/save/readback, personal terminal identity and isolated Markdown.
    A browser or assertion failure MUST NOT be projected as a successful journey.
    Browser configuration and cache MUST use a private writable fixture directory,
    including when the probe runs under an account with an unwritable home.
    """
    marker = "overalls-browser-journey-" + str(time.monotonic_ns())
    stage(Stage.LAUNCH)
    with (
        TemporaryDirectory(prefix="overalls-browser-profile-") as profile,
        sync_playwright() as playwright,
    ):
        browser = playwright.chromium.launch(
            executable_path=str(chromium),
            env={**os.environ, "XDG_CONFIG_HOME": profile, "XDG_CACHE_HOME": profile},
            args=["--disable-dev-shm-usage"] + (["--no-sandbox"] if os.geteuid() == 0 else []),
        )
        context = browser.new_context(storage_state=fixture.storage_state_path)
        context.set_default_timeout(8000)
        context.set_default_navigation_timeout(15000)
        page = context.new_page()
        observed = observe_startup(page, fixture.expected_editor_origin)
        probe_terminal: ElementHandle | None = None
        try:
            stage(Stage.HANDOFF)
            page.goto(f"{fixture.marshall_origin}/machines/{fixture.machine_id}/code")
            page.wait_for_url(fixture.expected_editor_origin + "/**")
            stage(Stage.WORKBENCH)
            expect(page.locator(".monaco-workbench")).to_be_visible()
            stage(Stage.WORKSPACE_NAVIGATION)
            page.goto(
                fixture.expected_editor_origin
                + "/?"
                + urlencode({"folder": str(Path(fixture.workspace_file).parent)})
            )
            stage(Stage.WORKSPACE_WORKBENCH)
            expect(page.locator(".monaco-workbench")).to_be_visible()
            stage(Stage.WORKSPACE_TRUST)
            trust_workspace(page)
            stage(Stage.EDIT)
            open_file(page, fixture.workspace_file)
            page.locator(".editor-instance .monaco-editor").first.click()
            page.keyboard.press("Control+a")
            page.keyboard.insert_text(f"# Overalls browser journey\n\n{marker}\n")
            stage(Stage.SAVE)
            page.keyboard.press("Control+s")
            expect(page.locator(".tabs-container .tab.active.dirty")).to_have_count(0)
            stage(Stage.READBACK)
            command(page, "View: Close Editor")
            open_file(page, fixture.workspace_file)
            expect(page.locator(".editor-instance .view-lines").first).to_contain_text(marker)
            stage(Stage.WEBVIEW)
            command(page, "Markdown: Open Preview to the Side")
            preview = page.frame_locator("iframe.webview").frame_locator("iframe#active-frame")
            expect(preview.locator("body")).to_contain_text(marker)
            frames = [frame.url for frame in page.frames if "/code-assets/" in frame.url]
            editor_origin = urlsplit(fixture.expected_editor_origin)
            zone = (editor_origin.hostname or "").partition(".")[2]
            if not any(urlsplit(url).path.endswith("/index.html") for url in frames) or any(
                urlsplit(url).scheme != "https"
                or not re.fullmatch(
                    r"[01][0-9a-v]{51}\." + re.escape(zone),
                    urlsplit(url).hostname or "",
                )
                or (urlsplit(url).port or 443) != (editor_origin.port or 443)
                or not re.fullmatch(
                    r"/code-assets/[0-9a-f]{64}/out/vs/workbench/contrib/webview/browser/pre/(?:index|fake)\.html",
                    urlsplit(url).path,
                )
                for url in frames
            ):
                raise RuntimeError("isolated Markdown frame required")
            stage(Stage.TERMINAL_CONTROLS)
            probe_terminal = create_probe_terminal(page)
            terminal = probe_terminal
            stage(Stage.TERMINAL_ACCESSIBILITY)
            accessible: object = terminal.evaluate(
                "element => !!element.closest('.terminal-wrapper')"
                "?.querySelector('.xterm-accessibility-tree')"
            )
            if accessible is False:
                command(page, "Toggle Screen Reader Accessibility Mode")
            elif accessible is not True:
                raise RuntimeError("terminal accessibility custody unavailable")
            page.wait_for_function(
                "element => !!element.closest('.terminal-wrapper')"
                "?.querySelector('.xterm-accessibility-tree')",
                arg=terminal,
            )
            stage(Stage.TERMINAL)
            terminal.focus()
            terminal.press("Control+u")
            # Xterm exposes visible rows, rather than scrollback. Keep all three
            # independent observations together in one bounded result line.
            terminal.type(
                "printf 'uid=%s(%s) saved=%s ID=%s\\n' "
                '"$(id -u)" "$(id -un)" '
                '"$(tail -n 1 '
                + shlex.quote(fixture.workspace_file)
                + ')" "$(. /etc/os-release; printf \'%s\' "$ID")"'
            )
            terminal.press("Enter")
            terminal_output_contains(
                page, terminal, f"uid={fixture.expected_uid}({fixture.expected_username})"
            )
            terminal_output_contains(page, terminal, marker)
            terminal_output_contains(page, terminal, "ID=" + fixture.expected_guest)
        except Exception:
            with suppress(Exception):
                startup_diagnostic(page, observed)
            raise
        finally:
            try:
                if probe_terminal is not None:
                    stage(Stage.TERMINAL_CLEANUP)
                    close_probe_terminal(page, probe_terminal)
            finally:
                context.close()
                browser.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("fixture", type=Path)
    parser.add_argument("--chromium", required=True, type=Path)
    args = parser.parse_args()
    try:
        run_journey(load_fixture(args.fixture), args.chromium)
    except Exception as error:
        print("Browser editor journey failed: " + failure_kind(error).value, file=sys.stderr)
        return 1
    print("Browser editor journey passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
