"""Real X.509 signing/verification and private file custody tests."""

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from datetime import UTC, datetime
from importlib.abc import Loader
from importlib.machinery import ModuleSpec
from pathlib import Path
from typing import cast

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

SOURCE = Path(__file__).resolve().parents[2] / "priv/private_pki/authority.py"
BOOTSTRAP = SOURCE.with_name("bootstrap.py")
spec = importlib.util.spec_from_file_location("authority", SOURCE)
# spec_from_file_location returns None only for unloadable locations; SOURCE is a .py file.
module_spec = cast(ModuleSpec, spec)
pki = importlib.util.module_from_spec(module_spec)
cast(Loader, module_spec.loader).exec_module(pki)


class AuthorityTest(unittest.TestCase):
    def setUp(self) -> None:
        self.now = datetime(2028, 2, 29, tzinfo=UTC)
        self.root_key, self.root, self.key, self.issuer = pki.bootstrap(self.now)

    def test_real_chain_and_calendar_lifetimes(self) -> None:
        self.issuer.verify_directly_issued_by(self.root)
        key, csr = pki.request()
        leaf = pki.issue(csr, self.key, self.issuer, self.now)
        leaf.verify_directly_issued_by(self.issuer)
        self.assertEqual(self.root.not_valid_after_utc.year, 2048)
        self.assertEqual(self.issuer.not_valid_after_utc.year, 2038)
        self.assertEqual(leaf.not_valid_after_utc.year, 2038)
        self.assertEqual((pki.ROOT_YEARS, pki.INTERMEDIATE_YEARS, pki.SERVER_YEARS), (20, 10, 10))
        self.assertEqual(leaf.public_key().public_numbers(), key.public_key().public_numbers())
        self.assertEqual(pki.years_after(self.now, 1).day, 28)

    def test_fleet_request_has_exact_subject_and_names(self) -> None:
        self.assertEqual(pki.names(), ["llm.internal", "*.integration.internal"])
        _, csr_pem = pki.request()
        csr = x509.load_pem_x509_csr(csr_pem)
        names = csr.extensions.get_extension_for_class(x509.SubjectAlternativeName)
        self.assertEqual(csr.subject, pki.subject(pki.HOSTNAME))
        self.assertEqual(names.value.get_values_for_type(x509.DNSName), pki.names())

    def test_no_extra_names_or_ca_request_extensions(self) -> None:
        for extra in [
            x509.SubjectAlternativeName([x509.DNSName("evil.example")]),
            x509.BasicConstraints(True, 0),
        ]:
            key = ec.generate_private_key(ec.SECP256R1())
            csr = (
                x509.CertificateSigningRequestBuilder()
                .subject_name(pki.subject(pki.HOSTNAME))
                .add_extension(extra, False)
                .sign(key, hashes.SHA256())
            )
            with self.assertRaises((ValueError, x509.ExtensionNotFound)):
                pki.issue(
                    csr.public_bytes(serialization.Encoding.PEM),
                    self.key,
                    self.issuer,
                    self.now,
                )

    def test_leaf_expiry_capped_at_issuer(self) -> None:
        _, csr = pki.request()
        later = pki.years_after(self.now, 9)
        leaf = pki.issue(csr, self.key, self.issuer, later)
        self.assertEqual(leaf.not_valid_after_utc, self.issuer.not_valid_after_utc)

    def test_requests_generate_independent_keys(self) -> None:
        a, _ = pki.request()
        b, _ = pki.request()
        self.assertNotEqual(pki.private_bytes(a), pki.private_bytes(b))

    def test_offline_bootstrap_separates_recovery_and_runtime_bundles(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp) / "custody"
            directory.mkdir(mode=0o700)
            subprocess.run([sys.executable, str(BOOTSTRAP), str(directory)], check=True)

            recovery = json.loads((directory / "recovery.json").read_bytes())
            runtime = json.loads((directory / "audi-private.json").read_bytes())
            recovery_secrets = recovery["overalls-private-ca"]["production"]
            runtime_secrets = runtime["overalls-audi-private"]["production"]

            self.assertEqual(
                set(recovery_secrets),
                {
                    "AUDI_PRIVATE_ROOT_KEY",
                    "AUDI_PRIVATE_ROOT_CERTIFICATE",
                    "AUDI_PRIVATE_ISSUER_KEY",
                    "AUDI_PRIVATE_ISSUER_CERTIFICATE",
                },
            )
            self.assertEqual(
                set(runtime_secrets),
                {"AUDI_PRIVATE_CERTIFICATE_CHAIN", "AUDI_PRIVATE_CERTIFICATE_KEY"},
            )
            self.assertEqual(
                x509.load_pem_x509_certificate((directory / "server.pem").read_bytes())
                .extensions.get_extension_for_class(x509.SubjectAlternativeName)
                .value.get_values_for_type(x509.DNSName),
                pki.names(),
            )
            for path in directory.iterdir():
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_custody_never_overwrites_or_follows_symlinks(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "key"
            pki.create_private(target, b"first")
            with self.assertRaises(FileExistsError):
                pki.create_private(target, b"second")
            self.assertEqual(target.read_bytes(), b"first")
            self.assertEqual(target.stat().st_mode & 0o777, 0o600)
            link = Path(tmp) / "link"
            link.symlink_to(target)
            with self.assertRaises(FileExistsError):
                pki.create_private(link, b"second")


if __name__ == "__main__":
    unittest.main()
