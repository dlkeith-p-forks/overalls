"""Run only in the disposable native-ZFS machine, whose pool and receipts this fixture owns."""

import copy
import importlib.util
import json
import subprocess
import types
from collections.abc import Sequence
from pathlib import Path


def load(name: str, path: str) -> types.ModuleType:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError("resource helper unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


resources = load("resources", "/etc/resource-policy.py")
updater = load("updater", "/etc/updater.py")


def command(argv: Sequence[str], **kwargs: object) -> str:
    return subprocess.check_output(argv, text=True).strip()


command(["systemd-run", "--unit=resource-guest", "--slice=lilly.slice", "sleep", "infinity"])
pid = command(["systemctl", "show", "resource-guest.service", "-p", "MainPID", "--value"])
pool = command(["zpool", "get", "-Hp", "-o", "value", "guid", "tank"])
dataset = command(["zfs", "get", "-Hp", "-o", "value", "guid", "tank/lilly"])
binding = {
    "identity": {"hostId": "aabbccdd"},
    "storage": {"quotaBytes": 2 * 2**30},
    "effective": {
        "pools": {"tank": {"datasets": {"lilly": {"options": {"quota": str(2 * 2**30)}}}}}
    },
}
old = {
    "installationBinding": binding,
    "resourcePolicy": {
        "version": 1,
        "dataset": "tank/lilly",
        "zpoolGuid": pool,
        "datasetGuid": dataset,
        "cpuCores": 1,
        "memoryMiB": 512,
        "quotaBytes": 2 * 2**30,
        "arcMaxBytes": 512 * 2**20,
    },
    "lilly": {
        "binding": {"guestCpuCores": 1, "guestMemoryMiB": 512},
        "owner": {
            "pools": [
                {"storage": {"dataset": "tank/lilly", "zpool_guid": pool, "dataset_guid": dataset}}
            ]
        },
    },
}
new = copy.deepcopy(old)
new["resourcePolicy"].update(
    cpuCores=2, memoryMiB=768, quotaBytes=3 * 2**30, arcMaxBytes=256 * 2**20
)
new["lilly"]["binding"].update(guestCpuCores=2, guestMemoryMiB=768)
new["installationBinding"]["storage"]["quotaBytes"] = 3 * 2**30
new["installationBinding"]["effective"]["pools"]["tank"]["datasets"]["lilly"]["options"][
    "quota"
] = str(3 * 2**30)
receipt = {"binding": binding, "poolGuid": pool, "datasetGuid": dataset}
directory = Path("/var/lib/overalls-host")
directory.mkdir(mode=0o700)
state = Path("/var/lib/resource-fixture")
state.mkdir(mode=0o700)
updater.atomic_json(directory / "storage.json", receipt)
updater.atomic_json(directory / "enrollment.json", {"storage": receipt, "revision": "0" * 40})
assert resources.compatible(old, new)
transition = resources.Transition(old, new, command, updater.atomic_json, state)
transition.prepare()
transition.apply_native()
# Enrollment can publish a newer authenticated revision while resource replay
# is pending; replay may update storage evidence but must keep that revision.
updater.atomic_json(directory / "enrollment.json", {"storage": receipt, "revision": "1" * 40})
# Boot/activation replay completes receipts before host readiness checks them.
resources.reapply(new, command, state)
assert json.loads((directory / "storage.json").read_text())["binding"] == new["installationBinding"]
assert (
    json.loads((directory / "enrollment.json").read_text())["storage"]["binding"]
    == new["installationBinding"]
)
assert json.loads((directory / "enrollment.json").read_text())["revision"] == "1" * 40
retry = resources.Transition(new, new, command, updater.atomic_json, state)
retry.prepare()
retry.apply()
assert command(["systemctl", "show", "resource-guest.service", "-p", "MainPID", "--value"]) == pid
assert json.loads((directory / "storage.json").read_text())["binding"] == new["installationBinding"]
assert retry.record["receipts"]["storage.json"]["binding"] == binding
assert (
    json.loads((directory / "enrollment.json").read_text())["storage"]["binding"]
    == new["installationBinding"]
)
assert json.loads((directory / "enrollment.json").read_text())["revision"] == "1" * 40
assert not resources.compatible(new, old)


def with_memory(manifest: dict[str, object], memory_mib: int) -> dict[str, object]:
    changed = copy.deepcopy(manifest)
    policy = changed["resourcePolicy"]
    lilly = changed["lilly"]
    assert isinstance(policy, dict) and isinstance(lilly, dict)
    binding = lilly["binding"]
    assert isinstance(binding, dict)
    policy["memoryMiB"] = memory_mib
    binding["guestMemoryMiB"] = memory_mib
    return changed


# The RAM ceiling may decrease live while the slice's use plus two GiB fits
# (ADR-0164): raise it far above physical memory first, then lower it to a
# ceiling that still leaves the headroom, then refuse one that does not.
raised = with_memory(new, 4096)
assert resources.compatible(new, raised)
resources.Transition(new, raised, command, updater.atomic_json, state).apply_native()
lowered = with_memory(raised, 2560)
assert resources.compatible(raised, lowered)
resources.Transition(raised, lowered, command, updater.atomic_json, state).apply_native()
assert Path("/sys/fs/cgroup/lilly.slice/memory.max").read_text().strip() == str(2560 * 1048576)
assert Path("/sys/module/zfs/parameters/zfs_arc_dnode_limit").read_text().strip() == str(
    256 * 2**20 // 4
)
unsafe = with_memory(lowered, 1024)
assert resources.compatible(lowered, unsafe)
try:
    resources.Transition(lowered, unsafe, command, updater.atomic_json, state).apply_native()
except ValueError as error:
    assert resources.failure_reason(error) == "resource_decrease_unsafe"
else:
    raise AssertionError("unsafe memory decrease was applied")
assert Path("/sys/fs/cgroup/lilly.slice/memory.max").read_text().strip() == str(2560 * 1048576)
assert command(["systemctl", "show", "resource-guest.service", "-p", "MainPID", "--value"]) == pid
print("native resource tuning passed")
