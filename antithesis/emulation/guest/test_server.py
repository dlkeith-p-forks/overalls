"""Focused wire and identity checks that do not launch a guest."""

import hashlib
import json
import socket
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

from runner import Config, ensure_network, network_identity, stop
from server import (
    MAX_REQUEST_BYTES,
    GuestRequest,
    ToolConfig,
    dispatch,
    image_identity,
    inventory,
    parse_terminal_snapshot,
    process_proof,
    process_status,
    read_frame,
    stopped_record,
    witness,
    witness_config,
)


class GuestControlTest(unittest.TestCase):
    def test_profile_network_identity_matches_lilly_derivation(self) -> None:
        placement = "11111111-1111-4111-8111-111111111111"
        tap = "lvbd7662a5eeb4"
        for profile in (10, 20, 30, 40):
            for slot in (2, 65534):
                high, low = divmod(slot, 256)
                address = f"10.{profile}.{high}.{low}"
                mac = f"02:fc:0a:{profile:02x}:{high:02x}:{low:02x}"
                self.assertEqual(
                    network_identity(placement, address, tap, mac),
                    (
                        f"10.{profile}.0.1",
                        f"10.41.{high}.{low}" if profile == 40 else None,
                    ),
                )
                for invalid in (
                    (address, tap, "02:fc:0a:0a:00:02" if profile != 10 else "02:00:00:00:00:03"),
                    (address, "ktbd7662a5ee", mac),
                ):
                    with (
                        self.subTest(profile=profile, slot=slot, invalid=invalid),
                        self.assertRaises(ValueError),
                    ):
                        network_identity(placement, *invalid)
        for reserved in ("10.20.0.1", "10.20.255.255", "10.41.0.2"):
            with self.assertRaises(ValueError):
                network_identity(placement, reserved, tap, "02:fc:0a:14:00:02")

    def test_tap_routes_match_profile_and_inception_pair(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            base = Config(
                image_dir=state,
                state_dir=state,
                socket_dir=state / "sockets",
                placement_id="11111111-1111-4111-8111-111111111111",
                execution_epoch=1,
                generation=1,
                boot_challenge="a" * 64,
                address="10.20.0.2",
                tap="lvbd7662a5eeb4",
                mac="02:fc:0a:14:00:02",
                disk_bytes=4294967296,
                qemu=Path("/nix/store/qemu"),
                qemu_img=Path("/nix/store/qemu-img"),
                backend=Path("/nix/store/backend"),
                ip=Path("/nix/store/ip"),
            )
            with (
                patch("runner.tap_exists", return_value=False),
                patch("runner.command") as command,
            ):
                ensure_network(base)
            arguments = [entry.args[0] for entry in command.call_args_list]
            self.assertIn([str(base.ip), "addr", "add", "10.20.0.1/32", "dev", base.tap], arguments)
            self.assertIn(
                [str(base.ip), "route", "add", "10.20.0.2/32", "dev", base.tap, "scope", "link"],
                arguments,
            )
            self.assertFalse(any("10.41" in " ".join(parts) for parts in arguments))

            inception = replace(base, address="10.40.0.2", mac="02:fc:0a:28:00:02")
            with (
                patch("runner.tap_exists", return_value=False),
                patch("runner.command") as command,
            ):
                ensure_network(inception)
            arguments = [entry.args[0] for entry in command.call_args_list]
            self.assertIn(
                [str(base.ip), "route", "add", "10.41.0.2/32", "dev", base.tap, "scope", "link"],
                arguments,
            )

    def test_image_identity_matches_protocol_vector(self) -> None:
        artifact = {"bytes": 1024, "sha256": "a" * 64}
        manifest = {
            "version": 4,
            "workspace_source_version": None,
            "architecture": "x86_64",
            "boot_args": "console=ttyS0",
            "minimum_memory_bytes": 536870912,
            "minimum_disk_bytes": 2147483648,
            "kernel": artifact,
            "initrd": artifact,
            "rootfs": artifact,
        }
        with tempfile.TemporaryDirectory() as directory:
            image = Path(directory)
            (image / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
            result = image_identity(image)
        self.assertEqual(
            result["image_id"],
            "sha256:eeb47a8bb710690ac810aeea6a3b6a869272ed2816d5414a547ac3255b58607f",
        )

    def test_request_rejects_path_and_operation_expansion(self) -> None:
        request: dict[str, object] = {
            "operation": "reconcile",
            "placement_id": "11111111-1111-4111-8111-111111111111",
            "execution_epoch": 1,
            "generation": 1,
            "boot_challenge": "a" * 64,
            "address": "10.20.0.2",
            "tap": "lvbd7662a5eeb4",
            "mac": "02:fc:0a:14:00:02",
            "disk_bytes": 4294967296,
        }
        self.assertEqual(GuestRequest.parse(request).operation, "reconcile")
        self.assertEqual(
            GuestRequest.parse({**request, "operation": "process_proof"}).operation,
            "process_proof",
        )
        with self.assertRaises(ValueError):
            GuestRequest.parse({**request, "qemu": "/bin/sh"})
        with self.assertRaises(ValueError):
            GuestRequest.parse({**request, "operation": "qmp"})

    def test_frame_limit_and_uncertain_inventory(self) -> None:
        sender, receiver = socket.socketpair()
        with sender, receiver:
            sender.sendall(b"x" * (MAX_REQUEST_BYTES + 1) + b"\n")
            with self.assertRaises(ValueError):
                read_frame(receiver, MAX_REQUEST_BYTES)

        with (
            tempfile.TemporaryDirectory() as directory,
            tempfile.TemporaryDirectory() as image_directory,
        ):
            root = Path(directory)
            image = Path(image_directory)
            artifact = {"bytes": 1024, "sha256": "a" * 64}
            (image / "manifest.json").write_text(
                json.dumps(
                    {
                        "version": 4,
                        "workspace_source_version": None,
                        "architecture": "x86_64",
                        "boot_args": "console=ttyS0",
                        "minimum_memory_bytes": 536870912,
                        "minimum_disk_bytes": 2147483648,
                        "kernel": artifact,
                        "initrd": artifact,
                        "rootfs": artifact,
                    }
                ),
                encoding="utf-8",
            )
            placement = root / "11111111-1111-4111-8111-111111111111"
            placement.mkdir()
            (placement / "launch-attempt.json").write_text("{}", encoding="utf-8")
            tools = ToolConfig(
                image_dir=image,
                qemu=Path("/nix/store/qemu"),
                qemu_img=Path("/nix/store/qemu-img"),
                backend=Path("/nix/store/backend"),
                ip=Path("/nix/store/ip"),
            )
            result = inventory(root, tools)
        self.assertEqual(
            result["placements"],
            [
                {
                    "placement_id": "11111111-1111-4111-8111-111111111111",
                    "execution_epoch": None,
                    "generation": None,
                    "state": "uncertain",
                    "live": False,
                    "overlay_present": False,
                    "qemu_pid": None,
                    "backend_pid": None,
                }
            ],
        )

    def test_stopped_inventory_keeps_last_boot_tuple(self) -> None:
        with (
            tempfile.TemporaryDirectory() as directory,
            tempfile.TemporaryDirectory() as image_directory,
        ):
            root = Path(directory)
            image = Path(image_directory)
            artifact = {"bytes": 1024, "sha256": "a" * 64}
            (image / "manifest.json").write_text(
                json.dumps(
                    {
                        "version": 4,
                        "workspace_source_version": None,
                        "architecture": "x86_64",
                        "boot_args": "console=ttyS0",
                        "minimum_memory_bytes": 536870912,
                        "minimum_disk_bytes": 2147483648,
                        "kernel": artifact,
                        "initrd": artifact,
                        "rootfs": artifact,
                    }
                ),
                encoding="utf-8",
            )
            tools = ToolConfig(
                image_dir=image,
                qemu=Path("/nix/store/qemu"),
                qemu_img=Path("/nix/store/qemu-img"),
                backend=Path("/nix/store/backend"),
                ip=Path("/nix/store/ip"),
            )
            good = root / "11111111-1111-4111-8111-111111111111"
            good.mkdir()
            (good / "stopped.json").write_text(
                json.dumps({"placement_id": good.name, "execution_epoch": 3, "generation": 2}),
                encoding="utf-8",
            )
            stale = root / "22222222-2222-4222-8222-222222222222"
            stale.mkdir()
            (stale / "stopped.json").write_text(
                json.dumps({"placement_id": good.name, "execution_epoch": 3, "generation": 2}),
                encoding="utf-8",
            )
            placements = inventory(root, tools)["placements"]
        self.assertIsInstance(placements, list)
        assert isinstance(placements, list)
        self.assertEqual(
            [(p["state"], p["execution_epoch"], p["generation"]) for p in placements],
            [("stopped", 3, 2), ("uncertain", None, None)],
        )

    def test_stale_stop_does_not_terminate_newer_launch(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            config = Config(
                image_dir=state,
                state_dir=state,
                socket_dir=state / "sockets",
                placement_id="11111111-1111-4111-8111-111111111111",
                execution_epoch=3,
                generation=3,
                boot_challenge="a" * 64,
                address="10.20.0.2",
                tap="lvbd7662a5eeb4",
                mac="02:fc:0a:14:00:02",
                disk_bytes=4294967296,
                qemu=Path("/nix/store/qemu"),
                qemu_img=Path("/nix/store/qemu-img"),
                backend=Path("/nix/store/backend"),
                ip=Path("/nix/store/ip"),
            )
            (state / "launch-attempt.json").write_text(
                json.dumps(
                    {
                        "placement_id": config.placement_id,
                        "execution_epoch": config.execution_epoch,
                        "generation": config.generation,
                        "boot_challenge": config.boot_challenge,
                    }
                ),
                encoding="utf-8",
            )
            (state / "launch.json").write_text(
                json.dumps(
                    {
                        "placement_id": config.placement_id,
                        "execution_epoch": 4,
                        "generation": 4,
                        "boot_challenge": "b" * 64,
                        "address": config.address,
                        "tap": config.tap,
                        "mac": config.mac,
                        "qemu": {},
                        "backend": {},
                    }
                ),
                encoding="utf-8",
            )
            with patch("runner.terminate") as terminate:
                with self.assertRaises(ValueError):
                    stop(config)
                terminate.assert_not_called()

    def test_stop_retains_exact_stopped_boot_after_process_exit(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            config = Config(
                image_dir=state,
                state_dir=state,
                socket_dir=state / "sockets",
                placement_id="11111111-1111-4111-8111-111111111111",
                execution_epoch=3,
                generation=2,
                boot_challenge="a" * 64,
                address="10.20.0.2",
                tap="lvbd7662a5eeb4",
                mac="02:fc:0a:14:00:02",
                disk_bytes=4294967296,
                qemu=Path("/nix/store/qemu"),
                qemu_img=Path("/nix/store/qemu-img"),
                backend=Path("/nix/store/backend"),
                ip=Path("/nix/store/ip"),
            )
            (state / "manifest.json").write_bytes(b"fixture image")
            (state / "rootfs.qcow2").write_bytes(b"retained overlay")
            digest = hashlib.sha256(b"fixture image").hexdigest()
            (state / "image.json").write_text(
                json.dumps(
                    {
                        "image_dir": str(state.resolve()),
                        "disk_bytes": config.disk_bytes,
                        "manifest_sha256": digest,
                    }
                ),
                encoding="utf-8",
            )
            qemu = {"pid": 9999999, "start_ticks": 1, "executable": str(config.qemu)}
            backend = {"pid": 9999998, "start_ticks": 1, "executable": str(config.backend)}
            (state / "launch.json").write_text(
                json.dumps(
                    {
                        "placement_id": config.placement_id,
                        "execution_epoch": config.execution_epoch,
                        "generation": config.generation,
                        "boot_challenge": config.boot_challenge,
                        "address": config.address,
                        "tap": config.tap,
                        "mac": config.mac,
                        "qemu": qemu,
                        "backend": backend,
                    }
                ),
                encoding="utf-8",
            )
            with (
                patch("runner.terminate") as terminate,
                patch("runner.tap_exists", return_value=False),
            ):
                result = stop(config)
            self.assertEqual(result["state"], "stopped")
            self.assertEqual(terminate.call_count, 2)
            self.assertFalse((state / "launch.json").exists())
            self.assertEqual(
                json.loads((state / "stopped.json").read_text(encoding="utf-8")),
                {
                    "placement_id": config.placement_id,
                    "execution_epoch": config.execution_epoch,
                    "generation": config.generation,
                    "boot_challenge": config.boot_challenge,
                    "address": config.address,
                    "tap": config.tap,
                    "mac": config.mac,
                    "qemu": qemu,
                    "backend": backend,
                    "manifest_sha256": digest,
                    "disk_bytes": config.disk_bytes,
                },
            )

    def test_process_exit_requires_positive_proc_evidence(self) -> None:
        executable = Path("/nix/store/qemu")
        record = {"pid": 9999999, "start_ticks": 42, "executable": str(executable)}
        for observation in (None, ("Z", 42), ("S", 43)):
            with patch("server.proc_stat", return_value=observation):
                self.assertEqual(process_status(record, executable), "exited")
        with (
            patch("server.proc_stat", return_value=("S", 42)),
            patch("server.os.readlink", return_value=str(executable)),
        ):
            self.assertEqual(process_status(record, executable), "live")
        with (
            patch("server.proc_stat", side_effect=[("S", 42), None]),
            patch("server.os.readlink", return_value=str(executable)),
        ):
            self.assertEqual(process_status(record, executable), "exited")
        with (
            patch("server.proc_stat", return_value=("S", 42)),
            patch("server.os.readlink", return_value="/nix/store/foreign"),
            self.assertRaises(ValueError),
        ):
            process_status(record, executable)
        with (
            patch("server.proc_stat", return_value=("S", 42)),
            patch("server.os.readlink", side_effect=FileNotFoundError),
            self.assertRaises(RuntimeError),
        ):
            process_status(record, executable)

    def test_process_proof_is_fenced_to_exact_boot_and_image(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            config = Config(
                image_dir=state,
                state_dir=state,
                socket_dir=state / "sockets",
                placement_id="11111111-1111-4111-8111-111111111111",
                execution_epoch=3,
                generation=2,
                boot_challenge="a" * 64,
                address="10.20.0.2",
                tap="lvbd7662a5eeb4",
                mac="02:fc:0a:14:00:02",
                disk_bytes=4294967296,
                qemu=Path("/nix/store/qemu"),
                qemu_img=Path("/nix/store/qemu-img"),
                backend=Path("/nix/store/backend"),
                ip=Path("/nix/store/ip"),
            )
            qemu = {"pid": 9999999, "start_ticks": 42, "executable": str(config.qemu)}
            backend = {"pid": 9999998, "start_ticks": 43, "executable": str(config.backend)}
            launch = {
                "placement_id": config.placement_id,
                "execution_epoch": config.execution_epoch,
                "generation": config.generation,
                "boot_challenge": config.boot_challenge,
                "address": config.address,
                "tap": config.tap,
                "mac": config.mac,
                "qemu": qemu,
                "backend": backend,
            }
            launch_path = state / "launch.json"
            launch_path.write_text(json.dumps(launch), encoding="utf-8")
            with (
                patch("server.image_binding_matches", return_value=True),
                patch("server.process_status", side_effect=["exited", "live"]),
            ):
                self.assertEqual(
                    process_proof(config),
                    {
                        "state": "qemu_exited",
                        "placement_id": config.placement_id,
                        "execution_epoch": 3,
                        "generation": 2,
                        "qemu_pid": 9999999,
                        "qemu_start_ticks": 42,
                        "backend_pid": 9999998,
                        "backend_start_ticks": 43,
                    },
                )
            with (
                patch("server.image_binding_matches", return_value=False),
                patch("server.process_status") as process,
                self.assertRaises(ValueError),
            ):
                process_proof(config)
            process.assert_not_called()
            launch_path.write_text(json.dumps({**launch, "generation": 4}), encoding="utf-8")
            with self.assertRaises(ValueError):
                process_proof(config)

    def test_terminal_snapshot_binary_vector_and_truncation(self) -> None:
        header = (
            b"\x01\x01"
            + (2).to_bytes(8, "big")
            + (1).to_bytes(8, "big")
            + (4096).to_bytes(4, "big")
            + (1).to_bytes(2, "big")
            + (222).to_bytes(4, "big")
            + (333).to_bytes(8, "big")
            + b"\x01"
        )
        record = (
            (7).to_bytes(8, "big")
            + (123).to_bytes(4, "big")
            + (456).to_bytes(8, "big")
            + b"\x01"
            + (10).to_bytes(8, "big")
            + (30).to_bytes(8, "big")
            + (4096).to_bytes(4, "big")
            + (256).to_bytes(4, "big")
            + b"\x01"
            + (48).to_bytes(4, "big")
            + b"\x01"
        )
        payload = header + bytes.fromhex("ab" * 16) + record
        self.assertEqual(
            parse_terminal_snapshot(payload),
            {
                "state": "ok",
                "version": 1,
                "births": 2,
                "deaths": 1,
                "ring_total": 4096,
                "viewer_total": 1,
                "daemon_pid": 222,
                "daemon_start_ticks": 333,
                "ledger_digests": ["ab" * 16],
                "sessions": [
                    {
                        "session_id": 7,
                        "pid": 123,
                        "proc_start_ticks": 456,
                        "alive": True,
                        "ring_base": 10,
                        "ring_tail": 30,
                        "ring_limit": 4096,
                        "deque_allocated": 256,
                        "viewers": [{"queue_bytes": 48, "blocked_write": True}],
                    }
                ],
            },
        )
        allocation_offset = len(header) + 16 + 41
        overallocated = (
            payload[:allocation_offset]
            + (8192).to_bytes(4, "big")
            + payload[allocation_offset + 4 :]
        )
        self.assertEqual(
            parse_terminal_snapshot(overallocated)["sessions"][0]["deque_allocated"], 8192
        )
        too_large = (
            payload[:allocation_offset]
            + (64 * 1024 * 1024 + 1).to_bytes(4, "big")
            + payload[allocation_offset + 4 :]
        )
        with self.assertRaises(ValueError):
            parse_terminal_snapshot(too_large)
        for invalid in (payload[:-1], payload + b"\x00", payload[:36] + b"\x81" + payload[37:]):
            with self.subTest(invalid=invalid[-4:]), self.assertRaises(ValueError):
                parse_terminal_snapshot(invalid)

    def test_terminal_requests_are_witness_only_and_closed(self) -> None:
        placement = "11111111-1111-4111-8111-111111111111"
        request: dict[str, object] = {
            "operation": "terminal_witness",
            "placement_id": placement,
            "execution_epoch": 1,
            "generation": 1,
        }
        tools = ToolConfig(*(Path("/nix/store/fixture") for _ in range(5)))
        root = Path("/state")
        sockets = Path("/run/sockets")
        with patch("server.witness_config", return_value=object()) as configuration:
            with patch(
                "server.terminal_probe",
                return_value=b"\x01\x00" + b"\x00" * 22 + (222).to_bytes(4, "big") + b"\x00" * 9,
            ) as probe:
                result = dispatch(request, tools, root, sockets, "witness")
                self.assertEqual(
                    result,
                    {
                        "state": "ok",
                        "version": 1,
                        "births": 0,
                        "deaths": 0,
                        "ring_total": 0,
                        "viewer_total": 0,
                        "daemon_pid": 222,
                        "daemon_start_ticks": 0,
                        "sessions": [],
                        "ledger_digests": [],
                    },
                )
                probe.assert_called_once_with(configuration.return_value, 0x20, b"")
            with patch(
                "server.terminal_probe",
                return_value=b"\x01" + (5).to_bytes(8, "big") + (123).to_bytes(4, "big"),
            ) as probe:
                result = dispatch(
                    {**request, "operation": "terminal_input_stall", "session_id": 7},
                    tools,
                    root,
                    sockets,
                    "witness",
                )
                self.assertEqual(
                    result,
                    {
                        "state": "ok",
                        "version": 1,
                        "session_id": 7,
                        "pid": 123,
                        "in_progress": True,
                        "elapsed_ms": 5,
                    },
                )
                probe.assert_called_once_with(
                    configuration.return_value, 0x21, (7).to_bytes(8, "big")
                )
            for invalid in (
                {**request, "boot_challenge": "a" * 64},
                {**request, "operation": "terminal_input_stall"},
                {**request, "operation": "terminal_input_stall", "session_id": True},
            ):
                with self.subTest(request=invalid), self.assertRaises(ValueError):
                    dispatch(invalid, tools, root, sockets, "witness")
            with self.assertRaises(ValueError):
                dispatch(request, tools, root, sockets, "control")
            configuration.assert_called()

    def test_stopped_record_requires_exact_tuple_and_image_binding(self) -> None:
        placement = "11111111-1111-4111-8111-111111111111"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            image = root / "image"
            state = root / placement
            image.mkdir()
            state.mkdir()
            manifest = b"fixture image"
            (image / "manifest.json").write_bytes(manifest)
            (state / "rootfs.qcow2").write_bytes(b"overlay")
            digest = hashlib.sha256(manifest).hexdigest()
            executables = [root / name for name in ("qemu", "qemu-img", "backend", "ip")]
            for executable in executables:
                executable.write_bytes(b"fixture")
                executable.chmod(0o700)
            tools = ToolConfig(
                image,
                *executables,
            )
            qemu = {"pid": 9999999, "start_ticks": 1, "executable": str(tools.qemu)}
            backend = {"pid": 9999998, "start_ticks": 1, "executable": str(tools.backend)}
            record = {
                "placement_id": placement,
                "execution_epoch": 3,
                "generation": 2,
                "boot_challenge": "a" * 64,
                "address": "10.20.0.2",
                "tap": "lvbd7662a5eeb4",
                "mac": "02:fc:0a:14:00:02",
                "qemu": qemu,
                "backend": backend,
                "manifest_sha256": digest,
                "disk_bytes": 4294967296,
            }
            image_record = {
                "image_dir": str(image.resolve()),
                "disk_bytes": 4294967296,
                "manifest_sha256": digest,
            }
            (state / "stopped.json").write_text(json.dumps(record), encoding="utf-8")
            (state / "image.json").write_text(json.dumps(image_record), encoding="utf-8")
            self.assertEqual(stopped_record(state, placement, 3, 2, tools), record)
            observed = {
                "state": "stopped",
                "placement_id": placement,
                "execution_epoch": 3,
                "generation": 2,
                "boot_id": None,
                "qemu_pid": None,
                "backend_pid": None,
                "ready": False,
                "qemu_rss_kib": None,
                "backend_rss_kib": None,
                "error": None,
            }
            with (
                patch("server.observe", return_value=observed),
                patch(
                    "server.inventory",
                    return_value={
                        "state": "ok",
                        "placements": [
                            {
                                "placement_id": placement,
                                "state": "stopped",
                                "overlay_present": True,
                            }
                        ],
                    },
                ),
            ):
                config = witness_config(placement, 3, 2, tools, root, root / "sockets")
                receipt = witness(config)
            self.assertEqual(receipt["execution_epoch"], 3)
            self.assertEqual(receipt["generation"], 2)
            self.assertEqual(
                receipt["boot_challenge_sha256"], hashlib.sha256(b"a" * 64).hexdigest()
            )
            self.assertEqual(receipt["overlay_sha256"], hashlib.sha256(b"overlay").hexdigest())
            self.assertIsNone(receipt["qemu"])
            self.assertIsNone(receipt["backend"])
            with self.assertRaises(ValueError):
                stopped_record(state, placement, 4, 2, tools)
            (state / "launch-attempt.json").write_text("{}", encoding="utf-8")
            with self.assertRaises(ValueError):
                stopped_record(state, placement, 3, 2, tools)
            (state / "launch-attempt.json").unlink()
            (state / "image.json").write_text(
                json.dumps({**image_record, "disk_bytes": 4294967297}), encoding="utf-8"
            )
            with self.assertRaises(ValueError):
                stopped_record(state, placement, 3, 2, tools)


if __name__ == "__main__":
    unittest.main()
