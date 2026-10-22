"""Headless Chromium probes for the isolated artifact content origin."""

import json
import sys
import time
from pathlib import Path

from playwright.sync_api import (
    Browser,
    BrowserContext,
    ConsoleMessage,
    Frame,
    Page,
    Playwright,
    Request,
    expect,
    sync_playwright,
)

MARSHALL = "https://control.example.test"
CONTENT = "https://usercontent.example.test"
OUTSIDE = "http://outside.example.test:8081"
STATE = Path("/run/artifact-origin-browser/state.json")
MARKER = "ARTIFACT-ORIGIN-MARKER"

# Evaluated inside the content document. Every capability an artifact must not
# have is attempted; each outcome is reduced to a closed vocabulary.
PROBE = """
async () => {
  const within = (promise) => Promise.race([
    promise,
    new Promise((resolve) => setTimeout(() => resolve("blocked"), 3000)),
  ]);
  const attempt = (action) => { try { return action(); } catch (error) { return "blocked"; } };
  const xhr = (url) => new Promise((resolve) => {
    const request = new XMLHttpRequest();
    request.onload = () => resolve("allowed");
    request.onerror = () => resolve("blocked");
    try { request.open("GET", url); request.send(); } catch (error) { resolve("blocked"); }
  });
  const marker = document.getElementById("marker");
  return {
    origin: String(self.origin),
    marker: marker ? marker.textContent : "",
    inline_script: document.body && document.body.dataset.inlineScript === "ran" ? "ran" : "absent",
    cookie_read: attempt(() => document.cookie === "" ? "empty" : "readable"),
    cookie_write: attempt(() => {
      document.cookie = "planted=1; path=/";
      return document.cookie.includes("planted") ? "allowed" : "ignored";
    }),
    local_storage: attempt(() => { localStorage.setItem("probe", "1"); return "allowed"; }),
    session_storage: attempt(() => { sessionStorage.setItem("probe", "1"); return "allowed"; }),
    indexed_db: await within(new Promise((resolve) => {
      try {
        const opened = indexedDB.open("probe");
        opened.onsuccess = () => resolve("allowed");
        opened.onerror = () => resolve("blocked");
      } catch (error) { resolve("blocked"); }
    })),
    service_worker: await within((async () => {
      if (!("serviceWorker" in navigator)) { return "blocked"; }
      await navigator.serviceWorker.register("sw.js");
      return "allowed";
    })().catch(() => "blocked")),
    parent_document: attempt(() => window.parent === window
      ? "self" : (window.parent.document ? "allowed" : "blocked")),
    fetch_marshall: await within(fetch(MARSHALL + "/health/ready").then(() => "allowed", () => "blocked")),
    fetch_outside: await within(fetch(OUTSIDE + "/fetch").then(() => "allowed", () => "blocked")),
    xhr_marshall: await within(xhr(MARSHALL + "/health/ready")),
    xhr_outside: await within(xhr(OUTSIDE + "/xhr")),
    popup: attempt(() => window.open(OUTSIDE + "/popup") ? "allowed" : "blocked"),
    top_navigation: attempt(() => {
      if (window.top === window) { return "self"; }
      window.top.location.href = OUTSIDE + "/top";
      return "attempted";
    }),
  };
}
""".replace("MARSHALL", json.dumps(MARSHALL)).replace("OUTSIDE", json.dumps(OUTSIDE))

FORM = """
() => {
  const form = document.createElement("form");
  form.action = OUTSIDE + "/form";
  form.method = "GET";
  document.body.appendChild(form);
  try { form.submit(); return "submitted"; } catch (error) { return "blocked"; }
}
""".replace("OUTSIDE", json.dumps(OUTSIDE))

EXPECTED: dict[str, tuple[str, ...]] = {
    "origin": ("null",),
    "inline_script": ("ran",),
    "cookie_read": ("empty", "blocked"),
    "cookie_write": ("ignored", "blocked"),
    "local_storage": ("blocked",),
    "session_storage": ("blocked",),
    "indexed_db": ("blocked",),
    "service_worker": ("blocked",),
    "fetch_marshall": ("blocked",),
    "fetch_outside": ("blocked",),
    "xhr_marshall": ("blocked",),
    "xhr_outside": ("blocked",),
    "popup": ("blocked",),
}


def ticket(kind: str) -> str:
    value = Path(f"/run/overalls-test/artifact-{kind}").read_text().strip()
    assert value and all(c.isalnum() or c in "-_" for c in value), "malformed fixture ticket"
    return value


def content_url(ticket_value: str, path: str = "") -> str:
    return f"{CONTENT}/v/{ticket_value}/{path}"


def probe(frame: Frame, embedded: bool) -> dict[str, str]:
    raw: object = frame.evaluate(PROBE)
    assert isinstance(raw, dict), "probe returned no result object"
    result: dict[str, str] = {}
    for key, value in raw.items():
        assert isinstance(key, str) and isinstance(value, str), "probe result is not closed"
        result[key] = value
    for key, allowed in EXPECTED.items():
        assert result.get(key) in allowed, f"{key} escaped isolation: {result.get(key)}"
    assert result["marker"] == MARKER, "probe document did not render"
    if embedded:
        assert result["parent_document"] == "blocked", "iframe reached the embedding document"
        assert result["top_navigation"] in ("blocked", "attempted"), "top navigation result"
    else:
        assert result["parent_document"] == "self"
        assert result["top_navigation"] == "self"
    return result


def submit_form(page: Page, frame: Frame) -> None:
    before = frame.url
    try:
        outcome: object = frame.evaluate(FORM)
        assert outcome in ("submitted", "blocked")
    except Exception as error:
        raise AssertionError("form submission navigated the content document") from error
    page.wait_for_timeout(1500)
    assert frame.url == before, "form submission navigated the content document"
    assert page.url.startswith(MARSHALL) or page.url.startswith(CONTENT)


def browser(playwright: Playwright) -> Browser:
    return playwright.chromium.launch(
        executable_path="/run/current-system/sw/bin/chromium",
        args=[
            "--no-sandbox",
            "--host-resolver-rules=MAP control.example.test 127.0.0.1, "
            "MAP usercontent.example.test 127.0.0.1, MAP outside.example.test 127.0.0.1",
        ],
    )


def marshall_cookies(context: BrowserContext) -> dict[str, str]:
    """@cc [owner:ghuntley,label:verification;security] artifact-origin-host-cookie
    Marshall's session MUST be a host-only __Host- cookie for its own host;
    no cookie may be scoped to the shared registrable domain.
    """
    cookies = context.cookies()
    for cookie in cookies:
        domain = cookie.get("domain", "")
        assert not domain.startswith("."), "a cookie is scoped beyond its host"
        assert domain != "example.test", "a cookie is scoped to the registrable domain"
        assert cookie.get("name") != "planted", "an artifact planted a cookie"
    values = {
        str(cookie.get("name")): str(cookie.get("value"))
        for cookie in cookies
        if cookie.get("domain") == "control.example.test"
    }
    assert any(name.startswith("__Host-") for name in values), "Marshall session cookie missing"
    return values


def redact(text: str) -> str:
    """Drop ticket path segments so diagnostics never carry a bearer ticket."""
    return " ".join(
        word.split("/v/")[0] + "/v/<ticket>" if "/v/" in word else word for word in text.split()
    )


def inject_iframe(page: Page, url: str) -> Frame:
    console: list[str] = []

    def record(message: ConsoleMessage) -> None:
        console.append(redact(message.text)[:300])

    page.on("console", record)
    page.goto(MARSHALL + "/overview")
    expect(page.locator("[data-phx-main].phx-connected")).to_be_visible()
    page.evaluate(
        """(url) => {
          const frame = document.createElement("iframe");
          frame.id = "artifact-origin-probe";
          frame.setAttribute("sandbox", "allow-scripts");
          frame.setAttribute("referrerpolicy", "no-referrer");
          frame.setAttribute("allow", "");
          frame.setAttribute("credentialless", "");
          frame.src = url;
          document.body.appendChild(frame);
        }""",
        url,
    )
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        for frame in page.frames:
            if frame.url.startswith(CONTENT + "/v/"):
                frame.wait_for_load_state()
                return frame
        page.wait_for_timeout(200)
    origins = [redact(frame.url)[:120] for frame in page.frames]
    raise AssertionError(f"content iframe did not load inside Marshall: {origins} {console}")


def content_requests_carry_no_credentials(requests: list[Request]) -> None:
    observed = [request for request in requests if request.url.startswith(CONTENT + "/")]
    assert observed, "no content requests were observed"
    for request in observed:
        headers = request.all_headers()
        assert "cookie" not in headers, "the browser sent a cookie to the content host"
        assert "authorization" not in headers, "the browser sent credentials to the content host"


def login() -> None:
    with sync_playwright() as playwright:
        chromium = browser(playwright)
        context = chromium.new_context()
        page = context.new_page()
        token = Path("/run/overalls-test/artifact-owner-token").read_text().strip()
        page.goto(MARSHALL + "/magic_link/" + token)
        expect(page.locator("[data-phx-main].phx-connected")).to_be_visible()
        page.wait_for_url("**/overview")
        marshall_cookies(context)
        STATE.parent.mkdir(mode=0o700, exist_ok=True)
        context.storage_state(path=str(STATE))
        STATE.chmod(0o600)
        chromium.close()


def baseline() -> None:
    """Direct visit, Marshall-hosted iframe and the Marshall artifact viewer."""
    valid = ticket("ticket-valid")
    with sync_playwright() as playwright:
        chromium = browser(playwright)
        context = chromium.new_context(storage_state=str(STATE))
        requests: list[Request] = []

        # Playwright tags handlers with an attribute, which a builtin bound
        # method such as list.append cannot carry.
        def record(request: Request) -> None:
            requests.append(request)

        context.on("request", record)
        before = marshall_cookies(context)

        page = context.new_page()
        response = page.goto(content_url(valid))
        assert response is not None and response.status == 200
        assert "sandbox allow-scripts" in response.all_headers()["content-security-policy"]
        direct = probe(page.main_frame, embedded=False)
        submit_form(page, page.main_frame)
        svg = page.goto(content_url(valid, "image.svg"))
        assert svg is not None and svg.status == 200
        assert page.evaluate("() => String(self.origin)") == "null"

        host = context.new_page()
        frame = inject_iframe(host, content_url(valid))
        embedded = probe(frame, embedded=True)
        submit_form(host, frame)
        host.wait_for_timeout(1500)
        assert host.url.startswith(MARSHALL + "/overview"), "the artifact navigated Marshall"

        # The product viewer must embed the same origin with the same sandbox.
        state = json.loads(Path("/run/overalls-test/artifact-origin.json").read_text())
        viewer = context.new_page()
        viewer.goto(MARSHALL + "/artifacts/" + str(state["artifact_id"]))
        expect(viewer.locator("[data-phx-main].phx-connected")).to_be_visible()
        element = viewer.locator(f'iframe[src^="{CONTENT}/v/"]')
        expect(element).to_have_count(1)
        assert element.get_attribute("sandbox") == "allow-scripts"
        assert element.get_attribute("referrerpolicy") == "no-referrer"
        deadline = time.monotonic() + 20
        viewer_frame: Frame | None = None
        while viewer_frame is None and time.monotonic() < deadline:
            viewer_frame = next(
                (f for f in viewer.frames if f.url.startswith(CONTENT + "/v/")), None
            )
            viewer.wait_for_timeout(200)
        assert viewer_frame is not None, "viewer iframe did not load"
        viewer_frame.wait_for_load_state()
        probe(viewer_frame, embedded=True)

        content_requests_carry_no_credentials(requests)
        # Marshall may re-sign its own session on each visit; content must not
        # add, remove or rescope a cookie (values are Marshall's to change).
        assert marshall_cookies(context).keys() == before.keys(), (
            "content altered Marshall's cookies"
        )
        print(json.dumps({"direct": direct, "embedded": embedded}, sort_keys=True))
        chromium.close()


def foreign_embedding() -> None:
    """frame-ancestors must refuse framing from any origin except Marshall."""
    valid = ticket("ticket-valid")
    with sync_playwright() as playwright:
        chromium = browser(playwright)
        page = chromium.new_context().new_page()
        page.goto(OUTSIDE + "/embed?u=" + content_url(valid))
        page.wait_for_load_state("load")
        page.wait_for_timeout(2000)
        for frame in page.frames:
            if frame == page.main_frame:
                continue
            try:
                text = frame.content()
            except Exception:
                continue
            assert MARKER not in text, "a foreign origin framed artifact content"
        chromium.close()


def sniffing() -> None:
    """A text file holding markup must stay text; its script must not run."""
    valid = ticket("ticket-valid")
    with sync_playwright() as playwright:
        chromium = browser(playwright)
        page = chromium.new_context().new_page()
        response = page.goto(content_url(valid, "sniff.txt"))
        assert response is not None and response.status == 200
        assert response.all_headers()["x-content-type-options"] == "nosniff"
        assert page.evaluate("() => document.contentType") == "text/plain"
        assert page.title() != "SNIFFED", "sniffed markup executed"
        chromium.close()


def payload(path: str) -> None:
    """A generated escape payload must change nothing outside its document."""
    value = ticket("payload-ticket")
    with sync_playwright() as playwright:
        chromium = browser(playwright)
        context = chromium.new_context(storage_state=str(STATE))
        requests: list[Request] = []

        # Playwright tags handlers with an attribute, which a builtin bound
        # method such as list.append cannot carry.
        def record(request: Request) -> None:
            requests.append(request)

        context.on("request", record)
        before = marshall_cookies(context)
        page = context.new_page()
        response = page.goto(content_url(value, path))
        assert response is not None and response.status == 200
        page.wait_for_timeout(2000)
        assert page.url.startswith(content_url(value)), "payload navigated its own top level"
        host = context.new_page()
        inject_iframe(host, content_url(value, path))
        host.wait_for_timeout(2500)
        assert host.url.startswith(MARSHALL + "/overview"), "payload navigated Marshall"
        content_requests_carry_no_credentials(requests)
        assert marshall_cookies(context).keys() == before.keys(), (
            "payload altered Marshall's cookies"
        )
        chromium.close()


def main() -> None:
    mode = sys.argv[1]
    if mode == "login":
        login()
    elif mode == "baseline":
        baseline()
    elif mode == "foreign-embedding":
        foreign_embedding()
    elif mode == "sniffing":
        sniffing()
    elif mode == "payload":
        payload(sys.argv[2])
    else:
        raise SystemExit("unknown mode")


if __name__ == "__main__":
    main()
