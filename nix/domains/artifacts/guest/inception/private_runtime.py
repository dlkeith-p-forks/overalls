"""Bind inner Audi's private frontend to the enrolled host's owned namespace."""

import fcntl
import hashlib
import json
import os
import stat
import sys
import uuid
from pathlib import Path
from typing import TypedDict

from runtime import SetupError, encode, private_directory, publish, read_private


class Frontend(TypedDict):
    version: int
    role: str
    host_id: str
    connector_path: str
    connector_uid: int
    ziggy_socket: str
    certificate_file: str
    key_file: str
    roots_file: str
    status_socket: str


class Renewal(TypedDict):
    directory: str
    host_id: str
    control_plane: str
    control_ca: str
    credential_file: str
    roots: str


def configuration(host: object) -> tuple[str, Frontend, Renewal]:
    """@cc [owner:ghuntley,label:security] inception-private-audi-local-authority
    The namespace MUST use Lilly's deterministic name for the enrolled host.
    Runtime configuration MUST fix inner fleet TLS, local sockets, credential
    paths and instance public roots. No parent identity, issuer or host-network
    fallback may be selected by a runtime input.
    """
    if not isinstance(host, str) or str(uuid.UUID(host)) != host:
        raise SetupError("inner private host invalid")
    namespace = "/run/netns/lilly-" + hashlib.sha256(host.encode("ascii")).hexdigest()[:12]
    frontend = Frontend(
        version=1,
        role="private",
        host_id=host,
        connector_path="/run/lilly-ingress/private.sock",
        # The inner Lilly runs as its fixed unprivileged service user (ADR-0182).
        connector_uid=377,
        ziggy_socket="/run/ziggy/proxy.sock",
        certificate_file="/run/audi-private/credentials/chain.pem",
        key_file="/run/audi-private/credentials/key.pem",
        roots_file="/run/audi-private/credentials/roots.pem",
        status_socket="/run/audi-private/status.sock",
    )
    renewal = Renewal(
        directory="/var/lib/audi-private-certificates",
        host_id=host,
        control_plane="https://localhost:5443",
        control_ca="/run/audi-private-renewal/control-ca.pem",
        credential_file="/run/audi-private-renewal/audi.token",
        roots="/run/inception-public/private-root.pem",
    )
    return namespace, frontend, renewal


def prepare(
    state: Path = Path("/var/lib/inception"), runtime: Path = Path("/run/inception")
) -> None:
    """@cc [owner:ghuntley,label:security;recovery] inception-private-namespace-binding
    Preparation MUST require the enrolled private-service network configuration.
    It MUST serialize publication in the private runtime directory and refuse an
    existing foreign namespace link or file. The namespace may not yet exist;
    its absence MUST prevent frontend startup rather than select host networking.
    """
    private_directory(runtime)
    fd = os.open(runtime / "private-runtime.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "rb") as lock:
        info = os.fstat(lock.fileno())
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != os.getuid()
            or info.st_nlink != 1
            or info.st_mode & 0o077
        ):
            raise SetupError("inner private configuration lock invalid")
        fcntl.flock(lock, fcntl.LOCK_EX)
        value = json.loads(read_private(state / "lilly.json"))
        if value.get("execution", {}).get("private_services") is not True:
            raise SetupError("inner private networking unavailable")
        namespace, frontend, renewal = configuration(value["host_id"])
        target = runtime / "private-netns"
        if os.path.lexists(target):
            if (
                not target.is_symlink()
                or target.lstat().st_uid != os.getuid()
                or os.readlink(target) != namespace
            ):
                raise SetupError("inner private namespace mismatch")
        else:
            os.symlink(namespace, target)
        publish(runtime / "audi-private.json", encode(frontend))
        publish(runtime / "audi-private-renewal.json", encode(renewal))


if __name__ == "__main__":
    try:
        prepare()
    except (OSError, ValueError, KeyError, TypeError, AttributeError, SetupError):
        sys.exit("Inner private service configuration unavailable")
