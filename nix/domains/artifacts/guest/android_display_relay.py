#!/usr/bin/env python3
"""Bounded host-vsock to loopback-RFB relay for the Android guest."""

from __future__ import annotations

import json
import selectors
import socket
import threading
from dataclasses import dataclass
from typing import Final, TypedDict, cast


class RelayPreface(TypedDict):
    version: int
    ticket: str
    generation: int
    mode: str


@dataclass(frozen=True)
class RelayConfig:
    """Fixed guest relay limits and endpoints."""

    port: int = 5900
    rfb_port: int = 5901
    maximum_preface_bytes: int = 4096


CONFIG: Final = RelayConfig()


def _preface(payload: bytes) -> tuple[RelayPreface, bytes] | None:
    """Decode exactly one bounded JSON preface and preserve RFB bytes."""

    if not payload or len(payload) > CONFIG.maximum_preface_bytes:
        return None
    document: tuple[object, int] | None = None
    prefix_length = 0
    for index, byte in enumerate(payload):
        if byte != ord("}"):
            continue
        try:
            candidate = payload[: index + 1].decode("utf-8")
            parsed = json.JSONDecoder().raw_decode(candidate)
        except (UnicodeDecodeError, json.JSONDecodeError):
            continue
        if parsed[1] == len(candidate):
            document = parsed
            prefix_length = index + 1
            break
    if document is None:
        return None
    value, _offset = document
    if not isinstance(value, dict) or set(value) != {"version", "ticket", "generation", "mode"}:
        return None
    version = value.get("version")
    ticket = value.get("ticket")
    generation = value.get("generation")
    mode = value.get("mode")
    if (
        version != 1
        or not isinstance(ticket, str)
        or not 1 <= len(ticket.encode("utf-8")) <= 2048
        or not isinstance(generation, int)
        or isinstance(generation, bool)
        or generation <= 0
        or mode not in {"viewer", "controller"}
    ):
        return None
    return cast(RelayPreface, value), payload[prefix_length:]


def _copy(selector: selectors.BaseSelector) -> None:
    """Copy bounded socket chunks until either side closes."""

    while True:
        events = selector.select(timeout=30)
        if not events:
            return
        for key, _ in events:
            source = cast(socket.socket, key.fileobj)
            target = cast(socket.socket, key.data)
            try:
                data = source.recv(65536)
            except OSError:
                return
            if not data:
                return
            try:
                target.sendall(data)
            except OSError:
                return


def _serve(client: socket.socket) -> None:
    """Validate one host connection, then bridge it to loopback RFB."""

    client.settimeout(10)
    payload = b""
    while b"}" not in payload and len(payload) <= CONFIG.maximum_preface_bytes:
        chunk = client.recv(1024)
        if not chunk:
            return
        payload += chunk
    decoded = _preface(payload)
    if decoded is None:
        return
    _, remainder = decoded
    with socket.create_connection(("127.0.0.1", CONFIG.rfb_port), timeout=10) as rfb:
        client.settimeout(None)
        if remainder:
            rfb.sendall(remainder)
        selector = selectors.DefaultSelector()
        try:
            selector.register(client, selectors.EVENT_READ, rfb)
            selector.register(rfb, selectors.EVENT_READ, client)
            _copy(selector)
        finally:
            selector.close()


def main() -> None:
    """Serve Lilly's marked TAP ingress until systemd stops the unit."""

    # Lilly's reviewed namespace connector reaches the guest's fixed display
    # port through the placement TAP. The host nft mark is the network boundary;
    # this process adds the closed preface check before exposing loopback RFB.
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("0.0.0.0", CONFIG.port))
        listener.listen(8)
        while True:
            client, _address = listener.accept()
            threading.Thread(target=_serve_client, args=(client,), daemon=True).start()


def _serve_client(client: socket.socket) -> None:
    """Own and close one bounded relay connection."""

    with client:
        _serve(client)


if __name__ == "__main__":
    main()
