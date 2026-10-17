"""Selected host files from native ZFS snapshots, with durable cleanup ownership."""

import json
import os
import re
import shutil
import uuid
from collections.abc import Sequence
from pathlib import Path
from typing import Literal, TypedDict

from common import BackupError, atomic_json, private_directory, read_json, run
from schema import Config, integer, object_value, string


class OwnedSnapshot(TypedDict):
    version: int
    nonce: str
    dataset: str
    mount: str
    dataset_guid: str
    snapshot_guid: str | None


class PathMapping(TypedDict):
    original: str
    source: str
    filesystem: str
    dataset: str | None


def exclusions(patterns: Sequence[str], mappings: Sequence[PathMapping]) -> list[str]:
    """@cc [owner:ghuntley,label:recovery] host-exclusions-follow-original-paths
    Literal absolute exclusions MUST also exclude the corresponding snapshot or
    staged path. Path-prefix matches MUST respect directory boundaries.
    """
    result = list(patterns)
    for pattern in patterns:
        if not pattern.startswith("/"):
            continue
        excluded = pattern.rstrip("/")
        for mapping in mappings:
            original = mapping["original"].rstrip("/")
            source = mapping["source"].rstrip("/")
            if excluded == original or original.startswith(excluded + "/"):
                result.append(source)
            elif excluded.startswith(original + "/"):
                result.append(source + excluded[len(original) :])
    return list(dict.fromkeys(result))


def owned_snapshot(raw: object) -> OwnedSnapshot:
    value = object_value(raw)
    if set(value) != set(OwnedSnapshot.__annotations__):
        raise BackupError("cleanup")
    result = OwnedSnapshot(
        version=integer(value["version"]),
        nonce=string(value["nonce"]),
        dataset=string(value["dataset"]),
        mount=string(value["mount"]),
        dataset_guid=string(value["dataset_guid"]),
        snapshot_guid=string(value["snapshot_guid"])
        if value["snapshot_guid"] is not None
        else None,
    )
    if (
        result["version"] != 1
        or not re.fullmatch(r"[0-9a-f]{32}", result["nonce"])
        or not re.fullmatch(r"[A-Za-z][A-Za-z0-9_.:-]*(/[A-Za-z0-9_.:-]+)*", result["dataset"])
        or result["mount"] != "/run/overalls-backups/host/" + result["nonce"]
    ):
        raise BackupError("cleanup")
    for guid in (result["dataset_guid"], result["snapshot_guid"]):
        if guid is not None and (not re.fullmatch(r"[1-9][0-9]{0,19}", guid) or int(guid) >= 2**64):
            raise BackupError("cleanup")
    return result


def filesystems(body: str) -> list[dict[str, str]]:
    rows = object_value(json.loads(body))["filesystems"]
    if not isinstance(rows, list):
        raise BackupError("capture")
    return [{key: string(value) for key, value in object_value(row).items()} for row in rows]


class HostCapture:
    def __init__(self, config: Config) -> None:
        self.config = config
        self.root = private_directory(Path(config["state_directory"]) / "host-snapshots")

    def command(self, name: Literal["zfs", "findmnt", "mount", "umount"], args: list[str]) -> str:
        executables = {
            "zfs": self.config["zfs"],
            "findmnt": self.config["findmnt"],
            "mount": self.config["mount"],
            "umount": self.config["umount"],
        }
        return run([executables[name], *args], stage="capture", timeout=60).decode().strip()

    def snapshot_guid(self, name: str) -> str | None:
        listing = self.command("zfs", ["list", "-Hp", "-t", "snapshot", "-o", "name,guid"])
        result: dict[str, str] = {}
        for line in listing.splitlines():
            snapshot, guid = line.split("\t")
            result[snapshot] = guid
        return result.get(name)

    def cleanup(self) -> int:
        """@cc [owner:ghuntley,label:recovery;security] host-snapshot-cleanup-owned-only
        Cleanup MUST match durable dataset identity and a locally created nonce
        before destroying a snapshot. Failed/unavailable inspection MUST retain
        the journal and report pending work, never infer snapshot absence.
        """
        pending = 0
        for path in self.root.glob("*.json"):
            try:
                value = owned_snapshot(read_json(path))
                if path.name != value["nonce"] + ".json":
                    raise BackupError("cleanup")
                self.release(value)
            except (BackupError, OSError, ValueError, KeyError):
                pending += 1
        return pending

    def release(self, value: OwnedSnapshot) -> None:
        nonce = value["nonce"]
        if value["version"] != 1 or not re.fullmatch(r"[0-9a-f]{32}", nonce):
            raise BackupError("cleanup")
        name = value["dataset"] + "@overalls-backup-" + nonce
        mount = "/run/overalls-backups/host/" + nonce
        if value["mount"] != mount:
            raise BackupError("cleanup")
        guid = self.command("zfs", ["get", "-Hp", "-o", "value", "guid", value["dataset"]])
        if guid != value["dataset_guid"]:
            raise BackupError("cleanup")
        snapshot_guid = self.snapshot_guid(name)
        mounts = filesystems(self.command("findmnt", ["--json", "--list", "-o", "TARGET,SOURCE"]))
        selected = [entry for entry in mounts if entry["target"] == mount]
        if selected and (
            len(selected) != 1 or selected[0]["source"] != name or snapshot_guid is None
        ):
            raise BackupError("cleanup")
        if snapshot_guid is not None:
            marker = self.command(
                "zfs", ["get", "-Hp", "-o", "value,source", "overalls:backup_nonce", name]
            )
            if marker != nonce + "\tlocal" or value.get("snapshot_guid") not in (
                None,
                snapshot_guid,
            ):
                raise BackupError("cleanup")
            if selected:
                self.command("umount", ["--", mount])
            self.command("zfs", ["destroy", name])
            if self.snapshot_guid(name) is not None:
                raise BackupError("cleanup")
        if Path(mount).exists():
            Path(mount).rmdir()
        (self.root / (nonce + ".json")).unlink()
        descriptor = os.open(self.root, os.O_DIRECTORY | os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)

    def prepare(self, working: Path) -> tuple[list[str], list[PathMapping]]:
        sources: list[str] = []
        snapshots: dict[str, OwnedSnapshot] = {}
        mappings: list[PathMapping] = []
        for original in self.config["paths"]:
            path = Path(original)
            if not path.exists() and not path.is_symlink():
                raise BackupError("capture")
            # Declarative /etc entries frequently point into the store.
            source = path.resolve(strict=True) if path.is_symlink() else path
            found = filesystems(
                self.command(
                    "findmnt", ["--json", "--target", str(source), "-o", "TARGET,SOURCE,FSTYPE"]
                )
            )[0]
            if found["fstype"] == "zfs":
                dataset = found["source"]
                if "@" in dataset or "[" in dataset:
                    raise BackupError("capture")
                if any(
                    dataset == protected or dataset.startswith(protected + "/")
                    for protected in self.config["protected_datasets"]
                ):
                    # Lilly's parent/child policy admits only its own journaled
                    # snapshots. Ownership metadata is copied under its pool lock.
                    raise BackupError("configuration")
                if dataset not in snapshots:
                    nonce = uuid.uuid4().hex
                    mount = "/run/overalls-backups/host/" + nonce
                    value: OwnedSnapshot = {
                        "version": 1,
                        "nonce": nonce,
                        "dataset": dataset,
                        "mount": mount,
                        "dataset_guid": self.command(
                            "zfs", ["get", "-Hp", "-o", "value", "guid", dataset]
                        ),
                        "snapshot_guid": None,
                    }
                    atomic_json(self.root / (nonce + ".json"), value)
                    name = dataset + "@overalls-backup-" + nonce
                    self.command("zfs", ["snapshot", "-o", "overalls:backup_nonce=" + nonce, name])
                    value["snapshot_guid"] = self.snapshot_guid(name)
                    if value["snapshot_guid"] is None:
                        raise BackupError("capture")
                    atomic_json(self.root / (nonce + ".json"), value)
                    private_directory(mount)
                    self.command(
                        "mount", ["-t", "zfs", "-o", "ro,nodev,nosuid,noexec", name, mount]
                    )
                    snapshots[dataset] = value
                source = Path(snapshots[dataset]["mount"]) / source.relative_to(found["target"])
            sources.append(str(source))
            mappings.append(
                {
                    "original": original,
                    "source": str(source),
                    "filesystem": found["fstype"],
                    "dataset": found["source"],
                }
            )
        materialized = private_directory(Path(working) / "configuration")
        for index, original in enumerate(self.config["materialize"]):
            destination = materialized / str(index)
            shutil.copyfile(Path(original).resolve(strict=True), destination)
            destination.chmod(0o600)
            mappings.append(
                {
                    "original": original,
                    "source": str(destination),
                    "filesystem": "artifact",
                    "dataset": None,
                }
            )
        for index, original in enumerate(self.config["images"]):
            # Preserve kernels/initrds/manifests and immutable templates even when
            # they are store symlinks. Live VM contents are captured separately.
            destination = materialized / ("image-" + str(index))
            shutil.copytree(original, destination, symlinks=False)
            mappings.append(
                {
                    "original": original,
                    "source": str(destination),
                    "filesystem": "image",
                    "dataset": None,
                }
            )
        atomic_json(
            materialized / "paths.json",
            {
                "version": 1,
                "paths": mappings,
                "system": os.readlink("/run/current-system")
                if Path("/run/current-system").is_symlink()
                else None,
            },
        )
        return [*sources, str(materialized)], mappings
