"""Logical PostgreSQL capture using Marshall's runtime connection authority."""

import hashlib
import os
import re
import tempfile
from pathlib import Path
from typing import TypedDict
from urllib.parse import unquote, urlsplit

from common import BackupError, atomic_json, private_directory, run
from schema import PostgresConfig


class Connection(TypedDict):
    host: str
    port: int
    user: str
    password: str
    database: str


class Metadata(TypedDict):
    version: int
    format: str
    server_version: int
    client_major: int
    sha256: str


def connection(url: str | None) -> Connection:
    """@cc [owner:ghuntley,label:security] backup-database-follows-marshall
    Backup connection identity MUST derive exclusively from Marshall's runtime
    DATABASE_URL. Reject query/fragment overrides and malformed values without
    returning the URL in errors. Missing input MUST NOT fall back to localhost.
    """
    try:
        if not isinstance(url, str) or not 1 <= len(url.encode()) <= 16384:
            raise ValueError()
        parsed = urlsplit(url)
        if (
            parsed.scheme not in {"ecto", "postgres", "postgresql"}
            or "?" in url
            or "#" in url
            or not parsed.path.startswith("/")
        ):
            raise ValueError()
        if parsed.hostname is None:
            raise ValueError()
        result: Connection = {
            "host": parsed.hostname,
            "port": 5432 if parsed.port is None else parsed.port,
            "user": unquote(parsed.username or "", errors="strict"),
            "password": unquote(parsed.password or "", errors="strict"),
            "database": unquote(parsed.path[1:], errors="strict"),
        }
        for value in (result["host"], result["user"], result["database"]):
            if not isinstance(value, str) or not 1 <= len(value.encode()) <= 253:
                raise ValueError()
        if (
            not 1 <= result["port"] <= 65535
            or any(c in str(value) for value in result.values() for c in "\x00\r\n")
            or result["host"].startswith("/")
            or "," in result["host"]
        ):
            raise ValueError()
        return result
    except (ValueError, UnicodeError, TypeError):
        raise BackupError("database") from None


def environment(identity: Connection, ca_file: str, password_file: Path) -> dict[str, str]:
    def escape(value: str | int) -> str:
        return str(value).replace("\\", "\\\\").replace(":", "\\:")

    fields: list[str | int] = [
        identity["host"],
        identity["port"],
        identity["database"],
        identity["user"],
        identity["password"],
    ]
    with open(
        password_file, "x", encoding="utf-8", opener=lambda path, flags: os.open(path, flags, 0o600)
    ) as stream:
        stream.write(":".join(map(escape, fields)) + "\n")
    return {
        "PATH": os.environ.get("PATH", ""),
        "LC_ALL": "C",
        "HOME": str(Path(password_file).parent),
        "PGHOST": identity["host"],
        "PGPORT": str(identity["port"]),
        "PGUSER": identity["user"],
        "PGDATABASE": identity["database"],
        "PGPASSFILE": str(password_file),
        "PGSSLMODE": "verify-full",
        "PGSSLROOTCERT": ca_file,
        "PGSSLMINPROTOCOLVERSION": "TLSv1.2",
        "PGCONNECT_TIMEOUT": "10",
        "PGAPPNAME": "overalls-backup",
    }


def capture(config: PostgresConfig, destination: Path, url: str | None) -> Metadata:
    destination = private_directory(destination)
    identity = connection(url)
    with tempfile.TemporaryDirectory(prefix="postgres-auth-", dir=destination) as auth:
        env = environment(identity, config["ca_file"], Path(auth) / "pgpass")
        server = (
            run(
                [config["psql"], "-X", "-w", "-A", "-t", "-c", "SHOW server_version_num"],
                stage="database",
                environment=env,
                timeout=30,
            )
            .decode()
            .strip()
        )
        client = run(
            [config["pg_dump"], "--version"], stage="database", environment=env, timeout=10
        ).decode()
        match = re.search(r"\(PostgreSQL\) ([0-9]+)(?:\.|\b)", client)
        if not server.isdigit() or not match or not 10 <= int(server) // 10000 <= int(match[1]):
            raise BackupError("database")
        archive = destination / "database.dump"
        run(
            [
                config["pg_dump"],
                "--no-password",
                "--format=custom",
                "--compress=0",
                "--file",
                str(archive),
            ],
            stage="database",
            environment=env,
            timeout=config["timeout"],
        )
        run(
            [config["pg_restore"], "--list", str(archive)],
            stage="database",
            environment=env,
            timeout=60,
            maximum=16 * 1024 * 1024,
        )
        with archive.open("rb") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        metadata: Metadata = {
            "version": 1,
            "format": "postgres-custom",
            "server_version": int(server),
            "client_major": int(match[1]),
            "sha256": digest,
        }
        atomic_json(destination / "database.json", metadata)
        return metadata
