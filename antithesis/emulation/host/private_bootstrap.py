"""Synthetic private-service identity and role configs for the measured TCG host."""

import argparse
import hashlib
import json
import os
import re
import stat
import subprocess
import tempfile
from pathlib import Path
from typing import TypedDict

STATE = Path("/var/lib/lilly-host")
SECRETS = Path("/run/overalls-secrets")
ROOT_KEY = STATE / "private-ca.key"
ROOT_CERT = STATE / "private-ca.crt"
LEAF_KEY = STATE / "private-leaf.key"
LEAF_CERT = STATE / "private-leaf.crt"
MANIFEST = STATE / "private-pki.json"
HOST_CREDENTIAL = SECRETS / "lilly-host-credential.json"
CONTROL_CA = SECRETS / "ca.crt"
UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z")
SERVICE_UID = {"audi": 991, "ziggy": 992, "galileo": 993}
SERVICE_DIRECTORY = {"audi": "audi-private", "ziggy": "ziggy", "galileo": "galileo"}


class PKIManifest(TypedDict):
    version: int
    root_key_sha256: str
    root_cert_sha256: str
    leaf_key_sha256: str
    leaf_cert_sha256: str


def run(argv: list[str]) -> bytes:
    return subprocess.run(argv, capture_output=True, check=True, timeout=30).stdout


def safe_file(path: Path, uid: int, modes: set[int], maximum: int = 16384) -> bytes:
    details = path.lstat()
    if (
        not stat.S_ISREG(details.st_mode)
        or details.st_nlink != 1
        or details.st_uid != uid
        or stat.S_IMODE(details.st_mode) not in modes
        or details.st_size < 1
        or details.st_size > maximum
    ):
        raise ValueError("invalid private-service file")
    return path.read_bytes()


def atomic_file(path: Path, data: bytes, uid: int, mode: int) -> None:
    descriptor, name = tempfile.mkstemp(prefix="." + path.name + ".", dir=path.parent)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            os.fchmod(stream.fileno(), mode)
            os.fchown(stream.fileno(), uid, uid)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)
    directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def safe_directory(path: Path, uid: int, mode: int) -> None:
    path.mkdir(mode=mode, parents=True, exist_ok=True)
    details = path.lstat()
    if not stat.S_ISDIR(details.st_mode) or details.st_uid not in (0, uid):
        raise ValueError("invalid private-service directory")
    os.chown(path, uid, uid)
    os.chmod(path, mode)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def pki_files() -> dict[str, Path]:
    return {
        "root_key_sha256": ROOT_KEY,
        "root_cert_sha256": ROOT_CERT,
        "leaf_key_sha256": LEAF_KEY,
        "leaf_cert_sha256": LEAF_CERT,
    }


def validate_pki() -> None:
    raw: object = json.loads(safe_file(MANIFEST, 0, {0o600}))
    if not isinstance(raw, dict) or set(raw) != {"version", *pki_files()} or raw["version"] != 1:
        raise ValueError("invalid retained private-service identity")
    for field, path in pki_files().items():
        mode = {0o600} if "key" in field else {0o600, 0o644}
        if raw[field] != digest(safe_file(path, 0, mode)):
            raise ValueError("retained private-service identity changed")
    run(
        [
            "openssl",
            "verify",
            "-CAfile",
            str(ROOT_CERT),
            "-purpose",
            "sslserver",
            "-verify_hostname",
            "llm.internal",
            str(LEAF_CERT),
        ]
    )
    run(
        [
            "openssl",
            "verify",
            "-CAfile",
            str(ROOT_CERT),
            "-purpose",
            "sslserver",
            "-verify_hostname",
            "sample.integration.internal",
            str(LEAF_CERT),
        ]
    )
    leaf_public = run(["openssl", "x509", "-in", str(LEAF_CERT), "-pubkey", "-noout"])
    key_public = run(["openssl", "pkey", "-in", str(LEAF_KEY), "-pubout"])
    if leaf_public != key_public:
        raise ValueError("private-service leaf key changed")
    root_public = run(["openssl", "x509", "-in", str(ROOT_CERT), "-pubkey", "-noout"])
    root_key_public = run(["openssl", "pkey", "-in", str(ROOT_KEY), "-pubout"])
    if root_public != root_key_public:
        raise ValueError("private-service root key changed")


def prepare() -> None:
    """@cc [owner:ghuntley,label:security;recovery] retained-inner-private-pki
    Missing or changed retained identity MUST fail closed after first creation;
    a restart MUST preserve the exact CA and leaf that Lilly supplies to guests.
    The CA signing key MUST remain in root-owned inner-host state.
    """
    safe_directory(STATE, 0, 0o700)
    if MANIFEST.exists() or any(path.exists() for path in pki_files().values()):
        validate_pki()
        return
    with tempfile.TemporaryDirectory(prefix=".private-pki-", dir=STATE) as name:
        work = Path(name)
        run(
            [
                "openssl",
                "req",
                "-x509",
                "-newkey",
                "ec",
                "-pkeyopt",
                "ec_paramgen_curve:P-256",
                "-nodes",
                "-days",
                "365",
                "-subj",
                "/CN=Overalls-Antithesis-Inner-Private-Root",
                "-addext",
                "basicConstraints=critical,CA:TRUE",
                "-addext",
                "keyUsage=critical,keyCertSign,cRLSign",
                "-keyout",
                str(work / "root.key"),
                "-out",
                str(work / "root.crt"),
            ]
        )
        run(
            [
                "openssl",
                "req",
                "-new",
                "-newkey",
                "ec",
                "-pkeyopt",
                "ec_paramgen_curve:P-256",
                "-nodes",
                "-subj",
                "/CN=llm.internal",
                "-keyout",
                str(work / "leaf.key"),
                "-out",
                str(work / "leaf.csr"),
            ]
        )
        (work / "leaf.ext").write_text(
            "basicConstraints=critical,CA:FALSE\n"
            "keyUsage=critical,digitalSignature\n"
            "extendedKeyUsage=serverAuth\n"
            "subjectAltName=DNS:llm.internal,DNS:*.integration.internal\n",
            encoding="ascii",
        )
        run(
            [
                "openssl",
                "x509",
                "-req",
                "-in",
                str(work / "leaf.csr"),
                "-CA",
                str(work / "root.crt"),
                "-CAkey",
                str(work / "root.key"),
                "-CAcreateserial",
                "-days",
                "365",
                "-extfile",
                str(work / "leaf.ext"),
                "-out",
                str(work / "leaf.crt"),
            ]
        )
        sources = {
            ROOT_KEY: work / "root.key",
            ROOT_CERT: work / "root.crt",
            LEAF_KEY: work / "leaf.key",
            LEAF_CERT: work / "leaf.crt",
        }
        for target, source in sources.items():
            atomic_file(target, source.read_bytes(), 0, 0o600 if target.suffix == ".key" else 0o644)
    manifest: PKIManifest = {
        "version": 1,
        "root_key_sha256": digest(safe_file(ROOT_KEY, 0, {0o600})),
        "root_cert_sha256": digest(safe_file(ROOT_CERT, 0, {0o644})),
        "leaf_key_sha256": digest(safe_file(LEAF_KEY, 0, {0o600})),
        "leaf_cert_sha256": digest(safe_file(LEAF_CERT, 0, {0o644})),
    }
    atomic_file(MANIFEST, (json.dumps(manifest, sort_keys=True) + "\n").encode(), 0, 0o600)
    validate_pki()


def host_id() -> str:
    credential: object = json.loads(safe_file(HOST_CREDENTIAL, 0, {0o600}))
    if not isinstance(credential, dict):
        raise ValueError("invalid enrolled host credential")
    value = credential.get("host_id")
    if not isinstance(value, str) or UUID.fullmatch(value) is None:
        raise ValueError("invalid enrolled host identity")
    return value


def install_credential(source: Path, target: Path, uid: int, maximum: int = 16384) -> bytes:
    value = safe_file(source, 0, {0o600}, maximum)
    atomic_file(target, value, uid, 0o400)
    return value


def configure() -> None:
    """@cc [owner:ghuntley,label:security] inner-satellite-config-binding
    All role configs MUST bind the measured enrolled host; Ziggy and Galileo
    MUST use their distinct host-bound tokens. Audi MUST own its TLS key and
    status directory, and its connector MUST be Lilly's local Unix socket.
    """
    validate_pki()
    host = host_id()
    ca = safe_file(CONTROL_CA, 0, {0o600, 0o644}, 1_048_576)
    if b"-----BEGIN CERTIFICATE-----" not in ca:
        raise ValueError("invalid control root")
    run(["openssl", "x509", "-in", str(CONTROL_CA), "-noout"])
    for role, uid in SERVICE_UID.items():
        runtime = Path("/run") / SERVICE_DIRECTORY[role]
        safe_directory(runtime, uid, 0o700 if role == "audi" else 0o750)
        safe_directory(runtime / "credentials", uid, 0o700)
    safe_directory(Path("/var/lib/ziggy"), SERVICE_UID["ziggy"], 0o700)
    safe_directory(Path("/var/lib/ziggy/spool"), SERVICE_UID["ziggy"], 0o700)

    ziggy = Path("/run/ziggy/credentials")
    galileo = Path("/run/galileo/credentials")
    audi = Path("/run/audi-private/credentials")
    for role, destination in (("ziggy", ziggy), ("galileo", galileo)):
        token = install_credential(
            SECRETS / f"inner-{role}.token", destination / "control.token", SERVICE_UID[role], 256
        )
        if re.fullmatch(rb"[\x21-\x7e]{80}\n?", token) is None:
            raise ValueError("invalid inner satellite credential")
        atomic_file(destination / "ca.pem", ca, SERVICE_UID[role], 0o400)
    for provider in ("openai", "anthropic"):
        key = install_credential(
            SECRETS / f"inner-{provider}.key", ziggy / f"{provider}.key", SERVICE_UID["ziggy"], 256
        )
        if re.fullmatch(rb"[\x21-\x7e]{1,255}\n?", key) is None:
            raise ValueError("invalid synthetic provider key")
    atomic_file(audi / "chain.pem", safe_file(LEAF_CERT, 0, {0o644}), SERVICE_UID["audi"], 0o400)
    atomic_file(audi / "key.pem", safe_file(LEAF_KEY, 0, {0o600}), SERVICE_UID["audi"], 0o400)
    atomic_file(audi / "roots.pem", safe_file(ROOT_CERT, 0, {0o644}), SERVICE_UID["audi"], 0o400)

    configs: dict[str, dict[str, object]] = {
        "audi": {
            "version": 1,
            "role": "private",
            "host_id": host,
            "connector_path": "/run/lilly-ingress/private.sock",
            "connector_uid": 0,
            "ziggy_socket": "/run/ziggy/proxy.sock",
            "galileo_socket": "/run/galileo/proxy.sock",
            "certificate_file": str(audi / "chain.pem"),
            "key_file": str(audi / "key.pem"),
            "roots_file": str(audi / "roots.pem"),
            "status_socket": "/run/audi-private/status.sock",
        },
        "ziggy": {
            "version": 1,
            "host_id": host,
            "control_plane": "https://marshall-a:5443",
            "ca_file": str(ziggy / "ca.pem"),
            "credential_file": str(ziggy / "control.token"),
            "openai_key_file": str(ziggy / "openai.key"),
            "anthropic_key_file": str(ziggy / "anthropic.key"),
            "openai_origin": "http://127.0.0.1:8080",
            "agent_enabled": False,
            "socket": "/run/ziggy/proxy.sock",
            "spool": "/var/lib/ziggy/spool",
            "max_requests": 1000,
            "enabled_providers": ["openai"],
        },
        "galileo": {
            "version": 1,
            "host_id": host,
            "control_plane": "https://marshall-a:5443",
            "ca_file": str(galileo / "ca.pem"),
            "credential_file": str(galileo / "control.token"),
            "socket": "/run/galileo/proxy.sock",
        },
    }
    for role, config in configs.items():
        path = Path("/run") / SERVICE_DIRECTORY[role] / "config.json"
        atomic_file(
            path,
            (json.dumps(config, separators=(",", ":"), sort_keys=True) + "\n").encode(),
            SERVICE_UID[role],
            0o600,
        )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("prepare", "configure"))
    args = parser.parse_args()
    if args.action == "prepare":
        prepare()
    else:
        configure()


if __name__ == "__main__":
    main()
