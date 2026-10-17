"""Validate, extract and maintain the declared immutable Open VSX defaults."""

from __future__ import annotations

import argparse
import base64
import hashlib
import http.client
import io
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import urllib.request
import xml.etree.ElementTree as ET
import zipfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import IO, Literal, Protocol
from urllib.parse import urlencode, urlsplit

HERE = Path(__file__).resolve().parent
APPROVED_IDS = (
    "EditorConfig.EditorConfig",
    "cab404.vscode-direnv",
    "elixir-lsp.elixir-ls",
    "rust-lang.rust-analyzer",
)
MAX_VSIX_BYTES = 256 * 1024 * 1024
MAX_SIGNATURE_BYTES = 1024 * 1024
MAX_MANIFEST_BYTES = 1024 * 1024
MAX_METADATA_BYTES = 4 * 1024 * 1024
MAX_EXPANDED_BYTES = 512 * 1024 * 1024
MAX_ENTRIES = 100_000
PAGE_SIZE = 100
MAX_VERSIONS = 20_000
VERSION_PATTERN = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")
XML_NAMESPACE = "http://schemas.microsoft.com/developer/vsx-schema/2011"

type FailureReason = Literal[
    "metadata_invalid",
    "signature_refused",
    "lock_changed",
    "download_failed",
    "archive_invalid",
    "checksum_mismatch",
    "engine_incompatible",
    "validation_failed",
    "publication_durability_unknown",
]


class MaintenanceError(ValueError):
    def __init__(self, reason: FailureReason) -> None:
        super().__init__(reason)
        self.reason = reason


@dataclass(frozen=True)
class UpdateResult:
    id: str
    from_version: str
    version: str
    changed: bool

    def json(self) -> dict[str, str | bool]:
        return {
            "id": self.id,
            "fromVersion": self.from_version,
            "version": self.version,
            "changed": self.changed,
        }


def object_value(value: object) -> dict[str, object]:
    if not isinstance(value, dict):
        raise ValueError("expected object")
    result: dict[str, object] = {}
    for key, item in value.items():
        if not isinstance(key, str):
            raise ValueError("expected string object key")
        result[key] = item
    return result


def string(value: object) -> str:
    if not isinstance(value, str) or not value or len(value) > 4096:
        raise ValueError("expected bounded nonempty string")
    return value


def integer(value: object) -> int:
    if type(value) is not int:
        raise ValueError("expected integer")
    return value


def array(value: object) -> list[object]:
    if not isinstance(value, list):
        raise ValueError("expected array")
    return list(value)


def exact_fields(row: dict[str, object], expected: set[str]) -> None:
    if set(row) != expected:
        raise ValueError("unexpected or missing schema fields")


def version_key(value: str) -> tuple[int, int, int]:
    match = VERSION_PATTERN.fullmatch(value)
    if match is None:
        raise ValueError("expected stable three-component version")
    major, minor, patch = match.groups()
    return int(major), int(minor), int(patch)


def canonical_id(value: str) -> str:
    for approved in APPROVED_IDS:
        if value.casefold() == approved.casefold():
            return approved
    raise ValueError("extension identity is not approved")


def sri_hash(content: bytes) -> str:
    return "sha256-" + base64.b64encode(hashlib.sha256(content).digest()).decode("ascii")


def validate_hash(value: str) -> str:
    if not value.startswith("sha256-"):
        raise ValueError("expected SHA256 SRI hash")
    try:
        digest = base64.b64decode(value[7:], validate=True)
    except ValueError as error:
        raise ValueError("malformed SHA256 SRI hash") from error
    if len(digest) != 32 or base64.b64encode(digest).decode("ascii") != value[7:]:
        raise ValueError("malformed SHA256 SRI hash")
    return value


def artifact_urls(identity: str, version: str) -> tuple[str, str]:
    publisher, name = canonical_id(identity).split(".", 1)
    version_key(version)
    prefix = (
        f"https://open-vsx.org/api/{publisher}/{name}/{version}/file/{publisher}.{name}-{version}"
    )
    return prefix + ".vsix", prefix + ".sigzip"


@dataclass(frozen=True)
class Artifact:
    url: str
    hash: str

    def json(self) -> dict[str, str]:
        return {"url": self.url, "hash": self.hash}


@dataclass(frozen=True)
class Extension:
    id: str
    version: str
    target_platform: str
    vsix: Artifact
    signature: Artifact

    def json(self) -> dict[str, object]:
        return {
            "id": self.id,
            "version": self.version,
            "targetPlatform": self.target_platform,
            "vsix": self.vsix.json(),
            "signature": self.signature.json(),
        }


def extension_value(value: object) -> Extension:
    row = object_value(value)
    exact_fields(row, {"id", "version", "targetPlatform", "vsix", "signature"})
    identity = canonical_id(string(row["id"]))
    if row["id"] != identity or row["targetPlatform"] != "universal":
        raise ValueError("expected canonical identity and universal target")
    version = string(row["version"])
    expected_urls = artifact_urls(identity, version)
    artifacts: list[Artifact] = []
    for field, expected_url in zip(("vsix", "signature"), expected_urls, strict=True):
        artifact = object_value(row[field])
        exact_fields(artifact, {"url", "hash"})
        if artifact["url"] != expected_url:
            raise ValueError("artifact URL does not match pinned identity")
        artifacts.append(Artifact(expected_url, validate_hash(string(artifact["hash"]))))
    return Extension(identity, version, "universal", artifacts[0], artifacts[1])


def load_lock(content: bytes) -> tuple[Extension, ...]:
    value: object = json.loads(content)
    row = object_value(value)
    exact_fields(row, {"version", "extensions"})
    if integer(row["version"]) != 1:
        raise ValueError("unsupported extension lock schema")
    extensions = tuple(extension_value(item) for item in array(row["extensions"]))
    if sorted(item.id for item in extensions) != sorted(APPROVED_IDS):
        raise ValueError("extension lock must contain exactly the approved defaults")
    return tuple(sorted(extensions, key=lambda item: item.id))


def lock_bytes(extensions: tuple[Extension, ...]) -> bytes:
    row = {
        "version": 1,
        "extensions": [item.json() for item in sorted(extensions, key=lambda i: i.id)],
    }
    result = (json.dumps(row, indent=2) + "\n").encode("utf-8")
    load_lock(result)
    return result


def read_bounded(path: Path, maximum: int) -> bytes:
    if not path.is_file():
        raise ValueError("artifact must be a regular file")
    with path.open("rb") as source:
        content = source.read(maximum + 1)
    if not content or len(content) > maximum:
        raise ValueError("artifact exceeds byte limit or is empty")
    return content


class Validator(Protocol):
    def compatible(self, engine: str) -> bool: ...

    def verify(self, vsix: Path, signature: Path, engine: str) -> None: ...


@dataclass(frozen=True)
class NodeValidator:
    node: str
    script: Path
    keys: tuple[Path, ...]
    editor_version: str

    def command(self, engine: str) -> list[str]:
        version_key(self.editor_version)
        if not self.keys or len(self.keys) > 16:
            raise ValueError("expected reviewed signing key ring")
        return [
            self.node,
            str(self.script),
            "--engine",
            engine,
            "--editor-version",
            self.editor_version,
        ]

    def compatible(self, engine: str) -> bool:
        command = self.command(engine)
        result = subprocess.run(
            [*command[:2], "--engine-only", *command[2:]],
            capture_output=True,
            timeout=120,
            check=False,
        )
        if result.returncode == 0 and result.stdout == b"compatible\n":
            return True
        if result.returncode == 3 and result.stdout == b"incompatible\n":
            return False
        raise MaintenanceError("validation_failed")

    def verify(self, vsix: Path, signature: Path, engine: str) -> None:
        """@cc [owner:ghuntley,label:security] bundled-upstream-signature-boundary
        Artifact validation MUST invoke the actual packaged signature and engine
        validator with only reviewed caller-supplied keys; any refusal MUST fail.
        """
        arguments = [*self.command(engine), "--vsix", str(vsix), "--signature", str(signature)]
        for key in self.keys:
            arguments.extend(("--key", str(key)))
        result = subprocess.run(arguments, capture_output=True, timeout=120, check=False)
        if result.returncode != 0 or result.stdout != b"validated\n":
            raise MaintenanceError("signature_refused")


def archive_entries(source: zipfile.ZipFile, *, signature: bool = False) -> list[zipfile.ZipInfo]:
    """@cc [owner:ghuntley,label:security] bundled-safe-archive
    Archives MUST reject duplicate, noncanonical, escaping, encrypted and link
    entries, unsupported compression and bounded entry/expanded-byte overruns.
    """
    entries = source.infolist()
    maximum = MAX_SIGNATURE_BYTES if signature else MAX_EXPANDED_BYTES
    if not entries or len(entries) > (16 if signature else MAX_ENTRIES):
        raise ValueError("archive entry limit exceeded")
    names: set[str] = set()
    expanded = 0
    for entry in entries:
        name = entry.orig_filename.removesuffix("/")
        path = PurePosixPath(name)
        if (
            not name
            or len(name) > 4096
            or "\\" in name
            or ":" in name
            or "\x00" in name
            or path.is_absolute()
            or any(part in ("", ".", "..") for part in name.split("/"))
            or path.as_posix() != name
            or name in names
        ):
            raise ValueError("unsafe or duplicate archive path")
        names.add(name)
        mode = stat.S_IFMT(entry.external_attr >> 16)
        if mode not in (0, stat.S_IFREG, stat.S_IFDIR) or (
            (mode == stat.S_IFDIR) != entry.is_dir() and mode != 0
        ):
            raise ValueError("archive entry is not a regular file or directory")
        if entry.flag_bits & 1 or entry.compress_type not in (
            zipfile.ZIP_STORED,
            zipfile.ZIP_DEFLATED,
        ):
            raise ValueError("encrypted or unsupported archive entry")
        expanded += entry.file_size
        if expanded > maximum:
            raise ValueError("archive expanded byte limit exceeded")
        if (
            not signature
            and name not in ("[Content_Types].xml", "extension.vsixmanifest", "extension")
            and not name.startswith("extension/")
        ):
            raise ValueError("unexpected VSIX archive root")
    return entries


def read_entry(source: zipfile.ZipFile, name: str, maximum: int) -> bytes:
    entry = source.getinfo(name)
    if entry.is_dir() or entry.file_size > maximum:
        raise ValueError("invalid bounded archive member")
    with source.open(entry) as content:
        result = content.read(maximum + 1)
    if len(result) > maximum or len(result) != entry.file_size:
        raise ValueError("archive member byte limit exceeded")
    return result


def manifest_engine(source: zipfile.ZipFile, extension: Extension) -> str:
    raw = read_entry(source, "extension/package.json", MAX_MANIFEST_BYTES)
    value: object = json.loads(raw)
    row = object_value(value)
    if (
        f"{string(row.get('publisher'))}.{string(row.get('name'))}".casefold()
        != extension.id.casefold()
        or row.get("version") != extension.version
    ):
        raise ValueError("VSIX manifest identity or version mismatch")
    if row.get("extensionDependencies", []) != [] or row.get("extensionPack", []) != []:
        raise ValueError("undeclared extension dependencies or packs")
    main = string(row.get("main"))
    if PurePosixPath(main).is_absolute() or ".." in main.split("/") or "\\" in main:
        raise ValueError("invalid native extension entry point")
    kinds = row.get("extensionKind")
    if kinds is not None and (not isinstance(kinds, list) or "workspace" not in kinds):
        raise ValueError("default extension must support the workspace host")
    engine = string(object_value(row.get("engines")).get("vscode"))
    xml = read_entry(source, "extension.vsixmanifest", MAX_MANIFEST_BYTES)
    if b"<!DOCTYPE" in xml.upper() or b"<!ENTITY" in xml.upper():
        raise ValueError("VSIX XML entities are forbidden")
    root = ET.fromstring(xml)
    identities = root.findall(f".//{{{XML_NAMESPACE}}}Identity")
    if len(identities) != 1:
        raise ValueError("expected one VSIX identity")
    identity = identities[0].attrib
    if (
        f"{identity.get('Publisher', '')}.{identity.get('Id', '')}".casefold()
        != extension.id.casefold()
        or identity.get("Version") != extension.version
        or identity.get("TargetPlatform", "universal") != extension.target_platform
    ):
        raise ValueError("VSIX XML identity or platform mismatch")
    return engine


def validate_artifacts(
    extension: Extension, vsix: bytes, signature: bytes, validator: Validator
) -> str:
    """@cc [owner:ghuntley,label:security] bundled-whole-artifact-verification
    Validation MUST bind the pinned hashes, bounded safe archives, exact manifest
    identity/platform/dependency scope and upstream signature/engine acceptance
    before any extension payload is published or executed.
    """
    if (
        not vsix
        or len(vsix) > MAX_VSIX_BYTES
        or not signature
        or len(signature) > MAX_SIGNATURE_BYTES
    ):
        raise MaintenanceError("archive_invalid")
    if sri_hash(vsix) != extension.vsix.hash or sri_hash(signature) != extension.signature.hash:
        raise MaintenanceError("checksum_mismatch")
    try:
        with zipfile.ZipFile(io.BytesIO(signature)) as source:
            archive_entries(source, signature=True)
            if len(read_entry(source, ".signature.sig", 64)) != 64:
                raise ValueError("expected Ed25519 signature")
        with zipfile.ZipFile(io.BytesIO(vsix)) as source:
            archive_entries(source)
            engine = manifest_engine(source, extension)
    except (ValueError, KeyError, zipfile.BadZipFile, ET.ParseError) as error:
        raise MaintenanceError("archive_invalid") from error
    if not validator.compatible(engine):
        raise MaintenanceError("engine_incompatible")
    with tempfile.TemporaryDirectory(prefix="overalls-extension-verify-") as temporary:
        root = Path(temporary)
        vsix_path, signature_path = root / "extension.vsix", root / "extension.sigzip"
        vsix_path.write_bytes(vsix)
        signature_path.write_bytes(signature)
        validator.verify(vsix_path, signature_path, engine)
    # CRC/truncation failures in any payload member must be found before the
    # updater accepts the candidate, rather than only during later extraction.
    try:
        with zipfile.ZipFile(io.BytesIO(vsix)) as source:
            expanded = 0
            for entry in archive_entries(source):
                if entry.is_dir():
                    continue
                size = 0
                with source.open(entry) as content:
                    while chunk := content.read(64 * 1024):
                        size += len(chunk)
                        expanded += len(chunk)
                        if size > entry.file_size or expanded > MAX_EXPANDED_BYTES:
                            raise ValueError("archive payload byte limit exceeded")
                if size != entry.file_size:
                    raise ValueError("truncated archive member")
    except (ValueError, zipfile.BadZipFile) as error:
        raise MaintenanceError("archive_invalid") from error
    return engine


def extract_extension(
    extension: Extension, vsix: bytes, signature: bytes, validator: Validator, output: Path
) -> None:
    """@cc [owner:ghuntley,label:build] bundled-payload-preservation
    Extraction MUST retain the verified extension payload bytes and publish one
    complete new directory; validation/extraction failure MUST publish no payload.
    """
    validate_artifacts(extension, vsix, signature, validator)
    if output.exists() or output.is_symlink():
        raise ValueError("builtin destination already exists")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".overalls-extension-", dir=output.parent) as temporary:
        root = Path(temporary)
        staging = root / "extension"
        staging.mkdir()
        with zipfile.ZipFile(io.BytesIO(vsix)) as source:
            for entry in archive_entries(source):
                if not entry.filename.startswith("extension/"):
                    continue
                relative = entry.filename.removeprefix("extension/").removesuffix("/")
                if not relative:
                    continue
                target = staging / relative
                if entry.is_dir():
                    target.mkdir(parents=True, exist_ok=True)
                    continue
                target.parent.mkdir(parents=True, exist_ok=True)
                with source.open(entry) as content, target.open("xb") as destination:
                    shutil.copyfileobj(content, destination, length=64 * 1024)
                if target.stat().st_size != entry.file_size:
                    raise ValueError("extracted member size mismatch")
                target.chmod(0o755 if entry.external_attr >> 16 & 0o111 else 0o644)
        staging.rename(output)


class Transport(Protocol):
    def get(self, url: str, maximum: int) -> bytes: ...


class HTTPSRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(
        self,
        req: urllib.request.Request,
        fp: IO[bytes],
        code: int,
        msg: str,
        headers: http.client.HTTPMessage,
        newurl: str,
    ) -> urllib.request.Request | None:
        if urlsplit(newurl).scheme != "https":
            raise ValueError("registry redirect must retain HTTPS")
        # Keep urllib's redirect header filtering: forwarding the original Host
        # to the content CDN causes a misdirected request.
        request: object = super().redirect_request(req, fp, code, msg, headers, newurl)
        if request is None or isinstance(request, urllib.request.Request):
            return request
        raise ValueError("invalid registry redirect")


class NetworkTransport:
    def get(self, url: str, maximum: int) -> bytes:
        if urlsplit(url).scheme != "https" or urlsplit(url).hostname != "open-vsx.org":
            raise ValueError("unexpected extension registry URL")
        opener = urllib.request.build_opener(HTTPSRedirect())
        request = urllib.request.Request(
            url, headers={"User-Agent": "Overalls-extension-pin-updater/1"}
        )
        try:
            with opener.open(request, timeout=30) as response:
                content: bytes = response.read(maximum + 1)
        except OSError as error:
            raise MaintenanceError("download_failed") from error
        if not content or len(content) > maximum:
            raise MaintenanceError("download_failed")
        return content


def metadata_engine(value: object, identity: str, version: str | None = None) -> tuple[str, str]:
    row = object_value(value)
    if (
        f"{string(row.get('namespace'))}.{string(row.get('name'))}".casefold()
        != identity.casefold()
        or row.get("targetPlatform") != "universal"
    ):
        raise ValueError("registry identity or platform mismatch")
    release = string(row.get("version"))
    version_key(release)
    if version is not None and release != version:
        raise ValueError("registry version mismatch")
    if (
        row.get("preRelease") is not False
        or row.get("deprecated") is not False
        or row.get("downloadable") is not True
    ):
        raise ValueError("extension must be stable, downloadable and maintained")
    if row.get("dependencies", []) != [] or row.get("bundledExtensions", []) != []:
        raise ValueError("registry dependency expansion is not approved")
    return release, string(object_value(row.get("engines")).get("vscode"))


def stable_candidates(identity: str, transport: Transport) -> list[tuple[str, str]]:
    """@cc [owner:ghuntley,label:build] extension-stable-pagination
    Resolution MUST inspect every bounded consistent registry page and select
    explicit stable metadata rather than generic latest or version suffixes.
    Wrong identities/platforms, duplicate versions or incomplete pages MUST fail.
    """
    candidates: list[tuple[str, str]] = []
    seen: set[str] = set()
    total: int | None = None
    offset = 0
    while total is None or offset < total:
        query = urlencode(
            {
                "extensionId": identity,
                "targetPlatform": "universal",
                "includeAllVersions": "true",
                "size": PAGE_SIZE,
                "offset": offset,
            }
        )
        value: object = json.loads(
            transport.get("https://open-vsx.org/api/-/query?" + query, MAX_METADATA_BYTES)
        )
        row = object_value(value)
        current_total = integer(row.get("totalSize"))
        if (
            not 0 < current_total <= MAX_VERSIONS
            or integer(row.get("offset")) != offset
            or (total is not None and current_total != total)
        ):
            raise ValueError("inconsistent or oversized registry pagination")
        total = current_total
        page = array(row.get("extensions"))
        if len(page) != min(PAGE_SIZE, total - offset):
            raise ValueError("incomplete registry page")
        for item in page:
            metadata = object_value(item)
            if (
                f"{string(metadata.get('namespace'))}.{string(metadata.get('name'))}".casefold()
                != identity.casefold()
                or metadata.get("targetPlatform") != "universal"
            ):
                raise ValueError("registry page identity or platform mismatch")
            version = string(metadata.get("version"))
            if version in seen:
                raise ValueError("duplicate registry version")
            seen.add(version)
            if metadata.get("preRelease") is True:
                continue
            candidates.append(metadata_engine(metadata, identity))
        offset += len(page)
    return sorted(candidates, key=lambda candidate: version_key(candidate[0]), reverse=True)


def resolve_extension(
    identity: str, version: str | None, transport: Transport, validator: Validator
) -> Extension:
    identity = canonical_id(identity)
    if version is None:
        candidates = stable_candidates(identity, transport)
        version = next(
            (release for release, engine in candidates if validator.compatible(engine)), None
        )
        if version is None:
            raise ValueError("no compatible stable extension release")
    else:
        version_key(version)
    publisher, name = identity.split(".", 1)
    value: object = json.loads(
        transport.get(f"https://open-vsx.org/api/{publisher}/{name}/{version}", MAX_METADATA_BYTES)
    )
    _, engine = metadata_engine(value, identity, version)
    if not validator.compatible(engine):
        raise MaintenanceError("engine_incompatible")
    files = object_value(object_value(value).get("files"))
    vsix_url, signature_url = artifact_urls(identity, version)
    if files.get("download") != vsix_url or files.get("signature") != signature_url:
        raise ValueError("registry artifact URLs do not match identity")
    vsix = transport.get(vsix_url, MAX_VSIX_BYTES)
    signature = transport.get(signature_url, MAX_SIGNATURE_BYTES)
    extension = Extension(
        identity,
        version,
        "universal",
        Artifact(vsix_url, sri_hash(vsix)),
        Artifact(signature_url, sri_hash(signature)),
    )
    if validate_artifacts(extension, vsix, signature, validator) != engine:
        raise ValueError("registry and VSIX engine mismatch")
    return extension


def atomic_publish(path: Path, expected: bytes, replacement: bytes) -> None:
    """@cc [owner:ghuntley,label:build] extension-lock-atomic-publication
    Publication MUST replace the lock only after complete validation. Failures
    before replacement and observed concurrent edits MUST preserve the existing
    lock and remove temporary files. Publication MUST NOT follow a lock symlink.
    """
    if path.is_symlink():
        raise ValueError("lock must not be a symlink")
    load_lock(replacement)
    descriptor, filename = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(filename)
    try:
        with os.fdopen(descriptor, "wb") as destination:
            destination.write(replacement)
            destination.flush()
            os.fsync(destination.fileno())
        if path.is_symlink() or path.read_bytes() != expected:
            raise MaintenanceError("lock_changed")
        temporary.chmod(stat.S_IMODE(path.stat().st_mode))
        os.replace(temporary, path)
        try:
            directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        except OSError as error:
            raise MaintenanceError("publication_durability_unknown") from error
    finally:
        temporary.unlink(missing_ok=True)


def update_lock(
    path: Path,
    selected: tuple[str, ...],
    versions: dict[str, str],
    transport: Transport,
    validator: Validator,
    *,
    write: bool,
    report: list[UpdateResult] | None = None,
) -> bool:
    original = read_bounded(path, MAX_METADATA_BYTES)
    locked = load_lock(original)
    identities = set(canonical_id(item) for item in selected) if selected else set(APPROVED_IDS)
    if not set(versions).issubset(identities):
        raise ValueError("version request is outside selected extension set")
    resolved: list[Extension] = []
    results: list[UpdateResult] = []
    for extension in locked:
        if extension.id not in identities:
            resolved.append(extension)
            continue
        candidate = resolve_extension(
            extension.id, versions.get(extension.id), transport, validator
        )
        if extension.id not in versions and version_key(candidate.version) < version_key(
            extension.version
        ):
            raise ValueError("automatic extension downgrade refused")
        resolved.append(candidate)
        results.append(
            UpdateResult(extension.id, extension.version, candidate.version, candidate != extension)
        )
    replacement = lock_bytes(tuple(resolved))
    changed = load_lock(original) != load_lock(replacement)
    if changed and write:
        atomic_publish(path, original, replacement)
    if report is not None:
        report.extend(results)
    return changed


def parse_versions(values: list[str], selected: tuple[str, ...]) -> dict[str, str]:
    result: dict[str, str] = {}
    for value in values:
        if "=" in value:
            identity, version = value.split("=", 1)
            identity = canonical_id(identity)
        elif len(selected) == 1:
            identity, version = canonical_id(selected[0]), value
        else:
            raise ValueError("bare version requires exactly one --only")
        version_key(version)
        if identity in result:
            raise ValueError("duplicate requested extension version")
        result[identity] = version
    return result


def common_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--lock", type=Path, default=HERE / "extensions.lock.json")
    parser.add_argument("--node", required=True)
    parser.add_argument("--validator", type=Path, required=True)
    parser.add_argument("--key", type=Path, action="append", default=[])
    parser.add_argument("--editor-version", required=True)


def validator_arguments(arguments: dict[str, object]) -> NodeValidator:
    keys = tuple(item for item in array(arguments["key"]) if isinstance(item, Path))
    if len(keys) != len(array(arguments["key"])):
        raise ValueError("invalid key paths")
    script = arguments["validator"]
    if not isinstance(script, Path):
        raise ValueError("invalid validator path")
    return NodeValidator(
        string(arguments["node"]),
        script,
        keys or (HERE / "open-vsx-key.pem",),
        string(arguments["editor_version"]),
    )


def update_main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Review or atomically update only the approved Open VSX extension pins.",
        allow_abbrev=False,
    )
    common_arguments(parser)
    parser.set_defaults(lock=Path.cwd() / "nix/domains/artifacts/vscode-web/extensions.lock.json")
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--check", action="store_true")
    modes.add_argument("--write", action="store_true")
    parser.add_argument("--only", action="append", default=[])
    parser.add_argument("--version", action="append", default=[])
    arguments: dict[str, object] = vars(parser.parse_args(argv))
    try:
        selected = tuple(canonical_id(string(item)) for item in array(arguments["only"]))
        versions = parse_versions([string(item) for item in array(arguments["version"])], selected)
        path = arguments["lock"]
        if not isinstance(path, Path):
            raise ValueError("invalid lock path")
        report: list[UpdateResult] = []
        changed = update_lock(
            path,
            selected,
            versions,
            NetworkTransport(),
            validator_arguments(arguments),
            write=arguments["write"] is True,
            report=report,
        )
        outcome = (
            "updated"
            if changed and arguments["write"] is True
            else "stale"
            if changed
            else "current"
        )
        print(
            json.dumps(
                {"outcome": outcome, "extensions": [item.json() for item in report]}, sort_keys=True
            )
        )
        return 1 if changed and arguments["write"] is not True else 0
    except (
        ValueError,
        OSError,
        subprocess.SubprocessError,
        zipfile.BadZipFile,
        ET.ParseError,
        KeyError,
    ) as error:
        reason: FailureReason = (
            error.reason
            if isinstance(error, MaintenanceError)
            else "metadata_invalid"
            if isinstance(error, (ValueError, KeyError))
            else "validation_failed"
        )
        outcome = "durability_unknown" if reason == "publication_durability_unknown" else "failed"
        print(json.dumps({"outcome": outcome, "reason": reason}), file=sys.stderr)
        return 2


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument("command", choices=["extract"])
    common_arguments(parser)
    parser.add_argument("--id", required=True)
    parser.add_argument("--vsix", type=Path, required=True)
    parser.add_argument("--signature", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments: dict[str, object] = vars(parser.parse_args(argv))
    try:
        paths: dict[str, Path] = {}
        for name in ("lock", "vsix", "signature", "output"):
            item = arguments[name]
            if not isinstance(item, Path):
                raise ValueError("invalid artifact path")
            paths[name] = item
        identity = canonical_id(string(arguments["id"]))
        extension = next(
            item
            for item in load_lock(read_bounded(paths["lock"], MAX_METADATA_BYTES))
            if item.id == identity
        )
        extract_extension(
            extension,
            read_bounded(paths["vsix"], MAX_VSIX_BYTES),
            read_bounded(paths["signature"], MAX_SIGNATURE_BYTES),
            validator_arguments(arguments),
            paths["output"],
        )
        print("extension_extracted")
        return 0
    except (
        ValueError,
        OSError,
        subprocess.SubprocessError,
        zipfile.BadZipFile,
        ET.ParseError,
        KeyError,
    ):
        print("extension_extraction_failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
