"""Audi's private service certificate primitives. No network or implicit authority."""

import calendar
import os
import stat
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import cast

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID

ROOT_YEARS = 20
INTERMEDIATE_YEARS = 10
SERVER_YEARS = 10
HOSTNAME = "llm.internal"
NAMES = ["llm.internal", "*.integration.internal"]
MAX_PEM = 65536
# KeyUsage annotates encipher_only/decipher_only as bool, but None is the
# documented omitted value at runtime and encodes identically without key
# agreement, so cast the boundary instead of changing the encoded usage.
OMITTED = cast("bool", None)


def years_after(now: datetime, years: int) -> datetime:
    year = now.year + years
    return now.replace(year=year, day=min(now.day, calendar.monthrange(year, now.month)[1]))


def names() -> list[str]:
    """@cc [owner:ghuntley,label:security] internal-certificate-fleet-wildcard
    The fleet serves one offline-issued wildcard leaf. Certificate names MUST
    NOT bind a host, placement or caller-selected value."""
    return list(NAMES)


def private_bytes(key: ec.EllipticCurvePrivateKey) -> bytes:
    return key.private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()
    )


def public_bytes(certificate: x509.Certificate) -> bytes:
    return certificate.public_bytes(serialization.Encoding.PEM)


def subject(common_name: str) -> x509.Name:
    return x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, common_name)])


def builder(
    name: x509.Name,
    key: ec.EllipticCurvePrivateKey,
    issuer_name: x509.Name,
    now: datetime,
    expires: datetime,
) -> x509.CertificateBuilder:
    return (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(issuer_name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(minutes=5))
        .not_valid_after(expires)
        .add_extension(x509.SubjectKeyIdentifier.from_public_key(key.public_key()), False)
    )


def ca_usage() -> x509.KeyUsage:
    return x509.KeyUsage(False, False, False, False, False, True, True, OMITTED, OMITTED)


def bootstrap(
    now: datetime | None = None,
) -> tuple[
    ec.EllipticCurvePrivateKey, x509.Certificate, ec.EllipticCurvePrivateKey, x509.Certificate
]:
    """@cc [owner:ghuntley,label:security] private-ca-hierarchy
    Bootstrap MUST create independent P-256 root/intermediate keys, a path-length
    one root and a path-length zero intermediate constrained to internal DNS.
    Validity MUST use the approved calendar years and never exceed the issuer.
    """
    now = now or datetime.now(UTC)
    root_key = ec.generate_private_key(ec.SECP256R1())
    root_name = subject("Overalls private services root")
    root = (
        builder(root_name, root_key, root_name, now, years_after(now, ROOT_YEARS))
        .add_extension(x509.BasicConstraints(ca=True, path_length=1), True)
        .add_extension(ca_usage(), True)
        .sign(root_key, hashes.SHA256())
    )
    issuer_key = ec.generate_private_key(ec.SECP256R1())
    issuer_name = subject("Overalls private services issuer")
    issuer = (
        builder(
            issuer_name,
            issuer_key,
            root_name,
            now,
            min(years_after(now, INTERMEDIATE_YEARS), root.not_valid_after_utc),
        )
        .add_extension(x509.BasicConstraints(ca=True, path_length=0), True)
        .add_extension(ca_usage(), True)
        .add_extension(
            x509.NameConstraints(
                permitted_subtrees=[x509.DNSName("internal")], excluded_subtrees=None
            ),
            True,
        )
        .add_extension(
            x509.AuthorityKeyIdentifier.from_issuer_public_key(root_key.public_key()), False
        )
        .sign(root_key, hashes.SHA256())
    )
    return root_key, root, issuer_key, issuer


def request() -> tuple[ec.EllipticCurvePrivateKey, bytes]:
    """Generate a fleet leaf key and CSR with exactly the closed wildcard names."""
    san = names()
    key = ec.generate_private_key(ec.SECP256R1())
    csr = (
        x509.CertificateSigningRequestBuilder()
        .subject_name(subject(HOSTNAME))
        .add_extension(x509.SubjectAlternativeName([x509.DNSName(n) for n in san]), False)
        .sign(key, hashes.SHA256())
    )
    return key, csr.public_bytes(serialization.Encoding.PEM)


def issue(
    csr_pem: bytes,
    issuer_key: ec.EllipticCurvePrivateKey,
    issuer: x509.Certificate,
    now: datetime | None = None,
) -> x509.Certificate:
    """@cc [owner:ghuntley,label:security] private-ca-exact-fleet-csr
    Offline issuance MUST verify the CSR signature, exact fleet wildcard SANs,
    subject and P-256 key, reject other requested extensions, and cap leaf expiry
    at issuer expiry. This primitive MUST NOT accept caller-selected identities.
    """
    now = now or datetime.now(UTC)
    if len(csr_pem) > MAX_PEM:
        raise ValueError("invalid request")
    csr = x509.load_pem_x509_csr(csr_pem)
    key = csr.public_key()
    if not csr.is_signature_valid or csr.subject != subject(HOSTNAME):
        raise ValueError("invalid request")
    if not isinstance(key, ec.EllipticCurvePublicKey) or not isinstance(key.curve, ec.SECP256R1):
        raise ValueError("invalid request key")
    if len(csr.extensions) != 1:
        raise ValueError("invalid request extensions")
    san = csr.extensions.get_extension_for_class(x509.SubjectAlternativeName)
    if list(san.value) != [x509.DNSName(n) for n in names()] or san.critical:
        raise ValueError("invalid request names")
    # Certificate.public_key() returns a wide union; issuers here are always P-256.
    issuer_public = cast(ec.EllipticCurvePublicKey, issuer.public_key())
    if issuer_public.public_numbers() != issuer_key.public_key().public_numbers():
        raise ValueError("issuer key mismatch")
    if not issuer.not_valid_before_utc <= now < issuer.not_valid_after_utc - timedelta(hours=1):
        raise ValueError("issuer unavailable")
    constraints = issuer.extensions.get_extension_for_class(x509.BasicConstraints)
    scope = issuer.extensions.get_extension_for_class(x509.NameConstraints)
    usage = issuer.extensions.get_extension_for_class(x509.KeyUsage)
    if not constraints.critical or constraints.value != x509.BasicConstraints(True, 0):
        raise ValueError("invalid issuer constraints")
    if (
        not scope.critical
        or scope.value.permitted_subtrees != [x509.DNSName("internal")]
        or scope.value.excluded_subtrees
    ):
        raise ValueError("invalid issuer scope")
    if not usage.value.key_cert_sign:
        raise ValueError("invalid issuer usage")
    return (
        x509.CertificateBuilder()
        .subject_name(csr.subject)
        .issuer_name(issuer.subject)
        .public_key(key)
        .serial_number(x509.random_serial_number())
        .not_valid_before(max(now - timedelta(minutes=5), issuer.not_valid_before_utc))
        .not_valid_after(min(years_after(now, SERVER_YEARS), issuer.not_valid_after_utc))
        .add_extension(x509.BasicConstraints(False, None), True)
        .add_extension(
            x509.KeyUsage(True, False, False, False, False, False, False, OMITTED, OMITTED), True
        )
        .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), False)
        .add_extension(san.value, False)
        .add_extension(x509.SubjectKeyIdentifier.from_public_key(key), False)
        .add_extension(
            x509.AuthorityKeyIdentifier.from_issuer_public_key(issuer_key.public_key()), False
        )
        .sign(issuer_key, hashes.SHA256())
    )


def create_private(path: Path, contents: bytes) -> None:
    """@cc [owner:ghuntley,label:security] private-ca-exclusive-custody
    Key/custody writes MUST exclusively create single-link 0600 files under an
    existing private owner directory, sync before success, and never overwrite
    existing state. Secret bytes MUST NOT be returned through diagnostics.
    """
    path = Path(path)
    parent = path.parent
    info = parent.lstat()
    if (
        not stat.S_ISDIR(info.st_mode)
        or info.st_uid != os.getuid()
        or stat.S_IMODE(info.st_mode) != 0o700
    ):
        raise ValueError("invalid custody directory")
    for ancestor in [parent, *parent.parents]:
        info = ancestor.lstat()
        if not stat.S_ISDIR(info.st_mode) or (
            info.st_mode & 0o022 and not info.st_mode & stat.S_ISVTX
        ):
            raise ValueError("unsafe custody directory")
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(contents)
        stream.flush()
        os.fsync(stream.fileno())
    descriptor = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
