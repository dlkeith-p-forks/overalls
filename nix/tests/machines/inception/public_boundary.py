"""Exercise the real nested public listener without exposing response contents."""

import http.client
import ipaddress
import re
import socket
import ssl
import sys
import time


def check(hostname: str, address: str, roots: str) -> None:
    """@cc [owner:ghuntley,label:verification;security] inception-public-fleet-boundary
    Requests MUST traverse physical Audi with verified inner TLS and explicit
    IPv4 transport. Every reserved machine prefix MUST reject malformed bodies
    and forged forwarding metadata with an uncached 404 and no session or
    redirect. Response bodies and credentials MUST remain out of diagnostics.
    """
    if not re.fullmatch(r"[a-z0-9-]+(?:\.[a-z0-9-]+)+", hostname):
        raise ValueError("invalid fixture hostname")
    address = str(ipaddress.IPv4Address(address))
    context = ssl.create_default_context(cafile=roots)
    deadline = time.monotonic() + 90
    for service in ["provisioners", "ssh", "ziggy", "audi", "fleet"]:
        for method in ["GET", "POST"]:
            for suffix in ["/v1/identity", "/v999/unknown"]:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("fixture deadline")
                with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as raw:
                    raw.settimeout(min(5, remaining))
                    raw.connect((address, 443))
                    with context.wrap_socket(raw, server_hostname=hostname) as peer:
                        request = (
                            f"{method} /api/{service}{suffix} HTTP/1.1\r\n"
                            f"Host: {hostname}\r\n"
                            "Authorization: Bearer synthetic-boundary-probe\r\n"
                            "X-Forwarded-For: 127.0.0.1\r\n"
                            "X-Forwarded-Proto: https\r\n"
                            "Content-Type: application/json\r\n"
                            "Content-Length: 8\r\nConnection: close\r\n\r\nnot-json"
                        )
                        peer.sendall(request.encode("ascii"))
                        response = http.client.HTTPResponse(peer)
                        response.begin()
                        assert response.status == 404
                        assert response.getheader("cache-control") == "no-store"
                        assert response.getheader("set-cookie") is None
                        assert response.getheader("location") is None
                        assert response.read(128) == b"unavailable\n"


if __name__ == "__main__":
    try:
        check(*sys.argv[1:])
    except Exception:
        raise SystemExit("Inception public fleet boundary failed; response withheld") from None
