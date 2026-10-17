"""Private, TLS authenticated handoff of accepted synthetic SMTP messages."""

from __future__ import annotations

import base64
import binascii
import json
import os
import re
import time
from email import policy
from email.parser import BytesParser
from pathlib import Path

from core.http import HttpClient
from core.outcome import Observation, State

_LINK = re.compile(r"https://[^\s<>\"]+/magic_link/[A-Za-z0-9._-]+")


def _message_link(entry: dict[str, object], email: str) -> Observation[str | None]:
    recipient = entry.get("recipient")
    message_id = entry.get("message_id")
    raw = entry.get("data_b64")
    if (
        not isinstance(recipient, str)
        or not isinstance(message_id, str)
        or not isinstance(raw, str)
    ):
        return Observation.unavailable()
    if recipient.removeprefix("<").removesuffix(">").casefold() != email.casefold():
        return Observation.observed(None)
    try:
        data = base64.b64decode(raw, validate=True)
        message = BytesParser(policy=policy.default).parsebytes(data)
        plain = message.get_body(preferencelist=("plain",))
        content = plain.get_content() if plain is not None else ""
    except (ValueError, UnicodeError, binascii.Error, KeyError):
        return Observation.unavailable()
    if (
        not isinstance(content, str)
        or message.get("Message-ID") != message_id
        or len(data) > 262_144
    ):
        return Observation.unavailable()
    links = _LINK.findall(content)
    if len(links) != 1:
        return Observation.unavailable()
    return Observation.observed(links[0])


class MailLinks:
    def __init__(self, ca_file: Path, token_file: Path, origin: str) -> None:
        if origin != "https://smtp.fixture.test:8444":
            raise ValueError("unreviewed SMTP fixture endpoint")
        self._client = HttpClient(ca_file)
        self._token_file = token_file
        self._origin = origin

    @classmethod
    def from_environment(cls, _marshall_ca_file: Path) -> MailLinks:
        return cls(
            Path(os.getenv("ANTITHESIS_SMTP_CA_FILE", "/run/overalls-smtp-ca/ca.pem")),
            Path(
                os.getenv(
                    "ANTITHESIS_SMTP_ADMIN_TOKEN_FILE", "/run/overalls-smtp-admin/admin-token"
                )
            ),
            os.getenv("ANTITHESIS_SMTP_ADMIN_ORIGIN", "https://smtp.fixture.test:8444"),
        )

    def _query(self, after: int) -> Observation[dict[str, object]]:
        """@cc [owner:ghuntley,label:security;verification] smtp-private-link-handoff
        Accepted DATA MUST be read only over the fixture's authenticated TLS
        endpoint. Evicted/oversized/lost messages and malformed results MUST
        remain unavailable; credentials, DATA and links MUST never be logged.
        """
        if after < 0:
            raise ValueError("invalid SMTP cursor")
        try:
            token = self._token_file.read_text(encoding="ascii").strip()
        except (OSError, UnicodeError):
            return Observation.unavailable()
        if not 24 <= len(token) <= 256:
            return Observation.unavailable()
        reply = self._client.request(
            "GET",
            f"{self._origin}/v1/messages?after={after}&limit=1",
            headers={"X-Fixture-Admin-Token": token},
        )
        if reply.state is not State.OBSERVED or reply.value is None or reply.value.status != 200:
            return Observation.unavailable()
        try:
            parsed: object = json.loads(reply.value.body)
        except (UnicodeError, ValueError):
            return Observation.unavailable()
        if not isinstance(parsed, dict) or type(parsed.get("sequence")) is not int:
            return Observation.unavailable()
        if not isinstance(parsed.get("messages"), list):
            return Observation.unavailable()
        return Observation.observed(parsed)

    def sequence(self) -> Observation[int]:
        try:
            token = self._token_file.read_text(encoding="ascii").strip()
        except (OSError, UnicodeError):
            return Observation.unavailable()
        if not 24 <= len(token) <= 256:
            return Observation.unavailable()
        reply = self._client.request(
            "GET",
            f"{self._origin}/v1/receipts?after=0&limit=1",
            headers={"X-Fixture-Admin-Token": token},
        )
        if reply.state is not State.OBSERVED or reply.value is None or reply.value.status != 200:
            return Observation.unavailable()
        try:
            parsed: object = json.loads(reply.value.body)
        except (UnicodeError, ValueError):
            return Observation.unavailable()
        if not isinstance(parsed, dict):
            return Observation.unavailable()
        sequence = parsed.get("sequence")
        if type(sequence) is not int or sequence < 0:
            return Observation.unavailable()
        return Observation.observed(sequence)

    def wait_link(self, email: str, after: int, timeout_seconds: float) -> Observation[str]:
        deadline = time.monotonic() + timeout_seconds
        cursor = after
        while time.monotonic() < deadline:
            response = self._query(cursor)
            if response.state is not State.OBSERVED or response.value is None:
                return Observation.unavailable()
            entries = response.value["messages"]
            if not isinstance(entries, list):
                return Observation.unavailable()
            for entry in entries:
                if not isinstance(entry, dict):
                    return Observation.unavailable()
                seq = entry.get("seq")
                if type(seq) is not int or seq <= cursor:
                    return Observation.unavailable()
                cursor = seq
                found = _message_link(entry, email)
                if found.state is not State.OBSERVED:
                    return Observation.unavailable()
                if found.value is not None:
                    return Observation.observed(found.value)
            time.sleep(0.2)
        return Observation.unavailable()
