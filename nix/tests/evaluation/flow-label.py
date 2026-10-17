"""Run inside an isolated network namespace; tests native label lookup, not Firecracker."""

import socket
import subprocess
import sys

helper, nft = sys.argv[1:]
table = "brady_flow_fixture"


def rules(program: str) -> None:
    subprocess.run(
        [nft, "-f", "-"], input=program, text=True, check=True, capture_output=True, timeout=3
    )


def lookup(client: socket.socket, expected: str | None) -> None:
    source, sport = client.getsockname()
    target, dport = client.getpeername()
    result = subprocess.run(
        [helper, source, str(sport), target, str(dport)], capture_output=True, timeout=3
    )
    assert result.stderr == b""
    if expected is None:
        assert result.returncode != 0 and result.stdout == b""
    else:
        assert result.returncode == 0 and result.stdout == (expected + "\n").encode()


def connect(listener: socket.socket) -> tuple[socket.socket, socket.socket]:
    client = socket.create_connection(listener.getsockname(), timeout=2)
    server, _ = listener.accept()
    return client, server


# @cc [owner:ghuntley,label:verification] native-label-query-scope
# This fixture MUST use real TCP connections and the compiled helper, refuse to
# adopt an existing table, and remove only its own table and sockets. It MUST NOT
# claim guest TAP interception or VM-owner attribution from loopback evidence.
rules(f"create table inet {table}\n")
sockets = []
try:
    listener = socket.socket()
    sockets.append(listener)
    listener.settimeout(2)
    listener.bind(("127.0.0.1", 0))
    listener.listen(4)
    rules(
        f"add chain inet {table} identity {{ type filter hook output priority -151; policy accept; }}\n"
    )

    def assign(bits: str) -> None:
        rules(
            f"flush chain inet {table} identity\n"
            f"add rule inet {table} identity ct direction original ct state new "
            f"ct status & confirmed == 0 tcp flags & (fin | syn | rst | ack) == syn "
            f"ct label == (0 & 1) ct label set {bits}\n"
        )

    assign("1 | 3 | 5 | 127")
    first, first_server = connect(listener)
    sockets.extend([first, first_server])
    old = "8000000000000000000000000000002a"
    lookup(first, old)

    assign("2 | 64 | 127")
    second, second_server = connect(listener)
    sockets.extend([second, second_server])
    lookup(second, "80000000000000010000000000000004")
    first.sendall(b"x")
    assert first_server.recv(1) == b"x"
    lookup(first, old)

    rules(f"flush chain inet {table} identity\n")
    third, third_server = connect(listener)
    sockets.extend([third, third_server])
    lookup(third, None)
    assign("4 | 127")
    third.sendall(b"x")
    assert third_server.recv(1) == b"x"
    lookup(third, None)

    for args in [
        ["127.0.0.1", "0", "127.0.0.1", "443"],
        ["127.0.0.1", "01", "127.0.0.1", "443"],
        ["127.000.0.1", "1", "127.0.0.1", "443"],
        ["127.0.0.1", "1", "127.0.0.1", "65536"],
        ["127.0.0.1", "1", "127.0.0.1", "1"],
    ]:
        result = subprocess.run([helper, *args], capture_output=True, timeout=3)
        assert result.returncode != 0 and result.stdout == result.stderr == b""
finally:
    for connection in sockets:
        connection.close()
    rules(f"delete table inet {table}\n")

print("Native exact-tuple lookup, unchanged existing labels and unlabeled-flow refusal passed.")
