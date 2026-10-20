"""Replay a Linux dm-log-writes journal to model host power loss at a named mark."""

from __future__ import annotations

import argparse
import json
import os
import struct
from collections.abc import Iterator
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import BinaryIO

# Linux drivers/md/dm-log-writes.c on-disk format, version 1.
MAGIC = 0x6A736677736872
VERSION = 1
FLUSH = 1 << 0
FUA = 1 << 1
DISCARD = 1 << 2
MARK = 1 << 3
METADATA = 1 << 4
KNOWN = FLUSH | FUA | DISCARD | MARK | METADATA
SUPER = struct.Struct("<QQQI")
ENTRY = struct.Struct("<QQQQ")
MAX_ENTRIES = 16_000_000
MAX_MARK = 256
CHUNK = 1024**2


class LogError(ValueError):
    """A malformed or out-of-bounds journal; never partially trusted."""


@dataclass(frozen=True)
class Entry:
    index: int
    sector: int
    sectors: int
    flags: int
    data_offset: int
    mark: bytes


@dataclass(frozen=True)
class Segment:
    """Flush and write counts logged after a named mark, until the next mark."""

    mark: str
    flushes: int
    writes: int


@dataclass(frozen=True)
class Replay:
    """Counts only; journal bytes and offsets never become driver evidence."""

    sector_size: int
    entries_before_cut: int
    writes_applied: int
    flushes_before_cut: int
    fua_writes: int
    discards_applied: int
    bytes_applied: int
    entries_after_cut: int
    segments: tuple[Segment, ...] = ()


def header(log: BinaryIO) -> tuple[int, int]:
    log.seek(0)
    raw = log.read(SUPER.size)
    if len(raw) != SUPER.size:
        raise LogError("truncated dm-log-writes superblock")
    magic, version, entries, sector_size = SUPER.unpack(raw)
    if magic != MAGIC or version != VERSION:
        raise LogError("invalid dm-log-writes superblock")
    if sector_size not in (512, 4096) or not 0 <= entries <= MAX_ENTRIES:
        raise LogError("unsupported dm-log-writes geometry")
    return entries, sector_size


def entries(log: BinaryIO, log_bytes: int) -> Iterator[Entry]:
    """Yield each logged entry in log order with bounded, validated geometry."""
    count, sector_size = header(log)
    position = sector_size
    for index in range(count):
        if position + sector_size > log_bytes:
            raise LogError("dm-log-writes entry exceeds the log")
        log.seek(position)
        raw = log.read(sector_size)
        if len(raw) != sector_size:
            raise LogError("truncated dm-log-writes entry")
        sector, sectors, flags, data_length = ENTRY.unpack_from(raw)
        if flags & ~KNOWN:
            raise LogError("unknown dm-log-writes entry flag")
        mark = b""
        if flags & MARK:
            if sectors or not 0 < data_length <= min(MAX_MARK, sector_size - ENTRY.size):
                raise LogError("invalid dm-log-writes mark")
            mark = raw[ENTRY.size : ENTRY.size + data_length]
        elif data_length:
            raise LogError("inline dm-log-writes data is unsupported")
        position += sector_size
        data_offset = position
        if sectors and not flags & DISCARD:
            position += sectors * sector_size
            if position > log_bytes:
                raise LogError("dm-log-writes data exceeds the log")
        yield Entry(index, sector, sectors, flags, data_offset, mark)


def replay(log_path: Path, target_path: Path, cut: bytes) -> Replay:
    """@cc [owner:ghuntley,label:verification;recovery] native-power-loss-replay
    The replay MUST apply only entries logged before the first mark named `cut`,
    in log order, onto a target that already holds the device's initial bytes.
    dm-log-writes holds completed writes until a following flush (or FUA), so
    the applied prefix is exactly the state a volatile-cache device guarantees
    at that instant. A missing cut, unknown flag, inline data, or a write past the
    target MUST refuse. Counts MUST NOT claim which guest bytes were lost.
    """
    if not 0 < len(cut) <= MAX_MARK:
        raise LogError("invalid power-cut mark")
    with log_path.open("rb") as log, target_path.open("r+b") as target:
        log.seek(0, 2)
        log_bytes = log.tell()
        target.seek(0, 2)
        target_bytes = target.tell()
        _, sector_size = header(log)
        writes = flushes = fua = discards = applied = 0
        found: Entry | None = None
        segments: list[Segment] = []
        after = 0
        for entry in entries(log, log_bytes):
            if found is not None:
                after += 1
                continue
            if entry.flags & MARK:
                if entry.mark == cut:
                    found = entry
                else:
                    try:
                        name = entry.mark.decode("ascii")
                    except UnicodeDecodeError:
                        raise LogError("invalid dm-log-writes mark name") from None
                    segments.append(Segment(name, 0, 0))
                continue
            if entry.flags & FLUSH:
                flushes += 1
                if segments:
                    last = segments[-1]
                    segments[-1] = Segment(last.mark, last.flushes + 1, last.writes)
            if entry.sectors and not entry.flags & DISCARD and segments:
                last = segments[-1]
                segments[-1] = Segment(last.mark, last.flushes, last.writes + 1)
            if not entry.sectors:
                continue
            start = entry.sector * sector_size
            length = entry.sectors * sector_size
            if start + length > target_bytes:
                raise LogError("dm-log-writes entry exceeds the replay target")
            target.seek(start)
            if entry.flags & DISCARD:
                discards += 1
                remaining = length
                while remaining:
                    size = min(CHUNK, remaining)
                    target.write(bytes(size))
                    remaining -= size
                continue
            log.seek(entry.data_offset)
            remaining = length
            while remaining:
                chunk = log.read(min(CHUNK, remaining))
                if not chunk:
                    raise LogError("truncated dm-log-writes data")
                target.write(chunk)
                remaining -= len(chunk)
            writes += 1
            applied += length
            if entry.flags & FUA:
                fua += 1
        if found is None:
            raise LogError("power-cut mark is absent from the log")
        target.flush()
        os.fsync(target.fileno())
        return Replay(
            sector_size,
            found.index,
            writes,
            flushes,
            fua,
            discards,
            applied,
            after,
            tuple(segments),
        )


class Options(argparse.Namespace):
    log: Path
    target: Path
    cut: str
    receipt: Path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--target", type=Path, required=True)
    parser.add_argument("--cut", required=True)
    parser.add_argument("--receipt", type=Path, required=True)
    arguments = parser.parse_args(namespace=Options())
    result = replay(arguments.log, arguments.target, arguments.cut.encode("ascii"))
    arguments.receipt.write_text(json.dumps(asdict(result), sort_keys=True) + "\n")
    print(f"native power-loss replay {json.dumps(asdict(result), sort_keys=True)}", flush=True)


if __name__ == "__main__":
    main()
