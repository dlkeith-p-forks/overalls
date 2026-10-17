"""Private, issued Lilly credential envelope; never a diagnostic payload."""

import json
import re
import stat
from dataclasses import dataclass
from pathlib import Path
from uuid import UUID

_TOKEN = re.compile(r"[0-9a-f-]{36}:[A-Za-z0-9_-]{43}\Z")


@dataclass(frozen=True, repr=False)
class LillyCredential:
    host_id: UUID
    credential_id: UUID
    token: str


def read_lilly_credential(path: Path) -> LillyCredential:
    """@cc [owner:ghuntley,label:security] control-credential-private-file
    The workload MUST read only a regular private runtime credential envelope,
    validate its closed shape and binding, and never put the token in errors,
    logs, environment values, assertion details or process arguments.
    """
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o077:
        raise ValueError("Control credential file is not private and regular")
    if info.st_size > 4096 or info.st_size == 0:
        raise ValueError("invalid Control credential file size")
    try:
        parsed: object = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ValueError("unreadable Control credential envelope") from error
    if not isinstance(parsed, dict) or set(parsed) != {
        "version",
        "host_id",
        "credential_id",
        "credential",
        "expires_at",
    }:
        raise ValueError("invalid Control credential envelope")
    if parsed["version"] != 1 or type(parsed["version"]) is not int:
        raise ValueError("unsupported Control credential envelope")
    host = parsed["host_id"]
    identifier = parsed["credential_id"]
    token = parsed["credential"]
    expiry = parsed["expires_at"]
    if not all(isinstance(value, str) for value in (host, identifier, token, expiry)):
        raise ValueError("invalid Control credential fields")
    try:
        host_id = UUID(host)
        credential_id = UUID(identifier)
    except ValueError as error:
        raise ValueError("invalid Control credential identity") from error
    if str(host_id) != host or str(credential_id) != identifier:
        raise ValueError("noncanonical Control credential identity")
    if not _TOKEN.fullmatch(token) or not token.startswith(identifier + ":"):
        raise ValueError("invalid Control credential binding")
    if not expiry:
        raise ValueError("missing Control credential expiry")
    return LillyCredential(host_id, credential_id, token)


def find_current_credential(
    initial_path: Path, host_id: UUID, active_id: UUID
) -> LillyCredential | None:
    """Find the DB-selected current token among bounded operator-issued files."""
    directory = initial_path.parent
    paths = [initial_path]
    for path in directory.iterdir():
        if path == initial_path:
            continue
        if path.suffix == ".json" and len(path.stem) == 36:
            paths.append(path)
        if len(paths) > 128:
            return None
    for path in paths:
        try:
            candidate = read_lilly_credential(path)
        except (OSError, ValueError):
            continue
        if candidate.host_id == host_id and candidate.credential_id == active_id:
            return candidate
    return None
