"""Bounded real-HTTP lookup tests; private-network behavior has a machine suite."""

import asyncio
import importlib.util
import os
import sys
import tempfile
import types
import unittest
from collections.abc import Sequence
from pathlib import Path
from typing import Protocol
from unittest.mock import patch

import aiohttp
from aiohttp import web
from aiohttp.test_utils import TestServer
from aiohttp.typedefs import Handler


def load(name: str, path: str) -> types.ModuleType:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError("lookup helper unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


lookup = load("lookup", sys.argv.pop(1))
lego = load("lego", sys.argv.pop(1))
TOKENS = [letter * 43 for letter in "abc"]
HOST = "control.example.test"


class LookupState(Protocol):
    active: int


class LookupTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.calls: list[int] = [0, 0, 0]
        self.modes: list[str] = ["normal"] * 3
        self.waiting = asyncio.Event()
        self.release = asyncio.Event()
        self.servers: list[TestServer] = []
        for index in range(3):
            app = web.Application()
            app.router.add_route("*", "/{path:.*}", self.responder(index))
            server = TestServer(app)
            await server.start_server()
            self.servers.append(server)
        self.endpoints: list[dict[str, object]] = [
            {"address": "127.0.0.1", "port": server.port} for server in self.servers
        ]
        self.client = aiohttp.ClientSession(headers={"Host": HOST})
        self.routers: list[TestServer] = []

    def responder(self, index: int) -> Handler:
        async def handle(request: web.Request) -> web.Response:
            self.calls[index] += 1
            self.assertEqual(request.headers["Host"], HOST)
            mode = self.modes[index]
            if mode in ("slow", "blocked"):
                self.waiting.set()
                await self.release.wait()
            if mode == "redirect":
                return web.Response(
                    status=302,
                    headers={
                        "Location": f"http://127.0.0.1:{self.servers[2].port}/redirect-target"
                    },
                )
            if mode == "large":
                return web.Response(body=b"x" * 2048)
            if mode == "malformed":
                return web.Response(body=b"not-a-key-authorization")
            token = request.path.removeprefix(lookup.PREFIX)
            if token != TOKENS[index]:
                return web.Response(status=404)
            return web.Response(body=token.encode() + b"." + b"T" * 43)

        return handle

    async def router(self, order: Sequence[int] = (0, 1, 2)) -> tuple[TestServer, LookupState]:
        config: dict[str, object] = {
            "hostname": HOST,
            "local": self.endpoints[order[0]],
            "peers": [],
        }
        app = lookup.application(config)
        # Rootless transport fixtures use different loopback ports. Production
        # configuration validation is tested separately and in real private VMs.
        app[lookup.LOOKUP].config["peers"] = [self.endpoints[index] for index in order[1:]]
        server = TestServer(app)
        await server.start_server()
        self.routers.append(server)
        return server, app[lookup.LOOKUP]

    async def get(
        self, server: TestServer, token: str, headers: dict[str, str] | None = None
    ) -> tuple[int, bytes]:
        async with self.client.get(
            server.make_url(lookup.PREFIX + token), headers=headers
        ) as response:
            return response.status, await response.read()

    async def asyncTearDown(self) -> None:
        self.release.set()
        await self.client.close()
        for server in [*self.routers, *self.servers]:
            await server.close()

    async def test_all_nine_owner_ingress_combinations_and_concurrency(self) -> None:
        routers = [(await self.router(order))[0] for order in [(0, 1, 2), (1, 0, 2), (2, 0, 1)]]
        requests = [(server, token) for server in routers for token in TOKENS]
        results = await asyncio.gather(*(self.get(server, token) for server, token in requests))
        for (_, token), (status, body) in zip(requests, results, strict=False):
            self.assertEqual((status, body), (200, token.encode() + b"." + b"T" * 43))
        self.assertTrue(all(calls <= 9 for calls in self.calls))

    async def test_missing_token_and_invalid_requests(self) -> None:
        server, _ = await self.router()
        self.assertEqual((await self.get(server, "z" * 43))[0], 404)
        for token in ["short", "a" * 257, TOKENS[0] + "?redirect=http://elsewhere", "%2e%2e"]:
            self.assertEqual((await self.get(server, token))[0], 400)
        self.assertEqual(
            (await self.get(server, TOKENS[0], headers={"Host": "wrong.test"}))[0], 421
        )
        async with self.client.post(server.make_url(lookup.PREFIX + TOKENS[0])) as response:
            self.assertEqual(response.status, 405)

    async def test_slow_peer_does_not_delay_success_and_tasks_are_cancelled(self) -> None:
        self.modes[0] = "slow"
        server, state = await self.router()
        async with asyncio.timeout(1):
            self.assertEqual((await self.get(server, TOKENS[2]))[0], 200)
        self.assertEqual(state.active, 0)
        self.assertTrue(all(calls <= 1 for calls in self.calls))

    async def test_no_redirects_oversized_or_mismatched_responses(self) -> None:
        server, _ = await self.router()
        for mode in ["redirect", "large", "malformed"]:
            self.calls = [0, 0, 0]
            self.modes[0] = mode
            self.assertEqual((await self.get(server, TOKENS[0]))[0], 503)
            self.assertTrue(all(calls <= 1 for calls in self.calls))
            self.assertEqual((await self.get(server, TOKENS[2]))[0], 200)

    async def test_endpoint_timeout_and_unreachable_peer(self) -> None:
        server, state = await self.router()
        self.modes[0] = "slow"
        async with asyncio.timeout(3):
            self.assertEqual((await self.get(server, TOKENS[0]))[0], 503)
        self.assertEqual(state.active, 0)
        await self.servers[0].close()
        self.assertEqual((await self.get(server, TOKENS[2]))[0], 200)
        self.assertEqual((await self.get(server, TOKENS[0]))[0], 503)

    async def test_actual_concurrency_cap_and_release(self) -> None:
        self.modes = ["blocked"] * 3
        server, state = await self.router()
        pending = [asyncio.create_task(self.get(server, TOKENS[0])) for _ in range(16)]
        try:
            async with asyncio.timeout(1):
                while state.active < 16:
                    await asyncio.sleep(0.005)
            self.assertEqual((await self.get(server, TOKENS[0]))[0], 503)
            self.release.set()
            self.assertTrue(all(result[0] == 200 for result in await asyncio.gather(*pending)))
            self.assertEqual(state.active, 0)
        finally:
            self.release.set()
            await asyncio.gather(*pending, return_exceptions=True)

    async def test_overall_deadline_cancels_all_tasks(self) -> None:
        server, state = await self.router()

        async def stalled(*_args: object) -> None:
            await asyncio.sleep(30)

        with patch.object(state, "fetch", stalled), patch.object(lookup, "DEADLINE", 0.05):
            self.assertEqual((await self.get(server, TOKENS[0]))[0], 503)
        self.assertEqual(state.active, 0)


class ConfigurationTests(unittest.TestCase):
    def test_private_configuration(self) -> None:
        good = {
            "hostname": HOST,
            "local": {"address": "10.0.0.1", "port": 9080},
            "peers": [{"address": "10.0.0.2", "port": 9080}, {"address": "10.0.0.3", "port": 9080}],
        }
        lookup.configuration(good)
        for address in ["0.0.0.0", "127.0.0.1", "8.8.8.8", "10.0.0.1", "fd00::2", "host.test"]:
            with self.assertRaises(ValueError):
                lookup.configuration({**good, "peers": [{"address": address, "port": 9080}]})

    def test_ipv6_only_configurations_fail_before_client_creation(self) -> None:
        for local, peer in [
            ("fd00::1", "fd00::2"),
            ("::1", "::2"),
            ("::ffff:10.0.0.1", "::ffff:10.0.0.2"),
        ]:
            with self.assertRaises(ValueError):
                lookup.configuration(
                    {
                        "hostname": HOST,
                        "local": {"address": local, "port": 9080},
                        "peers": [{"address": peer, "port": 9080}],
                    }
                )

    def test_http_ignores_ambient_aws_credentials_and_profile(self) -> None:
        # Execute the real wrapper against a harmless environment-checking child.
        with tempfile.TemporaryDirectory() as directory:
            program = Path(directory) / "client"
            program.write_text(
                '#!/bin/sh\n[ -z "${AWS_SHARED_CREDENTIALS_FILE+x}" ] && [ -z "${AWS_ACCESS_KEY_ID+x}" ] && [ "$LEGO_CA_CERTIFICATES" = /trust ]\n'
            )
            program.chmod(0o700)
            with patch.dict(
                os.environ,
                {"AWS_SHARED_CREDENTIALS_FILE": "/missing", "AWS_ACCESS_KEY_ID": "ambient"},
            ):
                lego.main(
                    {
                        "challengeType": "http-01",
                        "caFile": "/trust",
                        "lego": str(program),
                        "timeoutSeconds": 3,
                    },
                    [],
                )


if __name__ == "__main__":
    unittest.main()
