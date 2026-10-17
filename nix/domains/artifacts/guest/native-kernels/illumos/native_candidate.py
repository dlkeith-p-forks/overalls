#!/usr/bin/python3
"""Native Solaris-kmod linkage and alternate-ZFS-root candidate installation."""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import TypedDict

MAX_FILE = 16 * 1024 * 1024
MAX_RECEIPT = 256 * 1024
EVIDENCE = Path("share/overalls/native-kernel")
type JSON = bool | int | str | list[JSON] | dict[str, JSON] | None


@dataclass(frozen=True)
class Module:
    name: str
    objects: tuple[str, ...]
    dependencies: tuple[str, ...]
    destination: str


SOCKFS = (
    "socksubr",
    "sockvfsops",
    "sockparams",
    "socksyscalls",
    "socktpi",
    "sockstr",
    "sockcommon_vnops",
    "sockcommon_subr",
    "sockcommon_sops",
    "sockcommon",
    "sock_notsupp",
    "socknotify",
    "sodirect",
    "sockfilter",
)
MODULES = (
    Module(
        "virtio",
        ("virtio_main", "virtio_dma", "virtio_legacy", "virtio_modern"),
        (),
        "kernel/misc/amd64/virtio",
    ),
    Module("vioblk", ("vioblk",), ("misc/virtio", "drv/blkdev"), "kernel/drv/amd64/vioblk"),
    Module("vioif", ("vioif",), ("misc/virtio", "misc/mac"), "kernel/drv/amd64/vioif"),
    Module("vioscsi", ("vioscsi",), ("misc/scsi", "misc/virtio"), "kernel/drv/amd64/vioscsi"),
    Module("vio9p", ("vio9p",), ("misc/virtio",), "kernel/drv/amd64/vio9p"),
    Module("viorand", ("viorand",), ("misc/kcf", "misc/virtio"), "kernel/drv/amd64/viorand"),
    Module("sockfs", SOCKFS, ("drv/ip",), "kernel/fs/amd64/sockfs"),
    Module("viosock", ("viosock", "ov_vsock"), ("misc/virtio",), "kernel/drv/amd64/viosock"),
    Module(
        "sockvsock",
        ("sockvsock",),
        ("fs/sockfs", "drv/viosock"),
        "kernel/socketmod/amd64/sockvsock",
    ),
)


class FileRecord(TypedDict):
    name: str
    bytes: int
    sha256: str


def read_file(path: Path, limit: int = MAX_FILE) -> bytes:
    """Read bounded regular files without following a final symbolic link."""
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        metadata = os.fstat(stream.fileno())
        if not stat.S_ISREG(metadata.st_mode) or not 0 < metadata.st_size <= limit:
            raise ValueError(f"not a bounded regular file: {path}")
        data = stream.read(limit + 1)
        if len(data) != metadata.st_size:
            raise ValueError(f"file changed or exceeded bound: {path}")
        return data


def json_value(value: object) -> JSON:
    if value is None or isinstance(value, str | bool | int):
        return value
    if isinstance(value, list):
        return [json_value(item) for item in value]
    if isinstance(value, dict):
        result: dict[str, JSON] = {}
        for key, item in value.items():
            if not isinstance(key, str):
                raise ValueError("receipt key is not text")
            result[key] = json_value(item)
        return result
    raise ValueError("unsupported receipt value")


def object_value(value: JSON) -> dict[str, JSON]:
    if not isinstance(value, dict):
        raise ValueError("expected receipt object")
    return value


def receipt(path: Path) -> tuple[dict[str, JSON], bytes]:
    data = read_file(path, MAX_RECEIPT)
    parsed: object = json.loads(data)
    return object_value(json_value(parsed)), data


def digest(value: str) -> str:
    if re.fullmatch(r"[0-9a-f]{64}", value) is None:
        raise ValueError("expected lowercase SHA-256/build identity")
    return value


def file_record(name: str, data: bytes) -> FileRecord:
    return {"name": name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def verified_file(path: Path, record: dict[str, JSON]) -> bytes:
    data = read_file(path)
    size = record.get("bytes")
    expected = record.get("sha256")
    if (
        type(size) is not int
        or not 0 < size <= MAX_FILE
        or not isinstance(expected, str)
        or digest(expected) != hashlib.sha256(data).hexdigest()
        or len(data) != size
    ):
        raise ValueError(f"file digest/size mismatch: {path}")
    return data


def check_elf(data: bytes) -> None:
    if (
        len(data) < 64
        or data[:7] != b"\x7fELF\x02\x01\x01"
        or int.from_bytes(data[16:18], "little") != 1
        or int.from_bytes(data[18:20], "little") != 62
    ):
        raise ValueError("expected ELF64 little-endian amd64 relocatable module/object")


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")
    path.chmod(0o644)


def native() -> None:
    if sys.platform != "sunos5":
        raise ValueError("this operation requires native illumos/Solaris")


def command(arguments: list[str], timeout: int = 120) -> str:
    result = subprocess.run(
        arguments,
        check=True,
        capture_output=True,
        text=True,
        timeout=timeout,
        env={"PATH": "/usr/sbin:/usr/bin:/sbin", "LC_ALL": "C"},
    )
    if len(result.stdout) + len(result.stderr) > MAX_RECEIPT:
        raise ValueError("native utility output exceeded evidence bound")
    return result.stdout + result.stderr


def link(bundle: Path, expected: str, output: Path) -> None:
    """@cc [owner:ghuntley,label:build;verification] native-solaris-kmod-link
    Linkage MUST verify the exact26 pinned object hashes and expected build ID,
    invoke native Solaris ld -ztype=kmod with the complete fixed dependency sets,
    and publish actual nine-module hashes only after every link succeeds.
    A link receipt MUST leave runtime validation and native admission false.
    """
    native()
    digest(expected)
    source, source_bytes = receipt(bundle / EVIDENCE / "build-receipt.json")
    if (
        source.get("version") != 1
        or source.get("os") != "illumos"
        or source.get("build_id") != expected
        or source.get("compiled") is not True
        or source.get("kernel_syscall_symbols_checked") is not True
        or source.get("linked") is not False
        or source.get("native_admission") is not False
        or read_file(bundle / EVIDENCE / "build-id", 65) != (expected + "\n").encode()
    ):
        raise ValueError("object receipt does not identify the expected closed candidate")
    objects = source.get("objects")
    if not isinstance(objects, list):
        raise ValueError("missing object list")
    wanted = {name + ".o" for module in MODULES for name in module.objects}
    records: dict[str, dict[str, JSON]] = {}
    for item in objects:
        record = object_value(item)
        name = record.get("name")
        if not isinstance(name, str) or name not in wanted or name in records:
            raise ValueError("unexpected/duplicate object name")
        records[name] = record
    if set(records) != wanted or len(records) != 26:
        raise ValueError("the complete exact26 object set is required")
    # Stage verified bytes, so linkage never rereads mutable source objects.
    output.mkdir(mode=0o700)
    staged = output / ".objects"
    staged.mkdir()
    for name, record in records.items():
        data = verified_file(bundle / "objects" / name, record)
        check_elf(data)
        (staged / name).write_bytes(data)
    evidence = output / EVIDENCE
    evidence.mkdir(parents=True)
    (evidence / "input-build-receipt.json").write_bytes(source_bytes)
    linker = command(["/usr/bin/ld", "-V"]).strip()
    if "Solaris Link Editors" not in linker:
        raise ValueError("native Solaris linker identity missing")
    module_records: list[FileRecord] = []
    module_dir = output / "modules"
    module_dir.mkdir()
    for module in MODULES:
        arguments = ["/usr/bin/ld", "-ztype=kmod"]
        for dependency in module.dependencies:
            arguments.extend(["-N", dependency])
        destination = module_dir / module.name
        arguments.extend(["-o", str(destination)])
        arguments.extend(str(staged / (name + ".o")) for name in module.objects)
        command(arguments)
        data = read_file(destination)
        check_elf(data)
        destination.chmod(0o644)
        module_records.append(file_record(module.name, data))
    header = read_file(bundle / "include/sys/vsock.h", 65536)
    (output / "include/sys").mkdir(parents=True)
    (output / "include/sys/vsock.h").write_bytes(header)
    (evidence / "build-id").write_text(expected + "\n")
    shutil.rmtree(staged)
    write_json(
        evidence / "linked-receipt.json",
        {
            "version": 1,
            "os": "illumos",
            "build_id": expected,
            "input_receipt_sha256": hashlib.sha256(source_bytes).hexdigest(),
            "linker": linker,
            "linker_contract": "solaris-kmod",
            "modules": module_records,
            "public_header": file_record("vsock.h", header),
            "linked": True,
            "loadability_validated": False,
            "runtime_validated": False,
            "native_admission": False,
        },
    )
    output.chmod(0o755)


def alternate_root(root: Path, mounts: str) -> str:
    """@cc [owner:ghuntley,label:isolation;build] native-alternate-zfs-root
    Installation MUST refuse the running root, a directory inside that root's
    dataset, and any non-ZFS mount. The target MUST be an exact canonical mount
    point of a different dataset, with no symlink in its absolute path.
    """
    if not root.is_absolute() or root != root.resolve() or root == Path("/"):
        raise ValueError("target must be a canonical alternate root")
    target = ""
    running = ""
    for line in mounts.splitlines():
        fields = line.split()
        if len(fields) not in (6, 7):
            continue
        dataset, _, mountpoint, filesystem, *_ = fields
        if mountpoint == "/":
            running = dataset
        if mountpoint == str(root):
            if filesystem != "zfs":
                raise ValueError("target is not a native ZFS filesystem")
            target = dataset
    if not target or not running or target == running or not root.is_dir():
        raise ValueError("target is not a separate mounted ZFS boot environment")
    return target


def destination(root: Path, relative: str) -> Path:
    path = root / relative
    if path.resolve() != path or not path.is_relative_to(root):
        raise ValueError("target path contains a symbolic link or escapes root")
    for ancestor in (path, *path.parents):
        if ancestor.exists():
            check_ownership(ancestor.lstat())
    return path


def check_ownership(metadata: os.stat_result) -> None:
    if metadata.st_uid != 0 or metadata.st_mode & 0o022:
        raise ValueError("target/ancestor must be root-owned and not writable by group/others")


def check_socket_mappings(root: Path) -> None:
    directory = destination(root, "etc/sock2path.d")
    mappings = sorted(directory.iterdir()) if directory.is_dir() else []
    legacy = root / "etc/sock2path"
    if legacy.exists() or legacy.is_symlink():
        mappings.append(legacy)
    for path in mappings:
        destination(root, str(path.relative_to(root)))
        check_socket_mapping(read_file(path, 65536).decode())


def check_socket_mapping(text: str) -> None:
    for line in text.splitlines():
        fields = line.split("#", 1)[0].split()
        if not fields:
            continue
        if len(fields) != 4:
            raise ValueError("unrecognized socket mapping row")
        family, socket_type, protocol = (int(value, 10) for value in fields[:3])
        if (
            family == 40
            and socket_type == 2
            and protocol in (-1, 0)
            and (protocol != 0 or fields[3] != "sockvsock")
        ):
            raise ValueError("conflicting family40 stream socket mapping")


def install_file(root: Path, relative: str, data: bytes, mode: int = 0o644) -> None:
    path = destination(root, relative)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".overalls-new")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
        os.fchown(stream.fileno(), 0, 0)
        os.fchmod(stream.fileno(), mode)
    temporary.replace(path)


def install(root: Path, bundle: Path, expected: str) -> None:
    """@cc [owner:ghuntley,label:build;security;verification] native-module-installation
    Installation MUST verify all nine linked module bytes and the public header
    before mutation, preserve legacy aliases, install the family40 stream mapping,
    and successfully rebuild the alternate root boot archive before its receipt.
    Existing destination ancestors MUST be root-owned and not writable by group
    or others; conflicting family40 stream socket mappings MUST refuse.
    It MUST NOT select a boot environment or claim runtime/native acceptance.
    """
    native()
    digest(expected)
    if os.geteuid() != 0:
        raise ValueError("alternate-root assembly requires root")
    dataset = alternate_root(root, command(["/usr/sbin/mount", "-p"]))
    destination(root, ".")
    command(["/usr/sbin/zfs", "list", "-H", "-o", "name", dataset])
    linked, linked_bytes = receipt(bundle / EVIDENCE / "linked-receipt.json")
    if (
        linked.get("version") != 1
        or linked.get("os") != "illumos"
        or linked.get("build_id") != expected
        or linked.get("linked") is not True
        or linked.get("linker_contract") != "solaris-kmod"
        or linked.get("runtime_validated") is not False
        or linked.get("native_admission") is not False
        or read_file(bundle / EVIDENCE / "build-id", 65) != (expected + "\n").encode()
    ):
        raise ValueError("linked receipt does not identify the expected closed candidate")
    modules = linked.get("modules")
    if not isinstance(modules, list) or len(modules) != len(MODULES):
        raise ValueError("complete linked module set required")
    verified: dict[str, bytes] = {}
    wanted = {module.name for module in MODULES}
    for item in modules:
        record = object_value(item)
        name = record.get("name")
        if not isinstance(name, str) or name not in wanted or name in verified:
            raise ValueError("unexpected/duplicate linked module")
        verified[name] = verified_file(bundle / "modules" / name, record)
        check_elf(verified[name])
    if set(verified) != wanted:
        raise ValueError("missing linked module")
    header = verified_file(
        bundle / "include/sys/vsock.h", object_value(linked.get("public_header"))
    )
    # Preflight every fixed destination before the first write.
    for relative in [module.destination for module in MODULES] + [
        "usr/include/sys/vsock.h",
        "etc/overalls/kernel-build-id",
        "etc/overalls/native-kernel/linked-receipt.json",
        "etc/driver_aliases",
        "etc/name_to_major",
        "etc/sock2path.d/overalls-native-vsock",
    ]:
        destination(root, relative)
    aliases = read_file(root / "etc/driver_aliases").decode()
    majors = read_file(root / "etc/name_to_major").decode()
    check_socket_mappings(root)
    registrations: list[tuple[str, str, bool]] = []
    for driver, alias in (
        ("vioblk", "pci1af4,1042,p"),
        ("vioif", "pci1af4,1041,p"),
        ("viosock", "pci1af4,1053,p"),
    ):
        existing = re.findall(rf'^([^\s]+)\s+"{re.escape(alias)}"\s*$', aliases, re.MULTILINE)
        if existing and existing != [driver]:
            raise ValueError("modern PCI alias has conflicting owner")
        if not existing:
            registrations.append(
                (driver, alias, re.search(rf"^{driver}\s", majors, re.MULTILINE) is not None)
            )
    for module in MODULES:
        install_file(root, module.destination, verified[module.name])
    install_file(root, "usr/include/sys/vsock.h", header)
    install_file(root, "etc/overalls/kernel-build-id", (expected + "\n").encode())
    install_file(root, "etc/overalls/native-kernel/linked-receipt.json", linked_bytes)
    for driver, alias, registered in registrations:
        utility = "/usr/sbin/update_drv" if registered else "/usr/sbin/add_drv"
        arguments = [utility, "-b", str(root)]
        if registered:
            arguments.append("-a")
        command([*arguments, "-i", f'"{alias}"', driver])
    install_file(root, "etc/sock2path.d/overalls-native-vsock", b"40 2 0 sockvsock\n")
    archive_output = command(["/usr/sbin/bootadm", "update-archive", "-v", "-R", str(root)], 600)
    install_file(
        root, "etc/overalls/native-kernel/boot-archive-output.txt", archive_output.encode()
    )
    install_file(
        root,
        "etc/overalls/native-kernel/install-receipt.json",
        (
            json.dumps(
                {
                    "version": 1,
                    "os": "illumos",
                    "build_id": expected,
                    "linked_receipt_sha256": hashlib.sha256(linked_bytes).hexdigest(),
                    "dataset": dataset,
                    "modules_installed": True,
                    "public_header_installed": True,
                    "boot_archive_updated": True,
                    "runtime_validated": False,
                    "native_admission": False,
                },
                sort_keys=True,
                indent=2,
            )
            + "\n"
        ).encode(),
    )


def main(arguments: list[str]) -> None:
    if len(arguments) == 4 and arguments[0] == "link":
        link(Path(arguments[1]).resolve(), arguments[2], Path(arguments[3]).absolute())
    elif len(arguments) == 4 and arguments[0] == "install":
        install(Path(arguments[1]), Path(arguments[2]).resolve(), arguments[3])
    else:
        raise ValueError(
            "usage: native_candidate.py link OBJECT_BUNDLE BUILD_ID NEW_OUTPUT_DIRECTORY\n"
            "   or: native_candidate.py install ALTERNATE_ZFS_ROOT LINKED_BUNDLE BUILD_ID"
        )


if __name__ == "__main__":
    main(sys.argv[1:])
