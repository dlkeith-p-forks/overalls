"""Real sessions at one verified HTTPS origin; public fixture coordination only."""

import base64
import contextlib
import json
import os
import re
import shlex
import sys
import time
import traceback
import uuid
from pathlib import Path
from urllib.parse import urlsplit

from playwright.sync_api import Dialog, Page, Response, WebSocket, expect, sync_playwright
from playwright.sync_api import Error as PlaywrightError
from playwright.sync_api import TimeoutError as PlaywrightTimeoutError


class BrowserProbe:
    def __init__(self, users: dict[str, str], vm: str, rendezvous: Path) -> None:
        self.users = users
        self.vm = vm
        self.rendezvous = rendezvous
        self.sequence = 0
        self.stage = "startup"
        self.origin = "https://control.example.test"
        self.path = "/machines/" + vm
        self.navigation = []
        self.attachments = 0
        self.terminal_transport: dict[str, int] = {
            "sent": 0,
            "received": 0,
            "received_binary": 0,
            "closed": 0,
        }
        # Bounded per-socket timings (ms) only: open offset, time to the attached
        # control frame, lifetime and received byte count. No frame contents.
        self.socket_history: list[dict[str, int | None]] = []
        self.started = time.monotonic()
        self.command_marker: bytes | None = None
        self.command_marker_seen = False
        self.command_marker_tail = b""
        self.browser_errors: dict[str, int] = {}

    def page_error(self, error: PlaywrightError) -> None:
        """Classify renderer failures without reporting exception or guest text."""
        message = error.message.lower()
        category = (
            "wasm"
            if "webassembly" in message or "wasm" in message
            else "graphics"
            if "sixel" in message or "image" in message
            else "push_event"
            if "push" in message and "event" in message
            else "null_property"
            if "cannot read properties of null" in message
            or "cannot read properties of undefined" in message
            else "websocket"
            if "websocket" in message
            else "liveview"
            if "liveview" in message or "phx" in message
            else "other"
        )
        self.browser_errors[category] = self.browser_errors.get(category, 0) + 1

    def socket_opened(self, socket: WebSocket) -> None:
        if "/terminals/" in urlsplit(socket.url).path:
            self.attachments += 1
            counters = {"sent": 0, "received": 0, "received_binary": 0, "closed": 0}
            self.terminal_transport = counters
            opened = time.monotonic()
            history: dict[str, int | None] = {
                "opened_ms": int((opened - self.started) * 1000),
                "attached_after_ms": None,
                "lifetime_ms": None,
                "received": 0,
            }
            self.socket_history = [*self.socket_history, history][-8:]

            def sent(payload: str | bytes) -> None:
                counters["sent"] += len(payload)

            def received(payload: str | bytes) -> None:
                counters["received"] += len(payload)
                # Binary frames are terminal output; text frames are control
                # (attach, acknowledgements), so input acks alone stay visible.
                if isinstance(payload, bytes):
                    counters["received_binary"] += len(payload)
                history["received"] = counters["received"]
                if (
                    isinstance(payload, str)
                    and history["attached_after_ms"] is None
                    and '"op":"attached"' in payload
                ):
                    history["attached_after_ms"] = int((time.monotonic() - opened) * 1000)
                if isinstance(payload, bytes) and self.command_marker:
                    data = self.command_marker_tail + payload
                    self.command_marker_seen |= self.command_marker in data
                    self.command_marker_tail = data[-len(self.command_marker) :]

            def closed(_socket: WebSocket | None = None) -> None:
                counters["closed"] = 1
                history["lifetime_ms"] = int((time.monotonic() - opened) * 1000)

            socket.on("framesent", sent)
            socket.on("framereceived", received)
            socket.on("close", closed)

    def navigation_response(self, response: Response) -> None:
        if response.request.is_navigation_request():
            path = urlsplit(response.url).path
            route = (
                "terminal"
                if path.endswith("/terminals")
                else "authentication"
                if path.startswith("/auth/")
                else "magic-link"
                if path.startswith("/magic_link/")
                else "machines"
                if path == "/machines"
                else "other"
            )
            self.navigation = ([*self.navigation, {"route": route, "status": response.status}])[
                -12:
            ]

    def coordinate(self, action: str, node: int | None = None) -> None:
        self.sequence += 1
        self.publish(
            {"phase": "request", "sequence": self.sequence, "action": action, "node": node}
        )
        deadline = time.monotonic() + 90
        while not (self.rendezvous / f"{self.sequence}.done").exists():
            if time.monotonic() >= deadline:
                raise AssertionError("Fixture coordination timed out")
            time.sleep(0.1)

    def publish(self, state: dict[str, object]) -> None:
        temporary = self.rendezvous / "state.tmp"
        temporary.write_text(json.dumps(state))
        temporary.replace(self.rendezvous / "state.json")

    def login(self, tab: Page, token: str) -> None:
        response = tab.goto(self.origin + "/magic_link/" + token)
        assert response is not None and response.status == 200
        # The connected LiveView submits the token automatically.
        expect(tab.locator("[data-phx-main].phx-connected")).to_be_visible(timeout=20000)
        tab.wait_for_url("**/overview")

    def watch(self, tab: Page, *, create: bool = False, writable: bool = False) -> str:
        tab.goto(self.origin + self.path + "/terminals")
        expect(tab.locator("#terminal-client")).to_be_visible(timeout=30000)
        expect(tab.locator("[data-phx-main].phx-connected")).to_be_visible(timeout=30000)
        item = tab.locator("[data-terminal-select]").first
        try:
            if create:
                expect(tab.locator("[data-terminal-select]")).to_have_count(1, timeout=30000)
            expect(item).to_be_visible(timeout=30000)
        except AssertionError:
            self.creation_outcome(tab)
            raise
        session = item.get_attribute("data-terminal-select")
        assert session is not None and str(uuid.UUID(session)) == session
        expected = "live" if writable else "readonly"
        expect(tab.locator("#terminal-status")).to_have_attribute(
            "data-status", expected, timeout=30000
        )
        return session

    def creation_outcome(self, tab: Page) -> None:
        """Report only closed UI categories and counts, never guest text."""
        notice = tab.locator("#terminal-notice")
        text = notice.text_content() if notice.count() else None
        category = {
            "Terminals are unavailable while the host is offline.": "stream_unavailable",
            "The terminal could not be opened.": "open_refused",
            "You do not have terminal access to this machine.": "forbidden",
            "Preparing your terminal…": "pending",
            "Preparing your guest account…": "account_pending",
            "Reconnecting to the terminal service…": "reconnecting",
            "Opening terminal; recovering the same request if the connection was interrupted.": "pending",
            "Waiting for the machine to start…": "machine_waiting",
            "Machine is stopping or stopped. Choose Start to open a terminal.": "machine_stopped",
            "Machine startup failed. Check the machine status and boot log.": "machine_failed",
            "Terminal limit reached for this machine.": "terminal_limit",
            "The guest cannot host more terminal sessions.": "guest_limit",
            "Terminal close requested; waiting for guest confirmation.": "closing",
            "Your guest account could not be prepared. Check that the guest account service is available, then choose New to retry.": "account_refused",
            "Your previous shell has closed. Choose New to open another terminal.": "closed",
            "Terminal access ended.": "access_ended",
        }.get((text or "").strip(), "no_recognized_notice")
        print(
            "Terminal creation outcome:",
            json.dumps(
                {"notice": category, "sessions": tab.locator("[data-terminal-select]").count()}
            ),
            flush=True,
        )

    def command(
        self,
        tab: Page,
        text: str,
        observer: Page | None = None,
        *,
        timeout_ms: int = 30000,
    ) -> None:
        stage = self.stage
        suffix = uuid.uuid4().hex
        marker = "FLEET_" + suffix
        self.command_marker = marker.encode()
        self.command_marker_seen = False
        self.command_marker_tail = b""
        self.stage = stage + ": focus"
        tab.bring_to_front()
        expect(tab.locator("#terminal-status")).to_have_attribute(
            "data-status", "live", timeout=45000
        )
        try:
            tab.locator("#terminal-pane-holder > div:not(.hidden) .xterm-helper-textarea").focus()
        except Exception:
            # Bounded census only: counts and booleans, never terminal content.
            # A census that itself times out points at a stalled renderer.
            try:
                census = tab.evaluate(
                    """() => {
                      const panes = [...document.querySelectorAll('#terminal-pane-holder > div')];
                      const ids = panes.map((pane) => pane.id);
                      return {panes: panes.length,
                        sidebar: document.querySelectorAll('[data-terminal-select]').length,
                        visible: panes.filter((pane) => !pane.classList.contains('hidden')).length,
                        visible_with_input: panes.filter((pane) => !pane.classList.contains('hidden')
                          && pane.querySelector('.xterm-helper-textarea')).length,
                        duplicate_ids: ids.length - new Set(ids).size,
                        document_hidden: document.hidden};
                    }"""
                )
            except Exception:
                census = {"census": "timed_out"}
            print("Terminal pane census:", json.dumps(census), flush=True)
            raise
        counters = self.terminal_transport
        before = dict(counters)
        self.stage = stage + ": type command"
        tab.keyboard.type("(" + text + ") && printf '\\nFLEET_%s\\n' '" + suffix + "'", delay=2)
        self.stage = stage + ": submit command"
        tab.keyboard.press("Enter")
        target = observer or tab
        target.bring_to_front()
        self.stage = stage + ": observe result"
        try:
            expect(
                target.locator("#terminal-pane-holder > div:not(.hidden) .xterm-accessibility-tree")
            ).to_contain_text(marker, timeout=timeout_ms)
        except AssertionError:
            print(
                "Terminal marker presence:",
                json.dumps(
                    {
                        "received_marker": self.command_marker_seen,
                        "owner": self.marker_visible(tab, marker),
                        "observer": self.marker_visible(target, marker),
                        "owner_echo": self.marker_visible(tab, suffix),
                        "observer_echo": self.marker_visible(target, suffix),
                        "body_available": self.dom_available(target, "body"),
                        "workspace_available": self.dom_available(target, "#terminal-client"),
                        "pane_available": self.dom_available(
                            target, "#terminal-pane-holder > div:not(.hidden)"
                        ),
                        "browser_errors": self.browser_errors,
                    }
                ),
                flush=True,
            )
            # Booleans and counts only: why the selected pane has no attachment.
            try:
                pane_state = target.evaluate("""() => {
                  const element = document.getElementById("terminal-client");
                  let result = null;
                  window.liveSocket.owner(element, view => {
                    const w = view.getHook(element);
                    const pane = w && w.panes.get(w.activeId);
                    result = pane ? {
                      live_connected: w.liveConnected,
                      connected: pane.connected,
                      status: pane.status,
                      has_emulator: pane.terminal !== null,
                      pending_writes: pane.pendingWrites,
                      socket_state: pane.socket ? pane.socket.readyState : null,
                      ticket_timer: w.ticketTimers.has(w.activeId),
                      replaying: pane.replaying,
                      live_emulators: [...w.panes.values()].filter(p => p.terminal).length,
                      draining_panes: [...w.panes.values()].filter(p => p.pendingWrites > 0).length,
                      view_connected: view.isConnected()
                    } : {pane: false};
                  });
                  return result;
                }""")
            except Exception:
                pane_state = {"pane_state": "unavailable"}
            print("Selected pane state:", json.dumps(pane_state), flush=True)
            print(
                "Terminal transport counters:",
                json.dumps(
                    {
                        key: counters[key] - before[key]
                        for key in ("sent", "received", "received_binary", "closed")
                    }
                ),
                flush=True,
            )
            raise
        self.command_marker = None
        self.command_marker_tail = b""
        self.assert_active_attachment(tab)
        if target is not tab:
            self.assert_active_attachment(target)
        self.stage = stage

    def assert_active_attachment(self, tab: Page) -> None:
        """@cc [owner:ghuntley,label:verification] fleet-browser-single-active-pane
        After a command's visible completion, the selected pane MUST own an OPEN
        socket and other panes MUST NOT own OPEN or CONNECTING sockets.
        CLOSING/CLOSED sockets MUST NOT be counted as
        live attachments; the observation MUST NOT expose tickets or terminal bytes.
        """
        state: object = tab.evaluate("""() => {
          const element = document.getElementById("terminal-client");
          let result = null;
          window.liveSocket.owner(element, view => {
            const workspace = view.getHook(element);
            let selectedOpen = false;
            let otherActive = 0;
            for (const [id, pane] of workspace.panes) {
              const state = pane.socket?.readyState;
              if (id === workspace.activeId) {
                selectedOpen = pane.connected && state === WebSocket.OPEN;
              } else if (state === WebSocket.OPEN || state === WebSocket.CONNECTING) {
                otherActive++;
              }
            }
            result = {selected_open: selectedOpen, other_active: otherActive};
          });
          return result;
        }""")
        assert isinstance(state, dict)
        fields: dict[str, object] = {}
        for key, value in state.items():
            assert isinstance(key, str)
            fields[key] = value
        assert set(fields) == {"selected_open", "other_active"}
        selected_open = fields["selected_open"]
        other_active = fields["other_active"]
        assert type(selected_open) is bool and type(other_active) is int
        assert selected_open and other_active == 0, "Unexpected settled terminal attachments"

    def marker_visible(self, tab: Page, marker: str) -> bool | None:
        """Bound failure diagnostics and expose only synthetic-marker presence."""
        try:
            text = tab.locator(
                "#terminal-pane-holder > div:not(.hidden) .xterm-accessibility-tree"
            ).text_content(timeout=1000)
            return marker in (text or "")
        except PlaywrightTimeoutError:
            return None

    def dom_available(self, tab: Page, selector: str) -> bool:
        """Distinguish missing terminal DOM from an unresponsive renderer."""
        try:
            tab.locator(selector).get_attribute("id", timeout=1000)
            return True
        except PlaywrightTimeoutError:
            return False

    def share(self, admin: Page, role: str) -> None:
        expect(admin.locator("[data-phx-main].phx-connected")).to_be_visible(timeout=30000)
        key = admin.locator("#access_request_key").input_value()
        admin.locator("#access_email").fill(self.users["member_email"])
        admin.locator("#access_role").select_option(role)
        admin.locator("#share-submit").click()
        expect(admin.locator("#access_request_key")).not_to_have_value(key)
        expect(admin.get_by_text("Access updated.", exact=True)).to_be_visible(timeout=30000)

    def workspace_acceptance(self, page: Page, first_session: str) -> None:
        """Exercise planned UI behavior with real guest effects, never report bytes."""
        self.stage = "terminal search, title, geometry and boot log"
        title = "terminal-acceptance-" + uuid.uuid4().hex
        # The login shell may set its own title when redrawing the prompt.
        # Emit the test title after that redraw, without disabling guest hooks.
        # The guest title belongs on the session's detail line; the label and
        # page title stay the generated (or locally renamed) session name.
        self.stage = "terminal title"
        self.command(page, "(sleep 1; printf '\\033]2;" + title + "\\007' >/dev/tty) &")
        expect(page.locator(f"#terminal-item-{first_session} .terminal-meta")).to_contain_text(
            title
        )
        expect(page).not_to_have_title(title + " · Terminals")
        self.stage = "terminal search"
        self.command(page, "printf 'SEARCH_%s\\n' NATIVE_ACCEPTANCE")
        page.keyboard.press("Control+f")
        search = page.locator("#terminal-search-query")
        expect(search).to_be_visible()
        search.fill("SEARCH_NATIVE_ACCEPTANCE")
        expect(page.locator("#terminal-search-result")).to_have_text("Match found")
        search.press("Escape")
        expect(search).not_to_be_visible()
        self.accessible_selection(page)
        page.set_viewport_size({"width": 1100, "height": 900})
        self.stage = "terminal initial geometry"
        self.command(page, "stty size > /tmp/terminal-size-first")
        page.set_viewport_size({"width": 1500, "height": 1000})
        # Resize is asynchronous. Retry the guest-observed geometry, not a UI flag.
        self.stage = "terminal resized geometry"
        self.command(
            page,
            'for i in $(seq 1 50); do test "$(stty size)" != "$(cat /tmp/terminal-size-first)" && break; sleep .1; done; test "$(stty size)" != "$(cat /tmp/terminal-size-first)"',
        )
        self.stage = "terminal boot log"
        page.locator("#terminal-boot-log").click()
        boot = page.locator("#terminal-boot-xterm")
        expect(boot.locator(".xterm")).to_be_visible(timeout=30000)
        # The accessibility tree holds only the viewport. The bounded boot
        # report (ADR-0154) follows the boot-complete line, so its fixed final
        # marker is what an autoscrolled pane shows of the retained console.
        expect(boot.locator(".xterm-accessibility-tree")).to_contain_text(
            "lilly-boot-report: end", timeout=30000
        )
        expect(boot.locator(".xterm-accessibility-tree")).not_to_contain_text("login:")
        expect(boot.locator(".xterm-accessibility-tree")).not_to_contain_text("[0;32m")
        page.locator("#terminal-boot-autoscroll").uncheck()
        page.locator(f"[data-terminal-select='{first_session}']").click()

        self.stage = "OSC52 consent and explicit clipboard policy"
        page.context.grant_permissions(["clipboard-read", "clipboard-write"])
        page.bring_to_front()
        page.evaluate("navigator.clipboard.writeText('unchanged')")

        # Handle browser dialogs without logging their text (guest controlled).
        def refuse(dialog: Dialog) -> None:
            dialog.dismiss()

        def allow(dialog: Dialog) -> None:
            dialog.accept("once")

        page.on("dialog", refuse)
        self.command(page, "printf '\\033]52;c;cmVwbGFjZWQ=\\007'")
        assert page.evaluate("navigator.clipboard.readText()") == "unchanged"
        page.remove_listener("dialog", refuse)
        page.on("dialog", allow)
        self.command(page, "printf '\\033]52;c;cmVwbGFjZWQ=\\007'")
        assert page.evaluate("navigator.clipboard.readText()") == "replaced"
        page.remove_listener("dialog", allow)

        self.stage = "fifty independent persistent browser terminals"
        for count in range(2, 51):
            page.locator("#terminal-create").click()
            try:
                expect(page.locator("[data-terminal-select]")).to_have_count(count, timeout=30000)
            except AssertionError:
                self.creation_outcome(page)
                raise
            expect(page.locator("#terminal-status")).to_have_attribute(
                "data-status", "live", timeout=30000
            )
        self.command(
            page,
            "printf '%s' fiftieth > /tmp/terminal-fifty; test \"$(cat /tmp/terminal-fifty)\" = fiftieth",
        )

        # The graphics stress runs in the fiftieth terminal so that the first
        # session, reused by the sharing, Marshall-loss and revocation stages,
        # does not carry ten thousand sixel images into every later replay.
        self.stage = "binary sequence and sixel replay through browser backpressure"
        # Ten thousand 31-byte images exceed the 256 KiB transport window while
        # all PTYs remain alive. Browser xterm alone parses these guest bytes.
        script = (
            "for i in $(seq 1 10000); do printf '\\033Pq\"1;1;64;64#1;2;100;0;0!64~\\033\\\\'; done"
        )
        encoded = base64.b64encode(script.encode()).decode()
        # Software rendering thousands of images in nested Chromium needs a
        # separate bounded deadline. Completion still requires the final guest
        # marker, followed by replay/reconnect and retained-shell assertions.
        self.command(page, "printf '%s' '" + encoded + "' | base64 -d | bash", timeout_ms=120000)
        # Terminal sockets outlive LiveView disconnects, so drop the active
        # pane's own socket to force a ticketed reconnect and scrollback replay.
        self.stage = "graphics replay: drop terminal socket"
        page.locator("#terminal-client").evaluate(
            """element => {
              window.liveSocket.owner(element, view => {
                const workspace = view.getHook(element);
                workspace.panes.get(workspace.activeId)?.socket?.close();
              });
            }"""
        )
        expect(page.locator("#terminal-status")).to_have_attribute("data-status", "reconnecting")
        self.stage = "graphics replay: reconnect terminal"
        expect(page.locator("#terminal-status")).to_have_attribute(
            "data-status", "live", timeout=45000
        )
        self.stage = "graphics replay: verify retained shell"
        self.command(page, 'test "$(cat /tmp/terminal-fifty)" = fiftieth')
        self.accessible_selection(page)
        self.stage = "first terminal after graphics"
        page.locator(f"[data-terminal-select='{first_session}']").click()
        self.command(page, 'test "$(cat /tmp/terminal-fifty)" = fiftieth')

    def accessible_selection(self, page: Page) -> None:
        """@cc [owner:ghuntley,label:verification] fleet-accessible-terminal-selection
        Native output with wide and combining characters MUST appear as an
        accessible list item and selecting that DOM text MUST select the same
        terminal text, before graphics and after replay. Report only success.
        """
        self.stage = "terminal accessible mixed-width selection"
        text = "ASCII 界é"
        self.command(page, r"printf '\101\123\103\111\111\040\347\225\214\145\314\201\n'")
        row = (
            page.locator("#terminal-pane-holder > div:not(.hidden)")
            .get_by_role("listitem")
            .filter(has_text=re.compile("^" + re.escape(text) + "$"))
            .last
        )
        expect(row).to_have_text(text, timeout=10000)
        selected: object = row.evaluate("""row => {
          if (!(row instanceof HTMLElement) || !(row.firstChild instanceof Text)) return false;
          const selection = document.getSelection();
          if (!selection) return false;
          selection.setBaseAndExtent(row.firstChild, 0, row.firstChild, row.textContent.length);
          return true;
        }""")
        assert selected is True
        page.wait_for_function(
            """expected => {
              const element = document.getElementById("terminal-client");
              let matched = false;
              window.liveSocket.owner(element, view => {
                const workspace = view.getHook(element);
                matched = workspace.panes.get(workspace.activeId)?.terminal.getSelection() === expected;
              });
              return matched;
            }""",
            arg=text,
            timeout=10000,
        )
        page.evaluate("document.getSelection()?.removeAllRanges()")

    def recovery_state(self, page: Page) -> None:
        """Report only closed status enums, booleans and bounded transport counters."""
        dom_status = None
        with contextlib.suppress(Exception):
            dom_status = page.locator("#terminal-status").get_attribute("data-status", timeout=1000)
        try:
            state: object = page.locator("#terminal-client").evaluate(
                """element => {
              let result = null;
              window.liveSocket.owner(element, view => {
                const workspace = view.getHook(element);
                const pane = workspace.panes.get(workspace.activeId);
                const statuses = ["connecting", "reconnecting", "restoring", "live", "readonly", "input-paused"];
                const status = document.getElementById("terminal-status")?.dataset.status;
                result = {
                  status: statuses.includes(status) ? status : "other",
                  mode: ["rw", "ro"].includes(pane?.mode) ? pane.mode : "other",
                  live_connected: workspace.liveConnected === true,
                  selected_exists: pane !== undefined,
                  connected: pane?.connected === true,
                  replaying: pane?.replaying === true,
                  socket: pane?.socket?.readyState ?? -1,
                  replay_remaining: pane?.replayRemaining ?? 0,
                  replay_to_parse: pane?.replayToParse ?? 0,
                  pending_writes: pane?.pendingWrites ?? 0
                };
              });
              return result;
            }""",
                timeout=1000,
            )
            assert isinstance(state, dict)
            if isinstance(state, dict) and not state:
                state = {}
            allowed: dict[str, object] = {}
            if isinstance(dom_status, str):
                allowed["dom_status"] = (
                    dom_status
                    if dom_status
                    in {
                        "connecting",
                        "reconnecting",
                        "restoring",
                        "live",
                        "readonly",
                        "input-paused",
                    }
                    else "other"
                )
            for key, value in state.items():
                assert isinstance(key, str)
                if key == "status":
                    assert value in {
                        "connecting",
                        "reconnecting",
                        "restoring",
                        "live",
                        "readonly",
                        "input-paused",
                        "other",
                    }
                elif key == "mode":
                    assert value in {"rw", "ro", "other"}
                elif key in {"live_connected", "selected_exists", "connected", "replaying"}:
                    assert type(value) is bool
                elif key == "socket":
                    assert type(value) is int and -1 <= value <= 3
                elif key in {"replay_remaining", "replay_to_parse", "pending_writes"}:
                    assert type(value) is int and 0 <= value <= 8_388_608
                else:
                    raise AssertionError("Unexpected recovery diagnostic field")
                allowed[key] = value
            print("Terminal recovery state:", json.dumps(allowed), flush=True)
        except Exception:
            allowed: dict[str, object] = {}
            if isinstance(dom_status, str):
                known = {
                    "connecting",
                    "reconnecting",
                    "restoring",
                    "live",
                    "readonly",
                    "input-paused",
                }
                allowed["dom_status"] = dom_status if dom_status in known else "other"
            if allowed:
                print("Terminal recovery state (dom-only):", json.dumps(allowed), flush=True)
            else:
                print("Terminal recovery state unavailable; private data withheld", flush=True)
        self.page_shape(page)

    def page_shape(self, page: Page) -> None:
        """Report the page's route class and element counts only."""
        path = urlsplit(page.url).path
        route = (
            "terminal"
            if path.endswith("/terminals")
            else "machines"
            if path == "/machines"
            else "sign-in"
            if path.startswith("/sign-in")
            else "other"
        )
        counts = {
            name: page.locator(selector).count()
            for name, selector in (
                ("workspace", "#terminal-workspace"),
                ("status", "#terminal-status"),
                ("sessions", "[data-terminal-select]"),
                ("error_page", "main.error-page"),
            )
        }
        print("Terminal page shape:", json.dumps({"route": route, **counts}), flush=True)
        print("Terminal socket history:", json.dumps(self.socket_history), flush=True)
        self.creation_outcome(page)

    def assert_starship(self, page: Page) -> None:
        """@cc [owner:ghuntley,label:verification] browser-personal-starship-startup
        A real personal browser PTY MUST execute Bash with Starship's active
        prompt hook, including nested login/non-login shells. Noninteractive Bash
        MUST preserve exact stdout. Guest output MUST remain private.
        """
        self.stage = "personal terminal Bash and Starship startup"
        hook = (
            'test -n "$BASH_VERSION" && test "$STARSHIP_SHELL" = bash && '
            "command -v starship >/dev/null && declare -F starship_precmd >/dev/null && "
            "[[ ${PROMPT_COMMAND[*]} == *starship_precmd* ]] && "
            'test "$(readlink /proc/$$/exe)" = "$(readlink -f "$(command -v bash)")" && '
            'test "$(readlink -f "$(getent passwd "$(id -un)" | cut -d: -f7)")" = '
            '"$(readlink -f "$(command -v bash)")"'
        )
        self.command(page, hook + " && shopt -q login_shell")
        self.command(page, shlex.join(["bash", "-ic", hook + " && ! shopt -q login_shell"]))
        self.command(page, shlex.join(["bash", "-lic", hook + " && shopt -q login_shell"]))
        for flag in ("-c", "-lc"):
            self.command(
                page,
                'test "$('
                + shlex.join(["bash", flag, "printf prompt-clean"])
                + "; printf '!')\" = 'prompt-clean!'",
            )

    # @cc [owner:ghuntley,label:verification;security] fleet-browser-real-authority
    # Sessions MUST use one origin with certificate verification enabled and
    # distinct user contexts. Actual terminal effects, view-only sharing and
    # revocations MUST pass through the production UI/domain, with no fabricated
    # WebSocket replies. Traces, screenshots and terminal/token diagnostics are forbidden.
    def run(self, *, prompt_only: bool = False) -> None:
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(
                executable_path="/run/current-system/sw/bin/chromium",
                headless=True,
                args=["--no-sandbox"],
            )
            try:
                owner, member, stranger = [browser.new_context() for _ in range(3)]
                page, viewer, outsider = owner.new_page(), member.new_page(), stranger.new_page()
                page.on("websocket", self.socket_opened)
                for tab in (page, viewer, outsider):
                    tab.on("pageerror", self.page_error)
                    tab.on("response", self.navigation_response)
                self.stage = "owner login on m1"
                self.coordinate("pin", 1)
                self.login(page, self.users["owner_token"])
                self.stage = "owner terminal creation on m1"
                session = self.watch(page, create=True, writable=True)
                self.stage = "personal terminal identity and home"
                self.command(
                    page,
                    'test "$(id -un)" != root && test "$HOME" = "/home/$(id -un)" && test "$PWD" = "$HOME" && id -u > /tmp/terminal-personal-uid && pwd > /tmp/terminal-personal-home',
                )
                self.assert_starship(page)
                if prompt_only:
                    self.stage = "retire prompt evaluation terminal"
                    page.once("dialog", lambda dialog: dialog.accept())
                    page.locator(f"[data-terminal-kill='{session}']").click()
                    expect(page.locator("[data-terminal-select]")).to_have_count(0, timeout=30000)
                    assert not self.browser_errors
                    self.coordinate("pin")
                    return
                self.stage = "personal terminal passwordless sudo"
                self.command(page, "sudo -n true")
                self.stage = "remove personal account with sync stopped"
                self.command(
                    page,
                    'sudo -n sh -c \'systemctl stop overalls-ssh-sync.timer overalls-ssh-sync.service && date +%s > /run/terminal-diagnostics-since && userdel -f "$SUDO_USER" && ! getent passwd "$SUDO_USER"\'',
                )
                self.stage = "missing personal account is provisioned before PTY"
                page.locator("#terminal-create").click()
                try:
                    expect(page.locator("[data-terminal-select]")).to_have_count(2, timeout=30000)
                except AssertionError:
                    self.creation_outcome(page)
                    print(
                        "Original terminal retained:",
                        page.locator(f"[data-terminal-select='{session}']").count() == 1,
                        flush=True,
                    )
                    raise
                self.command(
                    page,
                    'test "$(id -u)" = "$(cat /tmp/terminal-personal-uid)" && test "$PWD" = "$(cat /tmp/terminal-personal-home)" && test "$HOME" = "$PWD" && sudo systemctl start overalls-ssh-sync.timer',
                )
                replacement = page.locator(
                    f"[data-terminal-select]:not([data-terminal-select='{session}'])"
                ).get_attribute("data-terminal-select")
                assert replacement is not None
                page.once("dialog", lambda dialog: dialog.accept())
                page.locator(f"[data-terminal-kill='{session}']").click()
                expect(page.locator("[data-terminal-select]")).to_have_count(1, timeout=30000)
                session = replacement
                self.workspace_acceptance(page, session)
                self.stage = "owner sharing on m3"
                self.coordinate("pin", 3)
                admin = owner.new_page()
                admin.goto(self.origin + self.path + "/access")
                expect(admin.locator("#share-submit")).to_be_visible()
                self.share(admin, "viewer")
                page.locator(f"[data-terminal-share='{session}']").click()
                page.locator("#terminal-share-email").fill(self.users["member_email"])
                page.locator("[data-terminal-tool='share-submit']").click()
                try:
                    expect(page.locator("#terminal-share-result")).to_have_text(
                        "Viewing access updated.", timeout=30000
                    )
                except AssertionError:
                    outcome = page.locator("#terminal-share-result").text_content()
                    category = {
                        "Updating viewing access…": "pending",
                        "Could not update access. Check the account's machine access.": "denied",
                        "": "not_dispatched",
                    }.get(outcome or "", "unknown")
                    print("Terminal sharing outcome:", category, flush=True)
                    raise
                try:
                    page.locator("[data-terminal-tool='share-close']").click()
                except Exception:
                    print(
                        "Terminal dialog state:",
                        page.evaluate("""() => {
                      const dialog = document.getElementById('terminal-share-dialog');
                      const button = dialog.querySelector('[data-terminal-tool="share-close"]');
                      const box = button.getBoundingClientRect();
                      const top = document.elementFromPoint(box.x + box.width / 2, box.y + box.height / 2);
                      const modal = document.querySelectorAll('dialog[open]').length;
                      return {open: dialog.open, visible: box.width > 0 && box.height > 0,
                        onscreen: box.y >= 0 && box.bottom <= innerHeight,
                        receives: top === button || button.contains(top),
                        top_tag: top ? top.tagName : null,
                        top_in_dialog: top ? dialog.contains(top) : null,
                        top_is_dialog: top === dialog,
                        open_dialogs: modal,
                        fullscreen: document.fullscreenElement !== null,
                        dialog_scroll: [dialog.scrollTop, dialog.scrollHeight, dialog.clientHeight],
                        button_box: [Math.round(box.y), Math.round(box.bottom), innerHeight]};
                    }"""),
                        flush=True,
                    )
                    raise
                self.stage = "member login on m2"
                self.coordinate("pin", 2)
                self.login(viewer, self.users["member_token"])
                assert self.watch(viewer) == session
                self.stage = "unshared user denial"
                self.login(outsider, self.users["stranger_token"])
                outsider.goto(self.origin + self.path + "/terminals")
                outsider.wait_for_url("**/machines")
                expect(outsider.locator("#terminal-client")).to_have_count(0)
                self.stage = "real guest console"
                # A newline prompts an already-booted shell even if boot output
                # predates the terminal's bounded retained output window.
                page.locator(
                    "#terminal-pane-holder > div:not(.hidden) .xterm-helper-textarea"
                ).focus()
                page.keyboard.press("Enter")
                self.command(
                    page,
                    'test "$(id -un)" != root && test "$HOME" = "/home/$(id -un)" && test "$PWD" = "$HOME"',
                )
                path = "fleet-browser-" + uuid.uuid4().hex
                self.command(page, "printf 'owner\\n' >" + path, observer=viewer)
                self.stage = "Marshall loss with connected terminal"
                attachments = self.attachments
                self.coordinate("crash", 1)
                deadline = time.monotonic() + 45
                while self.attachments <= attachments:
                    assert time.monotonic() < deadline, "No replacement terminal socket"
                    page.wait_for_timeout(100)
                try:
                    expect(page.locator("#terminal-status")).to_have_attribute(
                        "data-status", "live", timeout=45000
                    )
                except AssertionError:
                    self.recovery_state(page)
                    raise
                expect(page.locator(f"[data-terminal-select='{session}']")).to_be_visible()
                active = page.locator("#terminal-pane-holder > div:not(.hidden)").get_attribute(
                    "id", timeout=5000
                )
                print("Active pane is the shared session:", active == "terminal-pane-" + session)
                self.command(page, 'test "$(wc -l <' + path + ')" = 1')
                self.coordinate("restore", 1)
                self.stage = "operator sharing remains view-only"
                self.share(admin, "operator")
                assert self.watch(viewer) == session
                viewer.locator(".xterm-helper-textarea").focus()
                viewer.keyboard.type("printf 'member\\n' >>" + path, delay=2)
                viewer.keyboard.press("Enter")
                self.command(page, 'test "$(wc -l <' + path + ')" = 1')
                self.stage = "grant revocation of a connected viewer"
                self.share(admin, "revoked")
                viewer.wait_for_url("**/machines", timeout=20000)
                self.command(page, 'test "$(wc -l <' + path + ')" = 1 && rm -f ' + path)
                self.stage = "login revocation across pages"
                admin.goto(self.origin + "/sign-out")
                admin.locator("form[action='/sign-out'] button[type=submit]").click()
                page.wait_for_url("**/sign-in", timeout=20000)
                assert not self.browser_errors
                self.coordinate("pin")
            finally:
                browser.close()


def main() -> int:
    os.umask(0o077)
    arguments = sys.argv[1:]
    assert len(arguments) == 3 or (len(arguments) == 4 and arguments[-1] == "--prompt-only")
    users_file, vm, rendezvous = arguments[:3]
    prompt_only = len(arguments) == 4
    assert str(uuid.UUID(vm)) == vm
    probe = BrowserProbe(json.loads(Path(users_file).read_text()), vm, Path(rendezvous))
    result = False
    failure: dict[str, object] = {}
    try:
        probe.run(prompt_only=prompt_only)
        result = True
        print(
            "Verified HTTPS personal terminal Bash and Starship startup passed"
            if prompt_only
            else "Verified HTTPS browser sharing, terminal effects and revocation passed",
            flush=True,
        )
    except BaseException as error:
        # Failure details use allowlisted, bounded fields only: the fixed stage
        # name, the exception class name, the pageerror category counters and the
        # navigation route/status history. No guest bytes, tokens or ticket data.
        failure = {
            "failure_stage": probe.stage,
            "failure_error": type(error).__name__,
            "browser_errors": probe.browser_errors,
            "navigation_tail": probe.navigation[-8:],
        }
        print(
            "Browser probe failed at "
            + probe.stage
            + " ("
            + type(error).__name__
            + "); private data withheld; bounded diagnostics in state.json",
            flush=True,
        )
        print("Navigation responses:", json.dumps(probe.navigation), flush=True)
        for frame in traceback.extract_tb(error.__traceback__):
            if Path(frame.filename).resolve() == Path(__file__).resolve():
                print("Fixture location: " + frame.name + ":" + str(frame.lineno), flush=True)
    finally:
        probe.publish({"phase": "finished", "passed": result} | failure)
    return 0 if result else 1


if __name__ == "__main__":
    sys.exit(main())
