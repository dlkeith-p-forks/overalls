"""Isolated storage custody fixtures; these do not establish native ZFS acceptance."""

import importlib.util
import io
import sys
import unittest
from types import SimpleNamespace
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("brady_storage", sys.argv.pop(1))
if spec is None or spec.loader is None:
    raise RuntimeError("brady storage helper unavailable")
s = importlib.util.module_from_spec(spec)
spec.loader.exec_module(s)


class StorageTest(unittest.TestCase):
    def config(self) -> dict[str, object]:
        return {
            "pool": {
                "storage": {"dataset": "tank/lilly", "dataset_guid": "456", "zpool_guid": "123"}
            },
            "dataset": "tank/brady-fixture",
            "host_id": "fixture",
        }

    def test_parent_mismatch_never_mutates(self) -> None:
        with (
            patch.object(s, "properties", return_value={"guid": "999"}),
            patch.object(s, "command") as command,
        ):
            with self.assertRaises(ValueError):
                s.prepare(self.config())
            command.assert_not_called()

    def test_cache_cannot_be_inside_guest_parent(self) -> None:
        config = self.config()
        config["dataset"] = "tank/lilly/brady"
        with patch.object(s, "command") as command:
            with self.assertRaises(ValueError):
                s.prepare(config)
            command.assert_not_called()

    def test_unowned_dataset_is_not_adopted(self) -> None:
        def properties(config: object, dataset: str, names: list[str]) -> dict[str, str]:
            if names == ["guid"]:
                return {"guid": "456"}
            if dataset == "tank":
                return {"used": str(10 * s.GIB), "available": str(90 * s.GIB)}
            return {"org.overalls:brady-host": "other"}

        with (
            patch.object(s, "properties", side_effect=properties),
            patch.object(s, "command", side_effect=["123", "tank\ntank/brady-fixture"]) as command,
        ):
            with self.assertRaisesRegex(ValueError, "cache_dataset_not_owned"):
                s.prepare(self.config())
            self.assertEqual(command.call_count, 2)
            self.assertTrue(
                all(call.args[2][0] in ("get", "list") for call in command.call_args_list)
            )

    def test_pressure_is_native_read_only_and_rejects_snapshot_descendants(self) -> None:
        def props(config: object, dataset: str, names: list[str]) -> dict[str, str]:
            values = {
                "guid": "456",
                "used": "10000000",
                "available": "90000000",
                "readonly": "off",
                "reservation": "0",
                "refreservation": "0",
                "org.overalls:brady-host": "fixture",
                "mountpoint": s.MOUNT,
                "mounted": "yes",
                "quota": "10000000",
                "refquota": "10000000",
                "usedbysnapshots": "0",
            }
            return {key: values[key] for key in names}

        def proc(path: str, **kwargs: object) -> io.StringIO:
            return io.StringIO(
                "100.00 100.00"
                if path == "/proc/uptime"
                else "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
            )

        with (
            patch.object(s, "properties", side_effect=props),
            patch.object(s, "command", side_effect=["123", "tank/brady-fixture"]) as command,
            patch.object(s.os.path, "ismount", return_value=True),
            patch.object(s.os.path, "realpath", return_value=s.MOUNT),
            patch.object(s.os, "stat", return_value=SimpleNamespace(st_dev=s.os.makedev(0, 99))),
            patch("builtins.open", side_effect=proc),
        ):
            value = s.observe(self.config())
            self.assertEqual(value["observed_ms"], 100000)
            self.assertEqual(value["device"], "0:99")
            self.assertEqual(value["pool_total_bytes"], 100000000)
            self.assertTrue(
                all(call.args[2][0] in ("get", "list") for call in command.call_args_list)
            )
            command.side_effect = ["123", "tank/brady-fixture\ntank/brady-fixture@snapshot"]
            with self.assertRaisesRegex(ValueError, "unexpected_cache_descendants"):
                s.observe(self.config())

    def test_command_output_is_bounded(self) -> None:
        with self.assertRaisesRegex(ValueError, "storage_output_limit"):
            s.command({"fixture": sys.executable}, "fixture", ["-c", "print('x' * 70000)"])


unittest.main()
