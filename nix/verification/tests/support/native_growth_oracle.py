"""Check actual FreeBSD root growth and preservation on disposable native disks."""

from __future__ import annotations

import hashlib
import json
import secrets
import subprocess
import uuid
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

import native_fat_oracle

EXPANSION = 2 * 1024**3
SWAP_TYPE = "516e7cb5-6ecf-11d6-8ff8-00022d09712b"
EFI_TYPE = "c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
SSH_LOGIN_EVENT = (
    b'{"service":"overalls-ssh-authorize","event":"ssh.login_recorded","severity":"info"}\n'
)
Probe = Callable[[str], subprocess.CompletedProcess[bytes]]


def object_value(value: object) -> dict[str, object]:
    if not isinstance(value, dict):
        raise ValueError("invalid native growth object")
    result: dict[str, object] = {}
    for name, item in value.items():
        if not isinstance(name, str):
            raise ValueError("invalid native growth object field")
        result[name] = item
    return result


def integer(value: object) -> int:
    if type(value) is not int or value < 0:
        raise ValueError("invalid native growth integer")
    return value


def identifier(value: object) -> str:
    if not isinstance(value, str):
        raise ValueError("invalid native growth GPT identity")
    parsed = uuid.UUID(value)
    if str(parsed) != value.lower():
        raise ValueError("invalid native growth GPT identity")
    return str(parsed)


def valid_last_sector(disk_bytes: int, last: int) -> bool:
    """Accept the pinned image end or FreeBSD gpart's native 4096-byte end."""
    maximum = disk_bytes // 512 - 34
    aligned = maximum - ((maximum + 1) % 8)
    return last in (maximum, aligned)


@dataclass(frozen=True)
class Partition:
    start: int
    sectors: int
    kind: str
    identity: str
    name: str
    attributes: str


@dataclass(frozen=True)
class Layout:
    identity: str
    first: int
    last: int
    partitions: tuple[Partition, ...]

    @property
    def root(self) -> Partition:
        return self.partitions[4]


def layout_value(raw: object, disk_bytes: int) -> Layout:
    """Narrow the bounded pinned sfdisk response before using partition offsets."""
    fields = object_value(raw)
    if set(fields) != {"partitiontable"}:
        raise ValueError("invalid native growth partition response")
    table = object_value(fields["partitiontable"])
    if table.get("label") != "gpt" or table.get("unit") != "sectors":
        raise ValueError("native growth requires GPT sectors")
    if type(table.get("sectorsize")) is not int or table["sectorsize"] != 512 or disk_bytes % 512:
        raise ValueError("native growth requires 512-byte sectors")
    first = integer(table.get("firstlba"))
    last = integer(table.get("lastlba"))
    if first != 34 or not valid_last_sector(disk_bytes, last):
        raise ValueError("native growth GPT does not cover the current disk")
    values: object = table.get("partitions")
    if not isinstance(values, list) or len(values) != 5:
        raise ValueError("native growth requires the actual FreeBSD partition set")
    partitions: list[Partition] = []
    end = first - 1
    for value in values:
        partition = object_value(value)
        start = integer(partition.get("start"))
        sectors = integer(partition.get("size"))
        name = partition.get("name", "")
        attributes = partition.get("attrs", "")
        if (
            not isinstance(name, str)
            or not isinstance(attributes, str)
            or len(name) > 72
            or len(attributes) > 256
            or sectors == 0
            or start <= end
            or start + sectors - 1 > last
        ):
            raise ValueError("invalid native growth partition geometry")
        partitions.append(
            Partition(
                start,
                sectors,
                identifier(partition.get("type")),
                identifier(partition.get("uuid")),
                name,
                attributes,
            )
        )
        end = start + sectors - 1
    if partitions[4].start != 2165940 or partitions[2].kind != SWAP_TYPE:
        raise ValueError("unexpected native growth root or swap partition")
    return Layout(identifier(table.get("id")), first, last, tuple(partitions))


def layout(disk: Path) -> Layout:
    result = subprocess.run(
        ["sfdisk", "--json", str(disk)], capture_output=True, check=True, timeout=15
    )
    if len(result.stdout) > 16384 or len(result.stderr) > 4096:
        raise RuntimeError("native growth partition response exceeded its bound")
    raw: object = json.loads(result.stdout)
    return layout_value(raw, disk.stat().st_size)


def partition_digest(disk: Path, partition: Partition) -> str:
    digest = hashlib.sha256()
    remaining = partition.sectors * 512
    with disk.open("rb") as source:
        source.seek(partition.start * 512)
        while remaining:
            chunk = source.read(min(1024**2, remaining))
            if not chunk:
                raise RuntimeError("native growth partition bytes are truncated")
            digest.update(chunk)
            remaining -= len(chunk)
    return digest.hexdigest()


@dataclass(frozen=True)
class Guest:
    disk_bytes: int
    root_start: int
    root_end: int
    root_bytes: int
    outcome: str


def guest_value(raw: object, root_bytes: int) -> Guest:
    fields = object_value(raw)
    keys = {
        "version",
        "os",
        "outcome",
        "disk_bytes",
        "root_start",
        "root_end_before",
        "root_end_after",
        "backup_before",
        "backup_after",
        "native_admission",
    }
    if set(fields) != keys:
        raise ValueError("invalid native growth receipt fields")
    outcome = fields["outcome"]
    if (
        type(fields["version"]) is not int
        or fields["version"] != 1
        or fields["os"] != "freebsd"
        or fields["native_admission"] is not False
        or not isinstance(outcome, str)
        or outcome not in ("grown", "unchanged")
    ):
        raise ValueError("invalid native growth receipt authority")
    disk = integer(fields["disk_bytes"])
    start = integer(fields["root_start"])
    before = integer(fields["root_end_before"])
    after = integer(fields["root_end_after"])
    backup_before = integer(fields["backup_before"])
    backup_after = integer(fields["backup_after"])
    if (
        disk < 1024**3
        or disk % 512
        or start != 2165940
        or not start <= before <= after < backup_after
        or not before < backup_before <= backup_after
        or backup_after != disk // 512 - 1
        or not valid_last_sector(disk, after)
        or (outcome == "grown") != (after > before)
        or root_bytes <= 0
        or root_bytes >= disk
    ):
        raise ValueError("invalid native growth receipt geometry")
    return Guest(disk, start, after, root_bytes, outcome)


class Oracle:
    """@cc [owner:ghuntley,label:verification;recovery] native-growth-real-disk-oracle
    Two host expansions MUST follow verified clean exits of one disposable root.
    Each expansion MUST increase native filesystem capacity. Every boot MUST
    prove current growth receipts, unchanged GPT identities/nonroot geometry/boot
    and config bytes, exact EFI boot file trees/bytes except bounded root NvVars
    firmware state, retained home data, and an unchanged foreign disk. Unprivileged
    growth MUST refuse. These observations MUST NOT grant native admission.
    """

    def __init__(self, disk: Path, work: Path) -> None:
        self.disk = disk
        self.work = work
        self.initial = layout(disk)
        self.initial_bytes = disk.stat().st_size
        self.immutable = {
            index: partition_digest(disk, partition)
            for index, partition in enumerate(self.initial.partitions[:4])
            if partition.kind not in (SWAP_TYPE, EFI_TYPE)
        }
        self.efi = {
            index: native_fat_oracle.inventory(disk, partition.start * 512, partition.sectors * 512)
            for index, partition in enumerate(self.initial.partitions[:4])
            if partition.kind == EFI_TYPE
        }
        self.foreign = work / "foreign.raw"
        foreign_bytes = secrets.token_bytes(1024**2)
        self.foreign.write_bytes(foreign_bytes)
        self.foreign_digest = hashlib.sha256(foreign_bytes).hexdigest()
        self.observations: list[Guest] = []

    def before_boot(self, generation: int) -> None:
        if generation != len(self.observations) or generation not in (0, 1, 2):
            raise RuntimeError("native growth boot sequence differs")
        if generation:
            with self.disk.open("r+b") as target:
                target.truncate(self.initial_bytes + generation * EXPANSION)

    def guest(self, probe: Probe, sudo: str) -> Guest:
        receipt = probe(f"{sudo} -n /bin/cat /var/run/overalls/root-growth.json")
        if receipt.returncode or len(receipt.stdout) > 4096:
            raise RuntimeError("native growth current receipt is unavailable")
        capacity = probe("/bin/df -kP /")
        lines = capacity.stdout.splitlines()
        if capacity.returncode or len(lines) != 2:
            raise RuntimeError("native growth capacity response differs")
        fields = lines[1].split()
        if len(fields) != 6 or fields[5] != b"/" or not fields[1].isdigit():
            raise RuntimeError("native growth capacity response differs")
        raw: object = json.loads(receipt.stdout)
        observation = guest_value(raw, int(fields[1]) * 1024)
        disabled = probe("/bin/cat /etc/rc.conf.d/growfs")
        if disabled.returncode or disabled.stdout != b'growfs_enable="NO"\n':
            raise RuntimeError("native growth stock firstboot path is enabled")
        refused = probe("/usr/local/libexec/overalls-native-grow-root")
        if (
            refused.returncode == 0
            or refused.stdout
            or refused.stderr != SSH_LOGIN_EVENT + b"native_root_growth_failed\n"
        ):
            raise RuntimeError("native growth unprivileged helper did not refuse")
        return observation

    def after_shutdown(self, observation: Guest) -> None:
        current = layout(self.disk)
        generation = len(self.observations)
        root = current.root
        if (
            observation.disk_bytes != self.initial_bytes + generation * EXPANSION
            or observation.disk_bytes != self.disk.stat().st_size
            or observation.root_start != root.start
            or observation.root_end != root.start + root.sectors - 1
            or current.identity != self.initial.identity
            or current.first != self.initial.first
            or current.partitions[:4] != self.initial.partitions[:4]
            or root.start != self.initial.root.start
            or root.kind != self.initial.root.kind
            or root.identity != self.initial.root.identity
            or root.name != self.initial.root.name
            or root.attributes != self.initial.root.attributes
            or any(
                partition_digest(self.disk, current.partitions[i]) != value
                for i, value in self.immutable.items()
            )
            or any(
                native_fat_oracle.inventory(
                    self.disk,
                    current.partitions[i].start * 512,
                    current.partitions[i].sectors * 512,
                )
                != value
                for i, value in self.efi.items()
            )
            or hashlib.sha256(self.foreign.read_bytes()).hexdigest() != self.foreign_digest
        ):
            raise RuntimeError("native root growth altered protected disk identities or bytes")
        if self.observations and (
            observation.outcome != "grown"
            or observation.root_bytes <= self.observations[-1].root_bytes
            or observation.root_end <= self.observations[-1].root_end
        ):
            raise RuntimeError("native root did not grow after host expansion")
        self.observations.append(observation)

    def finish(self, boot_ids: list[str]) -> None:
        if len(self.observations) != 3 or len(set(boot_ids)) != 3:
            raise RuntimeError("native root growth lacks three clean boot observations")
        receipt = {
            "version": 1,
            "os": "freebsd",
            "boot_ids": boot_ids,
            "physical_bytes": [value.disk_bytes for value in self.observations],
            "root_bytes": [value.root_bytes for value in self.observations],
            "checks": [
                "two-clean-reboot-native-root-capacity-increases",
                "gpt-identities-nonroot-geometry-boot-and-config-bytes-preserved",
                "attached-foreign-disk-bytes-unchanged",
                "unprivileged-growth-refused-and-stock-firstboot-disabled",
                "current-growth-receipts-and-home-bytes-retained-three-boots",
            ],
            "native_admission": False,
        }
        (self.work / "growth-receipt.json").write_text(
            json.dumps(receipt, sort_keys=True, indent=2) + "\n", encoding="utf-8"
        )
