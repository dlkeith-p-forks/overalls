"""Reviewed resource tuning; physical identity remains immutable across transitions."""

import copy
import hashlib
import json
import os
import subprocess
import sys
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import Protocol, TypedDict

MAX_INTEGER = 2**63 - 1
RESOURCE_FAILURES = frozenset(
    {
        "invalid_resource_policy",
        "resource_decrease_requires_maintenance",
        "resource_decrease_unsafe",
        "resource_identity_changed",
        "resource_journal_conflict",
        "resource_quota_drift",
        "resource_receipt_mismatch",
        "resource_settings_unconfirmed",
        "unbound_resource_policy",
    }
)


class Policy(TypedDict):
    version: int
    cpuCores: int
    memoryMiB: int
    arcMaxBytes: int
    quotaBytes: int
    dataset: str
    zpoolGuid: str
    datasetGuid: str


class Command(Protocol):
    def __call__(self, arguments: Sequence[str], /, *, capture: bool = False) -> str: ...


class AtomicReceipt(Protocol):
    def __call__(self, path: Path, value: Mapping[str, object]) -> None: ...


def integer_value(value: object) -> int:
    if type(value) is not int:
        raise ValueError("expected integer")
    return value


def string_value(value: object) -> str:
    if not isinstance(value, str):
        raise ValueError("expected string")
    return value


def object_value(value: object) -> dict[str, object]:
    if not isinstance(value, dict):
        raise ValueError("expected object")
    return value


def policy(manifest: Mapping[str, object]) -> Policy | None:
    value = manifest.get("resourcePolicy")
    if value is None:
        return None
    if not isinstance(value, dict):
        raise ValueError("invalid_resource_policy")
    keys = {
        "version",
        "cpuCores",
        "memoryMiB",
        "arcMaxBytes",
        "quotaBytes",
        "dataset",
        "zpoolGuid",
        "datasetGuid",
    }
    if set(value) != keys:
        raise ValueError("invalid_resource_policy")
    version = integer_value(value["version"])
    cpu_cores = integer_value(value["cpuCores"])
    memory = integer_value(value["memoryMiB"])
    arc = integer_value(value["arcMaxBytes"])
    quota = integer_value(value["quotaBytes"])
    if (
        version != 1
        or any(not 0 < field <= MAX_INTEGER for field in (cpu_cores, memory, arc, quota))
        or cpu_cores > 65536
        or memory > MAX_INTEGER // 1048576
    ):
        raise ValueError("invalid_resource_policy")
    dataset = string_value(value["dataset"])
    zpool_guid = string_value(value["zpoolGuid"])
    dataset_guid = string_value(value["datasetGuid"])
    lilly_value = manifest.get("lilly") or {}
    if not isinstance(lilly_value, dict):
        raise ValueError("invalid_resource_policy")
    binding = lilly_value.get("binding", {})
    if not isinstance(binding, dict):
        raise ValueError("invalid_resource_policy")
    if (binding.get("guestCpuCores"), binding.get("guestMemoryMiB")) != (cpu_cores, memory):
        raise ValueError("unbound_resource_policy")
    owner = lilly_value.get("owner", {})
    if not isinstance(owner, dict):
        raise ValueError("invalid_resource_policy")
    pools_row = owner.get("pools", [])
    if not isinstance(pools_row, list):
        raise ValueError("invalid_resource_policy")
    pools = []
    for pool in pools_row:
        if not isinstance(pool, dict):
            raise ValueError("invalid_resource_policy")
        storage = pool.get("storage", {})
        if not isinstance(storage, dict):
            raise ValueError("invalid_resource_policy")
        if storage.get("dataset") == dataset:
            pools.append(pool)
    if len(pools) != 1 or any(
        object_value(pools[0]["storage"]).get(key) != expected
        for key, expected in (("zpool_guid", zpool_guid), ("dataset_guid", dataset_guid))
    ):
        raise ValueError("unbound_resource_policy")
    pool, dataset_name = dataset.split("/", 1)
    installation = object_value(manifest["installationBinding"])
    storage = object_value(installation["storage"])
    effective = object_value(installation["effective"])
    pools_map = object_value(effective["pools"])
    pool_record = object_value(pools_map[pool])
    datasets = object_value(pool_record["datasets"])
    dataset_record = object_value(datasets[dataset_name])
    options = object_value(dataset_record["options"])
    if storage.get("quotaBytes") != quota or options.get("quota") != str(quota):
        raise ValueError("unbound_resource_policy")
    return Policy(
        version=version,
        cpuCores=cpu_cores,
        memoryMiB=memory,
        arcMaxBytes=arc,
        quotaBytes=quota,
        dataset=dataset,
        zpoolGuid=zpool_guid,
        datasetGuid=dataset_guid,
    )


def installation_identity(binding: dict[str, object], resource: Policy | None) -> dict[str, object]:
    result: dict[str, object] = copy.deepcopy(binding)
    if resource is not None:
        pool, dataset = resource["dataset"].split("/", 1)
        storage = object_value(result["storage"])
        storage.pop("quotaBytes")
        effective = object_value(result["effective"])
        pools_map = object_value(effective["pools"])
        pool_record = object_value(pools_map[pool])
        datasets = object_value(pool_record["datasets"])
        dataset_record = object_value(datasets[dataset])
        options = object_value(dataset_record["options"])
        options.pop("quota")
    return result


MEMORY_DECREASE_HEADROOM_BYTES = 2 * 2**30
DNODE_LIMIT_DIVISOR = 4


def dnode_limit(arc_max_bytes: int) -> int:
    """The ARC dnode limit derived from the ARC budget: a quarter of it."""
    return arc_max_bytes // DNODE_LIMIT_DIVISOR


def compatible(previous: Mapping[str, object], candidate: Mapping[str, object]) -> bool:
    """@cc [owner:ghuntley,label:recovery] resource-transition-exact-allowlist
    Resource updates MUST compare every identity field except the exact bound
    guest quota and CPU/RAM ceilings. CPU and quota ceilings may only increase;
    the RAM ceiling may also decrease, and apply_native decides whether that
    decrease is safe against live use. Policy introduction or removal, changed
    dataset identity and unrelated installation changes MUST fail.
    """
    old, new = policy(previous), policy(candidate)
    if old is None or new is None:
        if old is not None or new is not None:
            return False
        if previous.get("installationBinding") != candidate.get("installationBinding"):
            return False
        previous_lilly = previous.get("lilly") or {}
        candidate_lilly = candidate.get("lilly") or {}
        if not isinstance(previous_lilly, dict) or not isinstance(candidate_lilly, dict):
            raise AttributeError("invalid lilly binding")
        return previous_lilly.get("binding") == candidate_lilly.get("binding")
    if any(old[key] != new[key] for key in ("dataset", "zpoolGuid", "datasetGuid")):
        return False
    if any(new[key] < old[key] for key in ("cpuCores", "quotaBytes")):
        return False
    left_row = previous["lilly"]
    right_row = candidate["lilly"]
    if not isinstance(left_row, dict) or not isinstance(right_row, dict):
        raise TypeError("invalid lilly section")
    left = copy.deepcopy(left_row["binding"])
    right = copy.deepcopy(right_row["binding"])
    if not isinstance(left, dict) or not isinstance(right, dict):
        raise TypeError("invalid lilly binding")
    for key in ("guestCpuCores", "guestMemoryMiB"):
        left.pop(key)
        right.pop(key)
    previous_binding = previous["installationBinding"]
    candidate_binding = candidate["installationBinding"]
    if not isinstance(previous_binding, dict) or not isinstance(candidate_binding, dict):
        raise TypeError("invalid installation binding")
    return left == right and installation_identity(previous_binding, old) == installation_identity(
        candidate_binding, new
    )


class Transition:
    def __init__(
        self,
        previous: Mapping[str, object],
        candidate: Mapping[str, object],
        command: Command | None,
        atomic: AtomicReceipt,
        state: Path,
        root: Path = Path("/"),
    ) -> None:
        self.previous, self.candidate = previous, candidate
        self.new: Policy | None = policy(candidate)
        self.old: Mapping[str, object] | None = policy(previous)
        if self.old is None:
            self.old = self.new
        self.command, self.atomic, self.root = command, atomic, root
        digest = hashlib.sha256(
            json.dumps(
                {"policy": self.new, "binding": candidate.get("installationBinding")},
                sort_keys=True,
            ).encode()
        ).hexdigest()
        self.path: Path = state / ("resources-" + digest + ".json")

    def get(self, property: str) -> str:
        assert self.command is not None and self.new is not None
        return self.command(
            ["zfs", "get", "-Hp", "-o", "value", property, self.new["dataset"]], capture=True
        )

    def native_identity(self) -> None:
        assert self.command is not None and self.new is not None
        pool = self.new["dataset"].split("/", 1)[0]
        if (
            self.get("guid") != self.new["datasetGuid"]
            or self.command(["zpool", "get", "-Hp", "-o", "value", "guid", pool], capture=True)
            != self.new["zpoolGuid"]
        ):
            raise ValueError("resource_identity_changed")

    def prepare(self) -> None:
        """@cc [owner:ghuntley,label:recovery] resource-intent-before-mutation
        A transition MUST verify native GUIDs and preserve original receipts in a
        durable journal before changing resource limits. Retry may observe only
        that journal's original or target receipt, never approve unrelated drift.
        Enrollment receipt replay MUST preserve its current authenticated revision
        while changing only the nested storage evidence.
        """
        self.native_identity()
        if self.path.exists():
            record: dict[str, object] = json.loads(self.path.read_text())
            if not isinstance(record, dict):
                raise TypeError("invalid resource journal")
            self.record: dict[str, object] = record
            if (
                self.record["target"] != self.candidate["installationBinding"]
                or self.record["new"] != self.new
            ):
                raise ValueError("resource_journal_conflict")
            old = self.record["old"]
            if not isinstance(old, dict):
                raise TypeError("invalid resource journal")
            self.old = old
        else:
            assert self.new is not None
            receipts: dict[str, object] = {}
            for name in ("storage.json", "enrollment.json"):
                path = self.root / "var/lib/overalls-host" / name
                receipt: dict[str, object] = json.loads(path.read_text())
                observed = receipt if name == "storage.json" else receipt["storage"]
                if not isinstance(observed, dict):
                    raise TypeError("invalid resource receipt")
                if (
                    observed["binding"] != self.previous["installationBinding"]
                    or observed["poolGuid"] != self.new["zpoolGuid"]
                    or observed["datasetGuid"] != self.new["datasetGuid"]
                ):
                    raise ValueError("resource_receipt_mismatch")
                receipts[name] = receipt
            self.record = {
                "old": self.old,
                "new": self.new,
                "target": self.candidate["installationBinding"],
                "receipts": receipts,
            }
            self.atomic(self.path, self.record)
        assert self.old is not None and self.new is not None
        if int(self.get("quota")) not in (self.old["quotaBytes"], self.new["quotaBytes"]):
            raise ValueError("resource_quota_drift")
        journal_receipts = self.record["receipts"]
        if not isinstance(journal_receipts, dict):
            raise TypeError("invalid resource journal")
        for name, original in journal_receipts.items():
            current: object = json.loads((self.root / "var/lib/overalls-host" / name).read_text())
            observed = self.storage_receipt(name, current)
            expected = self.storage_receipt(name, original)
            updated = self.storage_receipt(name, self.updated_receipt(name, original))
            if observed not in (expected, updated):
                raise ValueError("resource_receipt_mismatch")

    def storage_receipt(self, name: str, receipt: object) -> dict[str, object]:
        if not isinstance(receipt, dict):
            raise TypeError("invalid resource receipt")
        if name == "storage.json":
            return receipt
        if (
            name != "enrollment.json"
            or set(receipt) != {"storage", "revision"}
            or not isinstance(receipt["revision"], str)
            or not isinstance(receipt["storage"], dict)
        ):
            raise TypeError("invalid resource receipt")
        return receipt["storage"]

    def updated_receipt(self, name: str, original: object) -> dict[str, object]:
        result: object = copy.deepcopy(original)
        if not isinstance(result, dict):
            raise TypeError("invalid resource receipt")
        observed = result if name == "storage.json" else result["storage"]
        if not isinstance(observed, dict):
            raise TypeError("invalid resource receipt")
        observed["binding"] = self.record["target"]
        return result

    def apply(self) -> None:
        """@cc [owner:ghuntley,label:recovery] resource-live-application
        Apply MUST recheck GUIDs, update the existing slice and dataset in place,
        and publish reconciled receipts only after all native settings succeed.
        It MUST NOT stop guests, format storage or shrink CPU/disk ceilings; it
        shrinks the RAM ceiling only under the safe-decrease rule of apply_native.
        """
        self.apply_native()
        journal_receipts = self.record["receipts"]
        if not isinstance(journal_receipts, dict):
            raise TypeError("invalid resource journal")
        for name_value in journal_receipts:
            name = string_value(name_value)
            path = self.root / "var/lib/overalls-host" / name
            current: object = json.loads(path.read_text())
            self.atomic(path, self.updated_receipt(name, current))

    def apply_native(self) -> None:
        """@cc [owner:ghuntley,label:recovery;capacity] resource-safe-memory-decrease
        A RAM ceiling decrease MUST be applied only while the guest slice's
        current memory use plus two GiB of headroom fits under the new ceiling,
        read immediately before the change; otherwise it MUST refuse with
        resource_decrease_unsafe and leave every setting untouched. CPU and
        quota decreases still require maintenance. The ARC dnode limit MUST be
        written and verified beside the ARC maximum as a quarter of it.
        """
        assert self.command is not None and self.new is not None
        self.native_identity()
        if int(self.get("quota")) > self.new["quotaBytes"]:
            raise ValueError("resource_decrease_requires_maintenance")
        cgroup = self.root / "sys/fs/cgroup/lilly.slice"
        maximum = (cgroup / "memory.max").read_text().strip()
        target = self.new["memoryMiB"] * 1048576
        if maximum == "max":
            raise ValueError("resource_decrease_requires_maintenance")
        if int(maximum) > target:
            current = int((cgroup / "memory.current").read_text().strip())
            if current + MEMORY_DECREASE_HEADROOM_BYTES > target:
                raise ValueError("resource_decrease_unsafe")
        quota, period = (cgroup / "cpu.max").read_text().split()
        if quota == "max" or int(quota) > self.new["cpuCores"] * int(period):
            raise ValueError("resource_decrease_requires_maintenance")
        self.command(
            [
                "systemctl",
                "set-property",
                "--runtime",
                "lilly.slice",
                "CPUQuota=" + str(self.new["cpuCores"] * 100) + "%",
                "MemoryMax=" + str(self.new["memoryMiB"] * 1048576),
            ]
        )
        self.command(["zfs", "set", "quota=" + str(self.new["quotaBytes"]), self.new["dataset"]])
        parameters = self.root / "sys/module/zfs/parameters"
        (parameters / "zfs_arc_max").write_text(str(self.new["arcMaxBytes"]))
        (parameters / "zfs_arc_dnode_limit").write_text(str(dnode_limit(self.new["arcMaxBytes"])))
        actual_quota, period = (cgroup / "cpu.max").read_text().split()
        if (
            actual_quota == "max"
            or int(actual_quota) != self.new["cpuCores"] * int(period)
            or int((cgroup / "memory.max").read_text()) != target
            or int(self.get("quota")) != self.new["quotaBytes"]
            or int((parameters / "zfs_arc_max").read_text()) != self.new["arcMaxBytes"]
            or int((parameters / "zfs_arc_dnode_limit").read_text())
            != dnode_limit(self.new["arcMaxBytes"])
        ):
            raise ValueError("resource_settings_unconfirmed")


def atomic_receipt(path: Path, value: Mapping[str, object]) -> None:
    """Publish an existing transition's reconciled receipt durably and privately."""
    temporary = path.with_name(path.name + ".new")
    with temporary.open("w") as stream:
        os.fchmod(stream.fileno(), 0o600)
        json.dump(value, stream, sort_keys=True)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
    fd = os.open(path.parent, os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def reapply(
    manifest: Mapping[str, object],
    command: Command | None,
    state: Path = Path("/var/lib/overalls-auto-update"),
    root: Path = Path("/"),
) -> None:
    """@cc [owner:ghuntley,label:recovery] resource-readiness-after-journal-replay
    Boot/activation MUST finish a matching pre-existing journal before host
    readiness checks receipts. Without that journal it MUST NOT manufacture
    or rewrite receipts. Explicit enrollment marked in progress MUST apply native
    settings but defer receipt replay until enrollment health publishes its new
    receipt. Replays retain original evidence and native GUID checks.
    """
    transition = Transition(manifest, manifest, command, atomic_receipt, state, root)
    enrollment = root / "var/lib/overalls-host/enrollment-in-progress.json"
    if enrollment.exists():
        transition.apply_native()
    elif transition.path.exists():
        transition.prepare()
        transition.apply()
    else:
        transition.apply_native()


def failure_reason(error: Exception) -> str:
    """@cc [owner:ghuntley,label:security;observability] resource-failure-diagnostics-closed
    Resource-policy failure diagnostics MUST return only reviewed reason enums;
    exception text, command arguments and command output MUST remain private.
    """
    if (
        isinstance(error, ValueError)
        and len(error.args) == 1
        and isinstance(error.args[0], str)
        and error.args[0] in RESOURCE_FAILURES
    ):
        return error.args[0]
    if isinstance(error, subprocess.CalledProcessError):
        return "resource_command_failed"
    if isinstance(error, OSError):
        filename = error.filename
        if isinstance(filename, str):
            if filename.endswith(("/cpu.max", "/memory.max")):
                return "resource_cgroup_unavailable"
            if filename.endswith(("/zfs_arc_max", "/zfs_arc_dnode_limit")):
                return "resource_arc_unavailable"
            if filename.endswith(".json"):
                return "resource_state_io_failed"
        return "resource_io_failed"
    return "resource_policy_invalid_state"


def main() -> None:
    manifest: dict[str, object] = json.loads(Path(sys.argv[1]).read_text())

    def command(argv: Sequence[str], capture: bool = False) -> str:
        return subprocess.check_output(argv, text=True).strip()

    reapply(manifest, command)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print("resource_policy_failed reason=" + failure_reason(error), file=sys.stderr)
        sys.exit(1)
