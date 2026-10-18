"""Exercise the Monospace Web presentation against its disposable local fixture."""

import json
import os
import re
import sys
import traceback
from pathlib import Path
from typing import Literal, TypedDict
from urllib.parse import urlsplit

from playwright.sync_api import (
    Browser,
    BrowserContext,
    Page,
    Request,
    expect,
    sync_playwright,
)
from playwright.sync_api import (
    TimeoutError as PlaywrightTimeoutError,
)


class Context(TypedDict):
    origin: str
    vm_id: str
    owner: str
    admin: str
    empty: str
    viewer: str
    operator: str
    manager: str
    owner_email: str
    viewer_email: str
    operator_email: str
    manager_email: str
    ready_thread_id: str
    archived_thread_id: str
    pending_thread_id: str
    provisioning_thread_id: str
    failed_thread_id: str


class OffGrid(TypedDict):
    selector: str
    offset: float


def read_context(path: Path) -> Context:
    """Validate the external fixture data before using browser destinations."""
    data: object = json.loads(path.read_text())
    if not isinstance(data, dict):
        raise ValueError("Invalid fixture context")

    def field(key: str) -> str:
        value: object = data.get(key)
        if not isinstance(value, str) or not value:
            raise ValueError("Invalid fixture context field")
        return value

    origin = field("origin")
    if (
        not origin.startswith("http://localhost:")
        or not origin.removeprefix("http://localhost:").isdigit()
    ):
        raise ValueError("Fixture must use localhost")
    return Context(
        origin=origin,
        vm_id=field("vm_id"),
        owner=field("owner"),
        admin=field("admin"),
        empty=field("empty"),
        viewer=field("viewer"),
        operator=field("operator"),
        manager=field("manager"),
        owner_email=field("owner_email"),
        viewer_email=field("viewer_email"),
        operator_email=field("operator_email"),
        manager_email=field("manager_email"),
        ready_thread_id=field("ready_thread_id"),
        archived_thread_id=field("archived_thread_id"),
        pending_thread_id=field("pending_thread_id"),
        provisioning_thread_id=field("provisioning_thread_id"),
        failed_thread_id=field("failed_thread_id"),
    )


class ExternalRequests:
    """@cc [owner:ghuntley,label:security;product] presentation-no-external-resources
    Every stylesheet, script, font and image MUST load from the application origin.
    A request to any other host fails the probe regardless of its outcome; this
    recorder keeps every cross-origin request URL for the final assertion.
    """

    def __init__(self, origin: str) -> None:
        self.host = urlsplit(origin).netloc
        self.urls: list[str] = []

    def observe(self, request: Request) -> None:
        if urlsplit(request.url).netloc != self.host:
            self.urls.append(request.url)


def sign_in(
    browser: Browser,
    fixture: Context,
    role: Literal["owner", "admin", "empty", "viewer", "operator", "manager"],
    watch: ExternalRequests,
) -> BrowserContext:
    context = browser.new_context(
        viewport={"width": 1440, "height": 1000},
        # Keep touch input available for the phone-width composer probe while
        # retaining the same authenticated context for desktop checks.
        has_touch=True,
    )
    context.on("request", watch.observe)
    page = context.new_page()
    login = fixture[role]
    page.goto(fixture["origin"] + login)
    # The magic-link page submits itself once connected; the button is the
    # JavaScript-free fallback and must not race that navigation.
    try:
        page.wait_for_url("**/overview", timeout=10_000)
    except PlaywrightTimeoutError:
        page.locator("form button[type=submit]").click(no_wait_after=True)
        page.wait_for_url("**/overview")
    expect(page.locator("#overview")).to_be_visible()
    check_browser_extension_presence(page)
    return context


def check_browser_extension_presence(page: Page) -> None:
    """@cc [owner:ghuntley,label:product;verification] browser-extension-setup-discovery
    Setup entry points MUST remain visible without the local extension marker
    and MUST be hidden after the marker is added. Removing the marker MUST make
    the entry points visible again; this presentation signal grants no access.
    """
    setup = page.locator("[data-overalls-extension-setup]")
    expect(setup).to_have_count(2)
    expect(setup.nth(0)).to_be_visible()
    expect(setup.nth(1)).to_be_visible()
    page.evaluate(
        "document.documentElement.setAttribute('data-overalls-browser-extension', 'installed')"
    )
    expect(setup.nth(0)).not_to_be_visible()
    expect(setup.nth(1)).not_to_be_visible()
    page.evaluate("document.documentElement.removeAttribute('data-overalls-browser-extension')")
    expect(setup.nth(0)).to_be_visible()
    expect(setup.nth(1)).to_be_visible()


def visit(page: Page, origin: str, route: str) -> None:
    page.goto(origin + route)
    expect(page.locator("#main-content")).to_be_visible()
    page.locator("[data-phx-main]").wait_for(state="attached")
    page.wait_for_function(
        "document.querySelector('[data-phx-main]')?.classList.contains('phx-connected')"
    )
    page.evaluate("document.fonts.ready")


def check_overflow(page: Page) -> None:
    assert page.evaluate("document.documentElement.scrollWidth <= window.innerWidth + 1"), (
        "Page overflows the viewport"
    )


def check_font(page: Page) -> None:
    assert page.evaluate("document.fonts.check('16px \"JetBrains Mono\"')"), (
        "JetBrains Mono is not available from the application origin"
    )


def check_machine_tabs(page: Page) -> None:
    """Wrapped machine tabs must remain within their navigation box."""
    tabs = page.locator("nav[aria-label='Machine workspace']")
    bounds = tabs.bounding_box()
    assert bounds is not None, "Machine navigation is missing"
    for link in tabs.locator("a, button").all():
        item = link.bounding_box()
        assert item is not None, "Machine navigation control is hidden"
        assert bounds["y"] - 0.1 <= item["y"], "Machine tab begins outside its navigation"
        assert item["y"] + item["height"] <= bounds["y"] + bounds["height"] + 0.1, (
            "Wrapped machine tab escapes its navigation"
        )


def check_machine_header(page: Page) -> None:
    """The heading box shows name, state and operating system, then facts and the ID with Copy."""
    heading = page.locator("#machine-workspace-header .machine-heading")
    expect(heading).to_be_visible()
    expect(heading.locator("h1")).to_be_visible()
    expect(page.locator("#machine-state")).to_be_visible()
    expect(page.locator("#machine-os")).to_be_visible()
    os_name = page.locator("#machine-os").text_content()
    assert os_name is not None and os_name.strip() not in ("", "nil"), "Operating system is blank"
    expect(page.locator("#machine-id")).to_be_visible()
    expect(page.locator("[data-copy-command='machine-id']")).to_be_visible()
    bounds = heading.bounding_box()
    assert bounds is not None, "Machine heading is missing"
    for selector in ("h1", "#machine-state", "#machine-os", "#machine-id", "#lifecycle-actions"):
        if selector == "#lifecycle-actions" and heading.locator(selector).count() == 0:
            continue  # power actions render only for managers
        item = heading.locator(selector).first.bounding_box()
        assert item is not None, f"{selector} is hidden in the machine heading"
        assert bounds["y"] - 0.1 <= item["y"], f"{selector} begins above the heading box"
        assert item["y"] + item["height"] <= bounds["y"] + bounds["height"] + 0.1, (
            f"{selector} escapes the heading box"
        )
        assert item["x"] + item["width"] <= bounds["x"] + bounds["width"] + 0.1, (
            f"{selector} overflows the heading box"
        )
    title = heading.locator("h1").bounding_box()
    state = page.locator("#machine-state").bounding_box()
    assert title is not None and state is not None
    assert abs(title["y"] - state["y"]) < 0.1 or state["y"] > title["y"], (
        "State label sits above the machine name"
    )


def check_grid(page: Page, route: str) -> None:
    """Every laid-out element starts on a half-line boundary (renderer DOM excluded)."""
    result: object = page.evaluate("window.overallsGrid.check()")
    if not isinstance(result, list):
        raise ValueError("Grid check must return a list")
    offenders: list[OffGrid] = []
    for item in result:
        if not isinstance(item, dict):
            raise ValueError("Grid check entries must be objects")
        selector: object = item.get("selector")
        offset: object = item.get("offset")
        if not isinstance(selector, str) or not isinstance(offset, (int, float)):
            raise ValueError("Grid check entry fields are invalid")
        offenders.append(OffGrid(selector=selector, offset=float(offset)))
    assert offenders == [], f"Off-grid elements on {route}: {offenders[:8]}"


def screenshot(page: Page, artifacts: Path, name: str) -> None:
    page.screenshot(path=str(artifacts / f"{name}.png"), full_page=True)


def check_thread_order(page: Page, *, composer: bool) -> None:
    """@cc [owner:ghuntley,label:product;verification] thread-browser-reading-order
    The ready-thread composer MUST precede the transcript in DOM and visual order.
    Every synthetic transcript event MUST appear newest first in both orders,
    including tool events between assistant messages, with the initial prompt last.
    """
    kinds = (
        "turn_finished",
        "assistant",
        "tool_result",
        "tool_queued",
        "tool_result",
        "tool_queued",
        "assistant",
        "turn_started",
        "prompt",
    )
    articles = page.locator("#thread-transcript article")
    expect(articles).to_have_count(len(kinds))
    previous_bottom: float | None = None
    for index, kind in enumerate(kinds):
        article = articles.nth(index)
        expect(article).to_have_attribute("data-kind", kind)
        bounds = article.bounding_box()
        assert bounds is not None
        if previous_bottom is not None:
            assert previous_bottom <= bounds["y"], "Transcript visual order differs from DOM order"
        previous_bottom = bounds["y"] + bounds["height"]

    if composer:
        form = page.locator("#thread-prompt-form")
        before: object = form.evaluate(
            "node => Boolean(node.compareDocumentPosition("
            "document.querySelector('#thread-transcript')) & Node.DOCUMENT_POSITION_FOLLOWING)"
        )
        assert before is True, "Composer must precede the transcript in DOM order"
        form_bounds = form.bounding_box()
        transcript_bounds = page.locator("#thread-transcript").bounding_box()
        assert form_bounds is not None and transcript_bounds is not None
        assert form_bounds["y"] + form_bounds["height"] <= transcript_bounds["y"], (
            "Composer must appear above the transcript"
        )


def check_thread_share_details(page: Page, fixture: Context) -> None:
    """The manager disclosure shows the immutable owner and current named roles."""
    toggle = page.locator("#thread-share-toggle")
    expect(toggle).to_be_visible()
    if toggle.get_attribute("aria-expanded") != "true":
        toggle.click()
    expect(page.locator("#thread-sharing")).to_be_visible()
    expect(page.locator("#thread-access-form")).to_be_visible()
    expect(page.locator("#thread-grant-owner")).to_contain_text(fixture["owner_email"])
    expect(page.locator("#thread-grant-owner button")).to_have_count(0)
    grants = page.locator("#thread-grant-items > div")
    expect(grants).to_have_count(3)
    for email, role in (
        (fixture["viewer_email"], "viewer"),
        (fixture["operator_email"], "operator"),
        (fixture["manager_email"], "manager"),
    ):
        grant = grants.filter(has_text=email)
        expect(grant).to_have_count(1)
        expect(grant.locator("[data-role]")).to_have_attribute("data-role", role)


def check_thread_composer_controls(page: Page, *, mobile: bool) -> None:
    """@cc [owner:ghuntley,label:product;verification] thread-browser-composer-controls
    The ready-thread composer MUST open the command palette when a slash is
    typed at the command position. Palette search MUST autocomplete commands,
    Arrow keys MUST move the active option, and Tab MUST insert the selected
    command into the draft without submitting a prompt. LiveView validation
    patches MUST leave the palette open and keep the current search query.
    Escape MUST close the palette without losing the draft and restore focus to
    the invoking control; IME composition MUST defer palette opening until
    composition ends.
    The same controls MUST be reachable through a mobile tap. Browser actions
    MUST not submit a prompt or invoke a machine operation.
    """
    composer = page.locator("#thread-prompt-form textarea[data-thread-input]")
    commands = page.locator("#thread-prompt-form [data-thread-commands-open]")
    palette = page.locator("#thread-command-palette")
    search = page.locator("#thread-command-search")

    expect(composer).to_have_count(1)
    expect(commands).to_have_count(1)
    expect(composer).to_have_attribute("aria-controls", "thread-command-options")
    expect(search).to_have_attribute("role", "combobox")

    # A slash at byte zero opens the palette; its search receives the command
    # prefix while the draft remains in the composer. Tab only inserts the
    # command and leaves the draft for the user to submit explicitly.
    composer.fill("/")
    expect(palette).to_be_visible()
    expect(search).to_be_focused()
    expect(composer).to_have_attribute("aria-expanded", "true")
    expect(page.locator("#thread-command-plan")).to_be_visible()
    page.keyboard.type("pl")
    expect(palette).to_be_visible()
    expect(search).to_have_value("pl")
    expect(page.locator("#thread-command-plan")).to_be_visible()
    expect(page.locator("#thread-command-work")).not_to_be_visible()
    search.fill("")
    search.press("ArrowDown")
    expect(page.locator("#thread-command-work")).to_have_attribute("aria-selected", "true")
    search.press("ArrowDown")
    expect(page.locator("#thread-command-compact")).to_have_attribute("aria-selected", "true")
    search.press("ArrowUp")
    expect(page.locator("#thread-command-work")).to_have_attribute("aria-selected", "true")
    search.fill("wo")
    expect(page.locator("#thread-command-work")).to_be_visible()
    expect(page.locator("#thread-command-plan")).not_to_be_visible()
    expect(page.locator("#thread-command-work")).to_have_attribute("aria-selected", "true")
    search.press("Tab")
    expect(composer).to_have_value("/work ")
    expect(palette).not_to_be_visible()
    expect(composer).to_be_focused()

    # A partially typed slash seeds palette search; Escape closes it and
    # preserves the in-progress composer text.
    composer.fill("/pla")
    expect(palette).to_be_visible()
    expect(search).to_have_value("pla")
    search.press("Escape")
    expect(composer).to_have_value("/pla")
    expect(palette).not_to_be_visible()
    expect(composer).to_have_attribute("aria-expanded", "false")
    expect(composer).to_be_focused()

    # A slash after leading whitespace remains ordinary prompt text.
    composer.fill(" /pla")
    expect(palette).not_to_be_visible()
    expect(composer).to_have_value(" /pla")

    # Ctrl/Cmd+K opens the palette from the composer. Escape restores focus to
    # the composer, while opening from the button restores focus to that button.
    composer.press("Control+k")
    expect(palette).to_be_visible()
    expect(search).to_be_focused()
    search.fill("terminal")
    expect(page.locator("#thread-command-terminal")).to_be_visible()
    expect(page.locator("#thread-command-plan")).not_to_be_visible()
    search.press("Escape")
    expect(palette).not_to_be_visible()
    expect(composer).to_be_focused()

    commands.click()
    expect(palette).to_be_visible()
    expect(search).to_be_focused()
    page.keyboard.press("Escape")
    expect(palette).not_to_be_visible()
    expect(commands).to_be_focused()

    # During IME composition the input event must not open the palette. The
    # follow-up input after compositionend may open it normally.
    composer.fill("")
    composer.evaluate(
        """node => {
          node.value = "/";
          node.dispatchEvent(new CompositionEvent("compositionstart", {bubbles: true}));
          node.dispatchEvent(new Event("input", {bubbles: true}));
        }"""
    )
    expect(palette).not_to_be_visible()
    composer.evaluate(
        """node => {
          node.dispatchEvent(new CompositionEvent("compositionend", {bubbles: true}));
          node.dispatchEvent(new Event("input", {bubbles: true}));
        }"""
    )
    expect(palette).to_be_visible()
    search.press("Escape")
    expect(composer).to_have_value("/")
    expect(composer).to_be_focused()

    if mobile:
        # Tap exercises the touch path at the phone viewport without invoking
        # a command or submitting the prompt.
        commands.tap()
        expect(palette).to_be_visible()
        palette.locator("[data-thread-commands-close]").tap()
        expect(palette).not_to_be_visible()


def check_thread_views(page: Page, fixture: Context, artifacts: Path) -> None:
    """@cc [owner:ghuntley,label:verification] thread-browser-lifecycle-coverage
    The probe MUST check list, new, activity and all five fixture lifecycle views
    in both themes at desktop and mobile widths. Archived and unready views MUST
    expose no prompt, terminal or editor control; ready views MUST expose all three.
    Ready views MUST also cover slash completion, the command palette, draft and
    focus preservation, IME composition and mobile touch access. Browser checks
    MUST NOT submit prompts or invoke lifecycle mutations.
    """
    routes = {
        "list": "/threads",
        "new": "/threads/new",
        "activity": "/threads/activity",
        "ready": f"/threads/{fixture['ready_thread_id']}",
        "archived": f"/threads/{fixture['archived_thread_id']}",
        "pending": f"/threads/{fixture['pending_thread_id']}",
        "provisioning": f"/threads/{fixture['provisioning_thread_id']}",
        "failed": f"/threads/{fixture['failed_thread_id']}",
    }
    for width in (1440, 390):
        page.set_viewport_size({"width": width, "height": 1000})
        for theme in ("light", "dark"):
            page.locator("[data-appearance]").select_option(theme, force=True)
            check_contrast(page)
            for name, route in routes.items():
                visit(page, fixture["origin"], route)
                expect(page.locator("html")).to_have_attribute("data-theme", theme)
                expect(page.locator("#threads")).to_be_visible()
                if name == "new":
                    expect(page.locator("#new-thread-form")).to_be_visible()
                    settings = page.locator("#new-thread-form details")
                    expect(settings).not_to_have_attribute("open", "")
                    expect(page.locator("select[name='thread[mode]']")).to_be_visible()
                    expect(page.locator("select[name='thread[profile]']")).not_to_be_visible()
                    settings.locator("summary").click()
                    expect(page.locator("select[name='thread[profile]']")).to_be_visible()
                    expect(page.locator("select[name='thread[image_id]']")).not_to_have_value("")
                    expect(
                        page.locator("select[name='thread[profile]'] option[value='customer']")
                    ).to_have_count(0)
                    check_overflow(page)
                    check_grid(page, route)
                    screenshot(page, artifacts, f"threads-new-expanded-{theme}-{width}")
                    settings.locator("summary").click()
                elif name == "activity":
                    expect(page.locator("#thread-activity-items > a")).to_have_count(5)
                    page.locator("select[name='filter[status]']").select_option("archived")
                    expect(page.locator("#thread-activity-items > a")).to_have_count(1)
                    page.locator("select[name='filter[status]']").select_option("deleting")
                    expect(page.locator("#thread-activity-empty")).to_be_visible()
                    page.locator("select[name='filter[status]']").select_option("all")
                    expect(page.locator("#thread-activity-items > a")).to_have_count(5)
                elif name == "list":
                    expect(page.locator("#thread-list-items > a")).to_have_count(5)
                    page.locator("#thread-status-filter").select_option("archived")
                    expect(page.locator("#thread-list-items > a")).to_have_count(1)
                    page.locator("#thread-status-filter").select_option("active")
                    expect(page.locator("#thread-list-items > a")).to_have_count(4)
                    page.locator("#thread-status-filter").select_option("all")
                    page.locator("#thread-search").fill("nothing should match this")
                    expect(page.locator("#thread-search-empty")).to_be_visible()
                    page.locator("#thread-search").fill("")
                    expect(page.locator("#thread-list-items > a")).to_have_count(5)
                elif name == "ready":
                    check_thread_order(page, composer=True)
                    check_thread_composer_controls(page, mobile=width <= 500)
                    expect(page.locator("#thread-prompt-form")).to_be_visible()
                    expect(page.locator("#thread-terminal a")).to_have_attribute(
                        "href", f"/machines/{fixture['vm_id']}/terminals"
                    )
                    expect(page.locator("#thread-terminal")).to_be_visible()
                    expect(page.locator("#thread-vscode")).to_be_visible()
                    expect(page.locator("#thread-vscode")).to_have_attribute(
                        "href", f"/machines/{fixture['vm_id']}/code"
                    )
                    check_thread_share_details(page, fixture)
                    check_overflow(page)
                    check_grid(page, route)
                    screenshot(page, artifacts, f"threads-sharing-{theme}-{width}")
                    page.locator("#thread-share-toggle").click()
                    expect(page.locator("#thread-sharing")).not_to_be_visible()
                elif name == "archived":
                    check_thread_order(page, composer=False)
                    expect(page.locator("#thread-archived")).to_be_visible()
                    expect(page.get_by_role("button", name="Reopen", exact=True)).to_be_visible()
                elif name in ("pending", "provisioning"):
                    expect(page.locator("#thread-provisioning")).to_be_visible()
                elif name == "failed":
                    expect(page.locator("#thread-provision-error")).to_be_visible()
                    expect(page.get_by_role("button", name="Retry", exact=True)).to_be_visible()

                if name in ("archived", "pending", "provisioning", "failed"):
                    expect(page.locator("#thread-prompt-form")).to_have_count(0)
                    expect(page.locator("#thread-terminal")).to_have_count(0)
                    expect(page.locator("#thread-vscode")).to_have_count(0)
                if name in ("ready", "archived"):
                    expect(
                        page.locator("#thread-transcript article[data-kind='assistant']").first
                    ).to_contain_text("requested changes")
                check_overflow(page)
                check_font(page)
                check_grid(page, route)
                screenshot(page, artifacts, f"threads-{name}-{theme}-{width}")
    page.set_viewport_size({"width": 1440, "height": 1000})


def check_thread_collaborators(
    browser: Browser,
    owner_page: Page,
    fixture: Context,
    artifacts: Path,
    watch: ExternalRequests,
    page_errors: list[str],
) -> None:
    """@cc [owner:ghuntley,label:security;verification] thread-browser-role-controls
    Viewers MUST read ready/archived transcripts without mutation controls.
    Operators MUST see ready prompts and eligible machine terminal/editor links;
    only managers may see sharing and lifecycle controls. Revoking a fixture
    viewer through the sharing form MUST remove its mounted transcript on refresh.
    """
    roles: tuple[Literal["viewer", "operator", "manager"], ...] = (
        "viewer",
        "operator",
        "manager",
    )
    contexts: dict[str, BrowserContext] = {}
    try:
        for role in roles:
            context = sign_in(browser, fixture, role, watch)
            contexts[role] = context
            page = context.pages[0]
            page.on("pageerror", lambda error: page_errors.append(type(error).__name__))
            for width in (1440, 390):
                page.set_viewport_size({"width": width, "height": 1000})
                for theme in ("light", "dark"):
                    page.locator("[data-appearance]").select_option(theme, force=True)
                    for state, identifier in (
                        ("ready", fixture["ready_thread_id"]),
                        ("archived", fixture["archived_thread_id"]),
                        ("failed", fixture["failed_thread_id"]),
                    ):
                        route = f"/threads/{identifier}"
                        visit(page, fixture["origin"], route)
                        expect(page.locator("html")).to_have_attribute("data-theme", theme)
                        expect(page.locator("#thread-forbidden")).to_have_count(0)
                        writable = role != "viewer" and state == "ready"
                        for selector in (
                            "#thread-prompt-form",
                            "#thread-terminal",
                            "#thread-vscode",
                        ):
                            if writable:
                                expect(page.locator(selector)).to_be_visible()
                            else:
                                expect(page.locator(selector)).to_have_count(0)
                        expect(page.locator("#thread-share-toggle")).to_have_count(
                            1 if role == "manager" else 0
                        )
                        for action in ("archive", "delete", "retry", "reopen"):
                            allowed = role == "manager" and (
                                (action in ("archive", "delete") and state in ("ready", "failed"))
                                or (action == "retry" and state == "failed")
                                or (action == "reopen" and state == "archived")
                            )
                            expect(page.locator(f"button[phx-click='{action}']")).to_have_count(
                                1 if allowed else 0
                            )
                        if state in ("ready", "archived"):
                            check_thread_order(page, composer=writable)
                        if state == "ready" and role == "viewer":
                            expect(page.locator("#thread-read-only")).to_be_visible()
                        if state == "ready" and role == "manager":
                            check_thread_share_details(page, fixture)
                        check_overflow(page)
                        check_font(page)
                        check_grid(page, route)
                        screenshot(page, artifacts, f"threads-{role}-{state}-{theme}-{width}")

        viewer_page = contexts["viewer"].pages[0]
        route = f"/threads/{fixture['ready_thread_id']}"
        visit(viewer_page, fixture["origin"], route)
        visit(owner_page, fixture["origin"], route)
        check_thread_share_details(owner_page, fixture)
        form = owner_page.locator("#thread-access-form")
        viewer_grant = owner_page.locator("#thread-grant-items > div").filter(
            has_text=fixture["viewer_email"]
        )
        viewer_grant.get_by_role("button", name="Change", exact=True).click()
        expect(form.locator("input[name='access[email]']")).to_have_value(fixture["viewer_email"])
        form.locator("select[name='access[role]']").select_option("revoked")
        form.locator("button[type='submit']").click()
        expect(viewer_grant).to_have_count(0)
        expect(owner_page.locator("#thread-share-error")).to_have_count(0)
        expect(viewer_page.locator("#thread-forbidden")).to_be_visible(timeout=10_000)
        for selector in (
            "#thread-transcript",
            "#thread-prompt-form",
            "#thread-terminal",
            "#thread-vscode",
        ):
            expect(viewer_page.locator(selector)).to_have_count(0)
        screenshot(viewer_page, artifacts, "threads-viewer-revoked")

        form.locator("input[name='access[email]']").fill(fixture["viewer_email"])
        form.locator("select[name='access[role]']").select_option("viewer")
        form.locator("button[type='submit']").click()
        expect(viewer_grant.locator("[data-role]")).to_have_attribute("data-role", "viewer")
        expect(viewer_page.locator("#thread-read-only")).to_be_visible(timeout=10_000)
        check_thread_order(viewer_page, composer=False)
        expect(viewer_page.locator("#thread-prompt-form")).to_have_count(0)
        screenshot(viewer_page, artifacts, "threads-viewer-restored")
    finally:
        for context in contexts.values():
            context.close()


def check_thread_refusal(page: Page, fixture: Context, artifacts: Path) -> None:
    """@cc [owner:ghuntley,label:security;verification] thread-browser-refusal
    An unrelated signed-in account MUST see neither thread list entries nor a
    ready or archived transcript, prompt, terminal or editor on direct navigation.
    """
    visit(page, fixture["origin"], "/threads")
    expect(page.locator("#thread-list-items > a")).to_have_count(0)
    for state, identifier in (
        ("ready", fixture["ready_thread_id"]),
        ("archived", fixture["archived_thread_id"]),
    ):
        visit(page, fixture["origin"], f"/threads/{identifier}")
        expect(page.locator("#thread-forbidden")).to_be_visible()
        for selector in (
            "#thread-transcript",
            "#thread-prompt-form",
            "#thread-terminal",
            "#thread-vscode",
        ):
            expect(page.locator(selector)).to_have_count(0)
        check_overflow(page)
        screenshot(page, artifacts, f"threads-{state}-forbidden")


def luminance(page: Page, token: str) -> float:
    channels: object = page.evaluate(
        """token => {
          const sample = document.createElement('span');
          sample.style.color = `var(${token})`;
          document.body.append(sample);
          const context = document.createElement('canvas').getContext('2d');
          context.fillStyle = getComputedStyle(sample).color;
          context.fillRect(0, 0, 1, 1);
          sample.remove();
          return Array.from(context.getImageData(0, 0, 1, 1).data).slice(0, 3);
        }""",
        token,
    )
    if not isinstance(channels, list) or len(channels) != 3:
        raise ValueError("Expected three color channels")
    total = 0.0
    for channel, weight in zip(channels, (0.2126, 0.7152, 0.0722), strict=True):
        if not isinstance(channel, int) or not 0 <= channel <= 255:
            raise ValueError("Invalid color channel")
        value = channel / 255
        linear = value / 12.92 if value <= 0.04045 else ((value + 0.055) / 1.055) ** 2.4
        total += linear * weight
    return total


def check_contrast(page: Page) -> None:
    """The four presentation tokens keep readable contrast in both themes."""
    pairs = [
        ("--text-color", "--background-color", 7.0),
        ("--text-color", "--background-color-alt", 7.0),
        ("--text-color-alt", "--background-color", 4.5),
        ("--text-color-alt", "--background-color-alt", 4.5),
        ("--background-color", "--text-color", 7.0),
    ]
    for foreground, background, minimum in pairs:
        first, second = luminance(page, foreground), luminance(page, background)
        ratio = (max(first, second) + 0.05) / (min(first, second) + 0.05)
        assert ratio >= minimum, f"Insufficient contrast for {foreground} on {background}"


GRID_ROUTES = ("overview", "machines", "create", "machine", "boot-log", "security", "ssh", "hldd")


def run(fixture: Context, artifacts: Path) -> None:
    """@cc [owner:ghuntley,label:verification;security] monospace-browser-evidence
    Screenshots MUST use disposable accounts and omit token-bearing URL output.
    These checks MUST NOT claim synthetic machines executed guest commands.
    """
    artifacts.mkdir(parents=True, exist_ok=True)
    watch = ExternalRequests(fixture["origin"])
    page_errors: list[str] = []
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            executable_path=os.environ.get("CHROMIUM_PATH"),
            headless=True,
            args=["--no-sandbox"],
        )
        context = sign_in(browser, fixture, "owner", watch)
        context.grant_permissions(["clipboard-read", "clipboard-write"])
        page = context.pages[0]
        page.on("pageerror", lambda error: page_errors.append(type(error).__name__))
        routes = {
            "overview": "/overview",
            "machines": "/machines",
            "create": "/machines/new",
            "machine": f"/machines/{fixture['vm_id']}",
            "terminal": f"/machines/{fixture['vm_id']}/terminals",
            "boot-log": f"/machines/{fixture['vm_id']}/terminals?view=boot-log",
            "access": f"/machines/{fixture['vm_id']}/access",
            "machine-settings": f"/machines/{fixture['vm_id']}/settings",
            "agents": f"/machines/{fixture['vm_id']}/threads",
            "resize": f"/machines/{fixture['vm_id']}/resize",
            "integrations": "/integrations",
            "teams": "/teams",
            "git": "/git",
            "usage": "/usage",
            "security": "/settings/security",
            "ssh": "/settings/ssh-keys",
            "hldd": "/hldd",
            "hldd-section": "/hldd/system",
        }
        for theme in ("light", "dark"):
            page.locator("[data-appearance]").select_option(theme)
            check_contrast(page)
            for name, route in routes.items():
                visit(page, fixture["origin"], route)
                expect(page.locator("html")).to_have_attribute("data-theme", theme)
                check_overflow(page)
                check_font(page)
                if name in GRID_ROUTES:
                    check_grid(page, route)
                if name in (
                    "machine",
                    "terminal",
                    "boot-log",
                    "access",
                    "machine-settings",
                    "agents",
                    "resize",
                ):
                    expect(page.locator("#machine-connect")).to_be_visible()
                if name == "boot-log":
                    check_machine_tabs(page)
                    expect(page.locator(".machine-tabs #machine-boot-log")).to_have_count(0)
                    expect(page.locator("#terminal-boot-view")).to_be_visible()
                    expect(page.locator("#terminal-status")).to_have_text("Boot log · read-only")
                    expect(page.locator("#terminal-create")).to_have_count(0)
                if name == "machine":
                    check_machine_header(page)
                    page.locator("[data-copy-command='machine-id']").click()
                    expect(page.locator("#machine-copy-status")).to_have_text("Machine ID copied.")
                    assert (
                        page.evaluate("navigator.clipboard.readText()")
                        == page.locator("#machine-id").text_content()
                    )
                    page.locator("[data-copy-command='machine-install-command']").click()
                    expect(page.locator("#machine-copy-status")).to_have_text("Command copied.")
                    assert (
                        page.evaluate("navigator.clipboard.readText()")
                        == page.locator("#machine-install-command").text_content()
                    )
                if name == "hldd-section":
                    expect(page.locator("pre.hldd-diagram svg").first).to_be_visible()
                screenshot(page, artifacts, f"{name}-{theme}")
            page.set_viewport_size({"width": 390, "height": 844})
            for name in (
                "overview",
                "machines",
                "create",
                "machine",
                "terminal",
                "boot-log",
                "agents",
                "integrations",
                "teams",
                "usage",
                "security",
            ):
                visit(page, fixture["origin"], routes[name])
                check_overflow(page)
                if name in ("machine", "terminal", "boot-log"):
                    check_machine_tabs(page)
                    check_machine_header(page)
                    check_grid(page, routes[name])
                    terminal = page.locator("#terminal-display").bounding_box()
                    sidebar = page.locator("#terminal-sidebar-list").bounding_box()
                    assert terminal is not None and sidebar is not None
                    assert terminal["y"] < sidebar["y"]
                screenshot(page, artifacts, f"{name}-{theme}-mobile")
            page.locator("#navigation-open").click()
            expect(page.locator("#navigation-close")).to_be_focused()
            page.keyboard.press("Shift+Tab")
            assert page.locator("#workspace-sidebar").evaluate(
                "node => node.contains(document.activeElement)"
            )
            page.keyboard.press("Escape")
            expect(page.locator("#navigation-open")).to_be_focused()
            page.locator("#navigation-open").click()
            screenshot(page, artifacts, f"navigation-{theme}-mobile")
            page.locator("#workspace-sidebar a[href='/git']").click()
            expect(page.locator("#navigation-open")).to_have_attribute("aria-expanded", "false")
            page.set_viewport_size({"width": 1440, "height": 1000})

        check_thread_views(page, fixture, artifacts)
        check_thread_collaborators(browser, page, fixture, artifacts, watch, page_errors)
        visit(page, fixture["origin"], "/machines/new")
        page.locator("#machine_vcpu").fill("3")
        page.locator("#machine_vcpu").press("Tab")
        expect(page).to_have_url(re.compile(r"vcpu.*3"))
        key = page.locator("#machine_request_key").input_value()
        page.reload()
        expect(page.locator("#machine_vcpu")).to_have_value("3")
        expect(page.locator("#machine_request_key")).to_have_value(key)
        page.emulate_media(reduced_motion="reduce")
        assert page.locator(".console-button.primary").first.evaluate(
            "node => parseFloat(getComputedStyle(node).transitionDuration) < 0.01"
        )
        context.close()

        admin = sign_in(browser, fixture, "admin", watch)
        page = admin.pages[0]
        page.on("pageerror", lambda error: page_errors.append(type(error).__name__))
        for route in (
            "nodes",
            "workloads",
            "jobs",
            "operations",
            "users",
            "access",
            "git",
            "audit",
            "usage",
        ):
            visit(page, fixture["origin"], f"/admin/{route}")
            expect(page.locator("nav[aria-label=Administration]")).to_be_visible()
            expect(
                page.locator(f"nav[aria-label=Administration] a[href='/admin/{route}']")
            ).to_have_attribute("aria-current", "page")
            check_overflow(page)
            screenshot(page, artifacts, f"admin-{route}")
        admin.close()

        empty = sign_in(browser, fixture, "empty", watch)
        empty.pages[0].on("pageerror", lambda error: page_errors.append(type(error).__name__))
        expect(empty.pages[0].locator("#overview-machines-empty")).to_be_visible()
        screenshot(empty.pages[0], artifacts, "overview-empty")
        check_thread_refusal(empty.pages[0], fixture, artifacts)
        empty.close()

        public = browser.new_context(color_scheme="dark", viewport={"width": 390, "height": 844})
        public.on("request", watch.observe)
        page = public.new_page()
        page.on("pageerror", lambda error: page_errors.append(type(error).__name__))
        page.goto(fixture["origin"] + "/docs")
        expect(page.locator("html")).to_have_attribute("data-theme", "dark")
        assert public.cookies() == [], "Public docs must remain session-free"
        check_overflow(page)
        check_font(page)
        screenshot(page, artifacts, "docs-dark-mobile")
        page.locator("[data-appearance]").select_option("light")
        page.reload()
        expect(page.locator("html")).to_have_attribute("data-theme", "light")
        page.goto(fixture["origin"] + "/sign-in")
        check_overflow(page)
        assert not re.search(
            r'class="[^"]*\b(?:dark:|rounded|px-|py-|text-gray)', page.content()
        ), "Sign-in page still renders utility classes"
        screenshot(page, artifacts, "sign-in-mobile")
        public.close()
        browser.close()
    assert watch.urls == [], f"External resources were requested: {sorted(set(watch.urls))[:5]}"
    assert not page_errors, "Browser runtime error"
    print(
        "Monospace presentation passed: layouts, navigation, both themes, grid alignment, "
        "self-hosted font, no external requests or browser errors, drafts and public documentation. "
        "Threads passed 32 route/theme/viewport combinations, settings, filters, lifecycle controls, "
        "reading order, 36 collaborator role/state/theme/viewport combinations, sharing, "
        "live revocation and unrelated-account refusals. Synthetic fixtures only."
    )


if __name__ == "__main__":
    try:
        run(read_context(Path(sys.argv[1])), Path(sys.argv[2]))
    except Exception as error:
        # Browser exceptions can contain credential-bearing navigation URLs.
        frames = [
            frame
            for frame in traceback.extract_tb(error.__traceback__)
            if frame.filename == __file__
        ]
        print(
            f"Browser verification failed: {type(error).__name__} at probe line {frames[-1].lineno if frames else 0}."
        )
        raise SystemExit(1) from None
