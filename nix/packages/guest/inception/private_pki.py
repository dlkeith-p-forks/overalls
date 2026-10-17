"""Independent private-service hierarchy; never inherits a parent signing key."""

import fcntl
import json
import os
import stat
import sys
import tempfile
from datetime import UTC, datetime
from pathlib import Path
from types import ModuleType

from cryptography import x509
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from runtime import SetupError, encode, identities, private_directory, publish, read_private

STATE = Path("/var/lib/inception")
PUBLIC = Path("/run/inception-public")
FILES = {"root.key", "root.pem", "issuer.key", "issuer.pem", "binding.json"}


def validate(directory: Path, instance: str) -> bytes:
    """Validate durable custody without replacing missing, foreign or expired keys."""
    private_directory(directory)
    if {path.name for path in directory.iterdir()} != FILES:
        raise SetupError("private PKI files invalid")
    if json.loads(read_private(directory / "binding.json")) != {
        "version": 1,
        "instance_id": instance,
    }:
        raise SetupError("private PKI instance mismatch")
    certificates, keys = {}, {}
    now = datetime.now(UTC)
    for name, depth in [("root", 1), ("issuer", 0)]:
        key = serialization.load_pem_private_key(
            read_private(directory / (name + ".key")), password=None
        )
        pem = read_private(directory / (name + ".pem"))
        parsed = x509.load_pem_x509_certificates(pem)
        if len(parsed) != 1 or pem != parsed[0].public_bytes(serialization.Encoding.PEM):
            raise SetupError("private PKI certificate envelope invalid")
        certificate = parsed[0]
        public = certificate.public_key()
        if (
            not isinstance(key, ec.EllipticCurvePrivateKey)
            or not isinstance(key.curve, ec.SECP256R1)
            or not isinstance(public, ec.EllipticCurvePublicKey)
            or key.public_key().public_numbers() != public.public_numbers()
        ):
            raise SetupError("private PKI key mismatch")
        bounds = certificate.extensions.get_extension_for_class(x509.BasicConstraints)
        usage = certificate.extensions.get_extension_for_class(x509.KeyUsage)
        if (
            not bounds.critical
            or bounds.value != x509.BasicConstraints(True, depth)
            or not usage.critical
            or not usage.value.key_cert_sign
            or not usage.value.crl_sign
            or not certificate.not_valid_before_utc <= now < certificate.not_valid_after_utc
        ):
            raise SetupError("private PKI authority invalid")
        certificates[name], keys[name] = certificate, key
    root, issuer = certificates["root"], certificates["issuer"]
    root.verify_directly_issued_by(root)
    issuer.verify_directly_issued_by(root)
    constraints = issuer.extensions.get_extension_for_class(x509.NameConstraints)
    if (
        not constraints.critical
        or constraints.value.permitted_subtrees != [x509.DNSName("internal")]
        or constraints.value.excluded_subtrees
        or issuer.not_valid_after_utc > root.not_valid_after_utc
        or issuer.not_valid_before_utc < root.not_valid_before_utc
        or keys["root"].public_key().public_numbers()
        == keys["issuer"].public_key().public_numbers()
    ):
        raise SetupError("private PKI hierarchy invalid")
    return root.public_bytes(serialization.Encoding.PEM)


def public_root(public: Path, pem: bytes) -> None:
    public.mkdir(mode=0o755, parents=True, exist_ok=True)
    info = public.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
        raise SetupError("private PKI public directory invalid")
    public.chmod(0o755)
    publish(public / "private-root.pem", pem)
    (public / "private-root.pem").chmod(0o644)


def prepare(authority: ModuleType, state: Path = STATE, public: Path = PUBLIC) -> None:
    """@cc [owner:ghuntley,label:security;recovery] inception-private-pki-custody
    Each instance MUST generate independent root/intermediate keys through Audi's
    existing hierarchy primitives and bind them to its durable instance identity.
    Restart MUST reuse validated custody; missing, mismatched, expired or partial
    published state MUST fail without key rotation. Only the public root may leave
    private state. Bootstrap MUST serialize with other identity preparation and
    atomically publish a complete hierarchy before marking initialization.
    """
    private_directory(state)
    fd = os.open(state / "bootstrap.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "rb") as lock:
        info = os.fstat(lock.fileno())
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != os.getuid()
            or info.st_nlink != 1
            or info.st_mode & 0o077
        ):
            raise SetupError("private PKI lock invalid")
        fcntl.flock(lock, fcntl.LOCK_EX)
        instance = identities(state)["instance_id"]
        target = state / "private-pki"
        initialized = state / "private-pki-ready"
        marked = os.path.lexists(initialized)
        if marked and read_private(initialized) != b"1\n":
            raise SetupError("private PKI marker invalid")
        if not os.path.lexists(target):
            if marked:
                raise SetupError("private PKI custody missing")
            with tempfile.TemporaryDirectory(prefix=".private-pki-", dir=state) as temporary:
                directory = Path(temporary)
                root_key, root, issuer_key, issuer = authority.bootstrap()
                values = {
                    "root.key": authority.private_bytes(root_key),
                    "root.pem": authority.public_bytes(root),
                    "issuer.key": authority.private_bytes(issuer_key),
                    "issuer.pem": authority.public_bytes(issuer),
                    "binding.json": encode({"version": 1, "instance_id": instance}),
                }
                for name, value in values.items():
                    publish(directory / name, value, replace=False)
                validate(directory, instance)
                os.rename(directory, target)
                parent = os.open(state, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
                try:
                    os.fsync(parent)
                finally:
                    os.close(parent)
        pem = validate(target, instance)
        if not marked:
            publish(initialized, b"1\n", replace=False)
        public_root(public, pem)


if __name__ == "__main__":
    try:
        if os.getuid() != 0:
            raise SetupError("root preparation required")
        sys.path.insert(0, sys.argv[1])  # fixed, image-owned Audi primitives
        import authority  # ty: ignore[unresolved-import]  # audi/priv/private_pki via argv[1]

        prepare(authority)
    except Exception:
        print("Inception private PKI unavailable; preserve existing custody", file=sys.stderr)
        sys.exit(1)
