"""Failure, publication and property evidence for extension maintenance boundaries."""

from __future__ import annotations

import contextlib
import dataclasses
import io
import json
import os
import stat
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

import extensions as subject
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from hypothesis import given, settings
from hypothesis import strategies as st

HERE = Path(__file__).resolve().parent
HYPOTHESIS_DIRECTORY = tempfile.TemporaryDirectory(prefix="overalls-extension-hypothesis-")
os.environ["HYPOTHESIS_STORAGE_DIRECTORY"] = HYPOTHESIS_DIRECTORY.name


def archive(entries: list[tuple[str, bytes]]) -> bytes:
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as destination:
        for name, content in entries:
            destination.writestr(name, content)
    return output.getvalue()


def payload(identity: str, version: str, engine: str = "^1.0.0") -> bytes:
    publisher, name = identity.split(".", 1)
    manifest = {
        "publisher": publisher,
        "name": name,
        "version": version,
        "main": "./entry.js",
        "engines": {"vscode": engine},
    }
    xml = f'<PackageManifest xmlns="{subject.XML_NAMESPACE}"><Metadata><Identity Publisher="{publisher}" Id="{name}" Version="{version}"/></Metadata></PackageManifest>'
    return archive(
        [
            ("extension/package.json", json.dumps(manifest).encode()),
            ("extension.vsixmanifest", xml.encode()),
            ("extension/entry.js", b"synthetic extension fixture"),
            ("extension/LICENSE", b"synthetic license fixture"),
        ]
    )


class FixtureValidator:
    """Unit oracle; the separate packaged test exercises the real Node boundary."""

    def __init__(self, key: Ed25519PrivateKey) -> None:
        self.key = key.public_key()
        self.calls = 0

    def compatible(self, engine: str) -> bool:
        return engine == "^1.0.0"

    def verify(self, vsix: Path, signature: Path, engine: str) -> None:
        self.calls += 1
        with zipfile.ZipFile(signature) as source:
            signed = source.read(".signature.sig")
        try:
            self.key.verify(signed, vsix.read_bytes())
        except InvalidSignature as error:
            raise ValueError("fixture signature refused") from error
        if not self.compatible(engine):
            raise ValueError("fixture engine refused")


class Registry:
    def __init__(self, key: Ed25519PrivateKey) -> None:
        self.key = key
        self.rows: dict[str, list[dict[str, object]]] = {}
        self.artifacts: dict[str, bytes] = {}
        self.pages: list[int] = []
        self.fail_url: str | None = None

    def add(
        self, identity: str, version: str, *, engine: str = "^1.0.0", prerelease: bool = False
    ) -> subject.Extension:
        vsix = payload(identity, version, engine)
        signature = archive([(".signature.sig", self.key.sign(vsix))])
        urls = subject.artifact_urls(identity, version)
        extension = subject.Extension(
            identity,
            version,
            "universal",
            subject.Artifact(urls[0], subject.sri_hash(vsix)),
            subject.Artifact(urls[1], subject.sri_hash(signature)),
        )
        self.artifacts[urls[0]], self.artifacts[urls[1]] = vsix, signature
        publisher, name = identity.split(".", 1)
        row: dict[str, object] = {
            "namespace": publisher,
            "name": name,
            "version": version,
            "targetPlatform": "universal",
            "preRelease": prerelease,
            "deprecated": False,
            "downloadable": True,
            "engines": {"vscode": engine},
            "dependencies": [],
            "bundledExtensions": [],
            "files": {"download": urls[0], "signature": urls[1]},
        }
        self.rows.setdefault(identity, []).append(row)
        return extension

    def get(self, url: str, maximum: int) -> bytes:
        if url == self.fail_url:
            raise ValueError("synthetic registry failure")
        if url in self.artifacts:
            content = self.artifacts[url]
        elif urlsplit(url).path == "/api/-/query":
            query = parse_qs(urlsplit(url).query)
            identity = query["extensionId"][0]
            offset, size = int(query["offset"][0]), int(query["size"][0])
            self.pages.append(offset)
            rows = self.rows[identity]
            content = json.dumps(
                {
                    "totalSize": len(rows),
                    "offset": offset,
                    "extensions": rows[offset : offset + size],
                }
            ).encode()
        else:
            _, _, publisher, name, version = urlsplit(url).path.split("/")
            identity = subject.canonical_id(publisher + "." + name)
            row = next(item for item in self.rows[identity] if item["version"] == version)
            content = json.dumps(row).encode()
        if len(content) > maximum:
            raise ValueError("synthetic byte limit exceeded")
        return content


class ExtensionMaintenanceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.key = Ed25519PrivateKey.generate()
        self.validator = FixtureValidator(self.key)
        self.registry = Registry(self.key)
        self.locked = tuple(
            self.registry.add(identity, "1.0.0") for identity in subject.APPROVED_IDS
        )

    def test_declared_lock_rejects_substitution_and_unknown_fields(self) -> None:
        original: object = json.loads(subject.lock_bytes(self.locked))
        for field, value in [
            ("id", "someone.unapproved"),
            ("targetPlatform", "linux-x64"),
            ("version", "1.0.0-pre"),
            ("unexpected", True),
        ]:
            with self.subTest(field=field):
                row = subject.object_value(json.loads(json.dumps(original)))
                entries = subject.array(row["extensions"])
                extension = subject.object_value(entries[0])
                extension[field] = value
                entries[0] = extension
                row["extensions"] = entries
                with self.assertRaises(ValueError):
                    subject.load_lock(json.dumps(row).encode())

    def test_signature_rejection_survives_recomputed_hashes(self) -> None:
        extension = self.locked[0]
        vsix = self.registry.artifacts[extension.vsix.url]
        signature = archive([(".signature.sig", Ed25519PrivateKey.generate().sign(vsix))])
        forged = dataclasses.replace(
            extension,
            signature=subject.Artifact(extension.signature.url, subject.sri_hash(signature)),
        )
        with self.assertRaisesRegex(ValueError, "signature refused"):
            subject.validate_artifacts(forged, vsix, signature, self.validator)

    def test_changed_bytes_fail_before_validator(self) -> None:
        extension = self.locked[0]
        with self.assertRaisesRegex(ValueError, "checksum"):
            subject.validate_artifacts(
                extension,
                self.registry.artifacts[extension.vsix.url] + b"changed",
                self.registry.artifacts[extension.signature.url],
                self.validator,
            )
        self.assertEqual(self.validator.calls, 0)

    def test_wrong_engine_fails_even_with_valid_signature(self) -> None:
        extension = self.registry.add(subject.APPROVED_IDS[0], "2.0.0", engine="^999.0.0")
        with self.assertRaisesRegex(ValueError, "engine_incompatible"):
            subject.validate_artifacts(
                extension,
                self.registry.artifacts[extension.vsix.url],
                self.registry.artifacts[extension.signature.url],
                self.validator,
            )

    def test_manifest_refuses_dependency_expansion_and_wrong_xml_platform(self) -> None:
        extension = self.locked[0]
        original = self.registry.artifacts[extension.vsix.url]
        for mutation in ("dependency", "platform", "identity"):
            with self.subTest(mutation=mutation), zipfile.ZipFile(io.BytesIO(original)) as source:
                entries = [(entry.filename, source.read(entry)) for entry in source.infolist()]
                changed: list[tuple[str, bytes]] = []
                for name, content in entries:
                    if mutation == "dependency" and name == "extension/package.json":
                        manifest = subject.object_value(json.loads(content))
                        manifest["extensionDependencies"] = ["unapproved.extension"]
                        content = json.dumps(manifest).encode()
                    if mutation == "platform" and name == "extension.vsixmanifest":
                        content = content.replace(
                            b"<Identity ", b'<Identity TargetPlatform="linux-x64" '
                        )
                    if mutation == "identity" and name == "extension/package.json":
                        content = content.replace(
                            b'"publisher": "EditorConfig"', b'"publisher": "SomeoneElse"'
                        )
                    changed.append((name, content))
                vsix = archive(changed)
                signature = archive([(".signature.sig", self.key.sign(vsix))])
                forged = dataclasses.replace(
                    extension,
                    vsix=subject.Artifact(extension.vsix.url, subject.sri_hash(vsix)),
                    signature=subject.Artifact(
                        extension.signature.url, subject.sri_hash(signature)
                    ),
                )
                with self.assertRaises(ValueError):
                    subject.validate_artifacts(forged, vsix, signature, self.validator)

    @given(
        st.sampled_from(
            [
                "../outside",
                "/outside",
                "extension/../outside",
                "extension//duplicate",
                "extension/./alias",
                "extension\\outside",
                "C:/outside",
            ]
        )
    )
    def test_archive_paths_never_escape(self, name: str) -> None:
        with (
            zipfile.ZipFile(io.BytesIO(archive([(name, b"fixture")]))) as source,
            self.assertRaises(ValueError),
        ):
            subject.archive_entries(source)

    def test_archive_duplicate_links_and_expansion_limits(self) -> None:
        duplicate = io.BytesIO()
        with zipfile.ZipFile(duplicate, "w") as output:
            output.writestr("extension/a", b"a")
            with self.assertWarns(UserWarning):
                output.writestr("extension/a", b"b")
        with (
            zipfile.ZipFile(io.BytesIO(duplicate.getvalue())) as source,
            self.assertRaises(ValueError),
        ):
            subject.archive_entries(source)
        symlink = io.BytesIO()
        with zipfile.ZipFile(symlink, "w") as output:
            entry = zipfile.ZipInfo("extension/link")
            entry.external_attr = (stat.S_IFLNK | 0o777) << 16
            output.writestr(entry, "outside")
        with (
            zipfile.ZipFile(io.BytesIO(symlink.getvalue())) as source,
            self.assertRaises(ValueError),
        ):
            subject.archive_entries(source)
        with (
            patch.object(subject, "MAX_EXPANDED_BYTES", 3),
            zipfile.ZipFile(io.BytesIO(archive([("extension/big", b"aaaa")]))) as source,
            self.assertRaises(ValueError),
        ):
            subject.archive_entries(source)

    def test_successful_extraction_preserves_all_extension_bytes(self) -> None:
        extension = self.locked[0]
        vsix, signature = (
            self.registry.artifacts[extension.vsix.url],
            self.registry.artifacts[extension.signature.url],
        )
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "builtin"
            subject.extract_extension(extension, vsix, signature, self.validator, output)
            with zipfile.ZipFile(io.BytesIO(vsix)) as source:
                for entry in source.infolist():
                    if entry.filename.startswith("extension/"):
                        self.assertEqual(
                            (output / entry.filename.removeprefix("extension/")).read_bytes(),
                            source.read(entry),
                        )

    def test_failed_validation_publishes_no_builtin_directory(self) -> None:
        extension = self.locked[0]
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "builtin"
            with self.assertRaises(ValueError):
                subject.extract_extension(extension, b"wrong", b"wrong", self.validator, output)
            self.assertFalse(output.exists())
            self.assertEqual(list(Path(temporary).iterdir()), [])

    @settings(max_examples=8, deadline=None)
    @given(st.integers(min_value=101, max_value=130))
    def test_stable_selection_paginates_nightly_versions(self, nightly_count: int) -> None:
        registry = Registry(self.key)
        identity = subject.APPROVED_IDS[0]
        for offset in range(nightly_count):
            registry.add(identity, f"0.4.{offset}", prerelease=True)
        registry.add(identity, "0.3.99")
        expected = registry.add(identity, "0.3.100")
        registry.add(identity, "0.3.101", engine="^999.0.0")
        self.assertEqual(
            subject.resolve_extension(identity, None, registry, self.validator), expected
        )
        self.assertIn(100, registry.pages)

    def test_partial_failure_preserves_old_lock(self) -> None:
        for identity in subject.APPROVED_IDS:
            self.registry.add(identity, "2.0.0")
        self.registry.fail_url = subject.artifact_urls(subject.APPROVED_IDS[-1], "2.0.0")[1]
        original = subject.lock_bytes(self.locked)
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "lock.json"
            path.write_bytes(original)
            with self.assertRaises(ValueError):
                subject.update_lock(path, (), {}, self.registry, self.validator, write=True)
            self.assertEqual(path.read_bytes(), original)
            self.assertEqual([item.name for item in path.parent.iterdir()], ["lock.json"])

    def test_only_version_check_and_atomic_write(self) -> None:
        identity = subject.APPROVED_IDS[0]
        selected = self.registry.add(identity, "2.0.0")
        original = subject.lock_bytes(self.locked)
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "lock.json"
            path.write_bytes(original)
            versions = subject.parse_versions(["2.0.0"], (identity,))
            self.assertTrue(
                subject.update_lock(
                    path, (identity,), versions, self.registry, self.validator, write=False
                )
            )
            self.assertEqual(path.read_bytes(), original)
            with patch.object(subject.os, "fsync", wraps=os.fsync) as fsync:
                self.assertTrue(
                    subject.update_lock(
                        path, (identity,), versions, self.registry, self.validator, write=True
                    )
                )
                self.assertEqual(fsync.call_count, 2)
            updated = subject.load_lock(path.read_bytes())
            self.assertEqual(next(item for item in updated if item.id == identity), selected)
            self.assertEqual(
                [item for item in updated if item.id != identity],
                [item for item in self.locked if item.id != identity],
            )

    def test_observed_concurrent_change_and_fsync_failure_preserve_lock(self) -> None:
        original = subject.lock_bytes(self.locked)
        replacement = subject.lock_bytes(
            tuple(
                dataclasses.replace(
                    item,
                    version="2.0.0",
                    vsix=subject.Artifact(
                        subject.artifact_urls(item.id, "2.0.0")[0], item.vsix.hash
                    ),
                    signature=subject.Artifact(
                        subject.artifact_urls(item.id, "2.0.0")[1], item.signature.hash
                    ),
                )
                for item in self.locked
            )
        )
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "lock.json"
            path.write_bytes(original + b" ")
            with self.assertRaisesRegex(ValueError, "lock_changed"):
                subject.atomic_publish(path, original, replacement)
            self.assertEqual(path.read_bytes(), original + b" ")
            path.write_bytes(original)
            with (
                patch.object(subject.os, "fsync", side_effect=OSError("synthetic fsync failure")),
                self.assertRaises(OSError),
            ):
                subject.atomic_publish(path, original, replacement)
            self.assertEqual(path.read_bytes(), original)
            self.assertEqual([item.name for item in path.parent.iterdir()], ["lock.json"])

    def test_metadata_identity_platform_and_dependency_refusals(self) -> None:
        identity = subject.APPROVED_IDS[0]
        original = self.registry.rows[identity][0]
        for field, value in [
            ("namespace", "someone"),
            ("targetPlatform", "linux-x64"),
            ("preRelease", True),
            ("preRelease", 0),
            ("deprecated", True),
            ("dependencies", ["unapproved.extension"]),
            ("version", "1.0.0-preview"),
        ]:
            with self.subTest(field=field):
                changed = {**original, field: value}
                with self.assertRaises(ValueError):
                    subject.metadata_engine(changed, identity)

    def test_post_rename_durability_failure_preserves_complete_new_lock(self) -> None:
        original = subject.lock_bytes(self.locked)
        changed = self.registry.add(subject.APPROVED_IDS[0], "2.0.0")
        replacement = subject.lock_bytes(
            tuple(changed if item.id == changed.id else item for item in self.locked)
        )
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "lock.json"
            path.write_bytes(original)
            with (
                patch.object(
                    subject.os,
                    "fsync",
                    side_effect=[None, OSError("synthetic directory fsync failure")],
                ),
                self.assertRaisesRegex(subject.MaintenanceError, "publication_durability_unknown"),
            ):
                subject.atomic_publish(path, original, replacement)
            self.assertEqual(path.read_bytes(), replacement)
            self.assertEqual(subject.load_lock(path.read_bytes()), subject.load_lock(replacement))
            self.assertEqual([item.name for item in path.parent.iterdir()], ["lock.json"])

    def test_pagination_refuses_duplicate_and_changed_scope(self) -> None:
        identity = subject.APPROVED_IDS[0]
        self.registry.add(identity, "1.0.0")
        with self.assertRaisesRegex(ValueError, "duplicate"):
            subject.stable_candidates(identity, self.registry)
        self.registry.rows[identity][1]["version"] = "2.0.0"
        self.registry.rows[identity][1]["targetPlatform"] = "linux-x64"
        with self.assertRaisesRegex(ValueError, "platform"):
            subject.stable_candidates(identity, self.registry)

    def test_structured_check_results_and_closed_failure_reason(self) -> None:
        identity = subject.APPROVED_IDS[0]
        self.registry.add(identity, "2.0.0")
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "lock.json"
            original = subject.lock_bytes(self.locked)
            path.write_bytes(original)
            args = [
                "--lock",
                str(path),
                "--node",
                "fixture",
                "--validator",
                "fixture",
                "--editor-version",
                "1.141.0",
                "--only",
                identity,
            ]
            output = io.StringIO()
            with (
                patch.object(subject, "NetworkTransport", return_value=self.registry),
                patch.object(subject, "validator_arguments", return_value=self.validator),
                contextlib.redirect_stdout(output),
            ):
                self.assertEqual(subject.update_main(args), 1)
            report = subject.object_value(json.loads(output.getvalue()))
            self.assertEqual(
                report,
                {
                    "outcome": "stale",
                    "extensions": [
                        {
                            "id": identity,
                            "fromVersion": "1.0.0",
                            "version": "2.0.0",
                            "changed": True,
                        }
                    ],
                },
            )
            self.assertEqual(path.read_bytes(), original)
            failure = io.StringIO()
            with (
                patch.object(
                    subject,
                    "NetworkTransport",
                    side_effect=subject.MaintenanceError("download_failed"),
                ),
                contextlib.redirect_stderr(failure),
            ):
                self.assertEqual(subject.update_main(args), 2)
            self.assertEqual(
                subject.object_value(json.loads(failure.getvalue())),
                {"outcome": "failed", "reason": "download_failed"},
            )

    def test_project_adapters_preserve_arguments_and_refuse_missing_tools(self) -> None:
        shell = os.environ.get("TEST_SHELL", "/bin/sh")
        adapters = {
            "language_server.sh": ("elixir-ls", "project_elixir_ls_unavailable"),
            "debug_adapter.sh": (
                "elixir-debug-adapter",
                "project_elixir_debug_adapter_unavailable",
            ),
            "elixir_check.sh": ("elixir", "project_elixir_unavailable"),
        }
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            environment = {**os.environ, "PATH": str(directory)}
            for adapter, (command, failure) in adapters.items():
                with self.subTest(adapter=adapter):
                    path = HERE / "project-language-adapters" / adapter
                    result = subprocess.run(
                        [shell, str(path)], env=environment, capture_output=True, check=False
                    )
                    self.assertEqual(
                        (result.returncode, result.stdout, result.stderr),
                        (127, b"", (failure + "\n").encode()),
                    )
                    tool = directory / command
                    tool.write_text(f'#!{shell}\nprintf "%s\\n" "$@"\nexit 7\n')
                    tool.chmod(0o755)
                    result = subprocess.run(
                        [shell, str(path), "a b", "", "--flag"],
                        env=environment,
                        capture_output=True,
                        check=False,
                    )
                    self.assertEqual(
                        (result.returncode, result.stdout, result.stderr),
                        (7, b"a b\n\n--flag\n", b""),
                    )
                    tool.unlink()

    @unittest.skipUnless(
        os.environ.get("TEST_NODE") and os.environ.get("TEST_VALIDATOR"),
        "actual packaged validator is exercised by the Nix maintenance check",
    )
    def test_actual_packaged_signature_and_engine_boundary(self) -> None:
        extension = self.locked[0]
        with tempfile.TemporaryDirectory() as temporary:
            key = Path(temporary) / "public.pem"
            key.write_bytes(
                self.key.public_key().public_bytes(
                    serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo
                )
            )
            validator = subject.NodeValidator(
                os.environ["TEST_NODE"], Path(os.environ["TEST_VALIDATOR"]), (key,), "1.141.0"
            )
            self.assertTrue(validator.compatible("^1.0.0"))
            self.assertFalse(validator.compatible("^999.0.0"))
            vsix = self.registry.artifacts[extension.vsix.url]
            signature = self.registry.artifacts[extension.signature.url]
            subject.validate_artifacts(extension, vsix, signature, validator)
            bad_signature = archive([(".signature.sig", Ed25519PrivateKey.generate().sign(vsix))])
            rejected = dataclasses.replace(
                extension,
                signature=subject.Artifact(
                    extension.signature.url, subject.sri_hash(bad_signature)
                ),
            )
            with self.assertRaises(ValueError):
                subject.validate_artifacts(rejected, vsix, bad_signature, validator)


if __name__ == "__main__":
    try:
        unittest.main()
    finally:
        HYPOTHESIS_DIRECTORY.cleanup()
