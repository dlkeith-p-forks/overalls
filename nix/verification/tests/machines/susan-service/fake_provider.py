"""Fake APNs, Google OAuth, FCM, Entra ID and WNS origins over TLS with HTTP/2 (ASGI)."""

import json
from collections.abc import Awaitable, Callable
from pathlib import Path

state = Path("/run/fake-provider")
Scope = dict[str, object]
Message = dict[str, object]
Receive = Callable[[], Awaitable[Message]]
Send = Callable[[Message], Awaitable[None]]


def scripted(host: str) -> tuple[int, dict[str, str], bytes] | None:
    path = state / "script.json"
    if not path.exists():
        return None
    script: list[dict[str, object]] = json.loads(path.read_text())
    for index, entry in enumerate(script):
        if str(entry["host"]) == host:
            script.pop(index)
            path.write_text(json.dumps(script))
            headers = entry.get("headers", {})
            assert isinstance(headers, dict)
            return (
                int(str(entry["status"])),
                {str(k): str(v) for k, v in headers.items()},
                str(entry.get("body", "")).encode(),
            )
    return None


async def app(scope: Scope, receive: Receive, send: Send) -> None:
    if scope["type"] != "http":
        return
    headers = {
        k.decode(): v.decode()
        for k, v in scope["headers"]  # type: ignore[union-attr]
    }
    host = headers.get("host", headers.get(":authority", "")).split(":")[0]
    body = b""
    while True:
        message = await receive()
        body += message.get("body", b"")  # type: ignore[operator]
        if not message.get("more_body"):
            break
    record = {
        "host": host,
        "path": scope["path"],
        "http_version": scope["http_version"],
        "headers": {k: v for k, v in headers.items() if k.startswith(("apns-", "x-wns-"))},
        "authorization": headers.get("authorization", "").split(" ")[0],
        "body": body.decode(errors="replace"),
    }
    with (state / "requests.jsonl").open("a") as log:
        log.write(json.dumps(record) + "\n")
    response = scripted(host)
    if response is None:
        if host in ("oauth2.googleapis.com", "login.microsoftonline.com"):
            payload = {"access_token": "fake-oauth-access", "expires_in": 3600}
            response = (200, {}, json.dumps(payload).encode())
        else:
            response = (200, {}, b"{}")
    status, extra, content = response
    await send(
        {
            "type": "http.response.start",
            "status": status,
            "headers": [(b"content-type", b"application/json")]
            + [(k.encode(), v.encode()) for k, v in extra.items()],
        }
    )
    await send({"type": "http.response.body", "body": content})
