"""Read-only, bounded challenge lookup; no certificate or account key access."""

import asyncio
import ipaddress
import json
import logging
import os
import re
import socket
import sys
from pathlib import Path
from typing import TypedDict

import aiohttp
from aiohttp import web

PREFIX = "/.well-known/acme-challenge/"
TOKEN = re.compile(r"[A-Za-z0-9_-]{22,256}", re.ASCII)
THUMBPRINT = re.compile(rb"[A-Za-z0-9_-]{43}", re.ASCII)
MAX_RESPONSE = 1024
MAX_LOOKUPS = 16
DEADLINE = 3
ENDPOINT_TIMEOUT = 2
LOOKUP = web.AppKey("lookup", object)


class Endpoint(TypedDict):
    address: str
    port: int


class EndpointList(TypedDict):
    hostname: str
    local: Endpoint
    peers: list[Endpoint]


def endpoint_value(value: object) -> Endpoint:
    if not isinstance(value, dict):
        raise ValueError("invalid endpoint")
    address = value.get("address")
    port = value.get("port")
    if not isinstance(address, str) or type(port) is not int:
        raise ValueError("invalid endpoint")
    return Endpoint(address=address, port=port)


def configuration(raw: object) -> EndpointList:
    """@cc [owner:ghuntley,label:security] acme-lookup-ipv4-destinations
    Configuration MUST reject every IPv6 endpoint, including an all-IPv6 set.
    Fixed local and peer addresses MUST be validated before opening sockets.
    """
    if not isinstance(raw, dict):
        raise ValueError("invalid configuration")
    peers = raw.get("peers")
    if not isinstance(peers, list):
        raise ValueError("invalid configuration")
    local = endpoint_value(raw.get("local"))
    endpoints = [local, *[endpoint_value(peer) for peer in peers]]
    local_address = ipaddress.IPv4Address(local["address"])
    seen: set[ipaddress.IPv4Address] = set()
    for index, endpoint in enumerate(endpoints):
        address = ipaddress.IPv4Address(endpoint["address"])
        if (
            address.version != local_address.version
            or address.is_unspecified
            or address.is_multicast
        ):
            raise ValueError("invalid endpoint")
        if index and (address.is_loopback or not address.is_private):
            raise ValueError("invalid peer")
        if address in seen or not 1024 <= endpoint["port"] <= 65535:
            raise ValueError("invalid endpoint")
        seen.add(address)
    if peers and (local_address.is_loopback or not local_address.is_private):
        raise ValueError("invalid local endpoint")
    return EndpointList(hostname=string(raw.get("hostname")), local=local, peers=[*endpoints[1:]])


def string(value: object) -> str:
    if not isinstance(value, str):
        raise ValueError("expected string")
    return value


class Lookup:
    def __init__(self, config: object) -> None:
        self.config = configuration(config)
        self.session: aiohttp.ClientSession | None = None
        self.active = 0

    async def start(self, _app: web.Application) -> None:
        # No DNS lookup, environment proxy, cookies, decompression or redirects.
        connector = aiohttp.TCPConnector(
            limit=MAX_LOOKUPS * (1 + len(self.config["peers"])),
            local_addr=(self.config["local"]["address"], 0),
            family=socket.AF_INET,
        )
        self.session = aiohttp.ClientSession(
            connector=connector,
            trust_env=False,
            auto_decompress=False,
            cookie_jar=aiohttp.DummyCookieJar(),
            timeout=aiohttp.ClientTimeout(total=ENDPOINT_TIMEOUT, sock_connect=1),
            headers={"Host": self.config["hostname"], "Accept-Encoding": "identity"},
            max_line_size=1024,
            max_field_size=1024,
        )

    async def stop(self, _app: web.Application) -> None:
        assert self.session is not None
        await self.session.close()

    async def fetch(self, endpoint: Endpoint, token: str) -> tuple[int, bytes | None]:
        address = ipaddress.IPv4Address(endpoint["address"])
        host = str(address)
        url = f"http://{host}:{endpoint['port']}{PREFIX}{token}"
        try:
            assert self.session is not None
            async with self.session.get(url, allow_redirects=False) as response:
                if response.status == 404:
                    return 404, None
                if response.status != 200:
                    return 503, None
                body = bytearray()
                async for chunk in response.content.iter_chunked(MAX_RESPONSE + 1):
                    body.extend(chunk)
                    if len(body) > MAX_RESPONSE:
                        return 503, None
                value = bytes(body).rstrip(b"\r\n \t")
                expected = token.encode("ascii") + b"."
                if not value.startswith(expected) or not THUMBPRINT.fullmatch(
                    value[len(expected) :]
                ):
                    return 503, None
                return 200, bytes(body)
        except (aiohttp.ClientError, OSError, TimeoutError, ValueError):
            return 503, None

    async def handle(self, request: web.Request) -> web.StreamResponse:
        """@cc [owner:ghuntley,label:security] bounded-direct-challenge-lookup
        A lookup MUST read only fixed responders, at most once each, under a
        shared deadline and concurrency cap. It MUST accept only a matching
        bounded key authorization, cancel outstanding reads, and never log
        tokens, URLs, bodies or raw failures. No redirect or peer recursion.
        """
        if request.headers.get("Host", "").lower() not in (
            self.config["hostname"],
            self.config["hostname"] + ":80",
        ):
            return web.Response(status=421)
        if request.method != "GET":
            return web.Response(status=405)
        token = request.raw_path.removeprefix(PREFIX)
        if not request.raw_path.startswith(PREFIX) or not TOKEN.fullmatch(token):
            return web.Response(status=400)
        if request.can_read_body:
            return web.Response(status=400)
        if self.active >= MAX_LOOKUPS:
            return web.Response(status=503)
        self.active += 1
        tasks: list[asyncio.Task[tuple[int, bytes | None]]] = []
        try:
            tasks = [
                asyncio.create_task(self.fetch(endpoint, token))
                for endpoint in [self.config["local"], *self.config["peers"]]
            ]
            failed = False
            async with asyncio.timeout(DEADLINE):
                for result in asyncio.as_completed(tasks):
                    status, body = await result
                    if status == 200:
                        return web.Response(
                            body=body,
                            content_type="text/plain",
                            headers={"Cache-Control": "no-store"},
                        )
                    failed |= status != 404
            return web.Response(status=503 if failed else 404)
        except Exception:
            print('{"event":"acme.lookup_failed","severity":"error"}', flush=True)
            return web.Response(status=503)
        finally:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            self.active -= 1


def application(config: object) -> web.Application:
    lookup = Lookup(config)
    app = web.Application(
        client_max_size=1024, handler_args={"max_line_size": 1024, "max_field_size": 1024}
    )
    app[LOOKUP] = lookup
    app.on_startup.append(lookup.start)
    app.on_cleanup.append(lookup.stop)
    app.router.add_route("*", "/{path:.*}", lookup.handle)
    return app


def main() -> None:
    # aiohttp's parser/exception/access logs may contain raw request material.
    logging.disable(logging.CRITICAL)
    os.umask(0o077)
    raw: object = json.loads(Path(sys.argv[1]).read_text())
    if not isinstance(raw, dict):
        raise ValueError("invalid lookup configuration")
    path = Path(string(raw.get("socket")))
    path.unlink(missing_ok=True)
    web.run_app(application(raw), path=str(path), print=None, access_log=None, shutdown_timeout=4)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        print('{"event":"acme.lookup_start_failed","severity":"error"}', file=sys.stderr)
        sys.exit(1)
