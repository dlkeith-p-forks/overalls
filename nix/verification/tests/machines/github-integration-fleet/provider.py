"""Isolated OAuth front end for the real composed Marshall/Lilly fleet.

Only provider HTTP is simulated. The sibling packaged-edge fixture contributes
its GitHub data handlers; its control server and connector are never started.
"""

import base64
import hashlib
import html
import secrets
import ssl
import sys
import threading
from dataclasses import dataclass
from urllib.parse import parse_qs, urlencode, urlsplit

import provider_data

CALLBACK = "https://control.example.test/auth/github-com/callback"
CLIENT = "synthetic-fleet-client"
SECRET = "synthetic-fleet-client-secret"
SCOPES = "repo workflow read:org project gist notifications read:user user:email read:packages write:packages"
PENDING_LOCK = threading.Lock()


@dataclass(frozen=True)
class Ceremony:
    owner: int
    challenge: str


PENDING: dict[str, Ceremony] = {}


def field(parameters: dict[str, list[str]], name: str) -> str:
    values = parameters.get(name, [])
    if len(values) != 1 or len(values[0]) > 4096:
        raise ValueError("invalid provider field")
    return values[0]


class Handler(provider_data.Handler):
    def dispatch(self) -> None:
        host = self.headers.get("Host", "").split(":", 1)[0]
        path = urlsplit(self.path).path
        if host == "github.com" and path == "/login/oauth/authorize":
            return self.authorize()
        if host == "github.com" and path == "/login/oauth/approve":
            return self.approve()
        if host == "github.com" and path == "/login/oauth/access_token":
            return self.token()
        if host == "api.github.com" and path.startswith("/applications/"):
            if (
                self.command != "DELETE"
                or self.headers.get("Authorization")
                != "Basic " + base64.b64encode((CLIENT + ":" + SECRET).encode()).decode()
            ):
                return self.reply({}, 401)
            self.read_body()
            provider_data.record({"event": "oauth_revocation"})
            return self.bytes_reply(b"", 204)
        if path == "/api/control/v1":
            return self.reply({}, 404)
        super().dispatch()

    def authorize(self) -> None:
        parameters = parse_qs(urlsplit(self.path).query)
        if (
            self.command != "GET"
            or field(parameters, "client_id") != CLIENT
            or field(parameters, "redirect_uri") != CALLBACK
            or field(parameters, "code_challenge_method") != "S256"
        ):
            return self.reply({}, 400)
        fields = "".join(
            '<input type="hidden" name="'
            + name
            + '" value="'
            + html.escape(field(parameters, name), quote=True)
            + '">'
            for name in ("state", "code_challenge")
        )
        self.bytes_reply(
            (
                '<!doctype html><html lang="en"><title>Synthetic GitHub consent</title>'
                '<form action="/login/oauth/approve" method="post">'
                + fields
                + '<label>Fixture owner<input name="owner" required></label>'
                '<button id="authorize" type="submit">Authorize fixture</button></form></html>'
            ).encode(),
            headers={"Content-Type": "text/html", "Cache-Control": "no-store"},
        )

    def approve(self) -> None:
        parameters = parse_qs(self.read_body().decode())
        owner = field(parameters, "owner")
        if self.command != "POST" or owner not in {"1", "2"}:
            return self.reply({}, 400)
        code = secrets.token_urlsafe(32)
        with PENDING_LOCK:
            if len(PENDING) >= 128:
                return self.reply({}, 503)
            PENDING[code] = Ceremony(int(owner), field(parameters, "code_challenge"))
        provider_data.record({"event": "oauth_approved", "owner": int(owner)})
        self.bytes_reply(
            b"",
            303,
            {
                "Location": CALLBACK
                + "?"
                + urlencode({"code": code, "state": field(parameters, "state")}),
                "Cache-Control": "no-store",
                "Referrer-Policy": "no-referrer",
            },
        )

    def token(self) -> None:
        parameters = parse_qs(self.read_body().decode())
        if (
            self.command != "POST"
            or field(parameters, "client_id") != CLIENT
            or field(parameters, "client_secret") != SECRET
        ):
            return self.reply({}, 401)
        if parameters.get("grant_type") == ["refresh_token"]:
            token = field(parameters, "refresh_token")
            owner = next(
                (
                    n
                    for n in (1, 2)
                    if token
                    == f"synthetic-refresh-owner-{n}-generation-{provider_data.authority(n).generation}"
                ),
                None,
            )
            if owner is None:
                return self.reply({}, 401)
            generation = provider_data.authority(owner).generation + 1
            path = provider_data.ROOT / f"authority-{owner}.json"
            pending = path.with_suffix(".pending")
            pending.write_text(
                provider_data.json.dumps({"phase": "active", "generation": generation})
            )
            pending.replace(path)
            expiry = 3600
            provider_data.record({"event": "oauth_refreshed", "owner": owner})
        else:
            with PENDING_LOCK:
                ceremony = PENDING.pop(field(parameters, "code"), None)
            verifier = field(parameters, "code_verifier")
            challenge = (
                base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest())
                .decode()
                .rstrip("=")
            )
            if (
                ceremony is None
                or challenge != ceremony.challenge
                or field(parameters, "redirect_uri") != CALLBACK
            ):
                return self.reply({}, 401)
            owner = ceremony.owner
            expiry = 601
            provider_data.record({"event": "oauth_exchanged", "owner": owner})
        self.reply(
            {
                "access_token": provider_data.authority(owner).token,
                "refresh_token": f"synthetic-refresh-owner-{owner}-generation-{provider_data.authority(owner).generation}",
                "expires_in": expiry,
                "refresh_token_expires_in": 86400,
                "token_type": "bearer",
                "scope": SCOPES,
            },
            headers={"Cache-Control": "no-store"},
        )


def main() -> None:
    provider_data.ROOT.mkdir(exist_ok=True)
    provider_data.seed()
    server = provider_data.Server(("0.0.0.0", 443), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(sys.argv[1], sys.argv[2])
    server.socket = context.wrap_socket(server.socket, server_side=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
