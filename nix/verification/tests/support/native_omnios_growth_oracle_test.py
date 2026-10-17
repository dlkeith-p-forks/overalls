"""Exercise OmniOS growth evidence refusals without claiming native execution."""

from __future__ import annotations

import binascii
import json
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path

import native_growth_oracle as shared
import native_omnios_growth_oracle as growth

KERNEL = "b" * 64
BUILD_ID = "a" * 64
HELPER = "c" * 64
ASSEMBLY = "d" * 64
RESERVED = b"reserved-partition-retained\n"
BOOT_IDS = [f"00000000-0000-4000-8000-00000000000{index}" for index in range(3)]


def assembly() -> dict[str, object]:
    return {
        "version": 1,
        "os": "illumos",
        "build_id": BUILD_ID,
        "dataset": growth.DATASET,
        "pool_guid": growth.POOL_GUID,
        "native_admission": False,
        "runtime_validated": False,
        "unix_sha256": KERNEL,
        "assembly_sha256": ASSEMBLY,
        "helper_receipt_sha256": HELPER,
        "helper_sha256": HELPER,
        "installed_build_id": BUILD_ID + "\n",
    }


def receipt(generation: int) -> dict[str, object]:
    disk = growth.INITIAL_BYTES + generation * growth.EXPANSION
    before = growth.INITIAL_BYTES + max(0, generation - 1) * growth.EXPANSION
    return {
        "version": 1,
        "os": "illumos",
        "outcome": "grown" if generation else "unchanged",
        "disk_bytes": disk,
        "root_start": 524544,
        "root_end_before": before // 512 - 16418,
        "root_end_after": disk // 512 - 16418,
        "backup_before": before // 512 - 1,
        "backup_after": disk // 512 - 1,
        "native_admission": False,
    }


def topology() -> bytes:
    return f"""\
MOS Configuration:
        name: '{growth.POOL}'
        pool_guid: {growth.POOL_GUID}
        vdev_children: 1
        vdev_tree:
            type: 'root'
            guid: {growth.POOL_GUID}
            children[0]:
                type: 'disk'
                guid: {growth.VDEV_GUID}
                path: '/dev/dsk/c2t0d0s1'
                whole_disk: 1
                is_log: 0
""".encode()


def mounts() -> bytes:
    return (
        f"{growth.DATASET} - / zfs - no\nswap - /var/run tmpfs - no\nproc - /proc proc - no\n"
    ).encode()


def gpt_header(current: int, backup: int, array: int, last: int, entries: bytes) -> bytes:
    data = bytearray(512)
    data[:8] = b"EFI PART"
    struct.pack_into("<III", data, 8, 0x10000, 92, 0)
    struct.pack_into("<QQQQ", data, 24, current, backup, 34, last)
    data[56:72] = growth.guid_bytes(growth.DISK_GUID)
    struct.pack_into("<QIII", data, 72, array, 9, 128, binascii.crc32(entries))
    struct.pack_into("<I", data, 16, binascii.crc32(data[:92]))
    return bytes(data)


def write_layout(disk: Path, generation: int, *, entries_override: bytes | None = None) -> None:
    """Construct sparse pinned geometry and relocate retained reserved test bytes."""
    size = growth.INITIAL_BYTES + generation * growth.EXPANSION
    backup = size // 512 - 1
    entries = bytearray(9 * 128)
    specs = (
        (
            1,
            256,
            524543,
            "c12a7328-f81f-11d2-ba4b-00a0c93ec93b",
            "3ddfc4e1-8931-4041-a067-9c3af6e7e6ff",
            "loader",
        ),
        (
            2,
            524544,
            backup - 16417,
            "6a898cc3-1dd2-11b2-99a6-080020736631",
            "9610b7a1-df6c-1a45-ba89-159690b86a8d",
            "zfs",
        ),
        (
            9,
            backup - 16416,
            backup - 33,
            "6a945a3b-1dd2-11b2-99a6-080020736631",
            "4ae19670-ff90-8249-a2f6-d9a305e6fa78",
            "",
        ),
    )
    for index in range(2, 8):
        entries[index * 128 + 40 : index * 128 + 48] = b"\xff" * 8
    for slot, start, end, kind, identity, name in specs:
        offset = (slot - 1) * 128
        entries[offset : offset + 16] = growth.guid_bytes(kind)
        entries[offset + 16 : offset + 32] = growth.guid_bytes(identity)
        struct.pack_into("<QQQ", entries, offset + 32, start, end, 0)
        entries[offset + 56 : offset + 128] = name.encode("utf-16le").ljust(72, b"\0")
    serialized = entries_override if entries_override is not None else bytes(entries)
    mbr = bytearray(512)
    mbr[450] = 0xEE
    struct.pack_into("<II", mbr, 454, 1, size // 512 - 1)
    mbr[510:] = b"\x55\xaa"
    with disk.open("r+b" if disk.exists() else "w+b") as target:
        target.truncate(size)
        for sector, data in (
            (0, bytes(mbr)),
            (1, gpt_header(1, backup, 2, backup - 33, serialized)),
            (2, serialized),
            (backup - 32, serialized),
            (backup, gpt_header(backup, 1, backup - 32, backup - 33, serialized)),
            (backup - 16416, RESERVED),
        ):
            target.seek(sector * 512)
            target.write(data)


def fat_command(arguments: list[str]) -> None:
    subprocess.run(arguments, capture_output=True, check=True, timeout=15)


def loader_file(disk: Path, name: str, content: bytes) -> None:
    source = disk.parent / "loader-file"
    source.write_bytes(content)
    image = f"{disk}@@{256 * 512}"
    fat_command(["mcopy", "-o", "-i", image, str(source), "::/" + name])


def format_loader(disk: Path) -> None:
    image = f"{disk}@@{256 * 512}"
    fat_command(["mformat", "-i", image, "-T", "524288", "::"])
    fat_command(["mmd", "-i", image, "::/EFI", "::/EFI/BOOT"])
    loader_file(disk, "EFI/BOOT/BOOTX64.EFI", b"native-bootloader-retained\n")


class Probe:
    def __init__(self, generation: int) -> None:
        self.generation = generation
        self.assembly = assembly()
        self.commands: list[str] = []

    def __call__(self, command: str) -> subprocess.CompletedProcess[bytes]:
        self.commands.append(command)
        if command == growth.HELPER or command.endswith(" caller-selected-target"):
            return subprocess.CompletedProcess(
                command, 1, b"", shared.SSH_LOGIN_EVENT + b"native_root_growth_failed\n"
            )
        if command.endswith("/usr/sbin/mount -p"):
            body = mounts()
        elif command.endswith(growth.RECEIPT):
            body = json.dumps(receipt(self.generation)).encode()
        elif "zfs get" in command:
            capacity = 6 * 1024**3 + self.generation * growth.EXPANSION
            body = f"used\t1024\navailable\t{capacity - 1024}\nquota\t0\nrefquota\t0\n".encode()
        elif "/usr/bin/python3 -I -c" in command:
            body = json.dumps(self.assembly).encode()
        elif "zdb -C" in command:
            body = topology()
        elif "zpool get" in command:
            capacity = 7 * 1024**3 + self.generation * growth.EXPANSION
            body = f"guid\t{growth.POOL_GUID}\nsize\t{capacity}\n".encode()
        elif "/usr/bin/svcs -H -o state " in command:
            body = b"disabled\n"
        else:
            raise AssertionError("unreviewed synthetic growth probe")
        return subprocess.CompletedProcess(command, 0, body, shared.SSH_LOGIN_EVENT)


class GrowthBoundaryTest(unittest.TestCase):
    def test_assembly_kernel_digest_is_distinct_from_compiled_token_and_helper_binding(
        self,
    ) -> None:
        valid = growth.assembly_value(assembly(), KERNEL)
        self.assertEqual(valid.build_id, BUILD_ID)
        self.assertEqual(valid.helper_digest, HELPER)
        for key, value in (
            ("version", True),
            ("pool_guid", "42"),
            ("dataset", "foreign/ROOT/root"),
            ("native_admission", True),
            ("runtime_validated", True),
            ("unix_sha256", BUILD_ID),
            ("installed_build_id", KERNEL + "\n"),
            ("helper_sha256", "e" * 64),
            ("assembly_sha256", "unbounded"),
            ("extra", False),
        ):
            with self.subTest(key=key), self.assertRaises(ValueError):
                growth.assembly_value(assembly() | {key: value}, KERNEL)

    def test_native_receipt_refuses_stale_or_unbounded_geometry(self) -> None:
        for generation in range(3):
            self.assertEqual(
                growth.guest_value(receipt(generation), 6 * 1024**3).outcome,
                "grown" if generation else "unchanged",
            )
        for key, value in (
            ("version", True),
            ("os", "freebsd"),
            ("native_admission", True),
            ("root_start", 524543),
            ("root_end_before", 16760797),
            ("root_end_after", 16760798),
            ("backup_before", 16777214),
            ("disk_bytes", growth.INITIAL_BYTES),
            ("outcome", "unchanged"),
            ("extra", None),
        ):
            with self.subTest(key=key), self.assertRaises(ValueError):
                growth.guest_value(receipt(1) | {key: value}, 6 * 1024**3)

    def test_mounted_root_and_volatile_receipt_are_required(self) -> None:
        growth.mount_value(mounts())
        for invalid in (
            mounts().replace(growth.DATASET.encode(), b"foreign/ROOT/root"),
            mounts().replace(b"tmpfs", b"zfs"),
            mounts() + mounts(),
            b"foreign - / zfs - no\n",
        ):
            with self.subTest(body=invalid), self.assertRaises(ValueError):
                growth.mount_value(invalid)

    def test_exact_pool_leaf_guid_and_single_whole_disk_topology(self) -> None:
        self.assertEqual(growth.topology_value(topology()), "/dev/dsk/c2t0d0s1")
        for invalid in (
            topology().replace(growth.VDEV_GUID.encode(), b"42"),
            topology().replace(b"type: 'disk'", b"type: 'mirror'"),
            topology().replace(b"whole_disk: 1", b"whole_disk: 0"),
            topology().replace(b"s1'", b"s0'"),
            topology() + b"                children[1]:\n",
            topology() + b"                spares:\n",
            topology() + b"                path: '/dev/dsk/c3t0d0s1'\n",
        ):
            with self.subTest(body=invalid), self.assertRaises(ValueError):
                growth.topology_value(invalid)

    def test_capacity_properties_are_complete_numeric_and_unique(self) -> None:
        self.assertEqual(
            growth.properties_value(b"size\t42\nguid\t43\n", {"size", "guid"}),
            {"size": 42, "guid": 43},
        )
        for invalid in (
            b"size\t42\n",
            b"size\t42\nsize\t43\n",
            b"size\t1.5G\nguid\t43\n",
            b"size\t42\nguid\t-1\n",
            b"size\t42\nguid\t43\nextra\t0\n",
        ):
            with self.subTest(body=invalid), self.assertRaises(ValueError):
                growth.properties_value(invalid, {"size", "guid"})

    def test_commands_require_exact_login_event_and_helper_refusal(self) -> None:
        for status, body, error in (
            (0, b"ok", b""),
            (0, b"ok", shared.SSH_LOGIN_EVENT + b"extra"),
            (1, b"", shared.SSH_LOGIN_EVENT),
            (0, b"x" * 4097, shared.SSH_LOGIN_EVENT),
        ):

            def probe(
                command: str, status: int = status, body: bytes = body, error: bytes = error
            ) -> subprocess.CompletedProcess[bytes]:
                return subprocess.CompletedProcess(command, status, body, error)

            with self.subTest(status=status, size=len(body)), self.assertRaises(RuntimeError):
                growth.command(probe, "fixed")
        for status, body, error in (
            (0, b"", shared.SSH_LOGIN_EVENT + b"native_root_growth_failed\n"),
            (1, b"unexpected", shared.SSH_LOGIN_EVENT + b"native_root_growth_failed\n"),
            (1, b"", b"permission denied\n"),
        ):

            def refused(
                command: str, status: int = status, body: bytes = body, error: bytes = error
            ) -> subprocess.CompletedProcess[bytes]:
                return subprocess.CompletedProcess(command, status, body, error)

            with self.subTest(status=status, size=len(body)), self.assertRaises(RuntimeError):
                growth.refusal(refused, "fixed")

    def test_dual_gpt_crcs_identity_unused_sentinels_and_expanded_tail(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            disk = Path(directory) / "disk.raw"
            for generation in range(3):
                write_layout(disk, generation)
                current = growth.layout(disk)
                self.assertEqual(current.reserved.end - current.reserved.start + 1, 16384)
                self.assertEqual(current.root.end + 1, current.reserved.start)
                self.assertEqual(current.backup, disk.stat().st_size // 512 - 1)
            write_layout(disk, 0)
            with disk.open("r+b") as target:
                target.seek(512 + 16)
                target.write(b"\0" * 4)
            with self.assertRaises(ValueError):
                growth.layout(disk)
            write_layout(disk, 0)
            with disk.open("r+b") as target:
                target.seek((growth.INITIAL_BYTES // 512 - 33) * 512)
                target.write(b"corrupted")
            with self.assertRaises(ValueError):
                growth.layout(disk)
            for offset in (0, 128 + 16, 2 * 128 + 40, 8 * 128 + 48):
                write_layout(disk, 0)
                with disk.open("rb") as source:
                    source.seek(1024)
                    entries = bytearray(source.read(9 * 128))
                entries[offset] ^= 1
                write_layout(disk, 0, entries_override=bytes(entries))
                with self.subTest(offset=offset), self.assertRaises(ValueError):
                    growth.layout(disk)
            write_layout(disk, 0)
            with disk.open("r+b") as target:
                target.truncate(growth.INITIAL_BYTES + growth.EXPANSION)
            with self.assertRaises(ValueError):
                growth.layout(disk)

    def test_three_boot_state_machine_real_expansions_and_closed_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            disk = work / "disk.raw"
            write_layout(disk, 0)
            format_loader(disk)
            oracle = growth.Oracle(disk, work, KERNEL)
            with self.assertRaises(RuntimeError):
                oracle.before_boot(1)
            with self.assertRaises(RuntimeError):
                oracle.finish(BOOT_IDS)
            for generation in range(3):
                oracle.before_boot(generation)
                self.assertEqual(
                    disk.stat().st_size, growth.INITIAL_BYTES + generation * growth.EXPANSION
                )
                with self.assertRaises(RuntimeError):
                    oracle.before_boot(generation)
                write_layout(disk, generation)
                loader_file(disk, "NvVars", f"firmware-generation-{generation}".encode())
                probe = Probe(generation)
                observed = oracle.guest(probe, "/usr/bin/sudo")
                self.assertIn(growth.HELPER, probe.commands)
                self.assertIn(
                    f"/usr/bin/sudo -n {growth.HELPER} caller-selected-target", probe.commands
                )
                with self.assertRaises(RuntimeError):
                    oracle.guest(probe, "/usr/bin/sudo")
                oracle.after_shutdown(observed)
            with self.assertRaises(RuntimeError):
                oracle.finish([BOOT_IDS[0]] * 3)
            oracle.finish(BOOT_IDS)
            raw: object = json.loads((work / "growth-receipt.json").read_bytes())
            finished = shared.object_value(raw)
            self.assertIs(finished["native_admission"], False)
            self.assertEqual(finished["checks"], list(growth.CHECKS))
            self.assertEqual(finished["assembly_sha256"], ASSEMBLY)
            self.assertEqual(finished["compiled_build_id"], BUILD_ID)
            self.assertEqual(finished["kernel_sha256"], KERNEL)
            self.assertEqual(
                finished["physical_bytes"],
                [growth.INITIAL_BYTES + generation * growth.EXPANSION for generation in range(3)],
            )

    def test_foreign_disk_reserved_bytes_and_assembly_mutation_refuse_completion(self) -> None:
        for mutation in ("foreign", "reserved", "assembly", "boot-file"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                work = Path(directory)
                disk = work / "disk.raw"
                write_layout(disk, 0)
                format_loader(disk)
                oracle = growth.Oracle(disk, work, KERNEL)
                oracle.before_boot(0)
                observed = oracle.guest(Probe(0), "/usr/bin/sudo")
                oracle.after_shutdown(observed)
                oracle.before_boot(1)
                write_layout(disk, 1)
                probe = Probe(1)
                if mutation == "assembly":
                    probe.assembly["assembly_sha256"] = "e" * 64
                observed = oracle.guest(probe, "/usr/bin/sudo")
                if mutation == "foreign":
                    with oracle.foreign.open("r+b") as target:
                        target.write(b"foreign mutation")
                elif mutation == "reserved":
                    with disk.open("r+b") as target:
                        target.seek((disk.stat().st_size // 512 - 16417) * 512)
                        target.write(b"reserved mutation")
                elif mutation == "boot-file":
                    loader_file(disk, "EFI/BOOT/BOOTX64.EFI", b"unexpected boot-file mutation")
                with self.assertRaises(RuntimeError):
                    oracle.after_shutdown(observed)
                self.assertFalse((work / "growth-receipt.json").exists())

    def test_embedded_native_projection_is_valid_python(self) -> None:
        compile(growth.ASSEMBLY_PROBE, "native-assembly-projection", "exec")


if __name__ == "__main__":
    unittest.main()
