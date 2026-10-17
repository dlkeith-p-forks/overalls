"""Private, validated identities created by Marshall's closed fixture operator."""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlparse
from uuid import UUID

from access.passkey import Authenticator, authenticator_from_private


@dataclass(frozen=True)
class Actor:
    user_id: UUID
    email: str
    authenticator: Authenticator


@dataclass(frozen=True)
class AccessFixture:
    fixture_id: str
    webauthn_origin: str
    webauthn_rp_id: str
    admin_a: Actor
    admin_b: Actor
    target: Actor


def _actor(value: object) -> Actor:
    if not isinstance(value, dict):
        raise ValueError("invalid access fixture actor")
    user_id = value.get("id")
    email = value.get("email")
    key = value.get("authenticator")
    if not isinstance(user_id, str) or not isinstance(email, str) or not isinstance(key, dict):
        raise ValueError("invalid access fixture actor")
    if not email.endswith("@example.test") or len(email) > 254:
        raise ValueError("invalid synthetic actor email")
    authenticator = authenticator_from_private(key.get("id"), key.get("private_sec1_der"))
    if authenticator is None:
        raise ValueError("invalid fixture authenticator")
    return Actor(UUID(user_id), email, authenticator)


def read_access_fixture(path: Path) -> AccessFixture:
    """@cc [owner:ghuntley,label:security;verification] fixture-private-identity
    Private fixture keys MUST be read only from the operator's runtime volume,
    validated before use, and never printed or copied into assertion details.
    """
    parsed: object = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(parsed, dict) or parsed.get("schema_version") != 1:
        raise ValueError("invalid access fixture")
    fixture_id = parsed.get("fixture_id")
    origin = parsed.get("webauthn_origin")
    rp_id = parsed.get("webauthn_rp_id")
    if not isinstance(fixture_id, str) or not 1 <= len(fixture_id) <= 128:
        raise ValueError("invalid fixture identity")
    if not isinstance(origin, str) or not isinstance(rp_id, str):
        raise ValueError("invalid WebAuthn origin")
    url = urlparse(origin)
    if url.scheme != "https" or url.hostname != rp_id or url.path not in ("", "/"):
        raise ValueError("invalid WebAuthn RP binding")
    actors = (
        _actor(parsed.get("admin_a")),
        _actor(parsed.get("admin_b")),
        _actor(parsed.get("target")),
    )
    if len({actor.user_id for actor in actors}) != 3:
        raise ValueError("duplicate access fixture actor")
    return AccessFixture(fixture_id, origin, rp_id, *actors)
