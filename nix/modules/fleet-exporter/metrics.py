"""Bounded Linux measurements for fleet monitoring, independent of Lilly reports."""

import hashlib
import hmac
import math
import os
import re
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import TypedDict

MAX_FILE = 2 * 1024 * 1024
MAX_ENTITIES = 16384
MAX_INTEGER = 2**63 - 1
CPU_FIELDS = (
    "user",
    "nice",
    "system",
    "idle",
    "iowait",
    "irq",
    "softirq",
    "steal",
    "guest",
    "guest_nice",
)
MEMORY_FIELDS = (
    "MemTotal",
    "MemFree",
    "MemAvailable",
    "Buffers",
    "Cached",
    "SReclaimable",
    "Shmem",
    "SwapTotal",
    "SwapFree",
    "Dirty",
    "Writeback",
    "Slab",
    "PageTables",
    "KernelStack",
    "AnonPages",
    "Mapped",
)
CG_MEMORY_FIELDS = (
    "anon",
    "file",
    "kernel",
    "kernel_stack",
    "pagetables",
    "sock",
    "shmem",
    "file_mapped",
    "file_dirty",
    "file_writeback",
    "slab_reclaimable",
    "slab_unreclaimable",
)
UUID = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}")
UNIT = re.compile(r"[a-zA-Z0-9_.@:-]{1,200}\.service")

type Gauge = int | float


class UnitBase(TypedDict):
    unit: str
    invocation_id: str


class UnitRow(UnitBase, total=False):
    kind: str
    placement_id: str
    execution_epoch: int
    generation: int
    active_state: str
    sub_state: str
    deployment_revision: str
    intended_deployment_revision: str
    updater_phase: str
    updater_failure: str


type Snapshot = tuple[str, float, dict[str, object], dict[str, int]]


class Record(TypedDict):
    kind: str
    id: str
    context: dict[str, object]
    gauges: dict[str, Gauge]
    counters: dict[str, int]


class SampledRecord(Record, total=False):
    rates: dict[str, float]
    interval_seconds: float


def host_identity(value: str) -> str:
    """Match Lilly.Host.Identity; never export the raw machine ID."""
    # The HMAC label is frozen from before the product rename: enrolled host
    # identities were derived with it.
    if not re.fullmatch(r"[0-9a-f]{32}\n?", value) or int(value.strip(), 16) == 0:
        raise ValueError("invalid_machine_identity")
    return (
        "sha256:"
        + hmac.new(
            b"kittens.lilly.host.v1", bytes.fromhex(value.strip()), hashlib.sha256
        ).hexdigest()
    )


def number(value: object) -> int | None:
    if not isinstance(value, str | int | float):
        return None
    try:
        result = int(value)
        return result if 0 <= result <= MAX_INTEGER else None
    except (ValueError, TypeError):
        return None


def finite(value: object) -> float | None:
    if not isinstance(value, str | int | float):
        return None
    try:
        result = float(value)
        return result if math.isfinite(result) and 0 <= result <= MAX_INTEGER else None
    except (ValueError, TypeError):
        return None


def clean[T](values: Mapping[str, T | None]) -> dict[str, T]:
    return {key: value for key, value in values.items() if value is not None}


def pairs(text: str) -> dict[str, int | None]:
    return {p[0]: number(p[1]) for line in text.splitlines() if len(p := line.split()) == 2}


class Reader:
    def __init__(self, root: str = "/") -> None:
        self.root = Path(root)
        self.missing: set[str] = set()

    def path(self, path: str) -> Path:
        if not path.startswith("/") or ".." in Path(path).parts:
            raise ValueError("invalid_metric_path")
        return self.root / path.lstrip("/")

    def read(self, path: str) -> str:
        try:
            with self.path(path).open("r", encoding="ascii") as stream:
                value = stream.read(MAX_FILE + 1)
                if len(value) > MAX_FILE:
                    raise ValueError("metric_file_too_large")
                return value
        except (OSError, ValueError, UnicodeError):
            self.missing.add(path)
            return ""

    def exists(self, path: str) -> bool:
        return self.path(path).exists()


def pressure(reader: Reader, directory: str) -> tuple[dict[str, float], dict[str, int]]:
    gauges: dict[str, float | None] = {}
    counters: dict[str, int | None] = {}
    for resource in ("cpu", "memory", "io"):
        path = (
            f"{directory}/{resource}"
            if directory == "/proc/pressure"
            else f"{directory}/{resource}.pressure"
        )
        for line in reader.read(path).splitlines():
            parts = line.split()
            if not parts or parts[0] not in ("some", "full"):
                continue
            values = dict(part.split("=", 1) for part in parts[1:] if "=" in part)
            key = f"psi_{resource}_{parts[0]}"
            counters[key + "_usec"] = number(values.get("total"))
            for window in (10, 60, 300):
                value = finite(values.get(f"avg{window}"))
                gauges[f"{key}_avg{window}_percent"] = (
                    value if value is not None and value <= 100 else None
                )
    return clean(gauges), clean(counters)


def record(
    kind: str,
    identity: str,
    context: Mapping[str, object],
    gauges: Mapping[str, Gauge | None] | None = None,
    counters: Mapping[str, int | None] | None = None,
) -> SampledRecord:
    return {
        "kind": kind,
        "id": identity,
        "context": dict(context),
        "gauges": clean(gauges or {}),
        "counters": clean(counters or {}),
    }


def host_metrics(reader: Reader) -> list[SampledRecord]:
    result: list[SampledRecord] = []
    cpu_rows: list[SampledRecord] = []
    stat = reader.read("/proc/stat")
    for line in stat.splitlines():
        parts = line.split()
        if not parts or not re.fullmatch(r"cpu(?:[0-9]{1,5})?", parts[0]):
            continue
        if len(cpu_rows) >= 4097:
            break
        values = [number(value) for value in parts[1:11]]
        if len(values) < 8 or any(value is None for value in values):
            continue
        cpu_rows.append(
            record(
                "cpu",
                parts[0],
                {"scope": "aggregate" if parts[0] == "cpu" else "core"},
                counters=dict(zip(CPU_FIELDS, values, strict=False)),
            )
        )
    result.extend(cpu_rows)
    mem: dict[str, int] = {}
    for line in reader.read("/proc/meminfo").splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[0].rstrip(":") in MEMORY_FIELDS and parts[2] == "kB":
            value = number(parts[1])
            if value is not None and value <= MAX_INTEGER // 1024:
                mem[parts[0].rstrip(":") + "_bytes"] = value * 1024
    if (
        "MemTotal_bytes" in mem
        and "MemAvailable_bytes" in mem
        and mem["MemAvailable_bytes"] <= mem["MemTotal_bytes"]
    ):
        mem["memory_used_bytes"] = mem["MemTotal_bytes"] - mem["MemAvailable_bytes"]
    load = reader.read("/proc/loadavg").split()
    gauges: dict[str, Gauge | None] = {
        f"load_{window}": finite(value) for window, value in zip((1, 5, 15), load[:3], strict=False)
    }
    gauges.update(mem)
    core_count = sum(row["id"] != "cpu" for row in cpu_rows)
    if core_count:
        gauges["cpu_cores"] = core_count
    vmstat = pairs(reader.read("/proc/vmstat"))
    counters: dict[str, int | None] = {
        key: vmstat.get(key)
        for key in ("oom_kill", "pswpin", "pswpout", "pgfault", "pgmajfault", "pgpgin", "pgpgout")
    }
    p_gauges, p_counters = pressure(reader, "/proc/pressure")
    gauges.update(p_gauges)
    counters.update(p_counters)
    result.insert(0, record("host", "host", {"source": "linux_procfs"}, gauges, counters))
    return result


def device_metrics(
    reader: Reader,
    external_interfaces: Sequence[str] = (),
    vm_interfaces: Mapping[str, Mapping[str, object]] | None = None,
) -> list[SampledRecord]:
    result: list[SampledRecord] = []
    for line in reader.read("/proc/diskstats").splitlines()[:4096]:
        parts = line.split()
        if len(parts) < 14 or not re.fullmatch(r"[a-zA-Z0-9_.!-]{1,128}", parts[2]):
            continue
        major, minor, name = parts[:3]
        if number(major) is None or number(minor) is None:
            continue
        values = [number(value) for value in parts[3:14]]
        if any(value is None for value in values):
            continue
        # Linux diskstats sectors are 512 bytes, independent of device block size.
        counters = dict(
            zip(
                (
                    "read_ops",
                    "read_merges",
                    "read_sectors",
                    "read_ms",
                    "write_ops",
                    "write_merges",
                    "write_sectors",
                    "write_ms",
                    "inflight",
                    "busy_ms",
                    "weighted_ms",
                ),
                values,
                strict=False,
            )
        )
        inflight = counters.pop("inflight")
        context: dict[str, object] = {
            "name": name,
            "source": "linux_diskstats",
            "sector_bytes": 512,
            "partition": reader.exists(f"/sys/class/block/{name}/partition"),
            "physical": reader.exists(f"/sys/class/block/{name}/device"),
        }
        # diskseq distinguishes reuse of the same kernel major/minor identity.
        diskseq = number(reader.read(f"/sys/class/block/{name}/diskseq").strip())
        context["incarnation"] = str(diskseq) if diskseq is not None else None
        result.append(record("disk", f"{major}:{minor}", context, {"inflight": inflight}, counters))
    for line in reader.read("/proc/net/dev").splitlines()[:4098]:
        if ":" not in line:
            continue
        name, values = line.rsplit(":", 1)
        name = name.strip()
        if not re.fullmatch(r"[a-zA-Z0-9_.-]{1,15}", name):
            continue
        values = [number(value) for value in values.split()]
        if len(values) != 16 or any(value is None for value in values):
            continue
        index = number(reader.read(f"/sys/class/net/{name}/ifindex").strip())
        context = {
            "name": name,
            "incarnation": str(index) if index is not None else None,
            "scope": "external" if name in external_interfaces else "virtual",
        }
        owner = (vm_interfaces or {}).get(name, {})
        placement, epoch = owner.get("placement_id"), owner.get("execution_epoch")
        if isinstance(placement, str) and UUID.fullmatch(placement) and number(epoch) is not None:
            context.update(placement_id=placement, execution_epoch=epoch, scope="vm")
        counters = {
            f"{side}_{key}": values[offset + i]
            for side, offset in (("rx", 0), ("tx", 8))
            for i, key in enumerate(("bytes", "packets", "errors", "drops"))
        }
        result.append(record("interface", name, context, counters=counters))
    return result


def zfs_metrics(pool_output: str, dataset_output: str) -> list[SampledRecord]:
    """ZFS accounting is separate from physical block I/O and VM promised sizes."""
    result: list[SampledRecord] = []
    for line in pool_output.splitlines()[:1024]:
        fields = line.split("\t")
        if len(fields) != 8:
            continue
        guid, name, *values, health = fields
        if not valid_guid(guid) or not re.fullmatch(r"[a-zA-Z][a-zA-Z0-9_.:-]{0,127}", name):
            continue
        context = {
            "name": name,
            "source": "zpool_list",
            "incarnation": guid,
            "health": health
            if health
            in ("ONLINE", "DEGRADED", "FAULTED", "OFFLINE", "UNAVAIL", "REMOVED", "SUSPENDED")
            else "UNKNOWN",
        }
        result.append(
            record(
                "zpool",
                guid,
                context,
                dict(
                    zip(
                        (
                            "size_bytes",
                            "allocated_bytes",
                            "free_bytes",
                            "fragmentation_percent",
                            "capacity_percent",
                        ),
                        [number(value) for value in values],
                        strict=False,
                    )
                ),
            )
        )
    for line in dataset_output.splitlines()[:8192]:
        fields = line.split("\t")
        if len(fields) != 14:
            continue
        guid, name, *values, ratio = fields
        if not valid_guid(guid) or not re.fullmatch(r"[a-zA-Z][a-zA-Z0-9_.:/-]{0,255}", name):
            continue
        gauges: dict[str, Gauge | None] = dict(
            zip(
                (
                    "used_bytes",
                    "available_bytes",
                    "referenced_bytes",
                    "logical_used_bytes",
                    "logical_referenced_bytes",
                    "snapshots_used_bytes",
                    "dataset_used_bytes",
                    "children_used_bytes",
                    "reservation_used_bytes",
                    "quota_bytes",
                    "refquota_bytes",
                ),
                [number(value) for value in values],
                strict=False,
            )
        )
        gauges["compression_ratio"] = finite(ratio[:-1]) if ratio.endswith("x") else None
        context = {
            "name": name,
            "source": "zfs_list",
            "incarnation": guid,
            "pool": name.split("/")[0],
            "parent": name.rsplit("/", 1)[0] if "/" in name else None,
            "quota_unlimited": gauges["quota_bytes"] == 0,
            "refquota_unlimited": gauges["refquota_bytes"] == 0,
        }
        result.append(record("dataset", guid, context, gauges))
    return result


def valid_guid(value: str) -> bool:
    return bool(re.fullmatch(r"[1-9][0-9]{0,19}", value)) and int(value) <= 2**64 - 1


def cgroup_metrics(reader: Reader, workloads: Sequence[UnitRow]) -> list[SampledRecord]:
    """@cc [owner:ghuntley,label:security] monitor-cgroup-exact-attribution
    Workloads MUST have an explicit unit invocation and a confined unit cgroup.
    VM units MUST bind a placement UUID and execution epoch. Never read processes,
    command lines or environments; nested cgroups remain within their unit total.
    """
    result: list[SampledRecord] = []
    for workload in workloads[:2048]:
        kind, unit, invocation = (workload.get(key) for key in ("kind", "unit", "invocation_id"))
        if (
            not isinstance(kind, str)
            or kind not in ("vm", "service")
            or not isinstance(unit, str)
            or not UNIT.fullmatch(unit)
        ):
            continue
        if not isinstance(invocation, str) or not re.fullmatch(r"[0-9a-f]{32}", invocation):
            continue
        context: dict[str, object] = {"unit": unit, "incarnation": invocation}
        for key in (
            "active_state",
            "sub_state",
            "deployment_revision",
            "intended_deployment_revision",
            "updater_phase",
            "updater_failure",
        ):
            if workload.get(key):
                context[key] = workload[key]
        if kind == "vm":
            placement, epoch = workload.get("placement_id"), workload.get("execution_epoch")
            if (
                not isinstance(placement, str)
                or not UUID.fullmatch(placement)
                or number(epoch) is None
                or unit != f"lilly-vm-{placement}.service"
            ):
                continue
            context.update(placement_id=placement, execution_epoch=epoch)
            directory = f"/sys/fs/cgroup/lilly.slice/{unit}"
            identity = placement
        else:
            directory = f"/sys/fs/cgroup/system.slice/{unit}"
            identity = unit
        memory_values = {
            key: reader.read(f"{directory}/{key}").strip()
            for key in ("memory.current", "memory.swap.current", "memory.max", "memory.swap.max")
        }
        gauges: dict[str, Gauge | None] = {
            key.replace(".", "_") + "_bytes": number(value) for key, value in memory_values.items()
        }
        for key in ("memory.max", "memory.swap.max"):
            if memory_values[key] == "max":
                context[key.replace(".", "_") + "_unlimited"] = True
        mem = pairs(reader.read(f"{directory}/memory.stat"))
        gauges.update({"memory_" + key + "_bytes": mem.get(key) for key in CG_MEMORY_FIELDS})
        counters: dict[str, int | None] = {
            "cpu_" + key: value
            for key, value in pairs(reader.read(f"{directory}/cpu.stat")).items()
            if key
            in (
                "usage_usec",
                "user_usec",
                "system_usec",
                "nr_periods",
                "nr_throttled",
                "throttled_usec",
            )
        }
        events = pairs(reader.read(f"{directory}/memory.events"))
        counters.update(
            {
                "memory_" + key: events.get(key)
                for key in ("low", "high", "max", "oom", "oom_kill", "oom_group_kill")
            }
        )
        quota = reader.read(f"{directory}/cpu.max").split()
        if len(quota) == 2 and number(quota[0]) is not None and number(quota[1]):
            gauges["cpu_limit_cores"] = int(quota[0]) / int(quota[1])
        elif len(quota) == 2 and quota[0] == "max" and number(quota[1]):
            context["cpu_limit_unlimited"] = True
        pg, pc = pressure(reader, directory)
        gauges.update(pg)
        counters.update(pc)
        for line in reader.read(f"{directory}/io.stat").splitlines()[:4096]:
            parts = line.split()
            if not parts or not re.fullmatch(r"[0-9]+:[0-9]+", parts[0]):
                continue
            io = dict(item.split("=", 1) for item in parts[1:] if "=" in item)
            # Workload I/O has its own allowlisted context in Marshall. Service
            # lifecycle fields describe the service record and must not be
            # copied into the workload I/O projection.
            io_context = {
                key: value
                for key, value in context.items()
                if key
                in (
                    "unit",
                    "incarnation",
                    "placement_id",
                    "execution_epoch",
                    "memory_max_unlimited",
                    "memory_swap_max_unlimited",
                    "cpu_limit_unlimited",
                )
            }
            result.append(
                record(
                    "workload_io",
                    f"{kind}:{identity}:{parts[0]}",
                    dict(io_context, workload_kind=kind, workload_id=identity, device=parts[0]),
                    counters={
                        key: number(io.get(key))
                        for key in ("rbytes", "wbytes", "rios", "wios", "dbytes", "dios")
                    },
                )
            )
        result.append(record(kind, identity, context, gauges, counters))
        if len(result) >= MAX_ENTITIES:
            return result[:MAX_ENTITIES]
    return result


class Rates:
    """@cc [owner:ghuntley,label:product] monitor-rate-valid-pairs
    Rates MUST use monotonic elapsed time from matching boot/entity context.
    Missing incarnations for reusable identities, gaps over 15 seconds, counter
    decreases and first observations MUST produce no rate for affected counters.
    CPU guest time MUST NOT be counted twice in breakdowns or total utilization.
    """

    def __init__(self, ticks: int | None = None) -> None:
        self.previous: dict[tuple[str, str], Snapshot] = {}
        self.ticks = ticks or os.sysconf("SC_CLK_TCK")

    def apply(
        self, records: list[SampledRecord], boot: str, monotonic: float
    ) -> list[SampledRecord]:
        current: dict[tuple[str, str], Snapshot] = {}
        for row in records[:MAX_ENTITIES]:
            key = (row["kind"], row["id"])
            previous = self.previous.get(key)
            current[key] = (boot, monotonic, row["context"].copy(), row["counters"].copy())
            row["rates"] = {}
            if row["kind"] not in ("host", "cpu", "zpool", "dataset") and not row["context"].get(
                "incarnation"
            ):
                continue
            if not previous or previous[0] != boot or previous[2] != row["context"]:
                continue
            elapsed = monotonic - previous[1]
            if not 0 < elapsed <= 15:
                continue
            deltas = {
                name: value - previous[3][name]
                for name, value in row["counters"].items()
                if name in previous[3] and value >= previous[3][name]
            }
            row["rates"] = {name: value / elapsed for name, value in deltas.items()}
            row["interval_seconds"] = elapsed
            if row["kind"] == "cpu" and all(name in deltas for name in CPU_FIELDS[:8]):
                total = sum(deltas[name] for name in CPU_FIELDS[:8])
                if total > 0:
                    adjusted = dict(deltas)
                    adjusted["user"] -= deltas.get("guest", 0)
                    adjusted["nice"] -= deltas.get("guest_nice", 0)
                    if min(adjusted.values()) >= 0:
                        row["gauges"].update(
                            {
                                "cpu_" + name + "_percent": value * 100 / total
                                for name, value in adjusted.items()
                            }
                        )
                        row["gauges"]["cpu_busy_cores"] = (
                            (total - deltas["idle"] - deltas["iowait"]) / self.ticks / elapsed
                        )
        self.previous = current
        return records
