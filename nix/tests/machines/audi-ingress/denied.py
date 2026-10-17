import socket
import sys

if sys.argv[1] == "--mark":
    with socket.socket() as candidate:
        try:
            candidate.setsockopt(socket.SOL_SOCKET, 36, 0x41554449)
        except PermissionError:
            raise SystemExit(0) from None
        raise SystemExit("unprivileged process installed the ingress mark")

try:
    with socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=0.4):
        raise SystemExit("unexpected connection through the isolation boundary")
except OSError:
    pass
