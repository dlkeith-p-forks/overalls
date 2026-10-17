"""Host-only Inception namespace setup and boot-bound publication exchange."""

from __future__ import annotations

import contextlib
import fcntl
import json
import os
import re
import socket
import struct
import sys
import time
from collections.abc import Mapping
from pathlib import Path
from typing import TYPE_CHECKING, NotRequired, TypedDict

import observations
import public_settings
from runtime import SetupError, encode, environment_file, private_directory, publish, read_private

if TYPE_CHECKING:
    from readiness import Identity

# @cc [owner:ghuntley,label:security;recovery] inception-ingress-dedicated-vsock-port
# This listener MUST use a port distinct from readiness (1024), credentials
# (1025), and the inherited guest backup flush service (1026).
PORT = 1028
REQUEST_LIMIT = 65536
REPLY_LIMIT = 262144
ROOT = Path("/run/inception")
PUBLIC_CONFIG = Path("/etc/inception-public.json")
BINDING = {"placement_id", "execution_epoch", "boot_challenge"}
LABEL = re.compile(r"[a-z][a-z0-9-]*-[0-9a-f]{32}")
UUID = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}")


class Binding(TypedDict):
    placement_id: str
    execution_epoch: int
    boot_challenge: str


class Nameserver(TypedDict):
    name: str
    address: str
    port: int


class Public(TypedDict):
    issuer: str
    accept_terms: bool
    nameservers: list[Nameserver]
    mailbox: str
    issuer_ca_pem: str | None
    trust_pem: str | None


class Parent(TypedDict):
    origin: str
    label: str
    zone: str


class Origins(TypedDict):
    namespace: str
    control: str
    apps: str


class Configuration(TypedDict):
    version: int
    binding: Binding
    request_id: str
    generation: int
    origins: Origins
    public: NotRequired[Public]
    parent: NotRequired[Parent]
    observations: NotRequired[observations.Observations | None]


class Installed(TypedDict):
    version: int
    binding: Binding
    generation: int
    origins: Origins
    public: NotRequired[Public]
    parent: NotRequired[Parent]


class Publication(TypedDict):
    version: int
    binding: Binding
    generation: int
    request_id: str
    ttl_ms: int
    porsche_host_key: str | None
    audi_host_key: str | None
    records: list[observations.ReplyRecord]


def unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    value = {}
    for key, item in pairs:
        if key in value:
            raise SetupError("duplicate ingress field")
        value[key] = item
    return value


def request(body: bytes, boot: Mapping[str, object]) -> Configuration:
    """@cc [owner:ghuntley,label:security] inception-ingress-config-scope
    Requests MUST bind this kernel boot, use a closed schema and bounded canonical
    names in one environment namespace. Inputs MUST NOT select files, commands,
    credentials, listener addresses or arbitrary services.
    """
    if len(body) > REQUEST_LIMIT:
        raise SetupError("ingress request oversized")
    value: Configuration = json.loads(body, object_pairs_hook=unique_object)
    if (
        not isinstance(value, dict)
        or set(value) - {"public", "observations", "parent"}
        != {"version", "binding", "request_id", "generation", "origins"}
        or type(value["version"]) is not int
        or value["version"] != 1
        or value["binding"] != {key: boot[key] for key in BINDING}
        or not isinstance(value["binding"], dict)
        or type(value["binding"].get("execution_epoch")) is not int
        or not isinstance(value["request_id"], str)
        or not UUID.fullmatch(value["request_id"])
        or type(value["generation"]) is not int
        or not 1 <= value["generation"] <= 9223372036854775807
    ):
        raise SetupError("ingress boot binding invalid")
    origins = value["origins"]
    if (
        not isinstance(origins, dict)
        or set(origins) != {"namespace", "control", "apps"}
        or not all(isinstance(v, str) for v in origins.values())
    ):
        raise SetupError("ingress origins invalid")
    parts = origins["namespace"].split(".")
    if (
        len(parts) < 3
        or not 34 <= len(parts[0]) <= 63
        or not LABEL.fullmatch(parts[0])
        or parts[1] != "inception"
        or any(not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", p) for p in parts[2:])
        or origins["control"] != "control." + origins["namespace"]
        or origins["apps"] != "apps." + origins["namespace"]
        or len("_acme-challenge.") + 63 + 1 + len(origins["apps"]) > 253
    ):
        raise SetupError("ingress origins invalid")
    public_settings.validate_parent(value.get("parent"), origins["namespace"])
    public_settings.validate(value.get("public"))
    observations.validate(value.get("observations"))
    return value


def install(value: Configuration, root: Path = ROOT) -> None:
    """@cc [owner:ghuntley,label:recovery] inception-ingress-stable-config
    Repeated polls MUST preserve the installed namespace and MUST NOT rewrite
    unchanged configuration. Within one boot, generation rollback or namespace
    replacement or parent discovery/public issuer/trust/DNS replacement MUST fail; a poll
    identifier is not durable configuration. Operator public-setting changes
    require a new guest boot, never an implicit live trust rotation.
    """
    private_directory(root)
    config = Installed(
        version=value["version"],
        binding=value["binding"],
        generation=value["generation"],
        origins=value["origins"],
    )
    if "public" in value:
        config["public"] = value["public"]
    if "parent" in value:
        config["parent"] = value["parent"]
    fd = os.open(root / "ingress.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "r+b") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        path = root / "ingress.json"
        try:
            old = json.loads(read_private(path))
            if old["binding"] == config["binding"]:
                if (
                    old["origins"] != config["origins"]
                    or old.get("public") != config.get("public")
                    or old.get("parent") != config.get("parent")
                    or old["generation"] > config["generation"]
                ):
                    raise SetupError("ingress identity changed")
                if old == config:
                    public_environment(config, root)
                    return
        except FileNotFoundError:
            pass
        publish(path, encode(config))
        public_environment(config, root)


def public_environment(config: Installed, root: Path) -> None:
    """@cc [owner:ghuntley,label:security;recovery] inception-runtime-origins
    Only the accepted parent namespace may supply the inner public hostname and
    application zone. Files MUST contain no parent credentials. Repeated polls
    MUST retain unchanged files and repair interrupted publication before reply.
    The hostname credential MUST be published after the namespace environment.
    """
    acme_environment: dict[str, str] = {}
    public = config.get("public")
    image = json.loads(PUBLIC_CONFIG.read_bytes())
    system_roots = Path(image["system_ca"]).read_bytes()
    if not 1 <= len(system_roots) <= 1048576:
        raise SetupError("system trust bundle invalid")
    roots = {
        "audi-issuer-ca.pem": public["issuer_ca_pem"] if public is not None else None,
        "audi-trust.pem": public["trust_pem"] if public is not None else None,
    }
    for name, pem in roots.items():
        data = pem.encode("ascii") if pem is not None else system_roots
        path = root / name
        try:
            if read_private(path, limit=1048576) == data:
                continue
        except FileNotFoundError:
            pass
        publish(path, data)
    if public is not None:
        acme_environment.update(
            {
                "MARSHALL_FLEET_ACME_DIRECTORY": public["issuer"],
                "MARSHALL_FLEET_ACME_ISSUER_CA_FILE": "/run/credentials/marshall-inception.service/fleet-issuer-ca.pem",
                "MARSHALL_FLEET_ACME_ROOTS_FILE": "/run/credentials/marshall-inception.service/fleet-roots.pem",
                "MARSHALL_FLEET_ACME_NAMESERVERS": json.dumps(
                    [
                        {"address": peer["address"], "port": peer["port"]}
                        for peer in public["nameservers"]
                    ],
                    separators=(",", ":"),
                ),
                "MARSHALL_FLEET_ACME_ACCEPT_TERMS": "true",
            }
        )
    outputs = {
        "namespace.env": environment_file(
            {
                **acme_environment,
                "PHX_HOST": config["origins"]["control"],
                "MARSHALL_INGRESS_ZONE": config["origins"]["apps"],
            }
        ),
        "public-host": (config["origins"]["control"] + "\n").encode("ascii"),
    }
    for name, data in outputs.items():
        path = root / name
        try:
            if read_private(path) == data:
                continue
        except FileNotFoundError:
            pass
        publish(path, data)


def publication(value: Configuration, root: Path = ROOT, now: int | None = None) -> Publication:
    """@cc [owner:ghuntley,label:security] inception-child-publication-freshness
    Missing, expired or differently bound child state MUST produce an empty
    publication. State MUST match boot and environment generation and expire
    within five seconds. The response MUST echo this poll's request identity and
    report only the remaining lifetime, never a fresh five-second lifetime.
    """
    reply = Publication(
        version=value["version"],
        binding=value["binding"],
        generation=value["generation"],
        request_id=value["request_id"],
        ttl_ms=5000,
        porsche_host_key=None,
        audi_host_key=None,
        records=[],
    )
    try:
        snapshot = json.loads(read_private(root / "publication.json", REPLY_LIMIT))
    except FileNotFoundError:
        return reply
    current = time.monotonic_ns() // 1000000 if now is None else now
    if (
        not isinstance(snapshot, dict)
        or set(snapshot)
        != {
            "binding",
            "generation",
            "expires_at_ms",
            "porsche_host_key",
            "audi_host_key",
            "records",
        }
        or snapshot["binding"] != value["binding"]
        or snapshot["generation"] != value["generation"]
        or type(snapshot["expires_at_ms"]) is not int
        or not current < snapshot["expires_at_ms"] <= current + 5000
    ):
        return reply
    reply["ttl_ms"] = snapshot["expires_at_ms"] - current
    reply["porsche_host_key"] = snapshot["porsche_host_key"]
    reply["audi_host_key"] = snapshot["audi_host_key"]
    reply["records"] = snapshot["records"]
    return reply


def read_exact(connection: socket.socket, count: int, deadline: float) -> bytes:
    parts = []
    while count:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise SetupError("ingress deadline expired")
        connection.settimeout(remaining)
        part = connection.recv(count)
        if not part:
            raise SetupError("ingress frame incomplete")
        parts.append(part)
        count -= len(part)
    return b"".join(parts)


def answer(
    connection: socket.socket, peer: tuple[int, int], boot: Identity, root: Path = ROOT
) -> None:
    """@cc [owner:ghuntley,label:security] inception-ingress-vsock-peer
    Only host CID 2 may supply namespace configuration. One deadline MUST bound
    the entire framed exchange, and the declared length MUST be checked before
    reading the body. No request or exception payload may enter diagnostics.
    """
    if peer[0] != 2:
        return
    deadline = time.monotonic() + 5
    (size,) = struct.unpack("!I", read_exact(connection, 4, deadline))
    if not 1 <= size <= REQUEST_LIMIT:
        raise SetupError("ingress frame invalid")
    value = request(read_exact(connection, size, deadline), boot)
    install(value, root)
    observations.accept(value, root)
    sampled = time.monotonic_ns() // 1000000
    snapshot = publication(value, root, now=sampled)
    observations.remember(value, snapshot, root, sampled)
    reply = encode(snapshot)
    if len(reply) > REPLY_LIMIT:
        raise SetupError("ingress publication oversized")
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise SetupError("ingress deadline expired")
    connection.settimeout(remaining)
    connection.sendall(struct.pack("!I", len(reply)) + reply)


def main() -> None:
    sys.path.insert(0, sys.argv[1])
    from readiness import identity

    boot = identity(Path("/proc/cmdline").read_text())
    with socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM) as listener:
        listener.bind((socket.VMADDR_CID_ANY, PORT))
        listener.listen(4)
        while True:
            connection, peer = listener.accept()
            with (
                connection,
                contextlib.suppress(
                    OSError, ValueError, KeyError, TypeError, RecursionError, SetupError
                ),
            ):
                answer(connection, peer, boot)


if __name__ == "__main__":
    main()
