"""Guest boot readiness; no execution, transfer or cleanup authority."""

import contextlib
import ipaddress
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
from collections.abc import Callable
from typing import TypedDict

PORT = 1024
MAXIMUM = 9_223_372_036_854_775_807
UUID = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}")


class Identity(TypedDict):
    placement_id: str
    execution_epoch: int
    boot_challenge: str
    address: str
    gateway: str


def identity(cmdline: str) -> Identity:
    """@cc [owner:ghuntley,label:security] guest-readiness-boot-binding
    Boot identity MUST reject missing, duplicate or malformed placement, epoch,
    challenge and address parameters. Values MUST come from this boot's command
    line, never from a request or a portable disk's persisted readiness marker.
    """
    names = {"lilly.placement", "lilly.execution_epoch", "lilly.boot_challenge", "lilly.ipv4"}
    fields: dict[str, str] = {}
    if len(cmdline) > 4096:
        raise ValueError("invalid boot identity")
    for parameter in cmdline.split():
        name, separator, value = parameter.partition("=")
        if name in names:
            if not separator or name in fields:
                raise ValueError("invalid boot identity")
            fields[name] = value
    if fields.keys() != names:
        raise ValueError("invalid boot identity")
    placement = fields["lilly.placement"]
    epoch = fields["lilly.execution_epoch"]
    challenge = fields["lilly.boot_challenge"]
    address = fields["lilly.ipv4"]
    if not UUID.fullmatch(placement) or not re.fullmatch(r"[1-9][0-9]{0,18}", epoch):
        raise ValueError("invalid boot identity")
    if int(epoch) > MAXIMUM or not re.fullmatch(r"[0-9a-f]{64}", challenge):
        raise ValueError("invalid boot identity")
    octets = ipaddress.IPv4Address(address).packed
    slot = octets[2] * 256 + octets[3]
    if octets[0] != 10 or octets[1] not in (10, 20, 30, 40) or not 2 <= slot <= 65534:
        raise ValueError("invalid boot identity")
    return Identity(
        placement_id=placement,
        execution_epoch=int(epoch),
        boot_challenge=challenge,
        address=address,
        gateway=f"10.{octets[1]}.0.1",
    )


def command(arguments: list[str]) -> bytes:
    # Keep command output off the journal and bound what is read into memory.
    with tempfile.TemporaryFile() as output:
        subprocess.run(
            arguments,
            stdin=subprocess.DEVNULL,
            stdout=output,
            stderr=subprocess.DEVNULL,
            timeout=2,
            check=True,
        )
        output.seek(0)
        body = output.read(65537)
        if len(body) > 65536:
            raise ValueError("oversized probe result")
        return body


def network_ready(boot: Identity, addresses: object, routes: object) -> bool:
    def configured(interface: dict[str, object]) -> bool:
        flags = interface.get("flags", [])
        entries = interface.get("addr_info", [])
        return (
            interface.get("ifname") == "eth0"
            and isinstance(flags, list)
            and "UP" in flags
            and isinstance(entries, list)
            and any(
                isinstance(entry, dict)
                and entry.get("family") == "inet"
                and entry.get("local") == boot["address"]
                and entry.get("prefixlen") == 32
                for entry in entries
            )
        )

    expected_address = isinstance(addresses, list) and any(
        isinstance(interface, dict) and configured(interface) for interface in addresses
    )
    gateway = isinstance(routes, list) and any(
        isinstance(route, dict)
        and route.get("dev") == "eth0"
        and route.get("scope") == "link"
        and route.get("dst") in (boot["gateway"], boot["gateway"] + "/32")
        for route in routes
    )
    default = isinstance(routes, list) and any(
        isinstance(route, dict)
        and route.get("dev") == "eth0"
        and route.get("dst") == "default"
        and route.get("gateway") == boot["gateway"]
        for route in routes
    )
    return expected_address and gateway and default


def writable_root(directory: str = "/") -> None:
    # Create on the root filesystem itself, not /run or a private temporary mount.
    descriptor, name = tempfile.mkstemp(prefix=".lilly-readiness-", dir=directory)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(b"ready\n")
            output.flush()
            os.fsync(output.fileno())
    finally:
        os.unlink(name)


def ready(
    boot: Identity,
    systemctl: str,
    ip: str,
) -> bool:
    """@cc [owner:ghuntley,label:recovery] guest-readiness-live-probes
    A readiness response MUST require active multi-user and guest-network units,
    the configured /32 address and gateway routes, and a successful root write
    and fsync. Missing or failed probes MUST NOT produce readiness evidence.
    """
    try:
        command([systemctl, "is-active", "--quiet", "multi-user.target"])
        command([systemctl, "is-active", "--quiet", "lilly-network.service"])
        required = os.environ.get("LILLY_REQUIRED_UNITS", "").split()
        if len(required) > 16 or any(
            not re.fullmatch(r"[a-zA-Z0-9_-]+\.service", unit) for unit in required
        ):
            return False
        for unit in required:
            command([systemctl, "is-active", "--quiet", unit])
        ssh_unit = os.environ.get("LILLY_SSH_UNIT", "")
        if ssh_unit:
            if not re.fullmatch(r"(?:ssh|sshd)\.service", ssh_unit):
                return False
            command([systemctl, "is-active", "--quiet", ssh_unit])
        addresses: object = json.loads(command([ip, "-j", "-4", "address", "show", "dev", "eth0"]))
        # A device-filtered iproute2 query omits dev from each JSON route.
        # Retain it here so network_ready can verify interface ownership itself.
        routes: object = json.loads(command([ip, "-j", "-4", "route", "show"]))
        if not network_ready(boot, addresses, routes):
            return False
        writable_root()
        return True
    except (OSError, subprocess.SubprocessError, ValueError, TypeError, AttributeError):
        return False


def response(boot: Identity, boot_id: str) -> bytes:
    if not UUID.fullmatch(boot_id):
        raise ValueError("invalid kernel boot identity")
    message = {key: boot[key] for key in ("placement_id", "execution_epoch", "boot_challenge")}
    message.update(version=1, boot_id=boot_id, state="ready")
    return json.dumps(message, separators=(",", ":")).encode("ascii") + b"\n"


def answer(
    connection: socket.socket,
    peer: tuple[int, int],
    boot: Identity,
    boot_id: str,
    probe: Callable[[], bool],
) -> None:
    """@cc [owner:ghuntley,label:security] guest-readiness-host-only
    Only host CID 2 may receive a response, after live probes succeed. The service
    MUST NOT ingest caller identity or commands. Responses MUST bind this boot's
    placement, epoch, challenge and kernel boot ID, with bounded socket writes.
    """
    connection.settimeout(2)
    if peer[0] == 2 and probe():
        connection.sendall(response(boot, boot_id))


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("readiness tools not configured")
    try:
        with open("/proc/cmdline", encoding="ascii") as source:
            boot = identity(source.read(4097))
        with open("/proc/sys/kernel/random/boot_id", encoding="ascii") as source:
            boot_id = source.read(64).strip()
        response(boot, boot_id)
    except (OSError, ValueError):
        raise SystemExit("invalid readiness boot configuration") from None
    systemctl, ip = sys.argv[1:]
    with socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM) as listener:
        listener.bind((socket.VMADDR_CID_ANY, PORT))
        listener.listen(4)
        while True:
            connection, peer = listener.accept()
            with connection, contextlib.suppress(OSError, ValueError):
                answer(connection, peer, boot, boot_id, lambda: ready(boot, systemctl, ip))


if __name__ == "__main__":
    main()
