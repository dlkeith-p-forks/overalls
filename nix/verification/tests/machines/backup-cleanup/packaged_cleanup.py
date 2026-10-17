"""Native interrupted-run recovery through the installed unit and operator CLI."""

import fcntl
import os
import subprocess
from pathlib import Path
from typing import Literal

from common import atomic_json, read_json  # ty: ignore[unresolved-import] # VM runtime
from host import OwnedSnapshot  # ty: ignore[unresolved-import] # VM runtime
from hypothesis import example, given, settings
from hypothesis import strategies as st
from journal import Journal  # ty: ignore[unresolved-import] # VM runtime
from schema import object_value  # ty: ignore[unresolved-import] # VM runtime

type StartPhase = Literal["preparing", "capturing", "cleaning"]
ROOT = Path("/var/lib/overalls-backups")
counter: int = 0


def command(args: list[str]) -> str:
    return subprocess.check_output(args, text=True).strip()


def zfs(*args: str) -> str:
    return command([os.environ["NATIVE_ZFS"], *args])


def guid(name: str) -> str:
    return zfs("get", "-Hp", "-o", "value", "guid", name)


def cleanup(operator: bool, success: bool) -> None:
    args = (
        ["overalls-backup", "cleanup"]
        if operator
        else ["systemctl", "start", "overalls-backup-cleanup.service"]
    )
    result = subprocess.run(args, capture_output=True, text=True, timeout=30)
    assert (result.returncode == 0) == success
    if not operator:
        assert command(
            ["systemctl", "show", "-p", "ExecMainStatus", "--value", "overalls-backup-cleanup"]
        ) == ("0" if success else "1")
        if not success:
            command(["systemctl", "reset-failed", "overalls-backup-cleanup"])


@settings(max_examples=6, deadline=None, derandomize=True)
@example(phase="preparing", operator=False, repeats=1)
@example(phase="capturing", operator=True, repeats=2)
@example(phase="cleaning", operator=False, repeats=3)
@given(
    phase=st.sampled_from(["preparing", "capturing", "cleaning"]),
    operator=st.booleans(),
    repeats=st.sampled_from([1, 2, 3]),
)
def packaged_cleanup(phase: StartPhase, operator: bool, repeats: int) -> None:
    """@cc [owner:ghuntley,label:verification;recovery] packaged-cleanup-recovery
    The installed cleanup unit and operator MUST leave interrupted runs in
    cleaning with visible cleanup failure while snapshot ownership is foreign.
    The exact intent and native snapshot MUST survive refusal. Once proof is
    restored, cleanup MUST confirm absence and close the interrupted run as
    failed, preserve previous success fields, and leave terminal replay inert.
    Contending cleanup MUST leave persisted status, journal and snapshot intact.
    """
    global counter
    counter += 1
    nonce = f"{counter:032x}"
    dataset = f"tank/packaged-{counter}"
    snapshot = dataset + "@overalls-backup-" + nonce
    ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
    intents = ROOT / "host-snapshots"
    intents.mkdir(mode=0o700, exist_ok=True)
    run_path, status_path = ROOT / "run.json", ROOT / "status.json"
    run_path.unlink(missing_ok=True)
    journal = Journal.create(run_path, "storage", None)
    if phase == "capturing":
        journal.transition("capturing")
    elif phase == "cleaning":
        journal.transition("cleaning")
    identity = journal.value["run_id"]
    atomic_json(
        status_path,
        {
            "version": 1,
            "state": "running",
            "failure": "none",
            "last_success_at": 42,
            "manifest_id": "a" * 64,
        },
    )
    zfs("create", "-o", "mountpoint=none", dataset)
    dataset_guid = guid(dataset)
    zfs("snapshot", "-o", "overalls:backup_nonce=foreign", snapshot)
    snapshot_guid = guid(snapshot)
    value: OwnedSnapshot = {
        "version": 1,
        "nonce": nonce,
        "dataset": dataset,
        "dataset_guid": dataset_guid,
        "snapshot_guid": snapshot_guid,
        "mount": "/run/overalls-backups/host/" + nonce,
    }
    intent = intents / (nonce + ".json")
    atomic_json(intent, value)
    original = intent.read_bytes()
    with (ROOT / "owner.lock").open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        old_run, old_status = run_path.read_bytes(), status_path.read_bytes()
        cleanup(operator, True)
        assert run_path.read_bytes() == old_run
        assert status_path.read_bytes() == old_status
        assert intent.read_bytes() == original
        assert guid(snapshot) == snapshot_guid
    for _ in range(repeats):
        cleanup(operator, False)
        refused = Journal.load(run_path).value
        status = object_value(read_json(status_path))
        assert refused["run_id"] == identity
        assert refused["phase"] == "cleaning"
        assert refused["cleanup_confirmed"] is False
        assert refused["failures"] == ["interrupted"]
        assert refused["manifest_id"] is None
        assert status["state"] == "failed" and status["failure"] == "cleanup"
        assert status["cleanup_pending"] == 1
        assert status["last_success_at"] == 42 and status["manifest_id"] == "a" * 64
        assert intent.read_bytes() == original
        assert guid(snapshot) == snapshot_guid
    zfs("set", "overalls:backup_nonce=" + nonce, snapshot)
    cleanup(not operator, True)
    terminal = Journal.load(run_path).value
    assert terminal["run_id"] == identity
    assert terminal["phase"] == "failed" and terminal["cleanup_confirmed"] is True
    assert terminal["failures"] == ["interrupted"] and terminal["manifest_id"] is None
    assert not intent.exists()
    assert snapshot not in zfs("list", "-H", "-o", "name", "-t", "snapshot").splitlines()
    terminal_bytes = run_path.read_bytes()
    for _ in range(repeats):
        cleanup(operator, True)
        assert run_path.read_bytes() == terminal_bytes
        status = object_value(read_json(status_path))
        assert status["cleanup_pending"] == 0
        assert status["state"] == "failed" and status["failure"] == "interrupted"
        assert status["last_success_at"] == 42 and status["manifest_id"] == "a" * 64
        assert guid(dataset) == dataset_guid
        assert guid("tank/foreign@keep") == sentinel_guid
        assert Path("/tank/foreign/.zfs/snapshot/keep/witness").read_text() == "foreign stays\n"
    zfs("destroy", dataset)
    print(
        f"packaged cleanup history {counter}: phase={phase}, operator={operator}, repeats={repeats}"
    )


@settings(max_examples=6, deadline=None, derandomize=True)
@example(recorded=False, operator=False, count=0, repeats=1)
@example(recorded=True, operator=True, count=1, repeats=2)
@example(recorded=True, operator=False, count=3, repeats=3)
@given(
    recorded=st.booleans(),
    operator=st.booleans(),
    count=st.sampled_from([0, 1, 3]),
    repeats=st.sampled_from([1, 2, 3]),
)
def publication_recovery(recorded: bool, operator: bool, count: int, repeats: int) -> None:
    """@cc [owner:ghuntley,label:verification;recovery] interrupted-publication-recovery
    Installed cleanup MUST retire an interrupted publishing journal as failed,
    preserving run identity, components and any recorded manifest reference.
    Recovery MUST NOT advance last success or manufacture a complete run.
    Repeated cleanup MUST preserve the exact terminal journal bytes.
    """
    run_path, status_path = ROOT / "run.json", ROOT / "status.json"
    run_path.unlink(missing_ok=True)
    journal = Journal.create(run_path, "storage", "fixture-revision")
    journal.transition("capturing")
    for index in range(count):
        journal.component({"kind": "host-state", "snapshot_id": f"{index + 1:064x}"})
    journal.transition("cleaning")
    journal.save(cleanup_confirmed=True)
    journal.transition("publishing")
    if recorded:
        journal.save(manifest_id="b" * 64)
    before = journal.value
    atomic_json(
        status_path, {"version": 1, "state": "running", "failure": "none", "last_success_at": 42}
    )
    assert not list((ROOT / "host-snapshots").glob("*.json"))
    with (ROOT / "owner.lock").open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        old_run, old_status = run_path.read_bytes(), status_path.read_bytes()
        cleanup(operator, True)
        assert run_path.read_bytes() == old_run and status_path.read_bytes() == old_status
    cleanup(operator, True)
    terminal = Journal.load(run_path).value
    assert terminal["phase"] == "failed" and terminal["cleanup_confirmed"] is True
    assert terminal["failures"] == ["interrupted"]
    assert terminal["run_id"] == before["run_id"]
    assert terminal["hostname"] == before["hostname"]
    assert terminal["revision"] == before["revision"]
    assert terminal["started_at"] == before["started_at"]
    assert terminal["components"] == before["components"]
    assert terminal["manifest_id"] == before["manifest_id"]
    assert terminal["sequence"] > before["sequence"]
    status = object_value(read_json(status_path))
    assert status["last_success_at"] == 42
    assert status["state"] == "failed" and status["failure"] == "interrupted"
    assert status["cleanup_pending"] == 0
    terminal_bytes = run_path.read_bytes()
    for _ in range(repeats):
        cleanup(not operator, True)
        assert run_path.read_bytes() == terminal_bytes
        status = object_value(read_json(status_path))
        assert status["last_success_at"] == 42
        assert status["state"] == "failed" and status["failure"] == "interrupted"
        assert status["cleanup_pending"] == 0
        assert guid("tank/foreign@keep") == sentinel_guid
        assert Path("/tank/foreign/.zfs/snapshot/keep/witness").read_text() == "foreign stays\n"


if __name__ == "__main__":
    zfs("create", "tank/foreign")
    Path("/tank/foreign/witness").write_text("foreign stays\n")
    zfs("snapshot", "tank/foreign@keep")
    sentinel_guid: str = guid("tank/foreign@keep")
    packaged_cleanup()
    publication_recovery()
