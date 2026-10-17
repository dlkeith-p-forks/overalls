"""Preserve native EFI file bytes while allowing the pinned firmware variable store."""

from __future__ import annotations

import hashlib
import subprocess
from dataclasses import dataclass
from pathlib import Path

MAX_ENTRIES = 128
MAX_FILE_BYTES = 16 * 1024**2
MAX_NV_VARS_BYTES = 1024**2


@dataclass(frozen=True)
class File:
    path: str
    bytes: int
    sha256: str


@dataclass(frozen=True)
class Inventory:
    directories: tuple[str, ...]
    files: tuple[File, ...]


def command(arguments: list[str], maximum: int) -> bytes:
    result = subprocess.run(arguments, capture_output=True, check=False, timeout=15)
    if result.returncode or len(result.stdout) > maximum or len(result.stderr) > 4096:
        raise RuntimeError("native EFI filesystem inspection failed")
    return result.stdout


def inventory(disk: Path, offset: int, length: int) -> Inventory:
    """@cc [owner:ghuntley,label:verification;recovery] native-fat-boot-file-preservation
    Inventory MUST retain every EFI directory path and regular file's exact path,
    size and bytes, except the fixed root NvVars regular file of at most 1 MiB.
    Missing or changed boot files, unrelated new entries, a NvVars directory,
    malformed paths, oversized files and a FAT volume escaping its partition
    MUST refuse or produce a different inventory. Pinned CloudHv creates NvVars
    on first boot; its allocation metadata MUST NOT masquerade as boot-file loss.
    """
    if offset < 0 or length < 512 or length % 512 or offset + length > disk.stat().st_size:
        raise ValueError("invalid native EFI partition bound")
    with disk.open("rb") as source:
        source.seek(offset)
        header = source.read(512)
    sectors = int.from_bytes(header[19:21], "little") or int.from_bytes(header[32:36], "little")
    if (
        len(header) != 512
        or header[510:] != b"\x55\xaa"
        or int.from_bytes(header[11:13], "little") != 512
        or sectors * 512 != length
    ):
        raise ValueError("native EFI FAT volume differs from its partition")
    image = f"{disk}@@{offset}"
    listing = command(["mdir", "-b", "-s", "-a", "-i", image, "::/"], 16384)
    lines = listing.decode("utf-8").splitlines()
    if not lines or len(lines) > MAX_ENTRIES:
        raise ValueError("invalid native EFI entry count")
    directories: list[str] = []
    files: list[File] = []
    seen: set[str] = set()
    for line in lines:
        if not line.startswith("::/"):
            raise ValueError("invalid native EFI entry path")
        directory = line.endswith("/")
        path = line[3:-1] if directory else line[3:]
        if (
            not path
            or len(path) > 256
            or any(part in ("", ".", "..") for part in path.split("/"))
            or any(ord(value) < 32 or value == "\\" for value in path)
            or path.casefold() in seen
        ):
            raise ValueError("invalid native EFI entry path")
        seen.add(path.casefold())
        if directory:
            if path == "NvVars":
                raise ValueError("native EFI variable store is not a regular file")
            directories.append(path)
            continue
        maximum = MAX_NV_VARS_BYTES if path == "NvVars" else MAX_FILE_BYTES
        content = command(["mtype", "-i", image, "::/" + path], maximum)
        if path == "NvVars":
            continue
        files.append(File(path, len(content), hashlib.sha256(content).hexdigest()))
    return Inventory(tuple(sorted(directories)), tuple(sorted(files, key=lambda value: value.path)))
