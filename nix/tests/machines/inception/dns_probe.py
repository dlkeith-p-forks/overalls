"""Bounded native DNS replica liveness; proof propagation is checked separately."""

import ipaddress
import json
import secrets
import socket
import struct
import sys
from pathlib import Path


# @cc [owner:ghuntley,label:verification] inception-dns-native-local-proof
# The fixture MUST query the selected actual IPv4 DNS process over UDP and TCP,
# require its assigned zone and exact configured NS answers, and bound replies.
# It MUST emit no configuration contents or claim DNS-01 proof propagation.
def check(path: str = "/run/inception/dns.json", address: str = "127.0.0.1") -> None:
    config: dict[str, object] = json.loads(Path(path).read_bytes())
    address = str(ipaddress.IPv4Address(address))

    def name(value: str) -> bytes:
        return (
            b"".join(bytes([len(part)]) + part.encode("ascii") for part in value.split(".")) + b"\0"
        )

    zone = name(config["zone"])
    identifier = secrets.randbelow(65536)
    query = struct.pack("!6H", identifier, 0, 1, 0, 0, 0) + zone + struct.pack("!HH", 2, 1)
    expected = {name(value) for value in config["nameservers"]}
    for transport in [socket.SOCK_DGRAM, socket.SOCK_STREAM]:
        with socket.socket(socket.AF_INET, transport) as peer:
            peer.settimeout(2)
            peer.connect((address, 53))
            peer.sendall(
                (struct.pack("!H", len(query)) if transport == socket.SOCK_STREAM else b"") + query
            )
            if transport == socket.SOCK_DGRAM:
                reply = peer.recv(4097)
                assert len(reply) <= 4096
            else:
                header = b""
                while len(header) < 2:
                    chunk = peer.recv(2 - len(header))
                    assert chunk
                    header += chunk
                (length,) = struct.unpack("!H", header)
                assert 12 <= length <= 4096
                reply = b""
                while len(reply) < length:
                    chunk = peer.recv(length - len(reply))
                    assert chunk
                    reply += chunk
            tid, flags, questions, answers, authority, additional = struct.unpack("!6H", reply[:12])
            assert (tid, questions, answers, authority, additional) == (
                identifier,
                1,
                len(expected),
                0,
                0,
            )
            assert flags & 0xFE0F == 0x8400
            assert reply[12 : len(query)] == query[12:]
            offset = len(query)
            observed = set()
            for _ in range(answers):
                assert reply[offset : offset + len(zone)] == zone
                offset += len(zone)
                kind, cls, ttl, size = struct.unpack("!HHIH", reply[offset : offset + 10])
                offset += 10
                assert kind == 2 and cls == 1 and ttl > 0
                observed.add(reply[offset : offset + size])
                offset += size
            assert observed == expected and offset == len(reply)


try:
    check(*sys.argv[1:])
except Exception:
    raise SystemExit("DNS probe failed; configuration and response withheld") from None
