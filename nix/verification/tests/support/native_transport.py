"""Exercise the actual test-only native listener through Firecracker's UDS."""

from __future__ import annotations

import hashlib
import socket
import struct
import threading
import time
from dataclasses import dataclass
from pathlib import Path

PORT = 1099
MAX_BYTES = 1_048_576


@dataclass(frozen=True)
class Exchange:
    """Only bounded numeric outcomes and synthetic-data digests enter receipts."""

    size: int
    sha256: str


def read_line(stream: socket.socket, limit: int) -> bytes:
    """Read one bounded line without consuming the following protocol bytes."""
    line = bytearray()
    while len(line) < limit:
        value = stream.recv(1)
        if not value:
            raise RuntimeError("native probe closed before its protocol line")
        line.extend(value)
        if value == b"\n":
            return bytes(line)
    raise RuntimeError("native probe protocol line exceeded its bound")


def connect(uds: Path, expected_build_id: str) -> socket.socket:
    """Require the VMM handshake and the executing guest's exact build token."""
    if len(expected_build_id) != 64 or any(c not in "0123456789abcdef" for c in expected_build_id):
        raise ValueError("invalid expected transport identity")
    stream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        stream.settimeout(10)
        stream.connect(str(uds))
        stream.sendall(f"CONNECT {PORT}\n".encode("ascii"))
        handshake = read_line(stream, 64)
        if (
            not handshake.startswith(b"OK ")
            or not handshake[3:-1].isdigit()
            or not 0 < int(handshake[3:-1]) <= 0xFFFF_FFFF
        ):
            raise RuntimeError("invalid Firecracker vsock handshake")
        expected = f"NATIVE 1 {expected_build_id} 3 2\n".encode("ascii")
        if read_line(stream, 96) != expected:
            raise RuntimeError("native transport identity or CID mismatch")
        return stream
    except BaseException:
        stream.close()
        raise


def exchange(uds: Path, build_id: str, size: int) -> Exchange:
    """@cc [owner:ghuntley,label:verification] actual-native-credit-exchange
    Every reported exchange MUST compare all synthetic bytes from the actual
    guest listener, with concurrent host send/read so transfers larger than the
    native credit window exercise flow control. Unix half-close MUST NOT replace
    the explicit length/ack framing, because Firecracker maps EOF to full close.
    """
    if not 0 <= size <= MAX_BYTES:
        raise ValueError("invalid bounded native probe size")
    payload = (bytes(range(256)) * ((size + 255) // 256))[:size]
    with connect(uds, build_id) as stream:
        stream.sendall(struct.pack("<I", size))
        failures: list[OSError] = []

        def send() -> None:
            try:
                stream.sendall(payload)
            except OSError as error:
                failures.append(error)

        writer = threading.Thread(target=send, daemon=True)
        writer.start()
        received = bytearray()
        try:
            while len(received) < size:
                value = stream.recv(min(32_768, size - len(received)))
                if not value:
                    raise RuntimeError("native probe truncated its echo")
                received.extend(value)
            writer.join(10)
            if writer.is_alive() or failures or received != payload:
                raise RuntimeError("native credit exchange failed")
            stream.sendall(b"\xa5")
            if stream.recv(1):
                raise RuntimeError("native probe emitted excess bytes")
        finally:
            if writer.is_alive():
                stream.shutdown(socket.SHUT_RDWR)
                writer.join(10)
    return Exchange(size=size, sha256=hashlib.sha256(received).hexdigest())


def exercise(uds: Path, build_id: str) -> list[Exchange]:
    """Refuse malformed/disconnected histories, then cross both credit windows."""
    with connect(uds, build_id) as stream:
        stream.sendall(struct.pack("<I", MAX_BYTES + 1))
        if stream.recv(1):
            raise RuntimeError("native probe accepted an oversized history")
    with connect(uds, build_id) as stream:
        stream.sendall(struct.pack("<I", 32) + b"partial")
    return [
        exchange(uds, build_id, size)
        for size in (0, 1, 44, 4096, 65_535, 65_536, 65_537, 262_144, MAX_BYTES)
    ]


RESET_PORT = 1101


def reset_race(uds: Path, serial: Path) -> None:
    """Stream into the fault probe until its racing resets fence the transport.

    The guest reports its verdict only on the console. Afterwards the ordinary
    listener must be unreachable because the device stopped.
    """
    stream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        stream.settimeout(10)
        stream.connect(str(uds))
        stream.sendall(f"CONNECT {RESET_PORT}\n".encode("ascii"))
        if not read_line(stream, 64).startswith(b"OK "):
            raise RuntimeError("reset-race listener handshake failed")
        chunk = bytes(65_536)
        deadline = time.monotonic() + 15
        try:
            while time.monotonic() < deadline:
                stream.sendall(chunk)
        except OSError:
            pass
    finally:
        stream.close()
    deadline = time.monotonic() + 20
    while True:
        text = serial.read_bytes().decode("utf-8", "replace")
        if "OVFB-RESET-RACE pass" in text:
            break
        if "OVFB-RESET-RACE fail" in text or time.monotonic() >= deadline:
            raise RuntimeError("guest did not report a fenced reset race")
        time.sleep(0.5)
    probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        probe.settimeout(5)
        probe.connect(str(uds))
        probe.sendall(f"CONNECT {PORT}\n".encode("ascii"))
        try:
            reply = read_line(probe, 64)
        except (OSError, RuntimeError):
            return
        if reply.startswith(b"OK "):
            raise RuntimeError("fenced transport still accepted a connection")
    finally:
        probe.close()
