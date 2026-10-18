"""Fixed HTTPS probes from a real guest PTY through authenticated Marshall TerminalLive."""

import json
import re
import shlex
import time
from dataclasses import dataclass
from pathlib import Path
from uuid import UUID, uuid4

from access.fixture import read_access_fixture
from access.mail import MailLinks
from access.oracle import AccessOracle
from access.session import login_fixture, verify_fixture_login
from core.config import Config
from core.outcome import Observation, State
from core.sql import SqlOracle
from terminal.client import TerminalClient
from terminal.viewer import Viewer

_MARKER = re.compile(r"fx-[0-9a-f]{32}\Z")
_NAME = re.compile(r"at-[0-9a-f]{20}\Z")
_STATUS = re.compile(rb"SATfx-[0-9a-f]{32}:([0-5][0-9][0-9])\r?\n")


@dataclass(frozen=True)
class ProbeResult:
    status: int


class GuestProbe:
    def __init__(self, terminal: TerminalClient, viewer: Viewer, vm_id: UUID) -> None:
        self._terminal = terminal
        self._viewer = viewer
        # Daily accounting groups by owner/day/provider/model, so an isolated
        # model keeps this VM's observed delta separate from parallel commands.
        self.model = f"fixture-{vm_id.hex}"

    @classmethod
    def open(cls, config: Config, vm_id: UUID) -> Observation["GuestProbe"]:
        """@cc [owner:ghuntley,label:security;verification] satellite-guest-origin
        Satellite probes MUST originate in a real current VM terminal opened by
        an authenticated Marshall browser. No workload header or RPC may invent
        Audi's VM binding. Terminal dispatch alone is not an upstream effect.
        """
        fixture = read_access_fixture(Path("/run/overalls-control-secrets/fixture.json"))
        links = MailLinks.from_environment(config.ca_file)
        login = login_fixture(config, links, fixture.admin_a, config.marshall_urls[0])
        account = AccessOracle(SqlOracle(config)).account(fixture.admin_a.email)
        if (
            login is None
            or account.state is not State.OBSERVED
            or account.value is None
            or (
                account.value.mfa_enabled
                and not verify_fixture_login(
                    config, login, fixture.admin_a, fixture.webauthn_origin
                )
            )
        ):
            return Observation.unavailable()
        mounted = TerminalClient.mount(login.browser, login.origin, vm_id, config.ca_file)
        if mounted.state is not State.OBSERVED or mounted.value is None:
            return Observation.unavailable()
        terminal = mounted.value
        request_id = uuid4()
        deadline = time.monotonic() + 35
        while time.monotonic() < deadline:
            created = terminal.create(request_id)
            if created.state is State.OBSERVED and created.value is not None:
                if created.value.state == "failed":
                    terminal.close()
                    return Observation.unavailable()
                if created.value.session_id is not None:
                    attached = Viewer.attach(terminal, created.value.session_id)
                    if attached.state is State.OBSERVED and attached.value is not None:
                        return Observation.observed(cls(terminal, attached.value, vm_id))
            time.sleep(0.3)
        terminal.close()
        return Observation.unavailable()

    def submit_inference(self, marker: str, *, stream: bool = False) -> bool:
        if _MARKER.fullmatch(marker) is None:
            raise ValueError("invalid registered origin marker")
        body = json.dumps(
            {"model": self.model, "input": marker, "stream": stream}, separators=(",", ":")
        )
        return self._submit(
            marker,
            (
                "curl --noproxy '*' --silent --show-error --max-time 55 "
                "--output /dev/null --write-out '%{http_code}' "
                "-H 'Content-Type: application/json' --data-binary "
                f"{shlex.quote(body)} https://llm.internal/v1/responses"
            ),
        )

    def submit_integration(
        self, name: str, marker: str, *, held: bool = False, duplicate_headers: bool = False
    ) -> bool:
        if _NAME.fullmatch(name) is None or _MARKER.fullmatch(marker) is None:
            raise ValueError("invalid fixed integration selection")
        route = "stream" if held else "probe"
        headers = f"-H {shlex.quote('X-Fixture-Operation-ID: ' + marker)} "
        if duplicate_headers:
            headers += (
                "-H 'Authorization: Bearer guest-forgery' -H 'X-Fixture-Static: guest-forgery' "
            )
        return self._submit(
            marker,
            (
                "curl --noproxy '*' --silent --show-error --max-time 55 "
                "--output /dev/null --write-out '%{http_code}' "
                f"{headers}https://{name}.integration.internal/fixture/{route}"
            ),
        )

    def _submit(self, marker: str, command: str) -> bool:
        # The printed sentinel is assembled from split literals, so a PTY echo
        # of the command cannot masquerade as completed curl output.
        line = (
            "stty -echo; status=$(" + command + "); "
            "printf 'SAT%s%s:%s\\n' 'fx-' '" + marker[3:] + '\' "$status"\n'
        )
        sent = self._viewer.input(line.encode("ascii"))
        return sent.state is State.OBSERVED and sent.value is True

    def wait(self, marker: str, seconds: float = 60) -> Observation[ProbeResult]:
        if _MARKER.fullmatch(marker) is None or not 0 < seconds <= 65:
            raise ValueError("invalid probe wait")
        expected = ("SAT" + marker + ":").encode("ascii")
        received = bytearray()
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline and len(received) <= 262_144:
            chunk = self._viewer.receive(timeout=min(5.0, max(0.1, deadline - time.monotonic())))
            if chunk.state is not State.OBSERVED or chunk.value is None:
                continue
            received.extend(chunk.value)
            start = received.find(expected)
            if start >= 0:
                match = _STATUS.match(received, start)
                if match is not None:
                    return Observation.observed(ProbeResult(int(match.group(1))))
        return Observation.unavailable()

    def close(self) -> None:
        self._viewer.close()
        self._terminal.close()
