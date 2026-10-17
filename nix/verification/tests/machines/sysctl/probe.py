"""Inspect congestion control on connected sockets between isolated test nodes."""

import socket
import sys


def algorithm(connection: socket.socket) -> bytes:
    return connection.getsockopt(socket.IPPROTO_TCP, socket.TCP_CONGESTION, 16).rstrip(b"\0")


if sys.argv[1] == "server":
    with socket.create_server(("0.0.0.0", 8123)) as listener:
        while True:
            connection, _ = listener.accept()
            with connection:
                connection.settimeout(10)
                connection.sendall(algorithm(connection) + b"\n")
else:
    with socket.create_connection((sys.argv[2], 8123), timeout=10) as connection:
        assert algorithm(connection).decode() == sys.argv[3]
        with connection.makefile("rb") as stream:
            assert stream.readline(32).strip().decode() == sys.argv[4]
