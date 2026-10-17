"""Assemble the pinned OmniOS r151050 userland sysroot from official IPS data."""

import gzip
import hashlib
import io
import json
import posixpath
import re
import shlex
import ssl
import sys
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import TypedDict
from urllib.request import urlopen

BASE_URL = "https://pkg.omnios.org/r151050/core/file/1/"
MAX_MANIFEST = 16 * 1024 * 1024
MAX_PAYLOAD = 64 * 1024 * 1024


@dataclass(frozen=True)
class Entry:
    """One validated file, symbolic link or hard link from a fixed manifest."""

    kind: str
    path: str
    digest: str
    gzip_digest: str
    content_digest: str
    size: int
    compressed_size: int
    executable: bool
    target: str


@dataclass(frozen=True)
class Package:
    fmri: str
    manifest_digest: str
    manifest: bytes
    entries: tuple[Entry, ...]


class FileRecord(TypedDict):
    path: str
    sha256: str
    bytes: int


def single(attributes: dict[str, list[str]], key: str, default: str = "") -> str:
    values = attributes.get(key, [default])
    if len(values) != 1:
        raise ValueError("duplicate manifest attribute")
    return values[0]


def safe_path(value: str) -> str:
    path = PurePosixPath(value)
    if (
        not value
        or not path.parts
        or path.is_absolute()
        or str(path) != value
        or ".." in path.parts
        or not value.isascii()
        or any(ord(character) < 32 for character in value)
    ):
        raise ValueError("invalid sysroot path")
    return value


def selected(path: str) -> bool:
    """Select headers, AMD64 libraries and GCC 13's startup objects/archives."""
    return path.startswith(
        (
            "usr/include/",
            "lib/amd64/",
            "usr/lib/amd64/",
            "usr/gcc/7/lib/amd64/",
            "usr/gcc/13/lib/amd64/",
        )
    ) or (
        path.startswith("opt/gcc-13/lib/gcc/x86_64-pc-solaris2.11/13.2.0/")
        and "/32/" not in path
        and path.endswith((".o", ".a"))
    )


def sha512_256(value: bytes) -> str:
    return hashlib.new("sha512_256", value).hexdigest()


def bounded_integer(value: str) -> int:
    if re.fullmatch(r"[0-9]{1,10}", value) is None:
        raise ValueError("invalid payload size")
    result = int(value)
    if result > MAX_PAYLOAD:
        raise ValueError("oversized payload")
    return result


def content_hashes(attributes: dict[str, list[str]]) -> tuple[str, str]:
    hashes: dict[str, str] = {}
    for value in attributes.get("pkg.content-hash", []):
        parts = value.split(":")
        if len(parts) != 3:
            raise ValueError("invalid content hash")
        kind, algorithm, digest = parts
        if algorithm != "sha512t_256" or kind not in ("file", "gzip", "gelf", "gelf.unsigned"):
            raise ValueError("unsupported content hash")
        if re.fullmatch(r"[0-9a-f]{64}", digest) is None or kind in hashes:
            raise ValueError("invalid content digest")
        hashes[kind] = digest
    return hashes["gzip"], hashes["file"]


def parse_manifest(path: Path, select: Callable[[str], bool] = selected) -> Package:
    """@cc [owner:ghuntley,label:build;security] illumos-sdk-selected-paths
    Selected paths MUST be canonical relative paths; every selected symbolic or
    hard link MUST resolve inside the output. Absolute guest targets MUST become
    relative internal links, selected payload sizes MUST be bounded, and set-ID
    file modes MUST refuse.
    """
    with path.open("rb") as source:
        manifest = source.read(MAX_MANIFEST + 1)
    if len(manifest) > MAX_MANIFEST:
        raise ValueError("oversized manifest")
    fmri = ""
    actions: list[tuple[list[str], dict[str, list[str]]]] = []
    for line in manifest.decode("utf-8").splitlines():
        fields = shlex.split(line)
        if not fields:
            continue
        attributes: dict[str, list[str]] = {}
        for field in fields[1:]:
            if "=" in field:
                key, value = field.split("=", 1)
                attributes.setdefault(key, []).append(value)
        if fields[0] == "set" and single(attributes, "name") == "pkg.fmri":
            if fmri:
                raise ValueError("duplicate package identity")
            fmri = single(attributes, "value")
        if fields[0] in ("file", "link", "hardlink", "license"):
            actions.append((fields, attributes))
    if re.fullmatch(r"pkg://omnios/[a-z0-9/+_-]+@[0-9A-Za-z.,:-]+", fmri) is None:
        raise ValueError("invalid official package identity")
    entries: list[Entry] = []
    package_name = fmri.removeprefix("pkg://omnios/").split("@", 1)[0]
    for fields, attributes in actions:
        if single(attributes, "variant.debug.illumos", "false") != "false":
            continue
        kind = fields[0]
        target_path = single(attributes, "path")
        if kind == "license":
            license_name = safe_path(single(attributes, "license"))
            target_path = f"share/licenses/{package_name}/{license_name}"
        elif not select(target_path):
            continue
        target_path = safe_path(target_path)
        if kind in ("file", "license"):
            digest = fields[1]
            if re.fullmatch(r"[0-9a-f]{40}", digest) is None:
                raise ValueError("invalid IPS payload key")
            gzip_digest, content_digest = content_hashes(attributes)
            mode = single(attributes, "mode", "0644")
            if re.fullmatch(r"0?[0-7]{3,4}", mode) is None or int(mode, 8) & 0o6000:
                raise ValueError("invalid file mode")
            entries.append(
                Entry(
                    kind,
                    target_path,
                    digest,
                    gzip_digest,
                    content_digest,
                    bounded_integer(single(attributes, "pkg.size")),
                    bounded_integer(single(attributes, "pkg.csize")),
                    bool(int(mode, 8) & 0o111),
                    "",
                )
            )
        else:
            target = single(attributes, "target")
            if not target or not target.isascii() or any(ord(c) < 32 for c in target):
                raise ValueError("invalid link target")
            absolute = target.startswith("/")
            resolved = posixpath.normpath(
                target.removeprefix("/")
                if absolute
                else posixpath.join(posixpath.dirname(target_path), target)
            )
            safe_path(resolved)
            relative = posixpath.relpath(resolved, posixpath.dirname(target_path))
            entries.append(Entry(kind, target_path, "", "", "", 0, 0, False, relative))
    return Package(fmri, hashlib.sha256(manifest).hexdigest(), manifest, tuple(entries))


def receive_payload(url: str, limit: int) -> bytes:
    # Match Nix fetchurl for public fixed-output inputs: the pinned manifest
    # supplies both payload digests, checked before bytes enter the output.
    # No credentials are used or sent by this downloader.
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    with urlopen(url, timeout=90, context=context) as response:
        return response.read(limit)


def fetch_file(
    root: Path,
    entry: Entry,
    receive: Callable[[str, int], bytes] = receive_payload,
) -> FileRecord:
    """@cc [owner:ghuntley,label:build;security] illumos-sdk-payload-integrity
    A payload MUST match its compressed and plain sizes, SHA-512/256 digests and
    IPS object key before any file is created; reads MUST remain bounded by
    those validated sizes. Existing output files MUST NOT be overwritten.
    """
    compressed = receive(BASE_URL + entry.digest, entry.compressed_size + 1)
    if len(compressed) != entry.compressed_size or sha512_256(compressed) != entry.gzip_digest:
        raise ValueError("compressed payload digest mismatch")
    with gzip.GzipFile(fileobj=io.BytesIO(compressed)) as archive:
        data = archive.read(entry.size + 1)
    if (
        len(data) != entry.size
        or sha512_256(data) != entry.content_digest
        or hashlib.sha1(data).hexdigest() != entry.digest
    ):
        raise ValueError("payload digest mismatch")
    target = root / entry.path
    target.parent.mkdir(parents=True, exist_ok=True)
    with target.open("xb") as destination:
        destination.write(data)
    target.chmod(0o755 if entry.executable else 0o644)
    return {"path": entry.path, "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}


def assemble(root: Path, manifests: list[Path]) -> None:
    """@cc [owner:ghuntley,label:build;security] illumos-sdk-extraction-boundary
    SDK extraction MUST refuse conflicting paths, install all verified regular
    files before creating guest-relative internal links, and retain every
    selected package license, original manifest and per-file byte identity.
    """
    packages = sorted(
        (parse_manifest(path) for path in manifests), key=lambda package: package.fmri
    )
    paths: dict[str, Entry] = {}
    for package in packages:
        for entry in package.entries:
            previous = paths.setdefault(entry.path, entry)
            if previous != entry:
                raise ValueError("conflicting sysroot path")
    root.mkdir(parents=True, exist_ok=False)
    entries = sorted(paths.values(), key=lambda entry: entry.path)
    files = [entry for entry in entries if entry.kind in ("file", "license")]
    with ThreadPoolExecutor(max_workers=16) as executor:
        records = list(executor.map(lambda entry: fetch_file(root, entry), files))
    for kind in ("link", "hardlink"):
        for entry in entries:
            if entry.kind != kind:
                continue
            target = root / entry.path
            target.parent.mkdir(parents=True, exist_ok=True)
            if kind == "link":
                target.symlink_to(entry.target)
            else:
                target.hardlink_to(target.parent / entry.target)
    metadata = root / "share/overalls/illumos-sdk"
    metadata.mkdir(parents=True)
    for index, package in enumerate(packages):
        (metadata / f"manifest-{index}.p5m").write_bytes(package.manifest)
    provenance: dict[str, object] = {
        "version": 1,
        "release": "r151050",
        "source": "https://pkg.omnios.org/r151050/core/",
        "status": "userland-sysroot",
        "packages": [
            {"fmri": package.fmri, "sha256": package.manifest_digest} for package in packages
        ],
        "files": records,
    }
    (metadata / "provenance.json").write_text(json.dumps(provenance, sort_keys=True) + "\n")


def main() -> None:
    if len(sys.argv) != 9:
        raise ValueError("expected output path and seven pinned package manifests")
    assemble(Path(sys.argv[1]), [Path(value) for value in sys.argv[2:]])


if __name__ == "__main__":
    main()
