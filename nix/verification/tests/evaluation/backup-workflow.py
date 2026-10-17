"""Failure injection for host completion, cleanup replay and retention reachability."""

from __future__ import annotations

import json
import os
import random
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from collections.abc import Callable, Sequence
from datetime import UTC, datetime
from pathlib import Path
from typing import Literal
from unittest.mock import patch

from hypothesis import example, given, settings
from hypothesis import strategies as st

sys.path.insert(0, sys.argv.pop(1))
from common import (  # ty: ignore[unresolved-import] # argv[1] Nix backups module
    BackupError,
    atomic_json,
    group_has_live_members,
    run,
)
from host import (  # ty: ignore[unresolved-import] # argv[1] Nix backups module
    HostCapture,
    OwnedSnapshot,
    PathMapping,
    exclusions,
)
from journal import Journal  # ty: ignore[unresolved-import] # argv[1] Nix backups module
from restic import Repository, Snapshot  # ty: ignore[unresolved-import] # argv[1] backups module
from runtime import Runner  # ty: ignore[unresolved-import] # argv[1] Nix backups module
from schema import JSON, Config, Failure  # ty: ignore[unresolved-import] # argv[1] backups module


def configuration(root: Path) -> Config:
    return Config(
        hostname="fixture",
        repository=str(root / "repository"),
        region="test",
        password_file=str(root / "password"),
        cache_directory=str(root / "cache"),
        state_directory=str(root / "state"),
        revision=None,
        restic="unused",
        zfs="unused",
        findmnt="unused",
        mount="unused",
        umount="unused",
        command_timeout=10,
        upload_limit_kib=0,
        keep_last=3,
        initialize=True,
        paths=[],
        materialize=[],
        images=[],
        protected_datasets=[],
        excludes=[],
        lilly={"tool": "unused"},
        postgres=None,
    )


class FakeRepository(Repository):
    def __init__(self, config: Config) -> None:
        super().__init__(config)
        self.uploads: list[str] = []
        self.fail_tag: str | None = None
        self.retained = False

    def ensure(self) -> None:
        pass

    def backup(
        self,
        paths: Sequence[str | Path],
        tag: str,
        run_id: str,
        *,
        excludes: Sequence[str] = (),
        guard: Callable[[], None] | None = None,
    ) -> str:
        if guard:
            guard()
        self.uploads.append(tag)
        if tag == self.fail_tag:
            raise BackupError("upload")
        return f"{len(self.uploads):064x}"

    def retain(self, now: float) -> None:
        self.retained = True


class FakeHost(HostCapture):
    def cleanup(self) -> int:
        return 0

    def prepare(self, working: Path) -> tuple[list[str], list[PathMapping]]:
        return [], []


class FixtureRunner(Runner):
    repository: FakeRepository

    def __init__(self, config: Config) -> None:
        super().__init__(config)
        self.repository = FakeRepository(config)
        self.host = FakeHost(config)
        self.flush = "unconfirmed"
        self.releases: list[str] = []
        self.pending = 0
        self.capture_failure = False
        self.pressure = True

    def lilly(self, operation: str, value: object = None) -> dict[str, JSON]:
        if operation == "inventory":
            return {
                "guests": [{"id": "first", "pool_id": "pool"}, {"id": "second", "pool_id": "pool"}]
            }
        if operation == "capture":
            if not isinstance(value, dict):
                raise ValueError()
            if self.capture_failure and value["id"] == "first":
                # Native creation may have happened without a returned receipt.
                self.pending = 1
                raise BackupError("capture")
            return {"id": str(value["id"]), "flush": self.flush, "paths": []}
        if operation == "release":
            if not isinstance(value, dict):
                raise ValueError()
            self.releases.append(str(value["id"]))
            return {"pending": 0}
        if operation == "cleanup":
            return {"pending": self.pending}
        if operation == "pressure":
            return {"available": self.pressure}
        if operation == "metadata":
            return {"paths": []}
        raise ValueError()


class WorkflowTest(unittest.TestCase):
    def test_original_exclusions_follow_snapshot_paths_at_directory_boundaries(self) -> None:
        mappings = [
            PathMapping(
                original="/var/lib/service",
                source="/snapshot/service",
                filesystem="zfs",
                dataset="tank/state",
            )
        ]
        self.assertEqual(
            exclusions(["/var/lib/service/cache", "**/*.sock"], mappings),
            ["/var/lib/service/cache", "**/*.sock", "/snapshot/service/cache"],
        )
        self.assertEqual(exclusions(["/var/lib"], mappings), ["/var/lib", "/snapshot/service"])
        self.assertEqual(exclusions(["/var/lib/services"], mappings), ["/var/lib/services"])

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.config = configuration(Path(self.temp.name))
        self.runner = FixtureRunner(self.config)

    def test_unresponsive_and_stopped_guests_still_upload_all_disks(self) -> None:
        for flush, expected in (("unconfirmed", "degraded"), ("stopped", "healthy")):
            with self.subTest(flush=flush):
                self.runner.flush = flush
                self.runner.capture()
                self.assertEqual(self.runner.status["state"], expected)
                self.assertEqual(self.runner.status["guests_completed"], 2)
                self.assertEqual(
                    self.runner.repository.uploads[-4:],
                    ["guest:first", "guest:second", "host-state", "host-manifest"],
                )
                self.assertEqual(
                    Journal.load(self.runner.root / "run.json").value["phase"], "completed"
                )
                self.assertTrue(self.runner.repository.retained)

    def test_failed_upload_continues_other_guests_and_preserves_last_success(self) -> None:
        self.runner.publish(last_success_at=123)
        self.runner.repository.fail_tag = "guest:first"
        with self.assertRaises(BackupError):
            self.runner.capture()
        self.assertEqual(
            self.runner.repository.uploads, ["guest:first", "guest:second", "host-state"]
        )
        self.assertEqual(self.runner.releases, ["first", "second"])
        self.assertEqual(self.runner.status["last_success_at"], 123)
        self.assertFalse(self.runner.repository.retained)
        self.assertEqual(Journal.load(self.runner.root / "run.json").value["phase"], "failed")

    def test_interrupted_native_create_remains_retryable_without_receipt(self) -> None:
        self.runner.capture_failure = True
        with self.assertRaises(BackupError):
            self.runner.capture()
        journal = Journal.load(self.runner.root / "run.json")
        self.assertEqual(journal.value["phase"], "cleaning")
        self.assertEqual(self.runner.status["cleanup_pending"], 1)
        self.assertIn("guest:second", self.runner.repository.uploads)
        self.assertNotIn("host-manifest", self.runner.repository.uploads)
        self.runner.pending = 0
        self.runner.recover()
        self.assertEqual(Journal.load(self.runner.root / "run.json").value["phase"], "failed")

    def test_database_failure_does_not_suppress_guests_or_publish_completion(self) -> None:
        self.runner.config["postgres"] = {
            "ca_file": "ca",
            "pg_dump": "dump",
            "pg_restore": "restore",
            "psql": "psql",
            "timeout": 1,
        }
        with (
            patch("runtime.postgres.capture", side_effect=BackupError("database")),
            self.assertRaises(BackupError),
        ):
            self.runner.capture()
        self.assertEqual(
            self.runner.repository.uploads, ["guest:first", "guest:second", "host-state"]
        )
        self.assertEqual(self.runner.status["failure"], "database")
        self.assertFalse(self.runner.repository.retained)

    def test_capacity_failure_aborts_upload_and_releases_snapshot(self) -> None:
        self.runner.pressure = False
        with self.assertRaises(BackupError):
            self.runner.capture()
        self.assertEqual(self.runner.releases, ["first", "second"])
        self.assertEqual(self.runner.status["guests_failed"], 2)
        self.assertNotIn("host-manifest", self.runner.repository.uploads)


class RetentionRepository(Repository):
    def __init__(
        self, config: Config, rows: list[Snapshot], manifests: dict[str, dict[str, JSON]]
    ) -> None:
        super().__init__(config)
        self.rows, self.manifests = rows, manifests
        self.removed: set[str] = set()

    def snapshots(self) -> list[Snapshot]:
        return self.rows

    def manifest(self, row: Snapshot) -> dict[str, JSON]:
        return self.manifests[row["id"]]

    def command(
        self,
        arguments: Sequence[str],
        stage: Failure = "repository",
        maximum: int = 32 * 1024 * 1024,
        guard: Callable[[], None] | None = None,
    ) -> bytes:
        if arguments[0] != "forget":
            raise AssertionError("unexpected mutation")
        self.removed.update(arguments[1:])
        return b""


def snapshot(identity: int, stamp: int, manifest: bool = False) -> Snapshot:
    return Snapshot(
        id=f"{identity:064x}",
        time=datetime.fromtimestamp(stamp, UTC).isoformat(),
        tags=["overalls-backup", "host-manifest" if manifest else "guest"],
        paths=[],
    )


class RetentionTest(unittest.TestCase):
    def test_orphans_expire_even_before_the_first_complete_point(self) -> None:
        old, recent = snapshot(1, 1), snapshot(2, 199999)
        repo = RetentionRepository(configuration(Path("/unused")), [old, recent], {})
        repo.retain(200000)
        self.assertEqual(repo.removed, {old["id"]})

    def test_generated_retention_sets_preserve_shared_references_and_orphan_grace(self) -> None:
        randomizer = random.Random(44)
        config = configuration(Path("/unused"))
        for _ in range(100):
            count = randomizer.randint(1, 30)
            keep_count = randomizer.randint(1, 12)
            config["keep_last"] = keep_count
            components = [snapshot(index, 1) for index in range(1, 20)]
            manifests: dict[str, dict[str, JSON]] = {}
            references: list[set[str]] = []
            rows = list(components)
            for index in range(count):
                row = snapshot(index + 100, 1000 + index, True)
                refs = {
                    item["id"] for item in randomizer.sample(components, randomizer.randint(1, 5))
                }
                references.append(refs)
                manifests[row["id"]] = {"components": [{"snapshot_id": ref} for ref in refs]}
                rows.append(row)
            recent = snapshot(1000, 199999)
            rows.append(recent)
            repo = RetentionRepository(config, rows, manifests)
            repo.retain(200000)
            protected = set().union(*references[-keep_count:])
            protected.update(
                row["id"] for row in rows if row["id"] in list(manifests)[-keep_count:]
            )
            self.assertFalse(repo.removed & protected)
            self.assertNotIn(recent["id"], repo.removed)
            self.assertEqual(repo.removed, {row["id"] for row in rows} - protected - {recent["id"]})

    def test_missing_reference_prevents_every_deletion(self) -> None:
        row = snapshot(100, 100, True)
        repo = RetentionRepository(
            configuration(Path("/unused")),
            [row],
            {row["id"]: {"components": [{"snapshot_id": "f" * 64}]}},
        )
        with self.assertRaises(BackupError):
            repo.retain(200000)
        self.assertEqual(repo.removed, set())


class CommandTest(unittest.TestCase):
    def test_output_and_time_are_bounded_while_child_runs(self) -> None:
        for program, maximum in (
            ("import time; time.sleep(30)", 1024),
            ("import os; os.write(1, b'x' * 4096); import time; time.sleep(30)", 1024),
        ):
            started = time.monotonic()
            with self.assertRaises(BackupError):
                run([sys.executable, "-c", program], stage="capture", timeout=0.1, maximum=maximum)
            self.assertLess(time.monotonic() - started, 2)

    def test_guard_failure_reaps_reader_before_return(self) -> None:
        def fail() -> None:
            raise BackupError("capture")

        started = time.monotonic()
        with self.assertRaises(BackupError):
            run([sys.executable, "-c", "import time; time.sleep(30)"], stage="upload", guard=fail)
        self.assertLess(time.monotonic() - started, 2)

    @settings(max_examples=4, deadline=None, derandomize=True)
    @example(mode="timeout", count=1)
    @example(mode="success", count=2)
    @example(mode="nonzero", count=3)
    @example(mode="overflow", count=1)
    @given(
        mode=st.sampled_from(["timeout", "success", "nonzero", "overflow"]),
        count=st.sampled_from([1, 2, 3]),
    )
    def test_exited_leader_reader_group_is_retired(
        self, mode: Literal["timeout", "success", "nonzero", "overflow"], count: int
    ) -> None:
        """@cc [owner:ghuntley,label:verification;recovery] exited-leader-reader-retirement
        Backup subprocess return MUST stop every same-group reader even when
        its direct leader already exited. Success, failure, timeout and output
        overflow MUST preserve source-file state.
        """
        with tempfile.TemporaryDirectory(prefix="backup-reader-group-") as directory:
            root = Path(directory)
            (root / "source").write_bytes(b"reader witness")
            identities: list[tuple[int, int, str]] = []
            try:
                arguments = [
                    sys.executable,
                    os.environ["READER_HELPER"],
                    str(root),
                    str(count),
                    mode,
                ]
                if mode == "success":
                    self.assertEqual(run(arguments, stage="capture", timeout=1, maximum=1024), b"")
                else:
                    with self.assertRaises(BackupError):
                        run(arguments, stage="capture", timeout=1, maximum=1024)
                raw: object = json.loads((root / "readers.json").read_bytes())
                assert isinstance(raw, list)
                for row in raw:
                    assert isinstance(row, dict)
                    pid, group, start = row.get("pid"), row.get("group"), row.get("start")
                    assert type(pid) is int and type(group) is int and isinstance(start, str)
                    identities.append((pid, group, start))
                self.assertEqual(len(identities), count)

                def live(identity: tuple[int, int, str]) -> bool:
                    pid, group, start = identity
                    try:
                        fields = (
                            (Path("/proc") / str(pid) / "stat")
                            .read_text()
                            .rsplit(") ", 1)[1]
                            .split()
                        )
                        return fields[0] != "Z" and fields[19] == start and int(fields[2]) == group
                    except FileNotFoundError:
                        return False

                self.assertFalse(any(live(identity) for identity in identities))
                self.assertEqual((root / "source").read_bytes(), b"reader witness")
            finally:
                # Failed baseline examples must never leak their introduced readers.
                receipt = root / "readers.json"
                if receipt.exists():
                    raw_cleanup: object = json.loads(receipt.read_bytes())
                    assert isinstance(raw_cleanup, list)
                    for row in raw_cleanup:
                        assert isinstance(row, dict)
                        pid, group, start = row.get("pid"), row.get("group"), row.get("start")
                        assert type(pid) is int and type(group) is int and isinstance(start, str)
                        descriptor: int | None = None
                        try:
                            descriptor = os.pidfd_open(pid)
                            fields = (
                                (Path("/proc") / str(pid) / "stat")
                                .read_text()
                                .rsplit(") ", 1)[1]
                                .split()
                            )
                            if fields[0] != "Z" and fields[19] == start and int(fields[2]) == group:
                                signal.pidfd_send_signal(descriptor, signal.SIGKILL)
                        except (ProcessLookupError, FileNotFoundError):
                            pass
                        finally:
                            if descriptor is not None:
                                os.close(descriptor)

    @settings(max_examples=3, deadline=None, derandomize=True)
    @example(count=1)
    @example(count=3)
    @given(count=st.sampled_from([1, 2, 3]))
    def test_zombie_leader_does_not_hide_live_reader_threads(self, count: int) -> None:
        """@cc [owner:ghuntley,label:verification;recovery] zombie-leader-thread-inventory
        A zombie thread-group leader MUST NOT establish reader-group death while
        an independently observed same-group worker thread is still live.
        """
        with tempfile.TemporaryDirectory(prefix="backup-thread-group-") as directory:
            source = Path(directory) / "source"
            source.write_bytes(b"thread reader witness")
            with subprocess.Popen(
                [os.environ["THREAD_READER"], str(count), str(source)],
                start_new_session=True,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            ) as process:
                try:
                    deadline = time.monotonic() + 5
                    leader = Path("/proc") / str(process.pid)
                    while True:
                        fields = (leader / "stat").read_text().rsplit(") ", 1)[1].split()
                        if fields[0] == "Z":
                            break
                        self.assertLess(time.monotonic(), deadline)
                        time.sleep(0.001)
                    self.assertEqual(int(fields[2]), process.pid)
                    workers = [
                        (task / "stat").read_text().rsplit(") ", 1)[1].split()
                        for task in (leader / "task").iterdir()
                        if task.name != str(process.pid)
                    ]
                    self.assertEqual(len(workers), count)
                    self.assertTrue(
                        all(row[0] != "Z" and int(row[2]) == process.pid for row in workers)
                    )
                    self.assertTrue(group_has_live_members(process.pid))
                    self.assertEqual(source.read_bytes(), b"thread reader witness")
                finally:
                    # The unreaped process anchors its group while workers live.
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=5)


ProofMode = Literal[
    "valid",
    "dataset_changed",
    "snapshot_changed",
    "marker_foreign",
    "marker_nonce_foreign",
    "mount_foreign",
    "duplicate_mount",
    "mounted_absent",
    "get_unavailable",
    "list_unavailable",
    "mounts_unavailable",
    "marker_unavailable",
    "post_destroy_unavailable",
]


REFUSALS: tuple[ProofMode, ...] = (
    "dataset_changed",
    "snapshot_changed",
    "marker_foreign",
    "marker_nonce_foreign",
    "mount_foreign",
    "duplicate_mount",
    "mounted_absent",
    "get_unavailable",
    "list_unavailable",
    "mounts_unavailable",
    "marker_unavailable",
)


class ProofHost(HostCapture):
    def __init__(self, config: Config, value: OwnedSnapshot) -> None:
        super().__init__(config)
        self.value = value
        self.mode: ProofMode = "valid"
        self.present = True
        self.mounted = True
        self.destroyed = False
        self.destructive: list[tuple[str, tuple[str, ...]]] = []

    def command(self, name: Literal["zfs", "findmnt", "mount", "umount"], args: list[str]) -> str:
        snapshot = self.value["dataset"] + "@overalls-backup-" + self.value["nonce"]
        if name == "zfs" and args == ["get", "-Hp", "-o", "value", "guid", self.value["dataset"]]:
            if self.mode == "get_unavailable":
                raise BackupError("cleanup")
            return "777" if self.mode == "dataset_changed" else self.value["dataset_guid"]
        if name == "zfs" and args == ["list", "-Hp", "-t", "snapshot", "-o", "name,guid"]:
            if self.mode == "list_unavailable" or (
                self.mode == "post_destroy_unavailable" and self.destroyed
            ):
                raise BackupError("cleanup")
            if not self.present or self.mode == "mounted_absent":
                return ""
            guid = "888" if self.mode == "snapshot_changed" else "456"
            return snapshot + "\t" + guid
        if name == "findmnt" and args == ["--json", "--list", "-o", "TARGET,SOURCE"]:
            if self.mode == "mounts_unavailable":
                raise BackupError("cleanup")
            rows = []
            if self.mounted:
                rows.append(
                    {
                        "target": self.value["mount"],
                        "source": "foreign/volume@foreign"
                        if self.mode == "mount_foreign"
                        else snapshot,
                    }
                )
                if self.mode == "duplicate_mount":
                    rows.append(dict(rows[0]))
            return json.dumps({"filesystems": rows})
        if name == "zfs" and args == [
            "get",
            "-Hp",
            "-o",
            "value,source",
            "overalls:backup_nonce",
            snapshot,
        ]:
            if self.mode == "marker_unavailable":
                raise BackupError("cleanup")
            nonce = "b" * 32 if self.mode == "marker_nonce_foreign" else self.value["nonce"]
            return nonce + ("\tinherited" if self.mode == "marker_foreign" else "\tlocal")
        if name == "umount" and args == ["--", self.value["mount"]]:
            self.destructive.append((name, tuple(args)))
            self.mounted = False
            return ""
        if name == "zfs" and args == ["destroy", snapshot]:
            self.destructive.append((name, tuple(args)))
            self.present = False
            self.destroyed = True
            return ""
        raise AssertionError("unexpected host cleanup command")


class HostProofHistoryTest(unittest.TestCase):
    @settings(max_examples=8, deadline=None)
    @given(present=st.booleans(), mounted=st.booleans(), recorded=st.booleans())
    def test_cleanup_intent_survives_missing_guid_and_snapshot_boundaries(
        self, present: bool, mounted: bool, recorded: bool
    ) -> None:
        """@cc [owner:ghuntley,label:verification;recovery] host-intent-before-guid
        A valid durable nonce MUST permit cleanup before its snapshot GUID is
        recorded. Confirmed absence MUST converge without destruction; a mount
        claiming an absent snapshot MUST retain intent without destructive calls.
        """
        for fixed_present, fixed_mounted, fixed_recorded in (
            (present, mounted, recorded),
            (False, False, False),
            (True, False, False),
            (True, True, False),
            (False, True, True),
        ):
            with tempfile.TemporaryDirectory() as temporary:
                value = OwnedSnapshot(
                    version=1,
                    nonce="a" * 32,
                    dataset="fixture/owned",
                    mount="/run/overalls-backups/host/" + "a" * 32,
                    dataset_guid="123",
                    snapshot_guid="456" if fixed_recorded else None,
                )
                host = ProofHost(configuration(Path(temporary)), value)
                host.present = fixed_present
                host.mounted = fixed_mounted
                path = host.root / (value["nonce"] + ".json")
                atomic_json(path, value)
                before = path.read_bytes()
                fake_mount = Path(temporary) / "mount"
                fake_mount.mkdir()

                def mount_path(
                    requested: str,
                    expected_mount: str = value["mount"],
                    fixture_mount: Path = fake_mount,
                ) -> Path:
                    if requested != expected_mount:
                        raise AssertionError("unexpected cleanup mount path")
                    return fixture_mount

                with patch("host.Path", side_effect=mount_path):
                    if fixed_mounted and not fixed_present:
                        self.assertEqual(host.cleanup(), 1)
                        self.assertEqual(path.read_bytes(), before)
                        self.assertEqual(host.destructive, [])
                        self.assertTrue(fake_mount.is_dir())
                    else:
                        self.assertEqual(host.cleanup(), 0)
                        expected: list[tuple[str, tuple[str, ...]]] = []
                        if fixed_present:
                            if fixed_mounted:
                                expected.append(("umount", ("--", value["mount"])))
                            expected.append(
                                (
                                    "zfs",
                                    (
                                        "destroy",
                                        value["dataset"] + "@overalls-backup-" + value["nonce"],
                                    ),
                                )
                            )
                        self.assertEqual(host.destructive, expected)
                        self.assertFalse(path.exists())
                        self.assertFalse(fake_mount.exists())
                        self.assertEqual(host.cleanup(), 0)
                        self.assertEqual(host.destructive, expected)

    @settings(max_examples=24, deadline=None)
    @example(modes=list(REFUSALS), repeats=4, uncertain=False)
    @example(modes=list(reversed(REFUSALS)), repeats=1, uncertain=True)
    @given(
        modes=st.lists(st.sampled_from(REFUSALS), min_size=1, max_size=8),
        repeats=st.sampled_from([1, 2, 4]),
        uncertain=st.booleans(),
    )
    def test_owned_host_cleanup_refuses_foreign_proofs_and_replays_uncertainty(
        self,
        modes: list[ProofMode],
        repeats: int,
        uncertain: bool,
    ) -> None:
        """@cc [owner:ghuntley,label:verification;security;recovery] host-proof-cleanup-history
        Every refused proof prefix MUST preserve exact descriptor bytes and
        perform no destructive command. Post-destroy inspection uncertainty MUST
        retain the descriptor; valid retry MUST remove only the owned snapshot
        and converge without repeating destruction.
        """
        with tempfile.TemporaryDirectory() as temporary:
            value = OwnedSnapshot(
                version=1,
                nonce="a" * 32,
                dataset="fixture/owned",
                mount="/run/overalls-backups/host/" + "a" * 32,
                dataset_guid="123",
                snapshot_guid="456",
            )
            host = ProofHost(configuration(Path(temporary)), value)
            path = host.root / (value["nonce"] + ".json")
            atomic_json(path, value)
            before = path.read_bytes()
            fake_mount = Path(temporary) / "mount"
            fake_mount.mkdir()

            def mount_path(requested: str) -> Path:
                if requested != value["mount"]:
                    raise AssertionError("unexpected cleanup mount path")
                return fake_mount

            with patch("host.Path", side_effect=mount_path):
                self.check_history(host, path, before, value, fake_mount, modes, repeats, uncertain)

    def check_history(
        self,
        host: ProofHost,
        path: Path,
        before: bytes,
        value: OwnedSnapshot,
        fake_mount: Path,
        modes: list[ProofMode],
        repeats: int,
        uncertain: bool,
    ) -> None:
        for mode in modes:
            host.mode = mode
            for _ in range(repeats):
                self.assertEqual(host.cleanup(), 1)
                self.assertEqual(path.read_bytes(), before)
                self.assertEqual(host.destructive, [])
                self.assertTrue(fake_mount.is_dir())
        host.mode = "post_destroy_unavailable" if uncertain else "valid"
        self.assertEqual(host.cleanup(), 1 if uncertain else 0)
        if uncertain:
            self.assertEqual(path.read_bytes(), before)
        else:
            self.assertFalse(path.exists())
            self.assertFalse(fake_mount.exists())
        expected = [
            ("umount", ("--", value["mount"])),
            ("zfs", ("destroy", value["dataset"] + "@overalls-backup-" + value["nonce"])),
        ]
        self.assertEqual(host.destructive, expected)
        self.assertFalse(host.present)
        self.assertFalse(host.mounted)
        for _ in range(repeats if uncertain else 0):
            self.assertEqual(host.cleanup(), 1)
            self.assertEqual(path.read_bytes(), before)
            self.assertEqual(host.destructive, expected)
            self.assertTrue(fake_mount.is_dir())
        host.mode = "valid"
        self.assertEqual(host.cleanup(), 0)
        self.assertFalse(path.exists())
        self.assertFalse(fake_mount.exists())
        self.assertEqual(host.destructive, expected)
        self.assertEqual(host.cleanup(), 0)
        self.assertEqual(host.destructive, expected)


if __name__ == "__main__":
    unittest.main()
