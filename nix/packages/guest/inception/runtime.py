"""Private runtime identities and SMTP configuration for an Inception guest."""

import base64
import json
import os
import re
import secrets
import ssl
import stat
import uuid
from pathlib import Path
from typing import TypedDict


class SetupError(Exception):
    """A fixed, secret-free setup failure suitable for service diagnostics."""


class Identity(TypedDict):
    version: int
    instance_id: str
    enrollment_operation_id: str
    database_password: str
    secret_key_base: str
    token_signing_secret: str
    cloak_key: str


def private_directory(path: Path) -> Path:
    path = Path(path)
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise SetupError("private directory unavailable")
    return path


def read_private(path: Path, limit: int = 65536) -> bytes:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        info = os.fstat(fd)
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != os.getuid()
            or info.st_mode & 0o077
            or info.st_nlink != 1
            or info.st_size > limit
        ):
            raise SetupError("private file invalid")
        data = os.read(fd, limit + 1)
        if len(data) > limit:
            raise SetupError("private file oversized")
        return data
    finally:
        os.close(fd)


def publish(path: Path, data: bytes, replace: bool = True) -> None:
    """Publish under the caller's exclusive bootstrap lock and sync its entry."""
    path = Path(path)
    temporary = path.with_name("." + path.name + "." + secrets.token_hex(8))
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        if not replace and os.path.lexists(path):
            raise SetupError("persistent file already exists")
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        temporary.unlink(missing_ok=True)


def encode(value: object) -> bytes:
    return json.dumps(value, separators=(",", ":"), sort_keys=True).encode()


def identities(directory: Path) -> Identity:
    """@cc [owner:ghuntley,label:security;recovery] inception-independent-identities
    Each new guest MUST generate independent database, signing and encryption keys.
    A retry MUST reuse the exact persisted identity; malformed or missing identity
    after the initialization marker MUST fail rather than resetting credentials.
    Callers MUST serialize bootstrap in a private, instance-owned state directory.
    """
    directory = private_directory(directory)
    path = directory / "identity.json"
    try:
        value: object = json.loads(read_private(path))
    except FileNotFoundError:
        if os.path.lexists(directory / "initialized"):
            raise SetupError("persistent identity missing") from None
        value = {
            "version": 1,
            "instance_id": str(uuid.uuid4()),
            "enrollment_operation_id": str(uuid.uuid4()),
            "database_password": secrets.token_hex(32),
            "secret_key_base": secrets.token_hex(64),
            "token_signing_secret": secrets.token_hex(32),
            "cloak_key": base64.b64encode(secrets.token_bytes(32)).decode(),
        }
        publish(path, encode(value), replace=False)
    except (ValueError, OSError):
        raise SetupError("persistent identity invalid") from None

    try:
        if not isinstance(value, dict) or set(value) != {
            "version",
            "instance_id",
            "enrollment_operation_id",
            "database_password",
            "secret_key_base",
            "token_signing_secret",
            "cloak_key",
        }:
            raise ValueError()
        version = value["version"]
        instance_id = value["instance_id"]
        enrollment_operation_id = value["enrollment_operation_id"]
        database_password = value["database_password"]
        secret_key_base = value["secret_key_base"]
        token_signing_secret = value["token_signing_secret"]
        cloak_key = value["cloak_key"]
        if (
            type(version) is not int
            or version != 1
            or not isinstance(instance_id, str)
            or str(uuid.UUID(instance_id)) != instance_id
            or not isinstance(enrollment_operation_id, str)
            or str(uuid.UUID(enrollment_operation_id)) != enrollment_operation_id
            or not isinstance(database_password, str)
            or not re.fullmatch("[0-9a-f]{64}", database_password)
            or not isinstance(secret_key_base, str)
            or not re.fullmatch("[0-9a-f]{128}", secret_key_base)
            or not isinstance(token_signing_secret, str)
            or not re.fullmatch("[0-9a-f]{64}", token_signing_secret)
            or not isinstance(cloak_key, str)
            or len(base64.b64decode(cloak_key, validate=True)) != 32
        ):
            raise ValueError()
    except (ValueError, TypeError, AttributeError):
        raise SetupError("persistent identity invalid") from None

    publish(directory / "initialized", b"1\n")
    return Identity(
        version=version,
        instance_id=instance_id,
        enrollment_operation_id=enrollment_operation_id,
        database_password=database_password,
        secret_key_base=secret_key_base,
        token_signing_secret=token_signing_secret,
        cloak_key=cloak_key,
    )


def smtp_environment(value: object, runtime: Path) -> dict[str, str]:
    """@cc [owner:ghuntley,label:security] inception-smtp-only-shared-bundle
    The shared bundle MUST contain only validated SMTP configuration, never database,
    application or enrollment secrets. Remote SMTP MUST require authentication and
    verified TLS. Values MUST NOT contain line breaks or NULs or become shell code.
    """
    required = {"version", "host", "port", "username", "password", "from", "tls"}
    if (
        not isinstance(value, dict)
        or set(value) not in (required, required | {"ca_pem"})
        or type(value.get("version")) is not int
        or value["version"] != 1
    ):
        raise SetupError("SMTP bundle invalid")
    for key, maximum in [
        ("host", 253),
        ("username", 1024),
        ("password", 4096),
        ("from", 254),
        ("tls", 8),
    ]:
        item = value[key]
        if (
            not isinstance(item, str)
            or not 1 <= len(item.encode()) <= maximum
            or any(c in item for c in "\r\n\0")
        ):
            raise SetupError("SMTP bundle invalid")
    host = value["host"]
    username = value["username"]
    password = value["password"]
    sender = value["from"]
    port = value["port"]
    tls = value["tls"]
    if (
        not isinstance(host, str)
        or not isinstance(username, str)
        or not isinstance(password, str)
        or not isinstance(sender, str)
        or not isinstance(tls, str)
        or type(port) is not int
        or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]*", host)
        or not re.fullmatch(r"[^@\s]+@[A-Za-z0-9][A-Za-z0-9.-]*", sender)
        or not 1 <= port <= 65535
        or tls not in ["implicit", "starttls"]
    ):
        raise SetupError("SMTP bundle invalid")
    env = {
        "MARSHALL_MAIL_TRANSPORT": "smtp",
        "MARSHALL_SMTP_HOST": host,
        "MARSHALL_SMTP_PORT": str(port),
        "MARSHALL_SMTP_USERNAME": username,
        "MARSHALL_SMTP_PASSWORD": password,
        "MARSHALL_MAIL_FROM": sender,
        "MARSHALL_SMTP_TLS": tls,
    }
    if "ca_pem" in value:
        try:
            pem = value["ca_pem"]
            if not isinstance(pem, str) or len(pem.encode()) > 32768:
                raise ValueError()
            ssl.create_default_context(cadata=pem)
        except (ValueError, ssl.SSLError):
            raise SetupError("SMTP CA invalid") from None
        path = private_directory(runtime) / "smtp-ca.crt"
        publish(path, pem.encode())
        env["MARSHALL_SMTP_CA_CERTFILE"] = str(path)
    return env


def application_environment(
    identity: Identity, smtp: dict[str, str], database_ca: Path
) -> dict[str, str]:
    return {
        **smtp,
        "DATABASE_URL": "postgresql://marshall:"
        + identity["database_password"]
        + "@localhost/marshall",
        "SECRET_KEY_BASE": identity["secret_key_base"],
        "TOKEN_SIGNING_SECRET": identity["token_signing_secret"],
        "MARSHALL_CLOAK_KEYS": json.dumps([{"id": "inception", "key": identity["cloak_key"]}]),
        "MARSHALL_DB_TLS": "verify",
        "MARSHALL_DB_CA_CERTFILE": str(database_ca),
        "MARSHALL_INSTANCE_ID": "inception",
        "MARSHALL_REPLICA_COUNT": "1",
        "MARSHALL_DB_CONNECTION_BUDGET": "64",
        "POOL_SIZE": "10",
        "PHX_HOST": "localhost",
        "RELEASE_DISTRIBUTION": "none",
        "ERL_CRASH_DUMP": "/dev/null",
    }


def environment_file(env: dict[str, str]) -> bytes:
    """Systemd EnvironmentFile syntax; this file MUST NOT be sourced by a shell."""
    lines = []
    for key, value in sorted(env.items()):
        if not re.fullmatch(r"[A-Z][A-Z0-9_]*", key) or any(c in value for c in "\r\n\0"):
            raise SetupError("environment invalid")
        lines.append(key + '="' + value.replace("\\", "\\\\").replace('"', '\\"') + '"\n')
    return "".join(lines).encode()
