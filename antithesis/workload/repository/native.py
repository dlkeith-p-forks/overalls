"""Read-only kernel flock witness for Enrico's fixed native Git slots."""

import fcntl
import os
import stat
from pathlib import Path

from core.outcome import Observation
from repository.observer import NativeSnapshot


def occupied_slots(state_dir: Path) -> Observation[frozenset[int]]:
    """@cc [owner:ghuntley,label:verification] enrico-lock-inode-witness
    Slot observations MUST inspect the same existing private inodes used by
    enrico-git-owner. Missing, replaced or inaccessible inodes are unknown;
    probing MUST NOT create lock files or mutate the service-owned directory.
    """
    occupied: set[int] = set()
    inodes: set[tuple[int, int]] = set()
    for index in range(8):
        path = state_dir / f".enrico-git-slot-{index}.lock"
        try:
            descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        except OSError:
            return Observation.unavailable()
        try:
            info = os.fstat(descriptor)
            identity = info.st_dev, info.st_ino
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or identity in inodes:
                return Observation.unavailable()
            inodes.add(identity)
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                occupied.add(index)
            else:
                fcntl.flock(descriptor, fcntl.LOCK_UN)
        except OSError:
            return Observation.unavailable()
        finally:
            os.close(descriptor)
    return Observation.observed(frozenset(occupied))


def snapshot_matches_inodes(snapshot: NativeSnapshot, state_dir: Path) -> bool:
    """Check observer identities against current service-owned lock paths."""
    try:
        for slot in snapshot.slots:
            info = (state_dir / f".enrico-git-slot-{slot.slot}.lock").lstat()
            if (info.st_dev, info.st_ino) != (slot.device, slot.inode):
                return False
        for repository in snapshot.repositories:
            info = (state_dir / f".enrico-{repository.repository_id}.git.lock").lstat()
            if (info.st_dev, info.st_ino) != (repository.device, repository.inode):
                return False
    except OSError:
        return False
    return True


def service_generation(state_dir: Path) -> Observation[int]:
    """Read the exact release generation from Enrico's service-owned state."""
    path = state_dir / "launch-generation"
    try:
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > 20:
            return Observation.unavailable()
        raw = path.read_text(encoding="ascii").strip()
        if not raw.isascii() or not raw.isdecimal() or raw.startswith("0"):
            return Observation.unavailable()
        generation = int(raw)
        return Observation.observed(generation) if generation > 0 else Observation.unavailable()
    except (OSError, UnicodeError, ValueError):
        return Observation.unavailable()
