"""Synthetic fixture authenticator for real Marshall WebAuthn verification events."""

from __future__ import annotations

import base64
import binascii
import hashlib
import json
import os
import subprocess
from dataclasses import dataclass, field


@dataclass(frozen=True)
class Authenticator:
    raw_id: str
    private_der: bytes = field(repr=False)


def _decode(value: str) -> bytes:
    return base64.b64decode(value + "=" * (-len(value) % 4), altchars=b"-_", validate=True)


def _encode(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def assertion(
    challenge: object, authenticator: Authenticator, origin: str
) -> dict[str, str] | None:
    """@cc [owner:ghuntley,label:security;verification] webauthn-real-session-ceremony
    The assertion MUST sign the current server challenge for the current HTTPS
    origin and configured RP ID with the fixture authenticator. Its private key
    MUST stay in memory and out of command arguments, source and diagnostics.
    """
    if not isinstance(challenge, dict):
        return None
    identifier = challenge.get("id")
    public = challenge.get("publicKey")
    if not isinstance(identifier, str) or not isinstance(public, dict):
        return None
    nonce = public.get("challenge")
    rp_id = public.get("rpId")
    allowed = public.get("allowCredentials")
    if (
        not isinstance(nonce, str)
        or not isinstance(rp_id, str)
        or not isinstance(allowed, list)
        or not any(
            isinstance(item, dict) and item.get("id") == authenticator.raw_id for item in allowed
        )
    ):
        return None
    client_data = json.dumps(
        {"type": "webauthn.get", "challenge": nonce, "origin": origin, "crossOrigin": False},
        separators=(",", ":"),
    ).encode("utf-8")
    authenticator_data = hashlib.sha256(rp_id.encode("utf-8")).digest() + b"\x05\x00\x00\x00\x00"
    signed_bytes = authenticator_data + hashlib.sha256(client_data).digest()
    descriptor = os.memfd_create("overalls-passkey", os.MFD_CLOEXEC)
    try:
        os.write(descriptor, authenticator.private_der)
        os.lseek(descriptor, 0, os.SEEK_SET)
        result = subprocess.run(
            [
                "openssl",
                "pkeyutl",
                "-sign",
                "-inkey",
                f"/proc/self/fd/{descriptor}",
                "-keyform",
                "DER",
                "-rawin",
                "-digest",
                "sha256",
            ],
            input=signed_bytes,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=5,
            pass_fds=(descriptor,),
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    finally:
        os.close(descriptor)
    if result.returncode != 0 or not result.stdout:
        return None
    return {
        "id": identifier,
        "raw_id": authenticator.raw_id,
        "client_data_json": _encode(client_data),
        "authenticator_data": _encode(authenticator_data),
        "signature": _encode(result.stdout),
    }


# The operator writes a minimal P-256 SEC1 ECPrivateKey (version, 32-byte
# scalar, named-curve parameters, no public key): exactly 51 DER bytes.
# OpenSSL derives the public point when signing, so that is the smallest
# private key encoding this authenticator must accept.
_MINIMUM_PRIVATE_DER = 51


def authenticator_from_private(raw_id: object, private_der: object) -> Authenticator | None:
    if not isinstance(raw_id, str) or not isinstance(private_der, str):
        return None
    try:
        decoded_id = _decode(raw_id)
        decoded_key = _decode(private_der)
    except (ValueError, binascii.Error):
        return None
    if not 16 <= len(decoded_id) <= 1024 or not _MINIMUM_PRIVATE_DER <= len(decoded_key) <= 4096:
        return None
    return Authenticator(raw_id, decoded_key)
