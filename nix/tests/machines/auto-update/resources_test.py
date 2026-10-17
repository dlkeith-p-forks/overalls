"""Resource-policy mutations are isolated from real host state in these tests."""

import copy
import errno
import importlib.util
import json
import sys
import tempfile
import unittest
from collections.abc import Sequence
from pathlib import Path
from subprocess import CalledProcessError
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("resources", sys.argv.pop(1))
if spec is None or spec.loader is None:
    raise RuntimeError("resources helper unavailable")
resources = importlib.util.module_from_spec(spec)
spec.loader.exec_module(resources)


def manifest(cpu: int = 14, memory: int = 114688, quota: int = 1400) -> dict[str, object]:
    size = quota * 2**30
    return {
        "resourcePolicy": {
            "version": 1,
            "cpuCores": cpu,
            "memoryMiB": memory,
            "quotaBytes": size,
            "arcMaxBytes": 4 * 2**30,
            "dataset": "zroot/lilly",
            "zpoolGuid": "100",
            "datasetGuid": "200",
        },
        "installationBinding": {
            "identity": {"hostId": "fixed"},
            "storage": {"quotaBytes": size, "system": ["disk-a", "disk-b"]},
            "effective": {
                "pools": {
                    "zroot": {
                        "datasets": {
                            "lilly": {"options": {"quota": str(size), "compression": "lz4"}}
                        }
                    }
                }
            },
        },
        "lilly": {
            "binding": {"guestCpuCores": cpu, "guestMemoryMiB": memory, "hostId": "fixed"},
            "owner": {
                "pools": [
                    {
                        "storage": {
                            "dataset": "zroot/lilly",
                            "zpool_guid": "100",
                            "dataset_guid": "200",
                        }
                    }
                ]
            },
        },
    }


class Resources(unittest.TestCase):
    def test_failure_diagnostics_expose_only_closed_reasons(self) -> None:
        self.assertEqual(
            resources.failure_reason(ValueError("resource_identity_changed")),
            "resource_identity_changed",
        )
        self.assertEqual(
            resources.failure_reason(ValueError("sensitive unexpected detail")),
            "resource_policy_invalid_state",
        )
        self.assertEqual(
            resources.failure_reason(CalledProcessError(1, ["zfs", "secret"])),
            "resource_command_failed",
        )
        self.assertEqual(
            resources.failure_reason(
                OSError(errno.EIO, "private detail", "/sys/module/zfs/parameters/zfs_arc_max")
            ),
            "resource_arc_unavailable",
        )
        self.assertEqual(resources.failure_reason(OSError("private path")), "resource_io_failed")
        self.assertEqual(
            resources.failure_reason(
                OSError(errno.EIO, "detail", "/sys/module/zfs/parameters/zfs_arc_dnode_limit")
            ),
            "resource_arc_unavailable",
        )
        self.assertEqual(
            resources.failure_reason(ValueError("resource_decrease_unsafe")),
            "resource_decrease_unsafe",
        )

    def test_memory_decrease_applies_only_with_headroom(self) -> None:
        """@cc [owner:ghuntley,label:verification;capacity] resource-safe-memory-decrease-tested
        A RAM ceiling decrease MUST apply when the slice's current use plus two
        GiB fits and MUST refuse resource_decrease_unsafe, changing nothing,
        when it does not; the dnode limit MUST follow the ARC budget at a quarter.
        """
        old, new = manifest(), manifest(14, 95232, 1400)
        new["resourcePolicy"]["arcMaxBytes"] = 24 * 2**30
        for current_mib, applied in ((20 * 1024, True), (95232 - 2047, False)):
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self.assert_memory_decrease(old, new, root, current_mib, applied)

    def assert_memory_decrease(
        self,
        old: dict[str, object],
        new: dict[str, object],
        root: Path,
        current_mib: int,
        applied: bool,
    ) -> None:
        state = root / "state"
        state.mkdir()
        cgroup = root / "sys/fs/cgroup/lilly.slice"
        cgroup.mkdir(parents=True)
        (cgroup / "memory.max").write_text(str(114688 * 1048576))
        (cgroup / "memory.current").write_text(str(current_mib * 1048576))
        (cgroup / "cpu.max").write_text("1400000 100000")
        parameters = root / "sys/module/zfs/parameters"
        parameters.mkdir(parents=True)
        (parameters / "zfs_arc_max").write_text(str(4 * 2**30))
        (parameters / "zfs_arc_dnode_limit").write_text("0")
        commands: list[Sequence[str]] = []

        def command(argv: Sequence[str], **kwargs: object) -> str:
            commands.append(argv)
            if argv[:2] == ["zpool", "get"]:
                return "100"
            if argv[:2] == ["zfs", "get"]:
                return "200" if argv[-2] == "guid" else str(1400 * 2**30)
            if argv[:2] == ["systemctl", "set-property"]:
                (cgroup / "memory.max").write_text(str(95232 * 1048576))
            return ""

        def discard(path: Path, value: object) -> None:
            return None

        transition = resources.Transition(old, new, command, discard, state, root)
        if applied:
            transition.apply_native()
            self.assertEqual(int((cgroup / "memory.max").read_text()), 95232 * 1048576)
            self.assertEqual(int((parameters / "zfs_arc_max").read_text()), 24 * 2**30)
            self.assertEqual(int((parameters / "zfs_arc_dnode_limit").read_text()), 6 * 2**30)
            return
        with self.assertRaises(ValueError) as refused:
            transition.apply_native()
        self.assertEqual(resources.failure_reason(refused.exception), "resource_decrease_unsafe")
        self.assertEqual(int((cgroup / "memory.max").read_text()), 114688 * 1048576)
        self.assertEqual(int((parameters / "zfs_arc_max").read_text()), 4 * 2**30)
        self.assertFalse(any(argv[:2] == ["systemctl", "set-property"] for argv in commands))

    def test_only_reviewed_capacity_changes_are_compatible(self) -> None:
        old, new = manifest(), manifest(32, 116036, 1593)
        self.assertTrue(resources.compatible(old, new))
        self.assertFalse(resources.compatible(new, old))
        # The RAM ceiling may decrease (apply_native judges safety); CPU and
        # quota decreases stay incompatible.
        self.assertTrue(resources.compatible(manifest(), manifest(14, 95232, 1400)))
        self.assertFalse(resources.compatible(manifest(), manifest(13, 114688, 1400)))
        self.assertFalse(resources.compatible(manifest(), manifest(14, 114688, 1399)))
        for mutate in [
            lambda m: m["installationBinding"]["storage"]["system"].append("disk-c"),
            lambda m: m["installationBinding"]["identity"].update(hostId="other"),
            lambda m: m["lilly"]["binding"].update(hostId="other"),
        ]:
            changed = copy.deepcopy(new)
            mutate(changed)
            self.assertFalse(resources.compatible(old, changed))
        wrong = copy.deepcopy(new)
        wrong["resourcePolicy"]["datasetGuid"] = "300"
        with self.assertRaises(ValueError):
            resources.compatible(old, wrong)
        policyless = copy.deepcopy(old)
        policyless.pop("resourcePolicy")
        self.assertTrue(resources.compatible(policyless, policyless))
        self.assertFalse(resources.compatible(policyless, old))
        self.assertFalse(resources.compatible(policyless, new))
        self.assertFalse(resources.compatible(old, policyless))

    def test_boot_without_journal_does_not_publish_receipts(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with (
                patch.object(resources.Transition, "apply_native") as native,
                patch.object(resources.Transition, "prepare") as prepare,
                patch.object(resources.Transition, "apply") as apply,
            ):
                resources.reapply(manifest(), None, root / "state", root)
                native.assert_called_once_with()
                prepare.assert_not_called()
                apply.assert_not_called()
            self.assertEqual(list(root.iterdir()), [])

    def test_explicit_enrollment_defers_journal_receipt_replay(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            marker = root / "var/lib/overalls-host/enrollment-in-progress.json"
            marker.parent.mkdir(parents=True)
            marker.write_text('{"version":1,"revision":"fixture"}')
            with (
                patch.object(resources.Transition, "apply_native") as native,
                patch.object(resources.Transition, "prepare") as prepare,
                patch.object(resources.Transition, "apply") as apply,
            ):
                resources.reapply(manifest(), None, root / "state", root)
                native.assert_called_once_with()
                prepare.assert_not_called()
                apply.assert_not_called()

    def test_interrupted_application_retains_and_reconciles_original_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / "state"
            state.mkdir()
            old, new = manifest(), manifest(32, 116036, 1593)
            receipt = {
                "binding": old["installationBinding"],
                "poolGuid": "100",
                "datasetGuid": "200",
                "machine": "fixed",
            }
            original = {
                "storage.json": receipt,
                "enrollment.json": {"storage": receipt, "revision": "original"},
            }
            for name, record in original.items():
                path = root / "var/lib/overalls-host" / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(json.dumps(record))
            cgroup = root / "sys/fs/cgroup/lilly.slice"
            cgroup.mkdir(parents=True)
            (cgroup / "memory.max").write_text(str(114688 * 1048576))
            (cgroup / "cpu.max").write_text("1400000 100000")
            arc = root / "sys/module/zfs/parameters/zfs_arc_max"
            arc.parent.mkdir(parents=True)
            arc.write_text(str(8 * 2**30))
            commands = []
            quota = [1400 * 2**30]

            def command(argv: Sequence[str], **kwargs: object) -> str:
                commands.append(argv)
                if argv[:2] == ["zpool", "get"]:
                    return "100"
                if argv[:2] == ["zfs", "get"]:
                    return "200" if argv[-2] == "guid" else str(quota[0])
                if argv[:2] == ["zfs", "set"]:
                    quota[0] = int(argv[2].split("=")[1])
                if argv[:2] == ["systemctl", "set-property"]:
                    (cgroup / "cpu.max").write_text("3200000 100000")
                    (cgroup / "memory.max").write_text(str(116036 * 1048576))
                return ""

            def atomic(path: Path, value: object) -> None:
                path.write_text(json.dumps(value))

            transition = resources.Transition(old, new, command, atomic, state, root)
            transition.prepare()
            # Native effects and one receipt completed before process loss.
            transition.apply_native()
            atomic(
                root / "var/lib/overalls-host/storage.json",
                transition.updated_receipt("storage.json", receipt),
            )
            # A later authenticated enrollment may advance independently of the
            # retained resource journal. Resource replay must not revert it.
            enrollment_path = root / "var/lib/overalls-host/enrollment.json"
            enrollment = json.loads(enrollment_path.read_text())
            enrollment["revision"] = "newer-enrollment"
            atomic(enrollment_path, enrollment)
            retry = resources.Transition(new, new, command, atomic, state, root)
            resources.reapply(new, command, state, root)
            for name in original:
                current = json.loads((root / "var/lib/overalls-host" / name).read_text())
                expected = transition.updated_receipt(name, original[name])
                self.assertEqual(
                    transition.storage_receipt(name, current),
                    transition.storage_receipt(name, expected),
                )
            self.assertEqual(
                json.loads(enrollment_path.read_text())["revision"], "newer-enrollment"
            )
            retry.prepare()
            retry.apply()
            self.assertEqual(retry.record["receipts"], original)
            for name in original:
                current = json.loads((root / "var/lib/overalls-host" / name).read_text())
                expected = retry.updated_receipt(name, original[name])
                self.assertEqual(
                    retry.storage_receipt(name, current), retry.storage_receipt(name, expected)
                )
            self.assertEqual(
                json.loads(enrollment_path.read_text())["revision"], "newer-enrollment"
            )
            self.assertFalse(any("stop" in argv or "destroy" in argv for argv in commands))
            quota[0] += 1
            with self.assertRaises(ValueError):
                retry.prepare()


if __name__ == "__main__":
    unittest.main()
