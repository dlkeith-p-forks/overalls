"""Pinned Collector's explicit protobuf success; no trace bytes enter logs."""

import socket
from pathlib import Path


def main() -> None:
    path = Path("/run/overalls-otel-traces/collector.sock")
    path.unlink(missing_ok=True)
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
        listener.bind(str(path))
        path.chmod(0o660)
        listener.listen(8)
        while True:
            connection, _ = listener.accept()
            with connection:
                connection.settimeout(2)
                data = b""
                while b"\r\n\r\n" not in data and len(data) <= 4096:
                    data += connection.recv(4096)
                headers, body = data.split(b"\r\n\r\n", 1)
                lengths = [
                    int(line.split(b":", 1)[1].strip())
                    for line in headers.split(b"\r\n")
                    if line.lower().startswith(b"content-length:")
                ]
                if len(lengths) != 1 or not 0 < lengths[0] <= 262144:
                    continue
                while len(body) < lengths[0]:
                    chunk = connection.recv(4096)
                    if not chunk:
                        break
                    body += chunk
                if len(body) == lengths[0]:
                    # Collector 0.151.0 returns an explicit empty partial_success
                    # message, not a zero-length HTTP response, on complete success.
                    connection.sendall(
                        b"HTTP/1.1 200 OK\r\nContent-Type: application/x-protobuf\r\n"
                        b"Content-Length: 2\r\nConnection: close\r\n\r\n\x0a\x00"
                    )


if __name__ == "__main__":
    main()
