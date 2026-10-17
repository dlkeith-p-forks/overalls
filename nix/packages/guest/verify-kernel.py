"""Verify that ELF debug stripping preserves the x86-64 executable load image."""

import hashlib
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO


@dataclass(frozen=True)
class Segment:
    flags: int
    virtual: int
    physical: int
    file_size: int
    memory_size: int
    alignment: int
    digest: bytes


@dataclass(frozen=True)
class LoadImage:
    entry: int
    segments: tuple[Segment, ...]


def integer(data: bytes, offset: int, size: int) -> int:
    return int.from_bytes(data[offset : offset + size], "little")


def read_exact(source: BinaryIO, offset: int, size: int) -> bytes:
    source.seek(offset)
    result = source.read(size)
    if len(result) != size:
        raise ValueError("Truncated ELF")
    return result


def load_image(path: Path) -> LoadImage:
    """@cc [owner:ghuntley,label:verification] kernel-load-image-comparison
    Accept only bounded executable x86-64 ELF headers and hash all PT_LOAD bytes.
    Non-loadable sections and file offsets may change; execution contents may not.
    """
    with path.open("rb") as source:
        header = read_exact(source, 0, 64)
        if (
            header[:7] != b"\x7fELF\x02\x01\x01"
            or integer(header, 16, 2) != 2
            or integer(header, 18, 2) != 62
            or integer(header, 52, 2) != 64
            or integer(header, 54, 2) != 56
        ):
            raise ValueError("Expected executable ELF64 x86-64")
        count = integer(header, 56, 2)
        if not 1 <= count <= 128:
            raise ValueError("Invalid program header count")
        start = integer(header, 32, 8)
        file_size = path.stat().st_size
        segments: list[Segment] = []
        for index in range(count):
            ph = read_exact(source, start + index * 56, 56)
            if integer(ph, 0, 4) != 1:
                continue
            offset, size, memory = (integer(ph, field, 8) for field in (8, 32, 40))
            if offset + size > file_size or size > memory:
                raise ValueError("Invalid load segment")
            digest = hashlib.sha256()
            source.seek(offset)
            remaining = size
            while remaining:
                block = source.read(min(remaining, 1024 * 1024))
                if not block:
                    raise ValueError("Truncated segment")
                digest.update(block)
                remaining -= len(block)
            segments.append(
                Segment(
                    integer(ph, 4, 4),
                    integer(ph, 16, 8),
                    integer(ph, 24, 8),
                    size,
                    memory,
                    integer(ph, 48, 8),
                    digest.digest(),
                )
            )
        if not segments:
            raise ValueError("Missing load image")
        return LoadImage(integer(header, 24, 8), tuple(segments))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: verify-kernel.py ORIGINAL STRIPPED")
    if load_image(Path(sys.argv[1])) != load_image(Path(sys.argv[2])):
        raise SystemExit("Kernel load image changed")
