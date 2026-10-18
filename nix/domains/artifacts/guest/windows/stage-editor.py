"""Stage a deterministic regular-file archive for the Windows editor installer."""

from __future__ import annotations

import hashlib
import json
import os
import stat
import sys
import tarfile
from pathlib import Path
from typing import Final, TypedDict


class FileEntry(TypedDict):
    """Closed inventory entry for one editor payload file."""

    mode: int
    path: str
    sha256: str
    size: int


class Inventory(TypedDict):
    """Versioned editor archive inventory."""

    files: list[FileEntry]
    format: int


FORMAT: Final = 1


def digest(path: Path) -> str:
    """Return the SHA-256 digest of one regular file."""
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def relative_name(path: Path, source: Path) -> str:
    """Return a safe Windows-compatible POSIX archive name."""
    relative = path.relative_to(source)
    reserved = {"CON", "PRN", "AUX", "NUL"} | {
        f"{prefix}{number}" for prefix in ("COM", "LPT") for number in range(1, 10)
    }
    for part in relative.parts:
        if (
            part in ("", ".", "..")
            or part.rstrip(" .") != part
            or part.upper().split(".", 1)[0] in reserved
            or any(ord(character) < 32 or character in '<>:"/\\|?*' for character in part)
            or len(part) > 255
        ):
            raise ValueError("invalid editor archive path")
    name = "/".join(relative.parts)
    if len(name) > 32767:
        raise ValueError("editor archive path is too long")
    return name


def collect(source: Path) -> list[tuple[str, Path, os.stat_result]]:
    """Collect and validate all editor payload files."""
    if not source.is_dir() or source.is_symlink():
        raise ValueError("editor source must be a real directory")
    files: list[tuple[str, Path, os.stat_result]] = []
    for path in sorted(source.rglob("*"), key=lambda item: relative_name(item, source)):
        metadata = path.lstat()
        if stat.S_ISLNK(metadata.st_mode):
            raise ValueError("editor bundle contains a symbolic link")
        if stat.S_ISDIR(metadata.st_mode):
            continue
        if not stat.S_ISREG(metadata.st_mode):
            raise ValueError("editor bundle contains a non-regular entry")
        files.append((relative_name(path, source), path, metadata))
    if not files:
        raise ValueError("editor bundle is empty")
    return files


def write_archive(
    source: Path, destination: Path, files: list[tuple[str, Path, os.stat_result]]
) -> Inventory:
    """Write a deterministic PAX archive and its closed inventory."""
    entries: list[FileEntry] = []
    with tarfile.open(destination / "editor.tar", mode="w", format=tarfile.PAX_FORMAT) as archive:
        for name, path, metadata in files:
            entries.append(
                {
                    "mode": stat.S_IMODE(metadata.st_mode),
                    "path": name,
                    "sha256": digest(path),
                    "size": metadata.st_size,
                }
            )
            info = tarfile.TarInfo(name)
            info.size = metadata.st_size
            info.mode = stat.S_IMODE(metadata.st_mode)
            info.mtime = 0
            info.uid = 0
            info.gid = 0
            info.uname = ""
            info.gname = ""
            info.pax_headers = {"mtime": "0"}
            with path.open("rb") as stream:
                archive.addfile(info, stream)
    inventory: Inventory = {"files": entries, "format": FORMAT}
    inventory_bytes = (
        json.dumps(inventory, ensure_ascii=True, sort_keys=True, separators=(",", ":")) + "\n"
    )
    (destination / "editor.inventory.json").write_text(inventory_bytes, encoding="utf-8")
    archive_bytes = (destination / "editor.tar").read_bytes()
    metadata = {
        "archive_sha256": hashlib.sha256(archive_bytes).hexdigest(),
        "archive_size": len(archive_bytes),
        "file_count": len(entries),
        "format": FORMAT,
        "inventory_sha256": hashlib.sha256(inventory_bytes.encode("utf-8")).hexdigest(),
    }
    (destination / "editor.archive.json").write_text(
        json.dumps(metadata, ensure_ascii=True, sort_keys=True, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )
    return inventory


def main(arguments: list[str]) -> None:
    """Stage a regular-file-only editor archive.

    @cc [owner:ghuntley,label:security;build] windows-editor-archive-staging
    The staged archive MUST contain only deterministic regular files with
    Windows-compatible relative names, and its closed inventory MUST bind every
    path, size, mode and SHA-256 digest to the archive metadata.
    """
    if len(arguments) != 3:
        raise ValueError("usage: stage-editor.py SOURCE DESTINATION")
    source = Path(arguments[1]).resolve()
    destination = Path(arguments[2]).resolve()
    destination.mkdir(parents=True, exist_ok=True)
    files = collect(source)
    write_archive(source, destination, files)


if __name__ == "__main__":
    main(sys.argv)
