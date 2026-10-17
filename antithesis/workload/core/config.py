"""Validated, nonsecret runtime configuration and issued fixture identity."""

import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Literal
from urllib.parse import urlparse
from uuid import UUID


@dataclass(frozen=True)
class Fixture:
    fixture_id: str
    migration_version: int
    host_ids: tuple[UUID, ...]


@dataclass(frozen=True)
class Config:
    marshall_urls: tuple[str, ...]
    ca_file: Path
    fixture_manifest: Path
    db_host: str
    db_port: int
    db_user: str
    db_name: str
    db_password_file: Path
    timeout_seconds: int
    profile: Literal[
        "control-core", "repository-origin", "access-smtp", "recorder-host", "admission-stub"
    ] = "control-core"

    @classmethod
    def from_environment(cls) -> "Config":
        raw_urls = _required("ANTITHESIS_MARSHALL_URLS")
        urls = tuple(part.strip().rstrip("/") for part in raw_urls.split(","))
        if len(urls) < 1 or len(set(urls)) != len(urls):
            raise ValueError("Marshall URLs must be nonempty and distinct")
        for url in urls:
            parsed = urlparse(url)
            if (
                parsed.scheme != "https"
                or not parsed.hostname
                or parsed.path not in ("", "/")
                or parsed.query
                or parsed.fragment
                or parsed.username
                or parsed.password
            ):
                raise ValueError("Marshall URLs must be HTTPS origins")
        port = _positive_int(os.getenv("ANTITHESIS_DB_PORT", "5432"), "database port")
        timeout = _positive_int(
            os.getenv("ANTITHESIS_BOOTSTRAP_TIMEOUT_SECONDS", "180"), "bootstrap timeout"
        )
        if port > 65535 or timeout > 3600:
            raise ValueError("port or bootstrap timeout out of range")
        profile = os.getenv("ANTITHESIS_BOOTSTRAP_PROFILE", "control-core")
        if profile not in (
            "control-core",
            "repository-origin",
            "access-smtp",
            "recorder-host",
            "admission-stub",
        ):
            raise ValueError("unsupported bootstrap profile")
        return cls(
            marshall_urls=urls,
            ca_file=Path(_required("ANTITHESIS_CA_FILE")),
            fixture_manifest=Path(_required("ANTITHESIS_FIXTURE_MANIFEST")),
            db_host=_required("ANTITHESIS_DB_HOST"),
            db_port=port,
            db_user=_required("ANTITHESIS_DB_USER"),
            db_name=_required("ANTITHESIS_DB_NAME"),
            db_password_file=Path(_required("ANTITHESIS_DB_PASSWORD_FILE")),
            timeout_seconds=timeout,
            profile=profile,
        )


def _required(name: str) -> str:
    value = os.getenv(name)
    if value is None or not value.strip():
        raise ValueError(f"missing {name}")
    return value.strip()


def _positive_int(raw: str, label: str) -> int:
    try:
        value = int(raw)
    except ValueError as error:
        raise ValueError(f"invalid {label}") from error
    if value < 1:
        raise ValueError(f"invalid {label}")
    return value


def read_fixture(path: Path) -> Fixture:
    """@cc [owner:ghuntley,label:security;verification] fixture-manifest-not-authority
    The fixture manifest MUST only name authority created by Marshall's trusted
    enrollment action. Bootstrap MUST verify every named host against live SQL
    authority and reject missing, malformed or duplicate identities.
    """
    parsed: object = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(parsed, dict) or set(parsed) != {
        "schema_version",
        "fixture_id",
        "migration_version",
        "host_ids",
    }:
        raise ValueError("invalid fixture manifest shape")
    if parsed["schema_version"] != 1:
        raise ValueError("unsupported fixture manifest version")
    fixture_id = parsed["fixture_id"]
    migration = parsed["migration_version"]
    host_ids = parsed["host_ids"]
    if not isinstance(fixture_id, str) or not fixture_id or len(fixture_id) > 128:
        raise ValueError("invalid fixture identity")
    if not isinstance(migration, int) or isinstance(migration, bool) or migration <= 0:
        raise ValueError("invalid migration version")
    if (
        not isinstance(host_ids, list)
        or not host_ids
        or not all(isinstance(item, str) for item in host_ids)
    ):
        raise ValueError("invalid host identities")
    hosts = tuple(UUID(item) for item in host_ids)
    if len(hosts) != len(set(hosts)):
        raise ValueError("duplicate host identity")
    return Fixture(fixture_id, migration, hosts)
