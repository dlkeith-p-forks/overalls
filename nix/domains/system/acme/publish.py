"""Validate and publish an issued certificate, then request a graceful reload."""

import grp
import importlib.util
import ipaddress
import json
import os
import pwd
import socket
import ssl
import stat
import subprocess
import sys
import tempfile
from collections.abc import Mapping
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Protocol, TypedDict, cast

from cryptography import x509
from cryptography.hazmat.primitives import serialization


class Configuration(TypedDict):
    runtime: str
    destination: str
    peerCertificates: list[str]
    source: str
    issuer: str
    group: str
    hostname: str
    listenAddress: str | None
    listenAddressVariable: str | None
    listenPort: int
    caFile: str
    minimumValiditySeconds: int
    bundleLibrary: str
    openssl: str
    haproxy: str
    systemctl: str
    proxyConfig: str


def string(value: object) -> str:
    if not isinstance(value, str):
        raise ValueError("expected string")
    return value


def integer(value: object) -> int:
    if type(value) is not int:
        raise ValueError("expected integer")
    return value


def optional_string(value: object) -> str | None:
    return None if value is None else string(value)


def string_list(value: object) -> list[str]:
    if not isinstance(value, list):
        raise ValueError("expected list")
    return [string(item) for item in value]


def configuration_value(raw: object) -> Configuration:
    if not isinstance(raw, dict):
        raise ValueError("invalid publication configuration")
    return Configuration(
        runtime=string(raw["runtime"]),
        destination=string(raw["destination"]),
        peerCertificates=string_list(raw.get("peerCertificates", [])),
        source=string(raw["source"]),
        issuer=string(raw["issuer"]),
        group=string(raw["group"]),
        hostname=string(raw["hostname"]),
        listenAddress=optional_string(raw["listenAddress"]),
        listenAddressVariable=optional_string(raw.get("listenAddressVariable")),
        listenPort=integer(raw["listenPort"]),
        caFile=string(raw["caFile"]),
        minimumValiditySeconds=integer(raw["minimumValiditySeconds"]),
        bundleLibrary=string(raw["bundleLibrary"]),
        openssl=string(raw["openssl"]),
        haproxy=string(raw["haproxy"]),
        systemctl=string(raw["systemctl"]),
        proxyConfig=string(raw["proxyConfig"]),
    )


class Bundles(Protocol):
    def cleanup(self, configuration: Mapping[str, object]) -> None: ...

    def safe_directory(self, path: Path) -> None: ...

    def publish(
        self,
        destination: Path,
        contents: dict[str, bytes],
        group: str,
        *,
        durable: bool = False,
    ) -> None: ...


def bundle_library(configuration: Configuration) -> Bundles:
    spec = importlib.util.spec_from_file_location("bundles", configuration["bundleLibrary"])
    if spec is None or spec.loader is None:
        raise ValueError("bundle library unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return cast(Bundles, module)


def run(arguments: list[str], accepted: tuple[int, ...] = (0,)) -> int:
    result = subprocess.run(
        arguments,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=30,
    )
    if result.returncode not in accepted:
        raise ValueError("certificate operation failed")
    return result.returncode


def issuer_file(path: Path, issuer: int) -> bytes:
    for directory in [path.parent, *path.parent.parents]:
        info = directory.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid not in (0, issuer) or info.st_mode & 0o022:
            raise ValueError("untrusted issuer directory")
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC), "rb") as stream:
        info = os.fstat(stream.fileno())
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid not in (0, issuer)
            or info.st_nlink != 1
            or info.st_mode & 0o027
            or info.st_size > 65536
        ):
            raise ValueError("untrusted issuer file")
        value = stream.read(65537)
    if len(value) > 65536:
        raise ValueError("issuer file too large")
    return value


# @cc [owner:ghuntley,label:security] shared-proxy-certificate-validation
# Candidate validation MUST replace every published certificate reference in the
# bounded proxy configuration. Exactly one or two references are permitted for
# Marshall HTTPS and its optional Grafana frontend; zero or more MUST fail.
def validate(
    pem: bytes, runtime: Path, configuration: Configuration, minimum_validity: int
) -> bytes:
    certificates = x509.load_pem_x509_certificates(pem)
    if not 1 <= len(certificates) <= 8:
        raise ValueError("invalid certificate chain")
    key = serialization.load_pem_private_key(pem, password=None)
    public_format = (serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
    if key.public_key().public_bytes(*public_format) != certificates[0].public_key().public_bytes(
        *public_format
    ):
        raise ValueError("certificate key mismatch")
    now = datetime.now(UTC)
    leaf = certificates[0]
    if leaf.not_valid_before_utc > now or leaf.not_valid_after_utc <= now + timedelta(
        seconds=minimum_validity
    ):
        raise ValueError("certificate lifetime rejected")
    chain = b"".join(
        certificate.public_bytes(serialization.Encoding.PEM) for certificate in certificates
    )
    candidate = (
        key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        )
        + chain
    )
    (runtime / "leaf.pem").write_bytes(leaf.public_bytes(serialization.Encoding.PEM))
    (runtime / "chain.pem").write_bytes(chain)
    (runtime / "full.pem").write_bytes(candidate)
    run(
        [
            configuration["openssl"],
            "verify",
            "-purpose",
            "sslserver",
            "-verify_hostname",
            configuration["hostname"],
            "-CAfile",
            configuration["caFile"],
            "-no-CApath",
            "-no-CAstore",
            "-untrusted",
            str(runtime / "chain.pem"),
            str(runtime / "leaf.pem"),
        ]
    )
    destination = Path(configuration["destination"])
    proxy_config = Path(configuration["proxyConfig"]).read_text()
    reference = "crt " + str(destination / "full.pem")
    if proxy_config.count(reference) not in (1, 2) or len(proxy_config) > 262144:
        raise ValueError("unexpected proxy certificate configuration")
    candidate_config = proxy_config.replace(reference, "crt " + str(runtime / "full.pem"))
    candidate_config = substitute_unpublished_peers(candidate_config, runtime, configuration)
    (runtime / "haproxy.cfg").write_text(candidate_config)
    run([configuration["haproxy"], "-c", "-f", str(runtime / "haproxy.cfg")])
    return candidate


def substitute_unpublished_peers(
    proxy_config: str, runtime: Path, configuration: Configuration
) -> str:
    """@cc [owner:ghuntley,label:recovery] certificate-independent-peer-publication
    A sibling certificate on the same listener that has never been published
    MUST NOT block this certificate's validation: only inside the disposable
    candidate configuration, each absent peer reference is replaced by this
    candidate. A present peer is checked as published; the served proxy
    configuration is never rewritten.
    """
    for peer in configuration["peerCertificates"]:
        path = Path(peer)
        if not path.is_absolute() or path == Path(configuration["destination"]) / "full.pem":
            raise ValueError("invalid peer certificate")
        reference = "crt " + peer
        if proxy_config.count(reference) not in (1, 2):
            raise ValueError("unexpected peer certificate configuration")
        if not os.path.lexists(path):
            proxy_config = proxy_config.replace(reference, "crt " + str(runtime / "full.pem"))
    return proxy_config


def published_file(configuration: Configuration) -> bytes:
    current = Path(configuration["destination"]) / "full.pem"
    pem = issuer_file(current, 0)
    group = grp.getgrnam(configuration["group"]).gr_gid
    for path, mode in [(current, 0o640), (current.parent, 0o750)]:
        info = path.lstat()
        if stat.S_IMODE(info.st_mode) != mode or info.st_gid != group:
            raise ValueError("invalid published certificate custody")
    return pem


def listen_address(configuration: Configuration) -> ipaddress.IPv4Address:
    """Return the proxy listener address: the evaluated literal, or exactly one
    validated runtime value from the unit's EnvironmentFile."""
    literal, variable = configuration["listenAddress"], configuration["listenAddressVariable"]
    if variable is None:
        if literal is None:
            raise ValueError("listener address source is required")
        return ipaddress.IPv4Address(literal)
    if literal is not None:
        raise ValueError("exactly one listener address source is required")
    text = os.environ.get(variable, "")
    address = ipaddress.IPv4Address(text)
    if str(address) != text or address.is_unspecified:
        raise ValueError("runtime listener address must be canonical and explicit")
    return address


def served(configuration: Configuration, candidate: bytes) -> bool:
    try:
        address = listen_address(configuration)
        if address.is_unspecified:
            address = ipaddress.IPv4Address("127.0.0.1")
        context = ssl.create_default_context(cafile=configuration["caFile"])
        with (
            socket.create_connection(
                (str(address), configuration["listenPort"]), timeout=5
            ) as connection,
            context.wrap_socket(connection, server_hostname=configuration["hostname"]) as tls,
        ):
            leaf = x509.load_pem_x509_certificates(candidate)[0]
            return tls.getpeercert(binary_form=True) == leaf.public_bytes(
                serialization.Encoding.DER
            )
    except (OSError, ValueError):
        return False


# @cc [owner:ghuntley,label:recovery] proxy-validates-persistent-certificate-on-start
# Proxy startup MAY use the last validated persistent certificate if issuance
# fails, but MUST recheck its trust, hostname, lifetime, key and private custody.
def cached(configuration: Configuration) -> None:
    os.umask(0o077)
    with tempfile.TemporaryDirectory(prefix="certificate-", dir="/run/haproxy") as directory:
        validate(published_file(configuration), Path(directory), configuration, 0)
    print('{"event":"tls.cached_certificate_ready","severity":"info"}')


# @cc [owner:ghuntley,label:security] proxy-certificate-validated-before-publication
# Chain, hostname, lifetime, matching key and actual HAProxy configuration MUST
# validate before publication. Bootstrap self-signed output MUST NOT be served.
def publish(configuration: Configuration) -> None:
    if os.geteuid() != 0:
        raise ValueError("root required")
    os.umask(0o077)
    bundles = bundle_library(configuration)
    bundles.cleanup(configuration)
    source = Path(configuration["source"])
    issuer = pwd.getpwnam(configuration["issuer"]).pw_uid
    issuer_file(source.parent / "acme-success", issuer)
    candidate = validate(
        issuer_file(source, issuer),
        Path(configuration["runtime"]),
        configuration,
        configuration["minimumValiditySeconds"],
    )
    destination = Path(configuration["destination"])
    current = destination / "full.pem"
    changed = True
    if os.path.lexists(destination):
        bundles.safe_directory(destination)
        if current.is_symlink():
            raise ValueError("invalid published certificate path")
        changed = not current.exists() or published_file(configuration) != candidate
    if changed:
        bundles.publish(destination, {"full.pem": candidate}, configuration["group"], durable=True)
    status = run(
        [configuration["systemctl"], "is-active", "--quiet", "haproxy.service"], accepted=(0, 3)
    )
    if status != 0:
        run([configuration["systemctl"], "reset-failed", "haproxy.service"])
    # A prior reload may have failed after publishing exactly these bytes.
    # Verify what is served before skipping it; avoid creating needless old
    # workers for long-lived WebSockets at each periodic certificate check.
    if changed or status != 0 or not served(configuration, candidate):
        run([configuration["systemctl"], "--no-block", "reload-or-restart", "haproxy.service"])
    print('{"event":"tls.certificate_ready","severity":"info"}')


def cleanup(configuration: Configuration) -> None:
    if os.geteuid() != 0:
        raise ValueError("root required")
    bundle_library(configuration).cleanup(configuration)


if __name__ == "__main__":
    checking = len(sys.argv) == 3 and sys.argv[1] == "--cached"
    cleaning = len(sys.argv) == 3 and sys.argv[1] == "--cleanup"
    try:
        if (len(sys.argv) != 2 and not checking and not cleaning) or len(sys.argv) > 3:
            raise ValueError("invalid arguments")
        (cleanup if cleaning else cached if checking else publish)(
            configuration_value(
                json.loads(Path(sys.argv[2 if checking or cleaning else 1]).read_text())
            )
        )
    except Exception:
        event = (
            "tls.publication_cleanup_failed"
            if cleaning
            else "tls.cached_certificate_failed"
            if checking
            else "tls.publication_failed"
        )
        print(json.dumps({"event": event, "severity": "error"}), file=sys.stderr)
        sys.exit(1)
