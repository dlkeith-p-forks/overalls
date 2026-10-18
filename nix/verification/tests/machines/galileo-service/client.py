"""Cross-machine Galileo probes using only the Python standard library."""

import base64
import concurrent.futures
import hashlib
import http.client
import json
import socket
import ssl
import sys
import time
from pathlib import Path

HOST = "esample.integration.internal"


def fault_events() -> list[tuple[str, float]]:
    path = Path("/run/galileo-fixture/fault-events.jsonl")
    events: list[tuple[str, float]] = []
    for line in path.read_text().splitlines() if path.exists() else []:
        value: object = json.loads(line)
        if not isinstance(value, dict):
            raise ValueError("invalid event")
        event, timestamp = value.get("event"), value.get("time")
        if not isinstance(event, str) or not isinstance(timestamp, (float, int)):
            raise ValueError("invalid event fields")
        events.append((event, float(timestamp)))
    return events


def native_active() -> int:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as peer:
        peer.settimeout(1)
        peer.connect("/run/galileo/proxy.sock")
        peer.sendall(b"GET /metrics HTTP/1.1\r\nHost: galileo\r\nConnection: close\r\n\r\n")
        response = http.client.HTTPResponse(peer)
        response.begin()
        value: object = json.loads(response.read())
    if response.status != 200 or not isinstance(value, dict):
        raise ValueError("invalid metrics")
    gauges = value.get("gauges")
    if not isinstance(gauges, dict):
        raise ValueError("invalid gauges")
    active = gauges.get("galileo_active_requests")
    if not isinstance(active, int) or isinstance(active, bool) or active < 0:
        raise ValueError("invalid active count")
    return active


def lease_blocked_upload(terminal: str, *, partial: bool = False) -> None:
    """@cc [owner:ghuntley,label:verification] native-upload-lease-refusal
    A refused renewal MUST close the single blocked native upload and return
    its frontend response within five seconds; no late dispatch may appear.
    This isolates packaged Galileo/Bandit from Audi and real Marshall policy.
    """
    root = Path("/run/galileo-fixture")
    case = "response" if partial else "upload"
    path = "lease-partial-response" if partial else "lease-blocked-upload"
    method, size, body = ("GET", 0, "") if partial else ("POST", 100, "x")
    if terminal not in {"refused", "invalid", "blocked"}:
        raise ValueError("unknown renewal failure")
    (root / "fault-events.jsonl").unlink(missing_ok=True)
    binding = base64.urlsafe_b64encode(Path("/etc/galileo-binding.json").read_bytes())
    encoded = binding.decode().rstrip("=")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(5)
        client.connect("/run/galileo/proxy.sock")
        client.sendall(
            (
                f"{method} /api/v3/{path} HTTP/1.1\r\nHost: {HOST}\r\n"
                f"x-overalls-binding: {encoded}\r\nContent-Length: {size}\r\n"
                f"Connection: close\r\n\r\n{body}"
            ).encode()
        )
        deadline = time.monotonic() + 5
        while not all(
            any(event == expected for event, _ in fault_events())
            for expected in (case + "_dispatched", "renewal_accepted")
        ):
            if time.monotonic() >= deadline:
                raise RuntimeError("origin dispatch was not observed")
            time.sleep(0.02)
        try:
            (root / "renewal-mode").write_text(terminal)
            response = b""
            while chunk := client.recv(65_536):
                response += chunk
            returned_at = time.monotonic()
            if partial and (not response.startswith(b"HTTP/1.1 200") or b"prefix" not in response):
                raise RuntimeError("partial response was not delivered before cancellation")
            if not partial and response and not response.startswith(b"HTTP/1.1 502"):
                raise RuntimeError("cancelled upload did not return a gateway refusal")
            deadline = returned_at + 5
            while not any(event == case + "_closed" for event, _ in fault_events()):
                if time.monotonic() >= deadline:
                    raise RuntimeError("origin upload did not close")
                time.sleep(0.02)
            events = fault_events()
            refused_at = next(
                at
                for event, at in events
                if event in {"renewal_refused", "renewal_invalid", "renewal_stalled"}
            )
            closed_at = next(at for event, at in events if event == case + "_closed")
            if not 0 <= closed_at - refused_at <= 5 or returned_at - refused_at > 5:
                raise RuntimeError("lease cleanup exceeded five seconds")
            while native_active() != 0:
                if time.monotonic() - refused_at >= 5:
                    raise RuntimeError("active requests survived lease cancellation")
                time.sleep(0.02)
            if time.monotonic() - refused_at > 5:
                raise RuntimeError("cleanup counters exceeded five seconds")
            time.sleep(2)
            if sum(event == case + "_dispatched" for event, _ in fault_events()) != 1:
                raise RuntimeError("upload was replayed")
            if sum(event == "origin_tls_accepted" for event, _ in fault_events()) != 1:
                raise RuntimeError("origin TLS was retried")
            print(json.dumps({"origin_close_seconds": closed_at - refused_at}))
        finally:
            (root / "renewal-mode").unlink(missing_ok=True)


def context(ca_file: str) -> ssl.SSLContext:
    return ssl.create_default_context(cafile=ca_file)


def request(ca_file: str, path: str = "/api/v3/load") -> dict[str, object]:
    connection = http.client.HTTPSConnection(HOST, 443, context=context(ca_file), timeout=10)
    try:
        connection.request("GET", path)
        response = connection.getresponse()
        body = response.read()
        if response.status != 200:
            raise RuntimeError(f"unexpected status {response.status}")
        value: object = json.loads(body)
        if not isinstance(value, dict) or value.get("path") != path.removeprefix("/api/v3"):
            raise RuntimeError("unexpected response")
        return value
    finally:
        connection.close()


def sustained(ca_file: str, count: int) -> None:
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(lambda _: request(ca_file), range(count)))
    if len(results) != count:
        raise RuntimeError("incomplete request set")


def stalled_source(ca_file: str) -> None:
    address = socket.gethostbyname(HOST)
    started = time.monotonic()
    with (
        socket.create_connection((address, 443), timeout=5) as raw,
        context(ca_file).wrap_socket(raw, server_hostname=HOST) as client,
    ):
        client.settimeout(16)
        client.sendall(
            (
                f"POST /api/v3/stalled-source HTTP/1.1\r\nHost: {HOST}\r\n"
                "Content-Type: application/octet-stream\r\nContent-Length: 100\r\n"
                "Connection: close\r\n\r\nx"
            ).encode()
        )
        while client.recv(65_536):
            pass
    elapsed = time.monotonic() - started
    if not 8 <= elapsed <= 16:
        raise RuntimeError(f"source deadline was not bounded: {elapsed:.3f}s")
    print(json.dumps({"elapsed_seconds": elapsed}))


def upload(ca_file: str, payload_file: str) -> None:
    payload = Path(payload_file).read_bytes()
    connection = http.client.HTTPSConnection(HOST, 443, context=context(ca_file), timeout=15)
    try:
        connection.request(
            "POST",
            "/api/v3/upload",
            body=payload,
            headers={"content-type": "application/octet-stream"},
        )
        response = connection.getresponse()
        value: object = json.loads(response.read())
        expected = hashlib.sha256(payload).hexdigest()
        if (
            response.status != 200
            or not isinstance(value, dict)
            or value.get("body_bytes") != len(payload)
            or value.get("body_sha256") != expected
        ):
            raise RuntimeError("upload integrity failure")
    finally:
        connection.close()


def main() -> None:
    action, ca_file, *arguments = sys.argv[1:]
    if action == "sustained":
        sustained(ca_file, int(arguments[0]))
    elif action == "stalled-source":
        stalled_source(ca_file)
    elif action == "upload":
        upload(ca_file, arguments[0])
    elif action == "lease-blocked-upload":
        lease_blocked_upload(arguments[0])
    elif action == "lease-partial-response":
        lease_blocked_upload(arguments[0], partial=True)
    else:
        raise ValueError("unknown action")


if __name__ == "__main__":
    main()
