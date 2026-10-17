"""Native fixture: an observer refusal cannot change the producer's result."""

import json
import socket
import sys
import time
from pathlib import Path


def send(trace_socket: str, body: bytes) -> str:
    status = "unavailable"
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(1)
            connection.connect(trace_socket)
            connection.sendall(
                b"POST /v1/traces HTTP/1.1\r\nHost: localhost\r\n"
                b"Content-Type: application/x-protobuf\r\nContent-Length: "
                + str(len(body)).encode("ascii")
                + b"\r\nConnection: close\r\n\r\n"
                + body
            )
            reply = b""
            while b"\r\n" not in reply and len(reply) < 4096:
                chunk = connection.recv(4096)
                if not chunk:
                    break
                reply += chunk
            fields = reply.split(b"\r\n", 1)[0].split()
            if len(fields) >= 2 and fields[1].isdigit():
                status = fields[1].decode("ascii")
    except OSError:
        pass
    return status


def stress(trace_socket: str) -> None:
    body = bytes.fromhex(Path("/etc/trace-batch.hex").read_text(encoding="ascii").strip())
    accepted = 0
    refused = 0
    durations: list[int] = []
    for index in range(256):
        # Exact-size replacement changes reviewed synthetic correlation only;
        # span creation and protobuf framing come from the official SDK fixture.
        batch = body.replace(
            b"11111111-1111-4111-8111-111111111111",
            f"22222222-2222-4222-8222-{index:012x}".encode("ascii"),
        )
        before = time.monotonic_ns()
        status = send(trace_socket, batch)
        durations.append((time.monotonic_ns() - before) // 1000)
        if status == "200":
            accepted += 1
        elif status == "429":
            refused += 1
        else:
            raise RuntimeError(f"unexpected closed status {status}")
    result = {
        "accepted": accepted,
        "refused": refused,
        "spans_per_batch": 128,
        "encoded_bytes": len(body),
        "total_us": sum(durations),
        "first_32_max_us": max(durations[:32]),
        "last_32_max_us": max(durations[-32:]),
    }
    Path("/run/trace-results/stress.json").write_text(json.dumps(result), encoding="ascii")


def main() -> None:
    if len(sys.argv) != 5:
        raise SystemExit(2)
    trace_socket, fixture, result, work = sys.argv[1:]
    body = bytes.fromhex(Path(fixture).read_text(encoding="ascii").strip())
    if Path("/run/trace-results/stress").exists() and result.endswith("accepted"):
        stress(trace_socket)
        return
    if Path("/run/trace-results/malformed").exists() and result.endswith("accepted"):
        body = b"invalid protobuf"
    status = send(trace_socket, body)
    Path(result).write_text(status, encoding="ascii")
    Path(work).write_text("completed", encoding="ascii")


if __name__ == "__main__":
    main()
