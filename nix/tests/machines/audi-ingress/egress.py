"""Exercise real sockets and an established flow across Customer policy replacement."""

import json
import socket
import subprocess
import sys

if sys.argv[1] == "udp-server":
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind(("11.0.0.1", 53))
        while True:
            data, address = sock.recvfrom(1024)
            sock.sendto(data, address)
elif sys.argv[1] in ("allow", "deny"):
    allowed = sys.argv[1] == "allow"
    for kind, port in ((socket.SOCK_STREAM, 8080), (socket.SOCK_DGRAM, 53)):
        with socket.socket(socket.AF_INET, kind) as sock:
            sock.settimeout(0.7)
            try:
                sock.connect(("11.0.0.1", port))
                sock.sendall(b"egress-probe")
                assert sock.recv(12) == b"egress-probe"
            except TimeoutError:
                assert not allowed
            else:
                assert allowed
elif sys.argv[1] in ("established", "established-web"):
    # Enter Customer namespace only for socket creation; restore the host
    # namespace before applying the new router policy through ip-netns.
    import os

    with open("/run/ingress.json", encoding="utf-8") as ingress_file:
        identity = json.load(ingress_file)
    host = os.open("/proc/self/ns/net", os.O_RDONLY)
    web = sys.argv[1] == "established-web"
    guest = os.open("/run/netns/" + (identity["namespace"] if web else "guest1"), os.O_RDONLY)
    try:
        os.setns(guest, 0)
        sock = socket.socket()
        sock.settimeout(1)
        if web:
            sock.setsockopt(socket.SOL_SOCKET, 36, 0x41554457)
            sock.setsockopt(
                socket.SOL_SOCKET,
                socket.SO_BINDTODEVICE,
                identity["guests"][0]["tap"].encode() + b"\0",
            )
        sock.connect((identity["guests"][0]["address"], 80) if web else ("11.0.0.1", 8080))
        sock.sendall(b"before")
        assert sock.recv(6) == b"before"
        os.setns(host, 0)
        subprocess.run(
            ["ip", "netns", "exec", identity["namespace"], "nft", "-f", "/run/ingress.nft"],
            check=True,
        )
        sock.settimeout(0.7)
        sock.sendall(b"after")
        try:
            sock.recv(5)
        except TimeoutError:
            pass
        else:
            raise AssertionError(
                "Established forbidden Customer connection survived policy replacement"
            )
        sock.close()
    finally:
        os.setns(host, 0)
        os.close(guest)
        os.close(host)
