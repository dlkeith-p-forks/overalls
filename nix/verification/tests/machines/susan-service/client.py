"""Mila and Marshall stand-ins: issue push keys and send signed pokes to Susan."""

import base64
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ed25519

root = Path("/run/susan-fixture")
origin = os.environ.get("SUSAN_ORIGIN", "http://127.0.0.1:4100")


def b64(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).decode().rstrip("=")


def remember(values: list[str]) -> None:
    path = root / "sensitive.json"
    current: list[str] = json.loads(path.read_text()) if path.exists() else []
    path.write_text(json.dumps(sorted(set(current + values))))
    path.chmod(0o600)


def install(name: str) -> ed25519.Ed25519PrivateKey:
    path = root / f"install-{name}.key"
    if not path.exists():
        path.write_bytes(os.urandom(32))
        path.chmod(0o600)
    return ed25519.Ed25519PrivateKey.from_private_bytes(path.read_bytes())


def post(path: str, body: bytes, headers: dict[str, str]) -> tuple[int, dict[str, str], bytes]:
    request = urllib.request.Request(
        origin + path,
        data=body,
        method="POST",
        headers={"content-type": "application/json", **headers},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.status, dict(response.headers), response.read()
    except urllib.error.HTTPError as error:
        return error.code, dict(error.headers), error.read()


def issue(name: str, provider: str, source: str, reuse: str | None) -> None:
    if reuse is not None:
        token = str(json.loads((root / f"key-{reuse}.json").read_text())["token"])
    elif provider == "apns":
        token = os.urandom(32).hex()
    else:
        token = "fcm:" + b64(os.urandom(96))
    body = {
        "provider": provider,
        "token": token,
        "app_id": "dev.overalls.mila",
        "environment": "production",
        "deployment": "control.example.test",
    }
    status, _, response = post(
        "/api/push/v1/keys", json.dumps(body).encode(), {"x-forwarded-for": source}
    )
    if status != 201:
        print(json.dumps({"status": status}))
        return
    issued = json.loads(response)
    (root / f"key-{name}.json").write_text(json.dumps({**issued, "token": token}))
    remember([token, issued["push_key"], source])
    print(json.dumps({"status": status, "key_id": issued["key_id"]}))


def poke(name: str, delivery: str, source: str, installer: str, replay: str | None) -> None:
    if replay is not None and (root / replay).exists():
        saved = json.loads((root / replay).read_text())
        body, signature, public = saved["body"].encode(), saved["signature"], saved["public"]
    else:
        key = json.loads((root / f"key-{name}.json").read_text())
        forged = installer == "forged"
        signer = install("a" if forged else installer)
        ciphertext = b64(os.urandom(150))
        nonce = b64(os.urandom(16))
        document = {
            "push_key": key["push_key"],
            "deployment": "control.example.test",
            "ciphertext": ciphertext,
            "kind": "needs_input",
            # OverallsProtocol.SusanPoke: 22 base64url characters per install.
            "collapse_id": b64(hashlib.sha256(b"thread-1").digest())[:22],
            "delivery_id": delivery if delivery != "new" else str(uuid.uuid4()),
            "nonce": nonce,
            "issued_at": int(time.time()),
        }
        # The canonical body: members in ascending order, no whitespace.
        body = json.dumps(document, separators=(",", ":"), sort_keys=True).encode()
        signed = b"overalls-susan-poke-v1\x00" + body
        signature = b64((ed25519.Ed25519PrivateKey.generate() if forged else signer).sign(signed))
        public = b64(
            signer.public_key().public_bytes(
                serialization.Encoding.Raw, serialization.PublicFormat.Raw
            )
        )
        remember([ciphertext, nonce, source])
        if replay is not None:
            (root / replay).write_text(
                json.dumps({"body": body.decode(), "signature": signature, "public": public})
            )
    status, headers, answer = post(
        "/api/push/v1/poke",
        body,
        {
            "overalls-install-key": public,
            "overalls-install-signature": signature,
            "x-forwarded-for": source,
        },
    )
    print(
        json.dumps(
            {
                "status": status,
                "retry_after": headers.get("retry-after") or headers.get("Retry-After"),
                "body": answer.decode(),
            }
        )
    )


def malformed(source: str) -> None:
    status, _, answer = post("/api/push/v1/poke", b'{"push_key":1}', {"x-forwarded-for": source})
    print(json.dumps({"status": status, "body": answer.decode()}))


def fingerprint(installer: str) -> None:
    import hashlib

    public = (
        install(installer)
        .public_key()
        .public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    )
    print(hashlib.sha256(public).hexdigest())


root.mkdir(mode=0o700, exist_ok=True)
mode = sys.argv[1]
if mode == "key":
    issue(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5] if len(sys.argv) > 5 else None)
elif mode == "poke":
    poke(
        sys.argv[2],
        sys.argv[3],
        sys.argv[4],
        sys.argv[5],
        sys.argv[6] if len(sys.argv) > 6 else None,
    )
elif mode == "malformed":
    malformed(sys.argv[2])
elif mode == "fingerprint":
    fingerprint(sys.argv[2])
else:
    raise ValueError("invalid client mode")
