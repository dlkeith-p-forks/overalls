"""Generated ownership refusals and cleanup replay against native ZFS and mounts."""

import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Literal

from common import (  # ty: ignore[unresolved-import] # /etc/backup-runtime in Nix VM
    atomic_json,
    read_json,
)
from host import (  # ty: ignore[unresolved-import] # /etc/backup-runtime in Nix VM
    HostCapture,
    OwnedSnapshot,
    owned_snapshot,
)
from hypothesis import example, given, settings
from hypothesis import strategies as st
from schema import Config  # ty: ignore[unresolved-import] # /etc/backup-runtime in Nix VM

type Mode = Literal["dataset", "snapshot", "nonce", "inherited", "mount", "inspection", "post"]

AUDIT = Path("/run/cleanup-zfs-audit.jsonl")
DOWN = Path("/run/cleanup-inspection-down")
AFTER = Path("/run/cleanup-fail-after-destroy")
counter: int = 0
effects: list[tuple[str, list[str]]] = []


class AuditedCapture(HostCapture):
    def command(self, name: Literal["zfs", "findmnt", "mount", "umount"], args: list[str]) -> str:
        if name == "umount" or (name == "zfs" and args and args[0] == "destroy"):
            effects.append((name, list(args)))
        return super().command(name, args)


def command(args: list[str]) -> str:
    return subprocess.check_output(args, text=True).strip()


def zfs(*args: str) -> str:
    return command([os.environ["NATIVE_ZFS"], *args])


def guid(name: str) -> str:
    return zfs("get", "-Hp", "-o", "value", "guid", name)


def configuration(root: Path) -> Config:
    return Config(
        hostname="fixture",
        repository="unused",
        region="unused",
        password_file="unused",
        cache_directory=str(root / "cache"),
        state_directory=str(root / "state"),
        revision=None,
        restic="unused",
        zfs="/run/cleanup-zfs",
        findmnt="findmnt",
        mount="mount",
        umount="umount",
        command_timeout=10,
        upload_limit_kib=0,
        keep_last=1,
        initialize=False,
        paths=[],
        materialize=[],
        images=[],
        protected_datasets=[],
        excludes=[],
        lilly=None,
        postgres=None,
    )


def destroys(path: Path = AUDIT) -> list[list[str]]:
    result: list[list[str]] = []
    for line in path.read_text().splitlines():
        raw: object = json.loads(line)
        if not isinstance(raw, list) or not all(isinstance(item, str) for item in raw):
            raise AssertionError("invalid fixture command audit")
        row = [item for item in raw if isinstance(item, str)]
        if row and row[0] == "destroy":
            result.append(row)
    return result


def group_empty(events: Path) -> bool:
    try:
        return "populated 0" in events.read_text().splitlines()
    except FileNotFoundError:
        return True


@settings(max_examples=6, deadline=None, derandomize=True)
@example(mode="dataset", repeats=1, recorded=True)
@example(mode="snapshot", repeats=2, recorded=True)
@example(mode="nonce", repeats=3, recorded=False)
@example(mode="inherited", repeats=1, recorded=False)
@example(mode="mount", repeats=2, recorded=True)
@example(mode="inspection", repeats=3, recorded=False)
@example(mode="post", repeats=3, recorded=True)
@given(
    mode=st.sampled_from(
        ["dataset", "snapshot", "nonce", "inherited", "mount", "inspection", "post"]
    ),
    repeats=st.sampled_from([1, 2, 3]),
    recorded=st.booleans(),
)
def native_cleanup(mode: Mode, repeats: int, recorded: bool) -> None:
    """@cc [owner:ghuntley,label:verification;recovery] native-host-owned-cleanup-history
    Native foreign GUID/nonce/mount proofs and unavailable inspection MUST keep
    exact intent bytes and perform no unmount/destroy. After valid proof, the
    exact owned snapshot MUST be destroyed once; post-destroy uncertainty MUST
    retain intent and converge without repeated destruction. Foreign sentinel
    snapshot GUID and contents MUST survive every cleanup history.
    """
    global counter
    counter += 1
    nonce = f"{counter:032x}"
    dataset = f"tank/cleanup-{counter}"
    snapshot = dataset + "@overalls-backup-" + nonce
    mount = Path("/run/overalls-backups/host") / nonce
    capture = AuditedCapture(configuration(Path(f"/run/cleanup-case-{counter}")))
    journal = capture.root / (nonce + ".json")
    for flag in [DOWN, AFTER]:
        flag.unlink(missing_ok=True)
    AUDIT.write_text("")
    effects.clear()
    zfs("create", "-o", "mountpoint=none", dataset)
    zfs("set", "overalls:backup_nonce=" + nonce, dataset)
    value: OwnedSnapshot = {
        "version": 1,
        "nonce": nonce,
        "dataset": dataset,
        "mount": str(mount),
        "dataset_guid": guid(dataset),
        "snapshot_guid": None,
    }
    atomic_json(journal, value)
    if mode == "inherited":
        zfs("snapshot", snapshot)
    else:
        zfs("snapshot", "-o", "overalls:backup_nonce=" + nonce, snapshot)
    snapshot_guid = guid(snapshot)
    if recorded or mode == "snapshot":
        value["snapshot_guid"] = snapshot_guid
    mount.mkdir(parents=True, mode=0o700)
    if mode == "mount":
        command(["mount", "-t", "tmpfs", "foreign-cleanup", str(mount)])
    else:
        command(["mount", "-t", "zfs", "-o", "ro,nodev,nosuid,noexec", snapshot, str(mount)])
    if mode == "dataset":
        value["dataset_guid"] = str(int(value["dataset_guid"]) + 1)
    if mode == "snapshot":
        value["snapshot_guid"] = str(int(snapshot_guid) + 1)
    if mode == "nonce":
        zfs("set", "overalls:backup_nonce=" + "f" * 32, snapshot)
    if mode == "inspection":
        DOWN.touch()
    if mode == "post":
        AFTER.touch()
    atomic_json(journal, value)
    before = journal.read_bytes()
    sentinel_guid = guid("tank/foreign@keep")
    for _ in range(repeats):
        assert capture.cleanup() == 1
        assert journal.read_bytes() == before
        assert guid("tank/foreign@keep") == sentinel_guid
        assert Path("/tank/foreign/witness").read_text() == "foreign stays\n"
        assert Path("/tank/foreign/.zfs/snapshot/keep/witness").read_text() == "foreign stays\n"
        if mode == "post":
            assert effects == [("umount", ["--", str(mount)]), ("zfs", ["destroy", snapshot])]
            assert destroys() == [["destroy", snapshot]]
            assert (
                subprocess.run(
                    [os.environ["NATIVE_ZFS"], "list", snapshot], capture_output=True
                ).returncode
                != 0
            )
            assert (
                subprocess.run(
                    ["findmnt", "--mountpoint", str(mount)], capture_output=True
                ).returncode
                != 0
            )
        else:
            assert effects == []
            assert destroys() == []
            assert guid(snapshot) == snapshot_guid
            expected_source = "foreign-cleanup" if mode == "mount" else snapshot
            assert (
                command(["findmnt", "-n", "-o", "SOURCE", "--mountpoint", str(mount)])
                == expected_source
            )
    DOWN.unlink(missing_ok=True)
    AFTER.unlink(missing_ok=True)
    if mode == "mount":
        command(["umount", str(mount)])
        command(["mount", "-t", "zfs", "-o", "ro,nodev,nosuid,noexec", snapshot, str(mount)])
    if mode != "post":
        zfs("set", "overalls:backup_nonce=" + nonce, snapshot)
    value["dataset_guid"] = guid(dataset)
    value["snapshot_guid"] = snapshot_guid if recorded else None
    atomic_json(journal, value)
    assert capture.cleanup() == 0
    assert not journal.exists() and not mount.exists()
    assert destroys() == [["destroy", snapshot]]
    assert effects == [("umount", ["--", str(mount)]), ("zfs", ["destroy", snapshot])]
    assert capture.cleanup() == 0
    assert destroys() == [["destroy", snapshot]]
    assert guid("tank/foreign@keep") == sentinel_guid
    assert Path("/tank/foreign/witness").read_text() == "foreign stays\n"
    assert Path("/tank/foreign/.zfs/snapshot/keep/witness").read_text() == "foreign stays\n"
    zfs("destroy", dataset)
    print(f"native cleanup history {counter}: {mode}, repeats={repeats}, recorded={recorded}")


@settings(max_examples=4, deadline=None, derandomize=True)
@example(phase="before", mounted=True, recorded=True, repeats=1)
@example(phase="before", mounted=False, recorded=False, repeats=3)
@example(phase="after", mounted=True, recorded=False, repeats=2)
@example(phase="after", mounted=False, recorded=True, repeats=3)
@given(
    phase=st.sampled_from(["before", "after"]),
    mounted=st.booleans(),
    recorded=st.booleans(),
    repeats=st.sampled_from([1, 2, 3]),
)
def worker_death(
    phase: Literal["before", "after"], mounted: bool, recorded: bool, repeats: int
) -> None:
    """@cc [owner:ghuntley,label:verification;recovery] native-cleanup-worker-death
    SIGKILL of the actual cleanup worker and helper cgroup before/after native
    destroy MUST preserve exact descriptor bytes. Independent native state MUST
    distinguish an uncommitted from completed destroy. Recovery and repeated
    replay MUST converge with one successful destruction and no foreign loss.
    """
    global counter
    counter += 1
    nonce = f"{counter:032x}"
    root = Path(f"/run/worker-case-{counter}")
    dataset = f"tank/worker-{counter}"
    snapshot = dataset + "@overalls-backup-" + nonce
    mount = Path("/run/overalls-backups/host") / nonce
    capture = HostCapture(configuration(root))
    journal = capture.root / (nonce + ".json")
    barrier = Path("/run/cleanup-effect-barrier.json")
    commits = Path("/run/cleanup-zfs-commits.jsonl")
    unit = f"cleanup-worker-{counter}.service"
    for flag in [
        DOWN,
        AFTER,
        barrier,
        Path("/run/cleanup-pause-before"),
        Path("/run/cleanup-pause-after"),
    ]:
        flag.unlink(missing_ok=True)
    AUDIT.write_text("")
    commits.write_text("")
    zfs("create", "-o", "mountpoint=none", dataset)
    value: OwnedSnapshot = {
        "version": 1,
        "nonce": nonce,
        "dataset": dataset,
        "mount": str(mount),
        "dataset_guid": guid(dataset),
        "snapshot_guid": None,
    }
    atomic_json(journal, value)
    zfs("snapshot", "-o", "overalls:backup_nonce=" + nonce, snapshot)
    snapshot_guid = guid(snapshot)
    if recorded:
        value["snapshot_guid"] = snapshot_guid
    atomic_json(journal, value)
    before = journal.read_bytes()
    if mounted:
        mount.mkdir(parents=True, mode=0o700)
        command(["mount", "-t", "zfs", "-o", "ro,nodev,nosuid,noexec", snapshot, str(mount)])
    sentinel_guid = guid("tank/foreign@keep")
    pause_flag = Path("/run/cleanup-pause-" + phase)
    pause_flag.touch()
    command(
        [
            "systemd-run",
            "--quiet",
            "--unit=" + unit,
            "--property=Type=exec",
            "--property=Restart=no",
            "--property=TimeoutStopSec=5",
            "--setenv=PYTHONPATH=/etc/backup-runtime",
            "--setenv=NATIVE_ZFS=" + os.environ["NATIVE_ZFS"],
            sys.executable,
            __file__,
            "--worker",
            str(root),
        ]
    )
    try:
        deadline = time.monotonic() + 10
        while not barrier.exists():
            if time.monotonic() >= deadline:
                raise AssertionError("native cleanup worker did not reach selected effect window")
            time.sleep(0.02)
        raw: object = json.loads(barrier.read_text())
        assert raw == {"phase": phase, "args": ["destroy", snapshot]}
        assert int(command(["systemctl", "show", unit, "-p", "MainPID", "--value"])) > 1
        group = command(["systemctl", "show", unit, "-p", "ControlGroup", "--value"])
        assert group.startswith("/system.slice/cleanup-worker-")
        group_events = Path("/sys/fs/cgroup" + group) / "cgroup.events"
        assert journal.read_bytes() == before
        assert (
            subprocess.run(["findmnt", "--mountpoint", str(mount)], capture_output=True).returncode
            != 0
        )
        if phase == "before":
            assert guid(snapshot) == snapshot_guid
            assert destroys(commits) == []
        else:
            assert (
                subprocess.run(
                    [os.environ["NATIVE_ZFS"], "list", snapshot], capture_output=True
                ).returncode
                != 0
            )
            assert destroys(commits) == [["destroy", snapshot]]
        command(["systemctl", "kill", "--signal=SIGKILL", "--kill-whom=all", unit])
        deadline = time.monotonic() + 10
        while command(
            ["systemctl", "show", unit, "-p", "MainPID", "--value"]
        ) != "0" or not group_empty(group_events):
            if time.monotonic() >= deadline:
                raise AssertionError("killed cleanup worker did not exit")
            time.sleep(0.02)
        assert command(["systemctl", "show", unit, "-p", "ExecMainStatus", "--value"]) == "9"
        assert command(["systemctl", "show", unit, "-p", "ActiveState", "--value"]) in {
            "failed",
            "inactive",
        }
        assert journal.read_bytes() == before
        assert owned_snapshot(read_json(journal)) == value
    finally:
        subprocess.run(["systemctl", "stop", unit], check=False)
        pause_flag.unlink(missing_ok=True)
    assert guid("tank/foreign@keep") == sentinel_guid
    assert Path("/tank/foreign/.zfs/snapshot/keep/witness").read_text() == "foreign stays\n"
    for _ in range(repeats):
        assert capture.cleanup() == 0
        assert not journal.exists() and not mount.exists()
        assert destroys(commits) == [["destroy", snapshot]]
        assert len(destroys()) == (2 if phase == "before" else 1)
        assert guid("tank/foreign@keep") == sentinel_guid
        assert Path("/tank/foreign/.zfs/snapshot/keep/witness").read_text() == "foreign stays\n"
    zfs("destroy", dataset)
    print(
        f"worker death history {counter}: {phase}, mounted={mounted}, recorded={recorded}, replays={repeats}"
    )


@settings(max_examples=4, deadline=None, derandomize=True)
@example(kind="dataset", mounted=True, repeats=1)
@example(kind="dataset", mounted=False, repeats=3)
@example(kind="snapshot", mounted=True, repeats=2)
@example(kind="snapshot", mounted=False, repeats=3)
@given(
    kind=st.sampled_from(["dataset", "snapshot"]),
    mounted=st.booleans(),
    repeats=st.sampled_from([1, 2, 3]),
)
def identity_replacement(kind: Literal["dataset", "snapshot"], mounted: bool, repeats: int) -> None:
    """@cc [owner:ghuntley,label:verification;security] native-cleanup-identity-replacement
    Replacing the native dataset/snapshot at the recorded name MUST retain exact
    intent bytes, foreign GUID/content and mount, with zero destructive attempts.
    Returning the original native object MUST permit cleanup without rewriting
    its authority; only the originally recorded snapshot may then be destroyed.
    """
    global counter
    counter += 1
    nonce = f"{counter:032x}"
    dataset = f"tank/identity-{counter}"
    snapshot = dataset + "@overalls-backup-" + nonce
    owned_root = Path(f"/run/identity-owned-{counter}")
    foreign_root = Path(f"/run/identity-foreign-{counter}")
    mount = Path("/run/overalls-backups/host") / nonce
    view = mount if mounted else Path(f"/run/identity-view-{counter}")
    capture = AuditedCapture(configuration(Path(f"/run/identity-case-{counter}")))
    journal = capture.root / (nonce + ".json")
    AUDIT.write_text("")
    effects.clear()
    zfs("create", "-o", "mountpoint=" + str(owned_root), dataset)
    (owned_root / "witness").write_text("original owned snapshot\n")
    value: OwnedSnapshot = {
        "version": 1,
        "nonce": nonce,
        "dataset": dataset,
        "mount": str(mount),
        "dataset_guid": guid(dataset),
        "snapshot_guid": None,
    }
    atomic_json(journal, value)
    zfs("snapshot", "-o", "overalls:backup_nonce=" + nonce, snapshot)
    original_guid = guid(snapshot)
    value["snapshot_guid"] = original_guid
    atomic_json(journal, value)
    before = journal.read_bytes()
    if kind == "dataset":
        held = f"tank/identity-held-{counter}"
        zfs("rename", dataset, held)
        zfs("create", "-o", "mountpoint=" + str(foreign_root), dataset)
        (foreign_root / "witness").write_text("replacement foreign snapshot\n")
    else:
        held = dataset + "@identity-held-" + nonce
        zfs("rename", snapshot, held)
        (owned_root / "witness").write_text("replacement foreign snapshot\n")
    zfs("snapshot", "-o", "overalls:backup_nonce=" + nonce, snapshot)
    foreign_dataset_guid = guid(dataset)
    foreign_snapshot_guid = guid(snapshot)
    assert foreign_snapshot_guid != original_guid
    assert (foreign_dataset_guid != value["dataset_guid"]) == (kind == "dataset")
    view.mkdir(parents=True, mode=0o700)
    command(["mount", "-t", "zfs", "-o", "ro,nodev,nosuid,noexec", snapshot, str(view)])
    sentinel_guid = guid("tank/foreign@keep")
    for _ in range(repeats):
        assert capture.cleanup() == 1
        assert journal.read_bytes() == before
        assert effects == [] and destroys() == []
        assert guid(dataset) == foreign_dataset_guid
        assert guid(snapshot) == foreign_snapshot_guid
        assert command(["findmnt", "-n", "-o", "SOURCE", "--mountpoint", str(view)]) == snapshot
        assert (view / "witness").read_text() == "replacement foreign snapshot\n"
        assert guid("tank/foreign@keep") == sentinel_guid
        assert Path("/tank/foreign/.zfs/snapshot/keep/witness").read_text() == "foreign stays\n"
    # Fixture retirement uses independently observed replacement identities;
    # it never updates the original production descriptor to adopt foreign state.
    command(["umount", str(view)])
    assert guid(snapshot) == foreign_snapshot_guid
    zfs("destroy", snapshot)
    if kind == "dataset":
        assert guid(dataset) == foreign_dataset_guid
        zfs("destroy", dataset)
        zfs("rename", held, dataset)
    else:
        zfs("rename", held, snapshot)
    assert guid(dataset) == value["dataset_guid"]
    assert guid(snapshot) == original_guid
    assert journal.read_bytes() == before
    command(["mount", "-t", "zfs", "-o", "ro,nodev,nosuid,noexec", snapshot, str(view)])
    assert (view / "witness").read_text() == "original owned snapshot\n"
    if not mounted:
        command(["umount", str(view)])
        view.rmdir()
    assert capture.cleanup() == 0
    assert not journal.exists() and not mount.exists()
    assert destroys() == [["destroy", snapshot]]
    expected = [("umount", ["--", str(mount)])] if mounted else []
    assert effects == [*expected, ("zfs", ["destroy", snapshot])]
    assert capture.cleanup() == 0
    assert destroys() == [["destroy", snapshot]]
    assert guid("tank/foreign@keep") == sentinel_guid
    zfs("destroy", dataset)
    print(f"identity replacement history {counter}: {kind}, mounted={mounted}, replays={repeats}")


@settings(max_examples=4, deadline=None, derandomize=True)
@example(created=False, directory=False, unavailable=False, repeats=1)
@example(created=False, directory=True, unavailable=True, repeats=3)
@example(created=True, directory=False, unavailable=True, repeats=2)
@example(created=True, directory=True, unavailable=False, repeats=3)
@given(
    created=st.booleans(),
    directory=st.booleans(),
    unavailable=st.booleans(),
    repeats=st.sampled_from([1, 2, 3]),
)
def precreation_intent(created: bool, directory: bool, unavailable: bool, repeats: int) -> None:
    """@cc [owner:ghuntley,label:verification;recovery] native-cleanup-pre-guid-intent
    Durable intent without a recorded snapshot GUID MUST survive unavailable
    inspection exactly. Native absence MUST converge without destroy; a created
    locally tagged snapshot MUST be destroyed once. Dataset data/GUID and foreign
    snapshot contents MUST remain unchanged, and replay MUST be idempotent.
    """
    global counter
    counter += 1
    nonce = f"{counter:032x}"
    dataset = f"tank/precreation-{counter}"
    snapshot = dataset + "@overalls-backup-" + nonce
    root = Path(f"/run/precreation-data-{counter}")
    mount = Path("/run/overalls-backups/host") / nonce
    capture = AuditedCapture(configuration(Path(f"/run/precreation-case-{counter}")))
    journal = capture.root / (nonce + ".json")
    AUDIT.write_text("")
    effects.clear()
    zfs("create", "-o", "mountpoint=" + str(root), dataset)
    (root / "witness").write_text("dataset remains\n")
    value: OwnedSnapshot = {
        "version": 1,
        "nonce": nonce,
        "dataset": dataset,
        "mount": str(mount),
        "dataset_guid": guid(dataset),
        "snapshot_guid": None,
    }
    atomic_json(journal, value)
    before = journal.read_bytes()
    if created:
        zfs("snapshot", "-o", "overalls:backup_nonce=" + nonce, snapshot)
    if directory:
        mount.mkdir(parents=True, mode=0o700)
    sentinel_guid = guid("tank/foreign@keep")
    if unavailable:
        DOWN.touch()
        for _ in range(repeats):
            assert capture.cleanup() == 1
            assert journal.read_bytes() == before
            assert effects == [] and destroys() == []
            assert guid(dataset) == value["dataset_guid"]
        DOWN.unlink()
    assert owned_snapshot(read_json(journal)) == value
    assert (
        subprocess.run([os.environ["NATIVE_ZFS"], "list", snapshot], capture_output=True).returncode
        == 0
    ) == created
    for _ in range(repeats):
        assert capture.cleanup() == 0
        assert not journal.exists() and not mount.exists()
        expected = [["destroy", snapshot]] if created else []
        assert destroys() == expected
        assert effects == ([("zfs", ["destroy", snapshot])] if created else [])
        assert guid(dataset) == value["dataset_guid"]
        assert (root / "witness").read_text() == "dataset remains\n"
        assert guid("tank/foreign@keep") == sentinel_guid
        assert Path("/tank/foreign/.zfs/snapshot/keep/witness").read_text() == "foreign stays\n"
    zfs("destroy", dataset)
    print(
        f"pre-GUID intent history {counter}: created={created}, directory={directory}, outage={unavailable}, replays={repeats}"
    )


def main() -> None:
    if len(sys.argv) == 3 and sys.argv[1] == "--worker":
        if not re.fullmatch(r"/run/worker-case-[1-9][0-9]*", sys.argv[2]):
            raise AssertionError("invalid fixture worker root")
        capture = HostCapture(configuration(Path(sys.argv[2])))
        assert capture.cleanup() == 0
        return
    zfs("create", "tank/foreign")
    Path("/tank/foreign/witness").write_text("foreign stays\n")
    zfs("snapshot", "tank/foreign@keep")
    wrapper = Path("/run/cleanup-zfs")
    wrapper.write_text(
        "#!"
        + sys.executable
        + "\nexec(compile(open('/etc/cleanup-zfs.py').read(), '/etc/cleanup-zfs.py', 'exec'))\n"
    )
    wrapper.chmod(0o700)
    native_cleanup()
    worker_death()
    identity_replacement()
    precreation_intent()


if __name__ == "__main__":
    main()
