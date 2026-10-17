"""Built-in workbench and native extension-host smoke journey over trusted TLS."""

import argparse
import json
import os
import re
from contextlib import ExitStack
from pathlib import Path
from time import monotonic
from urllib.parse import urlparse, urlsplit

from browser_journey import (  # ty: ignore[unresolved-import] # copied nix/domains/system/otel-guest/browser_journey.py
    close_probe_terminal,
    create_probe_terminal,
    terminal_output_contains,
    trust_workspace,
)
from browser_journey import (  # ty: ignore[unresolved-import] # copied nix/domains/system/otel-guest/browser_journey.py
    command as probe_command,
)
from playwright.sync_api import (
    ConsoleMessage,
    ElementHandle,
    Error,
    Page,
    Request,
    Response,
    expect,
    sync_playwright,
)


def command(page: Page, title: str) -> None:
    """@cc [owner:ghuntley,label:verification] editor-native-command-registration
    Native commands MUST be discovered through an actual contributed palette
    row before execution. A palette opened before remote extension registration
    MAY refresh its action snapshot within the original 30-second deadline.
    The selected command MUST execute exactly once; execution is never retried.
    """
    deadline = monotonic() + 30
    while True:
        if monotonic() >= deadline:
            raise AssertionError("Native command registration deadline exceeded")
        page.keyboard.press("Control+Shift+p")
        entry = page.locator(".quick-input-widget input")
        expect(entry).to_be_visible(timeout=max(1, int((deadline - monotonic()) * 1000)))
        entry.fill(">" + title, timeout=max(1, int((deadline - monotonic()) * 1000)))
        row = page.locator(".quick-input-widget .monaco-list-row").filter(has_text=title).first
        remaining = max(1, int((deadline - monotonic()) * 1000))
        try:
            expect(row).to_be_visible(timeout=min(1000, remaining))
        except AssertionError:
            if monotonic() >= deadline:
                raise
            page.keyboard.press("Escape")
            expect(page.locator(".quick-input-widget")).not_to_be_visible(
                timeout=max(1, int((deadline - monotonic()) * 1000))
            )
            continue
        if monotonic() >= deadline:
            raise AssertionError("Native command registration deadline exceeded")
        row.click(timeout=max(1, int((deadline - monotonic()) * 1000)))
        expect(page.locator(".quick-input-widget")).not_to_be_visible(
            timeout=max(1, int((deadline - monotonic()) * 1000))
        )
        return


def ai_controls(page: Page) -> None:
    """@cc [owner:ghuntley,label:verification] editor-native-ai-actions-stay-closed
    Each guarded native AI command/resource MUST leave no visible Chat, Debug or
    inline UI immediately after its own success marker, before another editor
    action can hide it. Only closed action/selector names and counts may print.
    """
    for name in (
        "Chat",
        "Editor",
        "Quick",
        "Inline",
        "RestoreChat",
        "RestoreSession",
        "RestoreDebug",
    ):
        print("Editor native AI " + name + " command requested", flush=True)
        command(page, "Overalls Fixture: Native AI " + name)
        notice(page, "Native fixture native-ai-" + name.lower() + " passed")
        for selector in (".interactive-session", ".inline-chat", ".chat-debug-editor"):
            attached = page.locator(selector).count()
            visible = page.locator(selector + ":visible").count()
            print(
                "Editor native AI "
                + name
                + " "
                + selector
                + " attached="
                + str(attached)
                + " visible="
                + str(visible),
                flush=True,
            )
            expect(page.locator(selector + ":visible")).to_have_count(0)


def notice(page: Page, message: str) -> None:
    """@cc [owner:ghuntley,label:verification] editor-fixture-notice-coexists-with-direnv
    A fixture success MUST be found in its own notification; simultaneous direnv
    refusal or unrelated notices MUST NOT create a multiple-element assertion.
    """
    expect(
        page.locator(".notifications-list-container").filter(has_text=message).first
    ).to_contain_text(message, timeout=60000)


def open_file(page: Page, name: str) -> None:
    page.keyboard.press("Control+p")
    entry = page.locator(".quick-input-widget input")
    expect(entry).to_be_visible()
    entry.fill("/home/alice/workspace/" + name)
    expect(
        page.locator(".quick-input-widget .monaco-list-row").filter(has_text=name).first
    ).to_be_visible(timeout=30000)
    page.keyboard.press("Enter")
    expect(page.locator(".quick-input-widget")).not_to_be_visible()
    expect(page.locator(".editor-instance").last).to_be_visible()


def uninstall_fixture(page: Page) -> None:
    """@cc [owner:ghuntley,label:verification] editor-productless-extension-uninstall
    The activated browser-only fixture MUST uninstall through the real Extensions
    UI and disappear from installed results without optional chat configuration.
    """
    command(page, "Extensions: Show Installed Extensions")
    installed = page.locator(".extension-list-item").filter(has_text="Overalls Browser Fixture")
    expect(installed).to_have_count(1, timeout=30000)
    installed.click()
    editor = page.locator(".extension-editor")
    expect(editor).to_contain_text("Overalls Browser Fixture")
    uninstall = editor.get_by_role("button", name="Uninstall", exact=True)
    expect(uninstall).to_be_enabled()
    uninstall.click()
    expect(
        editor.get_by_role(
            "button", name=re.compile(r"^Please reload window to complete the uninstallation")
        )
    ).to_be_visible(timeout=30000)
    command(page, "Extensions: Refresh")
    expect(installed).to_have_count(0, timeout=30000)


def terminal_first_use_regression(page: Page) -> None:
    """@cc [owner:ghuntley,label:verification;security] editor-native-terminal-first-use
    The first terminal action MUST use the copied production create/output/close
    helpers after verifying the trust-disabled bootstrap, before fixture extension activation or
    developer-tool warming. Actions MUST use the production eight-second timeout;
    expectations MUST retain the production five-second default. Creation retains
    the helper's bounded first-profile wait. Actual
    output MUST prove the personal UID, and scoped cleanup MUST detach this input
    before the rest of the journey begins.
    """
    inputs = page.locator(".terminal-editor .xterm-helper-textarea")
    expect(page.locator(".terminal-wrapper")).to_have_count(0)
    with ExitStack() as cleanup:
        page.set_default_timeout(8000)
        cleanup.callback(page.set_default_timeout, 30000)
        probe = create_probe_terminal(page)
        cleanup.callback(probe.dispose)
        cleanup.callback(close_probe_terminal, page, probe)
        expect(inputs).to_have_count(1)
        if (
            probe.evaluate(
                "element => !!element.closest('.terminal-wrapper')"
                "?.querySelector('.xterm-accessibility-tree')"
            )
            is False
        ):
            probe_command(page, "Toggle Screen Reader Accessibility Mode")
        probe.focus()
        probe.type("printf 'uid=%s %s%s\\n' \"$(id -u)\" 'overalls-native-' 'first-use'")
        probe.press("Enter")
        terminal_output_contains(page, probe, "uid=200001 overalls-native-first-use")
        close_probe_terminal(page, probe)
        assert probe.evaluate("element => element.isConnected") is False
        expect(page.locator(".terminal-wrapper")).to_have_count(0)
    print("Browser terminal first-use regression passed", flush=True)


def terminal_custody_regression(page: Page) -> None:
    """@cc [owner:ghuntley,label:verification;security] editor-native-terminal-custody
    The copied production helper MUST create and close only its own terminal
    while two fixture-owned terminal editors remain connected and visible in
    separate groups. Its output assertion MUST read the newly captured terminal.
    Fixture cleanup MUST close only the inputs this function captured.
    """
    previous: list[tuple[ElementHandle, ElementHandle]] = []
    with ExitStack() as cleanup:

        def own_terminal(terminal: ElementHandle | None) -> ElementHandle:
            if terminal is None:
                raise RuntimeError("fixture terminal unavailable")
            cleanup.callback(terminal.dispose)
            cleanup.callback(close_probe_terminal, page, terminal)
            wrapper = terminal.evaluate_handle(
                "element => element.closest('.terminal-wrapper')"
            ).as_element()
            if wrapper is None:
                raise RuntimeError("fixture terminal wrapper unavailable")
            cleanup.callback(wrapper.dispose)
            previous.append((wrapper, terminal))
            return terminal

        inputs = page.locator(".terminal-editor .xterm-helper-textarea")
        command(page, "Terminal: Create New Terminal in Editor Area")
        expect(inputs).to_have_count(1, timeout=30000)
        first = own_terminal(inputs.element_handle())
        command(page, "Terminal: Create New Terminal in Editor Area to the Side")
        expect(inputs).to_have_count(2, timeout=30000)
        own_terminal(
            page.wait_for_function(
                """first => [...document.querySelectorAll(
                    '.terminal-editor .xterm-helper-textarea'
                )].find(input => input !== first) || false""",
                arg=first,
            ).as_element()
        )
        expect(page.locator(".terminal-editor .terminal-wrapper.active")).to_have_count(2)
        for wrapper, terminal in previous:
            assert wrapper.evaluate("element => element.isConnected") is True
            assert terminal.is_visible()

        command(page, "View: New Editor Group to the Right")
        probe = create_probe_terminal(page)
        cleanup.callback(probe.dispose)
        cleanup.callback(close_probe_terminal, page, probe)
        expect(inputs).to_have_count(3)
        assert (
            probe.evaluate(
                "(probe, previous) => previous.every(input => input !== probe)",
                [terminal for _wrapper, terminal in previous],
            )
            is True
        )
        if (
            probe.evaluate(
                "element => !!element.closest('.terminal-wrapper')"
                "?.querySelector('.xterm-accessibility-tree')"
            )
            is False
        ):
            command(page, "Toggle Screen Reader Accessibility Mode")
        probe.focus()
        probe.type("printf '%s%s\\n' 'overalls-native-' 'terminal-custody'")
        probe.press("Enter")
        terminal_output_contains(page, probe, "overalls-native-terminal-custody")
        close_probe_terminal(page, probe)
        assert probe.evaluate("element => element.isConnected") is False
        expect(inputs).to_have_count(2)
        for wrapper, terminal in previous:
            assert wrapper.evaluate("element => element.isConnected") is True
            assert terminal.evaluate("element => element.isConnected") is True
            assert terminal.is_visible()
        expect(page.locator(".terminal-editor .terminal-wrapper.active")).to_have_count(2)
    print("Browser terminal custody regression passed", flush=True)


def redacted_message(message: str) -> str:
    return re.sub(
        r"\b(?:https?|wss?|blob|file|data|about|vscode-remote):[^\s)]+",
        "[fixture URL]",
        message,
    )[:1024]


def resource_path(value: str) -> str:
    """Return only an HTTP path or the unsupported URL scheme's finite name."""
    parsed = urlsplit(value)
    if parsed.scheme in {"http", "https"}:
        return parsed.path[:512]
    return parsed.scheme if parsed.scheme in {"blob", "data", "file", "about"} else "other"


def capture(page: Page, diagnostics: list[dict[str, str | int]]) -> None:
    """@cc [owner:ghuntley,label:verification;security] editor-failure-evidence
    Every journey failure MUST retain a screenshot and bounded diagnostic entries.
    HTTP/CSP evidence MUST omit URL origins, queries and fragments; diagnostic text
    MUST redact complete URLs and MUST remain in the private fixture artifact.
    """
    violations: object = page.evaluate("() => globalThis.fixtureCspViolations ?? []")
    if isinstance(violations, list):
        for violation in violations[:32]:
            if not isinstance(violation, dict):
                continue
            entry: dict[str, str | int] = {"kind": "csp"}
            for key in ("directive", "blocked", "source", "disposition"):
                value = violation.get(key)
                if isinstance(value, str):
                    entry[key] = value[:512]
            diagnostics.append(entry)
    for path, contents in (
        (Path("/tmp/vscode-web-native.png"), page.screenshot(full_page=True)),
        (Path("/tmp/vscode-web-native-diagnostics.json"), json.dumps(diagnostics).encode()),
    ):
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "wb") as artifact:
            artifact.write(contents)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("origin")
    arguments = parser.parse_args()
    origin = arguments.origin
    assert isinstance(origin, str) and origin.startswith("https://")
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            executable_path="/run/current-system/sw/bin/chromium",
            headless=True,
            args=["--no-sandbox", "--disable-dev-shm-usage"],
        )
        context = browser.new_context()
        context.add_init_script("""
            globalThis.fixtureCspViolations = [];
            addEventListener('securitypolicyviolation', (event) => {
                const events = globalThis.fixtureCspViolations;
                if (events.length >= 32) return;
                /** @param {string} value @returns {string} */
                const path = (value) => {
                    try {
                        const url = new URL(value);
                        return ['http:', 'https:'].includes(url.protocol)
                            ? url.pathname.slice(0, 512) : url.protocol;
                    }
                    catch { return ['', 'inline', 'eval', 'self'].includes(value) ? value : 'other'; }
                };
                events.push({
                    directive: event.effectiveDirective,
                    blocked: path(event.blockedURI),
                    source: path(event.sourceFile),
                    disposition: event.disposition,
                });
            });
        """)
        page = context.new_page()
        diagnostics: list[dict[str, str | int]] = []

        def response_received(response: Response) -> None:
            if len(diagnostics) < 64:
                diagnostics.append(
                    {
                        "kind": "response",
                        "status": response.status,
                        "path": resource_path(response.url),
                        "resource": response.request.resource_type,
                    }
                )

        def console(message: ConsoleMessage) -> None:
            if message.type in {"error", "warning"} and len(diagnostics) < 96:
                diagnostics.append(
                    {
                        "kind": "console",
                        "level": message.type,
                        "error": redacted_message(message.text),
                    }
                )

        def page_error(error: Error) -> None:
            if len(diagnostics) < 96:
                diagnostics.append({"kind": "pageerror", "error": redacted_message(error.message)})

        def request_failed(request: Request) -> None:
            if len(diagnostics) < 96:
                diagnostics.append(
                    {
                        "kind": "requestfailed",
                        "path": resource_path(request.url),
                        "error": redacted_message(request.failure or "unknown"),
                    }
                )

        page.on("response", response_received)
        page.on("console", console)
        page.on("pageerror", page_error)
        page.on("requestfailed", request_failed)
        try:
            page.goto(origin + "/?folder=/home/alice/workspace")
            expect(page.locator(".monaco-workbench")).to_be_visible(timeout=60000)
            trust_workspace(page)
            terminal_first_use_regression(page)
            command(page, "Overalls Fixture: Native Policy")
            notice(page, "Native fixture native-policy passed")
            print("Editor native API policy passed", flush=True)
            ai_controls(page)
            command(page, "Overalls Fixture: Run Browser Extension")
            notice(page, "Browser-only extension activated")
            open_file(page, "invalid.json")
            command(page, "View: Toggle Problems")
            expect(page.locator(".markers-panel")).to_be_visible()
            expect(page.locator(".markers-panel")).to_contain_text("Value expected", timeout=30000)
            command(page, "View: Toggle Problems")
            open_file(page, "format.json")
            command(page, "Format Document")
            page.keyboard.press("Control+s")
            page.keyboard.press("Control+Shift+f")
            search = page.get_by_role("textbox", name=re.compile(r"^Search: Type Search Term"))
            expect(search).to_be_visible()
            search.fill("fixture-search-needle")
            page.keyboard.press("Enter")
            expect(page.locator(".search-view")).to_contain_text("README.md", timeout=30000)
            command(page, "Git: Show Git Output")
            expect(page.locator(".output-view")).to_be_visible()
            open_file(page, "README.md")
            command(page, "Markdown: Open Preview to the Side")
            preview = page.locator("iframe.webview").last
            expect(preview).to_be_visible(timeout=30000)
            frame = page.frame_locator("iframe.webview").last.frame_locator("iframe#active-frame")
            expect(frame.locator("body")).to_contain_text("fixture-search-needle", timeout=30000)
            image = frame.locator("img[alt=local-resource]")
            expect(image).to_be_visible()
            expect(image).to_have_js_property("complete", True)
            assert image.evaluate("image => image.naturalWidth > 0") is True
            urls = [candidate.url for candidate in page.frames if "/code-assets/" in candidate.url]
            assert urls and all(
                urlparse(value).hostname != urlparse(origin).hostname for value in urls
            )
            terminal_custody_regression(page)
            command(page, "Terminal: Create New Terminal")
            terminal = page.locator("textarea.xterm-helper-textarea").last
            expect(terminal).to_be_attached(timeout=30000)
            terminal.focus()
            page.keyboard.type("id -u > /home/alice/.editor-terminal-uid\n", delay=10)
            uninstall_fixture(page)
        finally:
            capture(page, diagnostics)
            context.close()
            browser.close()


if __name__ == "__main__":
    main()
