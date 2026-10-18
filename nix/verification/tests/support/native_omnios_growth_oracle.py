"""Observe native OmniOS ZFS growth on one disposable, repeatedly booted disk."""

from __future__ import annotations

import binascii
import hashlib
import json
import os
import re
import secrets
import shlex
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO

import native_fat_oracle as fat
import native_growth_oracle as shared

SECTOR = 512
INITIAL_BYTES = 8 * 1024**3
EXPANSION = shared.EXPANSION
POOL = "overalls_native_candidate"
DATASET = f"{POOL}/ROOT/overalls-native-candidate"
POOL_GUID = "6088636317398311714"
VDEV_GUID = "7318836247622920379"
DISK_GUID = "9c59ba04-83a2-0040-a996-c8c91931d866"
HELPER = "/opt/overalls/libexec/overalls-native-grow-root"
RECEIPT = "/var/run/overalls/root-growth.json"
STOCK_SERVICES = (
    "svc:/system/cloud-init:initlocal",
    "svc:/system/cloud-init:init",
    "svc:/system/cloud-init:modules",
    "svc:/system/cloud-init:final",
    "svc:/network/ssh:default",
)
CHECKS = (
    "two-clean-reboot-native-zfs-root-and-pool-capacity-increases",
    "dual-gpt-crcs-pinned-identities-and-unused-entries-preserved",
    "loader-file-bytes-preserved-except-bounded-firmware-nvvars-and-reserved-bytes-preserved",
    "assembly-kernel-helper-pool-and-single-whole-disk-vdev-bound",
    "attached-foreign-disk-bytes-unchanged",
    "unprivileged-and-caller-selected-growth-targets-refused",
    "stock-automation-disabled-and-current-volatile-growth-receipt",
    "home-bytes-retained-across-three-complete-service-boots",
)

# The full assembly receipt exceeds the SSH response bound. This fixed native
# probe checks its private files and returns only a small identity projection.
# All external JSON fields are narrowed again by assembly_value on the host.
ASSEMBLY_PROBE = """\
import hashlib
import json
import stat
from pathlib import Path


def object_value(value: object) -> dict[str, object]:
    if not isinstance(value, dict):
        raise ValueError("invalid native assembly object")
    fields: dict[str, object] = {}
    for key, item in value.items():
        if not isinstance(key, str):
            raise ValueError("invalid native assembly field")
        fields[key] = item
    return fields


def private_file(path: Path, limit: int) -> bytes:
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != 0 or metadata.st_mode & 0o022:
        raise ValueError("invalid native assembly file")
    with path.open("rb") as source:
        data = source.read(limit + 1)
    if len(data) > limit:
        raise ValueError("native assembly file exceeds bound")
    return data


data: bytes = private_file(Path("/etc/overalls/native-image/assembly-receipt.json"), 8 * 1024**2)
raw = object_value(json.loads(data))
keys: tuple[str, ...] = ("version", "os", "build_id", "dataset", "pool_guid", "native_admission", "runtime_validated")
projection: dict[str, object] = {key: raw[key] for key in keys}
unix = object_value(raw.get("unix"))
payload: object = raw.get("payload_files")
if not isinstance(payload, list):
    raise ValueError("invalid native assembly payload")
records: list[dict[str, object]] = []
for item in payload:
    record = object_value(item)
    if record.get("name") == "root/opt/overalls/libexec/overalls-native-grow-root":
        records.append(record)
if len(records) != 1 or records[0].get("kind") != "file" or records[0].get("mode") != 0o555:
    raise ValueError("invalid native assembly helper")
projection["unix_sha256"] = unix.get("sha256")
projection["assembly_sha256"] = hashlib.sha256(data).hexdigest()
projection["helper_receipt_sha256"] = records[0].get("sha256")
projection["helper_sha256"] = hashlib.sha256(private_file(Path("/opt/overalls/libexec/overalls-native-grow-root"), 100 * 1024**2)).hexdigest()
projection["installed_build_id"] = private_file(Path("/etc/overalls/kernel-build-id"), 65).decode("ascii")
print(json.dumps(projection, sort_keys=True))
"""


def digest_value(value: object) -> str:
    if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{64}", value) is None:
        raise ValueError("invalid native OmniOS digest")
    return value


def word(data: bytes, offset: int, size: int) -> int:
    if offset < 0 or size <= 0 or offset + size > len(data):
        raise ValueError("truncated native OmniOS GPT field")
    return int.from_bytes(data[offset : offset + size], "little")


def read_at(source: BinaryIO, sector: int, size: int) -> bytes:
    source.seek(sector * SECTOR)
    data = source.read(size)
    if len(data) != size:
        raise ValueError("truncated native OmniOS disk")
    return data


@dataclass(frozen=True)
class Header:
    current: int
    backup: int
    first: int
    last: int
    identity: bytes
    array: int
    array_crc: int


def header(data: bytes) -> Header:
    if (
        len(data) != SECTOR
        or data[:8] != b"EFI PART"
        or word(data, 8, 4) != 0x10000
        or word(data, 12, 4) != 92
        or word(data, 20, 4) != 0
        or word(data, 80, 4) != 9
        or word(data, 84, 4) != 128
    ):
        raise ValueError("invalid native OmniOS GPT header")
    checked = data[:16] + bytes(4) + data[20:92]
    if binascii.crc32(checked) != word(data, 16, 4):
        raise ValueError("invalid native OmniOS GPT header CRC")
    return Header(
        word(data, 24, 8),
        word(data, 32, 8),
        word(data, 40, 8),
        word(data, 48, 8),
        data[56:72],
        word(data, 72, 8),
        word(data, 88, 4),
    )


def guid_bytes(identity: str) -> bytes:
    return uuid.UUID(identity).bytes_le


@dataclass(frozen=True)
class Partition:
    start: int
    end: int
    entry: bytes

    @property
    def identity_bytes(self) -> bytes:
        return self.entry[:32] + self.entry[48:]


@dataclass(frozen=True)
class Layout:
    disk_bytes: int
    backup: int
    root: Partition
    loader: Partition
    reserved: Partition
    protected_mbr: bytes


def partition(entry: bytes, slot: int, backup: int) -> Partition:
    specs = {
        1: (
            256,
            524543,
            "c12a7328-f81f-11d2-ba4b-00a0c93ec93b",
            "3ddfc4e1-8931-4041-a067-9c3af6e7e6ff",
            "loader",
        ),
        2: (
            524544,
            backup - 16417,
            "6a898cc3-1dd2-11b2-99a6-080020736631",
            "9610b7a1-df6c-1a45-ba89-159690b86a8d",
            "zfs",
        ),
        9: (
            backup - 16416,
            backup - 33,
            "6a945a3b-1dd2-11b2-99a6-080020736631",
            "4ae19670-ff90-8249-a2f6-d9a305e6fa78",
            "",
        ),
    }
    start, end, kind, identity, name = specs[slot]
    expected_name = name.encode("utf-16le").ljust(72, b"\0")
    if (
        len(entry) != 128
        or entry[:16] != guid_bytes(kind)
        or entry[16:32] != guid_bytes(identity)
        or word(entry, 32, 8) != start
        or word(entry, 40, 8) != end
        or word(entry, 48, 8) != 0
        or entry[56:] != expected_name
    ):
        raise ValueError("native OmniOS GPT partition differs from the pinned layout")
    return Partition(start, end, entry)


def layout(disk: Path) -> Layout:
    """Validate both GPT copies independently of the guest growth helper."""
    size = disk.stat().st_size
    if size < INITIAL_BYTES or size > INITIAL_BYTES + 2 * EXPANSION or size % SECTOR:
        raise ValueError("invalid native OmniOS disk capacity")
    with disk.open("rb") as source:
        mbr = read_at(source, 0, SECTOR)
        if (
            mbr[510:] != b"\x55\xaa"
            or mbr[450] != 0xEE
            or word(mbr, 454, 4) != 1
            or any(mbr[462:510])
        ):
            raise ValueError("invalid native OmniOS protective MBR")
        primary = header(read_at(source, 1, SECTOR))
        backup_sector = size // SECTOR - 1
        if (
            primary.current != 1
            or primary.backup != backup_sector
            or primary.first != 34
            or primary.last != backup_sector - 33
            or primary.identity != guid_bytes(DISK_GUID)
            or primary.array != 2
        ):
            raise ValueError("native OmniOS GPT does not cover the current disk")
        secondary = header(read_at(source, backup_sector, SECTOR))
        if secondary != Header(
            backup_sector,
            1,
            primary.first,
            primary.last,
            primary.identity,
            backup_sector - 32,
            primary.array_crc,
        ):
            raise ValueError("native OmniOS backup GPT differs")
        entries = read_at(source, 2, 9 * 128)
        if (
            binascii.crc32(entries) != primary.array_crc
            or read_at(source, secondary.array, len(entries)) != entries
        ):
            raise ValueError("native OmniOS GPT arrays or CRCs differ")
    sentinel = bytes(40) + b"\xff" * 8 + bytes(80)
    if any(entries[index * 128 : (index + 1) * 128] != sentinel for index in range(2, 8)):
        raise ValueError("native OmniOS unused GPT slots differ")
    return Layout(
        size,
        backup_sector,
        partition(entries[128:256], 2, backup_sector),
        partition(entries[:128], 1, backup_sector),
        partition(entries[1024:], 9, backup_sector),
        mbr[:458] + mbr[462:],
    )


def partition_digest(disk: Path, part: Partition) -> str:
    digest = hashlib.sha256()
    remaining = (part.end - part.start + 1) * SECTOR
    with disk.open("rb") as source:
        source.seek(part.start * SECTOR)
        while remaining:
            chunk = source.read(min(1024**2, remaining))
            if not chunk:
                raise ValueError("truncated native OmniOS protected partition")
            digest.update(chunk)
            remaining -= len(chunk)
    return digest.hexdigest()


@dataclass(frozen=True)
class Assembly:
    digest: str
    build_id: str
    helper_digest: str


def assembly_value(raw: object, expected_kernel_sha256: str) -> Assembly:
    fields = shared.object_value(raw)
    keys = {
        "version",
        "os",
        "build_id",
        "dataset",
        "pool_guid",
        "native_admission",
        "runtime_validated",
        "unix_sha256",
        "assembly_sha256",
        "helper_receipt_sha256",
        "helper_sha256",
        "installed_build_id",
    }
    if (
        set(fields) != keys
        or type(fields["version"]) is not int
        or fields["version"] != 1
        or fields["os"] != "illumos"
        or fields["dataset"] != DATASET
        or fields["pool_guid"] != POOL_GUID
        or fields["native_admission"] is not False
        or fields["runtime_validated"] is not False
        or digest_value(fields["unix_sha256"]) != digest_value(expected_kernel_sha256)
        or digest_value(fields["helper_receipt_sha256"]) != digest_value(fields["helper_sha256"])
    ):
        raise ValueError("native OmniOS assembly identity differs")
    build_id = digest_value(fields["build_id"])
    if fields["installed_build_id"] != build_id + "\n":
        raise ValueError("native OmniOS installed compiled token differs")
    return Assembly(
        digest_value(fields["assembly_sha256"]), build_id, digest_value(fields["helper_sha256"])
    )


def mount_value(body: bytes) -> None:
    roots = 0
    volatile = 0
    for line in body.decode("ascii").splitlines():
        fields = line.split()
        if len(fields) not in (6, 7):
            raise ValueError("invalid native OmniOS mount response")
        if fields[2] == "/":
            if fields[:4] != [DATASET, "-", "/", "zfs"]:
                raise ValueError("native OmniOS growth is not the assembled root")
            roots += 1
        if fields[2] == "/var/run":
            if fields[3] != "tmpfs":
                raise ValueError("native OmniOS growth receipt is not volatile")
            volatile += 1
    if roots != 1 or volatile != 1:
        raise ValueError("native OmniOS growth lacks its root or volatile mount")


def topology_value(body: bytes) -> str:
    types: list[str] = []
    guids: list[str] = []
    fields: dict[str, str] = {}
    for line in body.decode("ascii").splitlines():
        key, separator, value = line.strip().partition(":")
        if not separator:
            continue
        value = value.strip()
        if key == "type":
            types.append(value)
        elif key == "guid":
            guids.append(value)
        elif key in (
            "name",
            "pool_guid",
            "vdev_children",
            "children[0]",
            "path",
            "whole_disk",
            "is_log",
        ):
            if key in fields:
                raise ValueError("duplicate native OmniOS pool identity")
            fields[key] = value
        elif key.startswith("children[") or key in ("spares", "l2cache", "is_spare"):
            raise ValueError("native OmniOS growth has another vdev")
    path = fields.get("path", "")
    if (
        types != ["'root'", "'disk'"]
        or guids != [POOL_GUID, VDEV_GUID]
        or fields.get("name") != f"'{POOL}'"
        or fields.get("pool_guid") != POOL_GUID
        or fields.get("vdev_children") != "1"
        or fields.get("children[0]") != ""
        or fields.get("whole_disk") != "1"
        or fields.get("is_log") != "0"
        or re.fullmatch(r"'/dev/dsk/c[0-9]{1,8}t[0-9]{1,8}d[0-9]{1,8}s1'", path) is None
    ):
        raise ValueError("native OmniOS mounted pool or sole whole-disk vdev differs")
    return path[1:-1]


def properties_value(body: bytes, expected: set[str]) -> dict[str, int]:
    fields: dict[str, int] = {}
    for line in body.decode("ascii").splitlines():
        columns = line.split()
        if len(columns) != 2 or columns[0] not in expected or columns[0] in fields:
            raise ValueError("invalid native OmniOS capacity properties")
        if re.fullmatch(r"[0-9]{1,20}", columns[1]) is None:
            raise ValueError("invalid native OmniOS capacity property")
        fields[columns[0]] = int(columns[1])
    if set(fields) != expected:
        raise ValueError("missing native OmniOS capacity property")
    return fields


def guest_value(raw: object, root_bytes: int) -> shared.Guest:
    fields = shared.object_value(raw)
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
    if (
        set(fields) != keys
        or type(fields["version"]) is not int
        or fields["version"] != 1
        or fields["os"] != "illumos"
        or fields["native_admission"] is not False
        or fields["outcome"] not in ("grown", "unchanged")
    ):
        raise ValueError("invalid native OmniOS growth receipt authority")
    disk = shared.integer(fields["disk_bytes"])
    start = shared.integer(fields["root_start"])
    before = shared.integer(fields["root_end_before"])
    after = shared.integer(fields["root_end_after"])
    backup_before = shared.integer(fields["backup_before"])
    backup_after = shared.integer(fields["backup_after"])
    outcome = fields["outcome"]
    if (
        disk not in (INITIAL_BYTES, INITIAL_BYTES + EXPANSION, INITIAL_BYTES + 2 * EXPANSION)
        or start != 524544
        or before < 16760798
        or after != backup_after - 16417
        or before != backup_before - 16417
        or before > after
        or backup_before > backup_after
        or backup_after != disk // SECTOR - 1
        or (outcome == "grown") != (after > before)
        or type(root_bytes) is not int
        or not 0 < root_bytes < disk
        or not isinstance(outcome, str)
    ):
        raise ValueError("invalid native OmniOS growth receipt geometry")
    return shared.Guest(disk, start, after, root_bytes, outcome)


def command(probe: shared.Probe, body: str) -> bytes:
    result = probe(body)
    if (
        result.returncode != 0
        or result.stderr != shared.SSH_LOGIN_EVENT
        or len(result.stdout) > 4096
    ):
        raise RuntimeError("native OmniOS growth guest command refused")
    return result.stdout


def refusal(probe: shared.Probe, body: str) -> None:
    result = probe(body)
    if (
        result.returncode == 0
        or result.stdout
        or result.stderr != shared.SSH_LOGIN_EVENT + b"native_root_growth_failed\n"
    ):
        raise RuntimeError("native OmniOS growth helper did not refuse")


@dataclass(frozen=True)
class Evidence:
    observation: shared.Guest
    assembly: Assembly
    pool_bytes: int
    path: str
    before: int
    backup_before: int


class Oracle:
    """@cc [owner:ghuntley,label:verification;recovery] native-omnios-growth-evidence
    Three complete real-service boots MUST reuse one pinned disposable disk and
    preserve home data. Host expansions MUST follow the runner's observed clean
    exits. Each expansion MUST increase root dataset and pool capacity. Both GPT
    copies, original loader file bytes, relocated reserved bytes and the foreign
    disk MUST remain valid. Only the bounded root firmware NvVars regular file
    MAY differ in the loader FAT inventory. The mounted pool/vdev and helper MUST match assembly
    evidence bound to the manifest kernel. Missing or stale evidence MUST refuse
    completion. These scoped observations MUST NOT grant native admission.
    """

    def __init__(self, disk: Path, work: Path, expected_kernel_sha256: str) -> None:
        self.disk = disk
        self.work = work
        self.kernel = digest_value(expected_kernel_sha256)
        self.initial = layout(disk)
        if self.initial.disk_bytes != INITIAL_BYTES:
            raise ValueError("native OmniOS growth requires the unexpanded pinned disk")
        self.loader_inventory = fat.inventory(
            disk,
            self.initial.loader.start * SECTOR,
            (self.initial.loader.end - self.initial.loader.start + 1) * SECTOR,
        )
        self.reserved_digest = partition_digest(disk, self.initial.reserved)
        self.foreign = work / "foreign.raw"
        with self.foreign.open("xb") as target:
            target.write(secrets.token_bytes(1024**2))
        self.foreign_digest = hashlib.sha256(self.foreign.read_bytes()).hexdigest()
        self.observations: list[Evidence] = []
        self.pending: Evidence | None = None
        self.active = False
        # A host-side expansion can be visible before the guest has published
        # its volatile receipt.  Keep that retry state explicit so a
        # test-only interruption can exercise recovery without silently
        # truncating the disk back to its previous capacity.
        self.retry_generation: int | None = None

    def before_boot(self, generation: int) -> None:
        if type(generation) is not int:
            raise RuntimeError("native OmniOS growth boot sequence differs")
        retry = self.retry_generation == generation
        expected_bytes = (
            INITIAL_BYTES + generation * EXPANSION
            if retry
            else INITIAL_BYTES + max(0, generation - 1) * EXPANSION
        )
        if (
            generation != len(self.observations)
            or generation not in (0, 1, 2)
            or self.active
            or self.pending is not None
            or self.disk.stat().st_size != expected_bytes
            or (self.retry_generation is not None and not retry)
        ):
            raise RuntimeError("native OmniOS growth boot sequence differs")
        if generation and not retry:
            with self.disk.open("r+b") as target:
                target.truncate(INITIAL_BYTES + generation * EXPANSION)
                target.flush()
                os.fsync(target.fileno())
        if retry:
            self.retry_generation = None
        self.active = True

    def interrupt_before_guest(self) -> None:
        """@cc [owner:ghuntley,label:verification;recovery] native-omnios-growth-retry
        A test-only interrupted expansion MUST retain the host-expanded disk,
        clear the active boot without publishing guest evidence, and allow one
        retry of the same generation. A retry MUST reuse the retained capacity
        and MUST still pass the ordinary guest and clean-shutdown checks before
        the closed growth receipt can be written.
        """
        generation = len(self.observations)
        if (
            not self.active
            or self.pending is not None
            or generation not in (1, 2)
            or self.retry_generation is not None
            or self.disk.stat().st_size != INITIAL_BYTES + generation * EXPANSION
        ):
            raise RuntimeError("native OmniOS growth interruption is not retryable")
        self.active = False
        self.retry_generation = generation

    def guest(self, probe: shared.Probe, sudo: str) -> shared.Guest:
        if not self.active or self.pending is not None or sudo != "/usr/bin/sudo":
            raise RuntimeError("native OmniOS growth lacks the current boot")
        mount_value(command(probe, f"{sudo} -n /usr/sbin/mount -p"))
        receipt = command(probe, f"{sudo} -n /usr/bin/cat {RECEIPT}")
        raw: object = json.loads(receipt)
        dataset = properties_value(
            command(
                probe,
                f"{sudo} -n /usr/sbin/zfs get -Hp -o property,value used,available,quota,refquota {DATASET}",
            ),
            {"used", "available", "quota", "refquota"},
        )
        if dataset["quota"] or dataset["refquota"]:
            raise RuntimeError("native OmniOS root capacity is limited by a quota")
        observation = guest_value(raw, dataset["used"] + dataset["available"])
        assembly_raw: object = json.loads(
            command(probe, f"{sudo} -n /usr/bin/python3 -I -c {shlex.quote(ASSEMBLY_PROBE)}")
        )
        assembly = assembly_value(assembly_raw, self.kernel)
        path = topology_value(command(probe, f"{sudo} -n /usr/sbin/zdb -C {POOL}"))
        pool = properties_value(
            command(probe, f"{sudo} -n /usr/sbin/zpool get -Hp -o property,value guid,size {POOL}"),
            {"guid", "size"},
        )
        if (
            str(pool["guid"]) != POOL_GUID
            or not observation.root_bytes < pool["size"] < observation.disk_bytes
        ):
            raise RuntimeError("native OmniOS root capacity does not belong to the pinned pool")
        for service in STOCK_SERVICES:
            if command(probe, f"{sudo} -n /usr/bin/svcs -H -o state {service}") != b"disabled\n":
                raise RuntimeError("native OmniOS stock automation is enabled")
        refusal(probe, HELPER)
        refusal(probe, f"{sudo} -n {HELPER} caller-selected-target")
        if command(probe, f"{sudo} -n /usr/bin/cat {RECEIPT}") != receipt:
            raise RuntimeError("refused native OmniOS growth changed the success receipt")
        fields = shared.object_value(raw)
        self.pending = Evidence(
            observation,
            assembly,
            pool["size"],
            path,
            shared.integer(fields["root_end_before"]),
            shared.integer(fields["backup_before"]),
        )
        return observation

    def after_shutdown(self, observation: shared.Guest) -> None:
        evidence = self.pending
        generation = len(self.observations)
        if evidence is None or evidence.observation != observation or not self.active:
            raise RuntimeError("native OmniOS growth lacks current guest observations")
        current = layout(self.disk)
        previous_root = (
            self.observations[-1].observation.root_end if generation else self.initial.root.end
        )
        previous_backup = previous_root + 16417
        if (
            observation.disk_bytes != INITIAL_BYTES + generation * EXPANSION
            or observation.disk_bytes != current.disk_bytes
            or observation.root_start != current.root.start
            or observation.root_end != current.root.end
            or evidence.before != previous_root
            or evidence.backup_before != previous_backup
            or observation.outcome != ("grown" if generation else "unchanged")
            or current.loader != self.initial.loader
            or current.root.identity_bytes != self.initial.root.identity_bytes
            or current.reserved.identity_bytes != self.initial.reserved.identity_bytes
            or current.protected_mbr != self.initial.protected_mbr
            or fat.inventory(
                self.disk,
                current.loader.start * SECTOR,
                (current.loader.end - current.loader.start + 1) * SECTOR,
            )
            != self.loader_inventory
            or partition_digest(self.disk, current.reserved) != self.reserved_digest
            or self.foreign.stat().st_size != 1024**2
            or hashlib.sha256(self.foreign.read_bytes()).hexdigest() != self.foreign_digest
        ):
            raise RuntimeError("native OmniOS growth altered protected disk identities or bytes")
        if self.observations and (
            evidence.assembly != self.observations[0].assembly
            or observation.root_bytes <= self.observations[-1].observation.root_bytes
            or evidence.pool_bytes <= self.observations[-1].pool_bytes
        ):
            raise RuntimeError(
                "native OmniOS growth lacks preserved assembly and increased capacity"
            )
        self.observations.append(evidence)
        self.pending = None
        self.active = False

    def finish(self, boot_ids: list[str]) -> None:
        if (
            len(self.observations) != 3
            or len(boot_ids) != 3
            or len(set(boot_ids)) != 3
            or any(
                re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", boot) is None
                for boot in boot_ids
            )
            or self.active
            or self.pending is not None
            or self.retry_generation is not None
        ):
            raise RuntimeError("native OmniOS growth lacks three clean boot observations")
        receipt = {
            "version": 1,
            "os": "illumos",
            "boot_ids": boot_ids,
            "physical_bytes": [value.observation.disk_bytes for value in self.observations],
            "root_bytes": [value.observation.root_bytes for value in self.observations],
            "pool_bytes": [value.pool_bytes for value in self.observations],
            "kernel_sha256": self.kernel,
            "assembly_sha256": self.observations[0].assembly.digest,
            "compiled_build_id": self.observations[0].assembly.build_id,
            "helper_sha256": self.observations[0].assembly.helper_digest,
            "pool_guid": POOL_GUID,
            "vdev_guid": VDEV_GUID,
            "checks": list(CHECKS),
            "scope": "three complete native service boots and two clean-shutdown root expansions; no interrupted expansion, isolation, fleet or catalog acceptance",
            "native_admission": False,
        }
        destination = self.work / "growth-receipt.json"
        temporary = self.work / ".growth-receipt.json.tmp"
        with temporary.open("x", encoding="utf-8") as target:
            target.write(json.dumps(receipt, sort_keys=True, indent=2) + "\n")
            target.flush()
            os.fsync(target.fileno())
        temporary.replace(destination)
