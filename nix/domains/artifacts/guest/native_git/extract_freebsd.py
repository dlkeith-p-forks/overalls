"""Extract reviewed FreeBSD runtime packages without running package scripts."""

import hashlib
import json
import posixpath
import re
import subprocess
import sys
import tarfile
from pathlib import Path, PurePosixPath
from typing import TypedDict

SUDO_PACKAGE_SHA256 = "7200c287a7756ae687feb90117a588a11e6703487adf63f96d604909b89cc29a"


class Package(TypedDict):
    name: str
    version: str
    url: str
    sha256: str
    dependencies: list[str]
    freebsd_version: int


def package_records(value: object) -> list[Package]:
    if not isinstance(value, list):
        raise ValueError("expected package array")
    records: list[Package] = []
    for item in value:
        if not isinstance(item, dict):
            raise ValueError("expected package object")
        name, version, url, digest = (item.get(key) for key in ("name", "version", "url", "sha256"))
        dependencies, release = item.get("dependencies"), item.get("freebsd_version")
        if (
            not all(isinstance(field, str) for field in (name, version, url, digest))
            or not isinstance(name, str)
            or re.fullmatch(r"[a-z0-9_-]+", name) is None
            or not isinstance(version, str)
            or not isinstance(url, str)
            or not url.startswith("https://pkg.freebsd.org/FreeBSD:14:amd64/release_3/All/")
            or not isinstance(digest, str)
            or re.fullmatch(r"[0-9a-f]{64}", digest) is None
            or not isinstance(dependencies, list)
            or any(not isinstance(dependency, str) for dependency in dependencies)
            or not isinstance(release, int)
            or isinstance(release, bool)
            or release > 1403000
            or release < 0
        ):
            raise ValueError("invalid compatible official package")
        records.append(
            Package(
                name=name,
                version=version,
                url=url,
                sha256=digest,
                dependencies=[str(dependency) for dependency in dependencies],
                freebsd_version=release,
            )
        )
    names = {record["name"] for record in records}
    if len(names) != len(records) or any(
        dependency not in names for record in records for dependency in record["dependencies"]
    ):
        raise ValueError("incomplete or ambiguous package dependency closure")
    return records


def relative_path(value: str) -> str:
    path = value.removeprefix("/")
    if (
        not path
        or not PurePosixPath(path).parts
        or str(PurePosixPath(path)) != path
        or PurePosixPath(path).is_absolute()
        or ".." in PurePosixPath(path).parts
        or not path.isascii()
        or any(ord(character) < 32 for character in path)
    ):
        raise ValueError("unsafe package path")
    return path


def link_target(path: str, target: str, hard: bool) -> str:
    resolved = posixpath.normpath(
        target.removeprefix("/")
        if target.startswith("/") or hard
        else posixpath.join(posixpath.dirname(path), target)
    )
    return relative_path(resolved)


def make_parents(root: Path, target: Path) -> None:
    """Never traverse a package-created directory symlink during extraction."""
    for parent in reversed(target.parent.relative_to(root).parents):
        candidate = root / parent
        if candidate.is_symlink():
            raise ValueError("package path traverses a symlink")
    if target.parent.is_symlink():
        raise ValueError("package path traverses a symlink")
    target.parent.mkdir(parents=True, exist_ok=True)


def extract(root: Path, archive_path: Path, expected_digest: str) -> None:
    """@cc [owner:ghuntley,label:build;security] freebsd-git-package-extraction
    A package MUST match its pinned SHA-256 before decompression. Extraction MUST
    reject escaping paths/links, devices, unapproved set-ID files and conflicting entries;
    only the exact pinned sudo archive's root-owned /usr/local/bin/sudo mode 04755
    MAY be accepted, with its set-ID stripped. Image assembly activates it explicitly.
    links are created only after all regular files, and scripts never execute.
    """
    with archive_path.open("rb") as archive:
        if hashlib.file_digest(archive, "sha256").hexdigest() != expected_digest:
            raise ValueError("package digest mismatch")
    links: list[tuple[str, str, bool]] = []
    total = 0
    with subprocess.Popen(
        ["zstd", "-dc", str(archive_path.resolve(strict=True))], stdout=subprocess.PIPE
    ) as process:
        if process.stdout is None:
            raise ValueError("missing decompressor output")
        try:
            with tarfile.open(fileobj=process.stdout, mode="r|") as archive:
                for member in archive:
                    extract_member(root, archive, member, links, expected_digest)
                    total += member.size
                    if total > 1024 * 1024 * 1024:
                        raise ValueError("oversized runtime package")
            if process.wait() != 0:
                raise ValueError("package decompression failed")
        except BaseException:
            process.kill()
            process.wait()
            raise
    for path, resolved, hard in sorted(links, key=lambda entry: not entry[2]):
        target = root / path
        make_parents(root, target)
        if target.exists() or target.is_symlink():
            raise ValueError("conflicting package link")
        if hard:
            source = root / resolved
            if (
                not source.is_file()
                or source.is_symlink()
                or not source.resolve().is_relative_to(root.resolve())
            ):
                raise ValueError("missing regular hardlink target")
            target.hardlink_to(source)
        else:
            target.symlink_to(posixpath.relpath(resolved, posixpath.dirname(path)))
            if not target.resolve().is_relative_to(root.resolve()):
                target.unlink()
                raise ValueError("escaping package symlink")


def extract_member(
    root: Path,
    archive: tarfile.TarFile,
    member: tarfile.TarInfo,
    links: list[tuple[str, str, bool]],
    package_digest: str,
) -> None:
    if member.name.startswith("+"):
        return
    path = relative_path(member.name)
    target = root / path
    approved_sudo = (
        package_digest == SUDO_PACKAGE_SHA256
        and path == "usr/local/bin/sudo"
        and member.isfile()
        and member.mode == 0o4755
        and member.uid == 0
        and member.gid == 0
    )
    if (member.mode & 0o6000 and not approved_sudo) or not 0 <= member.size <= 128 * 1024 * 1024:
        raise ValueError("unsupported package mode or size")
    if member.isdir():
        make_parents(root, target)
        if target.is_symlink():
            raise ValueError("package directory is a symlink")
        target.mkdir(parents=True, exist_ok=True)
        return
    if member.issym() or member.islnk():
        links.append((path, link_target(path, member.linkname, member.islnk()), member.islnk()))
        return
    if not member.isfile():
        raise ValueError("special package entry refused")
    source = archive.extractfile(member)
    if source is None:
        raise ValueError("missing package payload")
    data = source.read(member.size + 1)
    if len(data) != member.size:
        raise ValueError("truncated package payload")
    make_parents(root, target)
    if target.exists() or target.is_symlink():
        if not target.is_file() or target.is_symlink() or target.read_bytes() != data:
            raise ValueError("conflicting package file")
    else:
        target.write_bytes(data)
        target.chmod(0o755 if member.mode & 0o111 else 0o644)


def main(arguments: list[str]) -> None:
    if len(arguments) != 3:
        raise ValueError("expected OUTPUT LOCK PACKAGE_DIRECTORY")
    root, lock_path, packages_path = map(Path, arguments)
    records = package_records(json.loads(lock_path.read_text()))
    root.mkdir(parents=True, exist_ok=False)
    for record in records:
        extract(root, packages_path / (record["name"] + ".pkg"), record["sha256"])
    local_trust = root / "usr/local/etc/ssl/cert.pem"
    sample = local_trust.with_suffix(".pem.sample")
    if not local_trust.exists() and not local_trust.is_symlink():
        if not sample.is_symlink():
            raise ValueError("missing native trust sample")
        local_trust.symlink_to(sample.readlink())
    trust = root / "etc/ssl/cert.pem"
    trust.parent.mkdir(parents=True, exist_ok=True)
    if not trust.exists():
        trust.symlink_to("../../usr/local/share/certs/ca-root-nss.crt")
    metadata = root / "share/overalls/native-git"
    metadata.mkdir(parents=True)
    (metadata / "packages.json").write_bytes(lock_path.read_bytes())
    (metadata / "activation.json").write_text(
        json.dumps(
            {
                "version": 1,
                "setid_stripped": [
                    {
                        "path": "/usr/local/bin/sudo",
                        "package_sha256": SUDO_PACKAGE_SHA256,
                        "payload_mode": "0755",
                        "guest_owner": "root:wheel",
                        "guest_mode": "4755",
                    }
                ],
                "runtime_verified": False,
            },
            sort_keys=True,
        )
        + "\n"
    )


if __name__ == "__main__":
    main(sys.argv[1:])
