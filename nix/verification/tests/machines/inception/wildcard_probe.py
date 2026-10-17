"""Verify the child Audi listener presents only its own apps-zone wildcard."""

from __future__ import annotations

import hashlib
import ipaddress
import json
import re
import socket
import ssl
import sys
from pathlib import Path


def fields(value: object) -> dict[str, object]:
    if not isinstance(value, dict):
        raise ValueError("fixture configuration invalid")
    result: dict[str, object] = {}
    for key, item in value.items():
        if not isinstance(key, str):
            raise ValueError("fixture configuration invalid")
        result[key] = item
    return result


def main() -> None:
    """@cc [owner:ghuntley,label:verification;security] inception-child-wildcard-handshake
    A real child Audi listener MUST present the same CA-valid certificate for
    distinct one-label workload names under its bound apps zone and after
    Marshall and Audi restart. Its certificate MUST NOT authenticate the
    independent control origin. No private key or peer certificate bytes may
    be printed by this machine-test assertion.
    """
    namespace = fields(json.loads(Path("/run/inception/ingress.json").read_bytes()))
    origins = fields(namespace.get("origins"))
    audi = fields(json.loads(Path("/run/inception/audi.json").read_bytes()))
    apps = origins.get("apps")
    control = origins.get("control")
    bind = audi.get("bind")
    if (
        not isinstance(apps, str)
        or not isinstance(control, str)
        or not isinstance(bind, str)
        or not 1 <= len(apps) <= 253
        or not apps.startswith("apps.")
        or any(
            re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", part) is None
            for part in apps.split(".")
        )
        or control != "control." + apps.removeprefix("apps.")
        or str(ipaddress.IPv4Address(bind)) != bind
    ):
        raise ValueError("fixture configuration invalid")
    context = ssl.create_default_context(cafile="/run/inception/audi-trust.pem")
    certificates: list[bytes] = []
    for marker in ["1", "2"]:
        workload = "vm-" + marker * 32 + "." + apps
        with (
            socket.create_connection((bind, 443), timeout=3) as raw,
            context.wrap_socket(raw, server_hostname=workload) as secure,
        ):
            certificate = secure.getpeercert(binary_form=True)
            if not isinstance(certificate, bytes) or not certificate:
                raise RuntimeError("child wildcard unavailable")
            certificates.append(certificate)
    if certificates[0] != certificates[1]:
        raise RuntimeError("child wildcard differs across workload names")
    digest = hashlib.sha256(certificates[0]).hexdigest()
    baseline = Path("/run/inception-wildcard-digest")
    if sys.argv[1:] == ["--record"]:
        baseline.write_text(digest)
    elif sys.argv[1:] == ["--verify"]:
        if baseline.read_text() != digest:
            raise RuntimeError("child wildcard changed after restart")
    else:
        raise ValueError("fixture action invalid")
    try:
        with (
            socket.create_connection((bind, 443), timeout=3) as raw,
            context.wrap_socket(raw, server_hostname=control),
        ):
            pass
    except ssl.SSLError:
        return
    raise RuntimeError("child wildcard crossed control origin")


if __name__ == "__main__":
    main()
