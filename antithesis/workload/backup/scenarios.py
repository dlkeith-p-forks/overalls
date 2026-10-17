"""Backup graph, restore and publication histories against the production CLI."""

from __future__ import annotations

import hashlib
import json
import logging
import stat
import time
from pathlib import Path

from antithesis.assertions import always, reachable, sometimes

from backup.fixture import BackupFixture, Component, fixture
from core.interesting import choice

LOG = logging.getLogger(__name__)


def _components(manifest: dict[str, object]) -> list[dict[str, str]]:
    raw = manifest.get("components")
    if not isinstance(raw, list):
        raise ValueError("invalid manifest components")
    result: list[dict[str, str]] = []
    for item in raw:
        if not isinstance(item, dict):
            raise ValueError("invalid manifest component")
        kind, identity = item.get("kind"), item.get("snapshot_id")
        if not isinstance(kind, str) or not isinstance(identity, str):
            raise ValueError("invalid manifest reference")
        result.append({"kind": kind, "snapshot_id": identity})
    return result


def run_retained_closure() -> int:
    """Prune real Restic points; independently restore every retained reference."""
    keep = choice((1, 2, 3))
    guest_count = choice((0, 1, 3))
    with fixture(keep) as case:
        host = case.capture("host.bin", b"host-sentinel-" + bytes([keep]), "host-state")
        guests = [
            case.capture(f"guest-{index}.bin", f"guest-sentinel-{index}".encode(), "guest")
            for index in range(guest_count)
        ]
        known = {component.snapshot_id: component for component in [host, *guests]}
        points: list[str] = []
        for serial in range(1, keep + 2):
            components = [host, *guests] if serial % 2 else [host]
            points.append(case.publish(components, serial))
        if case.operator("prune", timeout=180).code != 0:
            LOG.info("Backup closure unexercised: real prune unavailable")
            return 0
        retained = case.manifests()
        retained_ids = {str(row["id"]) for row in retained}
        always(
            retained_ids == set(points[-keep:]),
            "Backup retention keeps exactly the newest complete manifest points",
        )
        all_ids = case.ids()
        for row in retained:
            raw = case.dump_manifest(row)
            references = _components(raw)
            expected = [
                known[item["snapshot_id"]] for item in references if item["snapshot_id"] in known
            ]
            complete = len(expected) == len(references) and any(
                item.kind == "host-state" for item in expected
            )
            hashes_match = complete
            for index, item in enumerate(expected):
                target = case.root / f"oracle-{row['id']}-{index}"
                hashes_match = hashes_match and case.restored_hash(item, target) == item.sha256
            always(
                complete
                and all(item["snapshot_id"] in all_ids for item in references)
                and hashes_match,
                "Retained backup manifest references restorable component snapshots",
            )
            inspect = case.operator("inspect", "--snapshot", str(row["id"]))
            always(
                inspect.code == 0 and json.loads(inspect.output) == raw,
                "Retained backup point passes the production manifest validator",
            )
        if guest_count and any(
            any(
                item["snapshot_id"] == host.snapshot_id
                for item in _components(case.dump_manifest(row))
            )
            for row in retained
        ):
            reachable("Backup retained points share a real Restic component snapshot")
    return 0


def run_publication_reply_loss() -> int:
    """Lose the manifest upload reply after real Restic publication and recover."""
    with fixture(2) as case:
        sentinel = case.source / "retained-host.bin"
        body = b"published-after-lost-reply"
        sentinel.write_bytes(body)
        case.config["materialize"] = [str(sentinel)]
        if case.operator("backup", timeout=180).code != 0:
            LOG.info("Backup reply-loss baseline unexercised")
            return 0
        before = {str(row["id"]) for row in case.manifests()}
        marker = case.root / "uploaded-manifest-blocked"
        case.gate("backup", marker, after=True)
        result = case.interrupt_at_gate("backup", marker)
        if result is None:
            LOG.info("Backup reply-loss window unexercised: upload gate not reached")
            return 0
        uploaded = [row for row in case.manifests() if str(row["id"]) not in before]
        always(
            len(uploaded) == 1,
            "Uploaded backup manifest remains tag-visible after its reply is lost",
        )
        if len(uploaded) != 1:
            return 0
        reachable("Backup manifest upload completed before its coordinator reply was lost")
        point = str(uploaded[0]["id"])
        raw = case.dump_manifest(uploaded[0])
        inspected = case.operator("inspect", "--snapshot", point)
        always(
            inspected.code == 0 and json.loads(inspected.output) == raw,
            "Uploaded backup manifest remains valid after its reply is lost",
        )
        if case.operator("cleanup").code != 0 or case.operator("prune", timeout=180).code != 0:
            LOG.info("Backup reply-loss recovery unexercised: cleanup or prune unavailable")
            return 0
        retained = point in {str(row["id"]) for row in case.manifests()}
        target = case.root / "reply-loss-restore"
        restored = case.operator("restore", "--snapshot", point, "--target", str(target))
        sentinels = list(target.rglob("configuration/0")) if target.exists() else []
        always(
            retained
            and restored.code == 0
            and (target / "manifest.json").is_file()
            and len(sentinels) == 1
            and hashlib.sha256(sentinels[0].read_bytes()).hexdigest()
            == hashlib.sha256(body).hexdigest(),
            "Retained uploaded backup point restores its component after local reply loss",
        )
    return 0


def _point(case: BackupFixture, serial: int = 23) -> tuple[str, tuple[Component, Component]]:
    host = case.capture("host.bin", b"host-verified-prefix", "host-state")
    guest = case.capture("guest.bin", b"guest-blocked-component", "guest")
    point = case.publish((host, guest), serial)
    return point, (host, guest)


def run_interrupted_restore() -> int:
    """Interrupt the real second Restic restore; inspect marker, prefix and retry."""
    with fixture() as case:
        point, components = _point(case)
        target = case.root / "partial-restore"
        marker = case.root / "restore-blocked"
        case.gate("restore", marker, target / "1")
        result = case.interrupt_at_gate(
            "restore", marker, "--snapshot", point, "--target", str(target)
        )
        if result is None:
            LOG.info("Backup restore interruption unexercised: gate not reached")
            return 0
        first = target / "0" / components[0].source.relative_to("/")
        prefix_ok = (
            first.is_file()
            and hashlib.sha256(first.read_bytes()).hexdigest() == components[0].sha256
        )
        marker_absent = not (target / "manifest.json").exists()
        always(
            result.code != 0 and marker_absent and prefix_ok,
            "Interrupted backup restore leaves its partial target unpublished",
        )
        if prefix_ok:
            reachable("Backup restore interruption retained a verified component prefix")
        before = _inventory(target)
        retry = case.operator("restore", "--snapshot", point, "--target", str(target))
        always(
            retry.code != 0 and _inventory(target) == before,
            "Backup restore refuses a nonempty partial target without changing its bytes",
        )
        fresh = case.root / "fresh-restore"
        success = case.operator("restore", "--snapshot", point, "--target", str(fresh))
        complete = success.code == 0 and (fresh / "manifest.json").is_file()
        for index, component in enumerate(components):
            path = fresh / str(index) / component.source.relative_to("/")
            complete = (
                complete
                and path.is_file()
                and hashlib.sha256(path.read_bytes()).hexdigest() == component.sha256
            )
        sometimes(
            complete,
            "Fresh backup restore eventually completes after an interrupted attempt",
        )
        if success.code == 0:
            always(complete, "Fresh backup restore publishes only after every component verifies")
            reachable("Backup restore completed into a fresh isolated target after interruption")
    return 0


def _inventory(root: Path) -> dict[str, tuple[int, str]]:
    if not root.exists():
        return {}
    result: dict[str, tuple[int, str]] = {}
    for path in [root, *sorted(root.rglob("*"))]:
        mode = path.lstat().st_mode
        digest = hashlib.sha256(path.read_bytes()).hexdigest() if stat.S_ISREG(mode) else ""
        result[str(path.relative_to(root))] = (mode, digest)
    return result


def run_published_compatibility() -> int:
    """Observe tag-visible points produced by the actual coordinator and validator."""
    with fixture(choice((1, 2, 12))) as case:
        sentinel = case.source / "host-materialized.bin"
        sentinel.write_bytes(b"coordinator-host-sentinel")
        case.config["materialize"] = [str(sentinel)]
        before = {str(row["id"]) for row in case.manifests()}
        result = case.operator("backup", timeout=180)
        after = [row for row in case.manifests() if str(row["id"]) not in before]
        if result.code == 0:
            always(
                len(after) == 1,
                "Successful coordinator backup advertises exactly one new host manifest",
            )
        if not after:
            LOG.info("Backup coordinator publication unexercised: code=%s", result.code)
            return 0
        for row in after:
            raw = case.dump_manifest(row)
            inspected = case.operator("inspect", "--snapshot", str(row["id"]))
            always(
                inspected.code == 0 and json.loads(inspected.output) == raw,
                "Newly published backup point passes its retention manifest validator",
            )
            started, completed = raw.get("started_at"), raw.get("completed_at")
            if type(started) is int and type(completed) is int and completed < started:
                reachable("Backup completion wall time precedes durable start time")
            reachable("Backup coordinator published a tag-visible host manifest")
    return 0


def run_historical_quarantine() -> int:
    """Restore a deliberately mixed-time graph into an isolated private target.

    The backup CLI exposes no activation/claim command or reconciliation receipt.
    This tests only the concrete private target boundary; authority reentry remains
    quarantined pending a separate documented protocol and native campaign.
    """
    with fixture() as case:
        old = case.capture("old-host.bin", b"host-before-guest-change", "host-state")
        time.sleep(0.01)
        newer = case.capture("new-guest.bin", b"guest-after-host-capture", "guest")
        point = case.publish((old, newer), 42)
        target = case.root / "isolated-recovery"
        result = case.operator("restore", "--snapshot", point, "--target", str(target))
        if result.code != 0:
            LOG.info("Mixed-time backup restore unexercised: operator unavailable")
            return 0
        manifest = target / "manifest.json"
        raw = next(
            (case.dump_manifest(row) for row in case.manifests() if row["id"] == point), None
        )
        isolated = (
            manifest.is_file()
            and stat.S_IMODE(target.stat().st_mode) == 0o700
            and target.is_relative_to(case.root)
            and raw is not None
            and json.loads(manifest.read_bytes()) == raw
        )
        for index, component in enumerate((old, newer)):
            path = target / str(index) / component.source.relative_to("/")
            isolated = (
                isolated
                and path.is_file()
                and hashlib.sha256(path.read_bytes()).hexdigest() == component.sha256
            )
        always(
            isolated,
            "Mixed-time backup restore remains in its private isolated target",
        )
        snapshots = {str(row["id"]): row for row in case.snapshots()}
        old_time = snapshots.get(old.snapshot_id, {}).get("time")
        new_time = snapshots.get(newer.snapshot_id, {}).get("time")
        if (
            isolated
            and isinstance(old_time, str)
            and isinstance(new_time, str)
            and old_time != new_time
        ):
            reachable("Backup fixture published independently timed components")
    return 0
