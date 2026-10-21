"""Independent bounded collector. No guest control calls and no payload diagnostics."""

import hashlib
import json
import os
import re
import selectors
import signal
import subprocess
import sys
import time
import uuid
from collections.abc import Sequence
from typing import TypedDict

import metrics
import terminal_metrics
from backup_status import backup_status

PROPERTIES = "Id,InvocationID,Description,ControlGroup,ActiveState,SubState,ExecMainStatus"
DESCRIPTION = re.compile(
    r"Overalls VM v1 placement=("
    + metrics.UUID.pattern
    + r") epoch=([1-9][0-9]{0,18}) generation=([1-9][0-9]{0,18})"
)
REVISION = re.compile(r"[0-9a-f]{40}")
UPDATER_PHASES = {
    "fetch",
    "build",
    "stage",
    "preflight",
    "migrate",
    "activate",
    "verify",
    "healthy",
    "never-run",
}


class Ziggy(TypedDict):
    socket: str
    host_id: str


class Config(TypedDict):
    port: int
    external_interfaces: list[str]
    services: list[str]
    backups_enabled: bool
    roles: list[str]
    lilly_host_id: str | None
    ziggy: Ziggy | None
    galileo: Ziggy | None
    curl: str
    systemctl: str
    ip: str
    zfs: str | None
    zpool: str | None


class SampleCore(TypedDict):
    sample_id: str
    version: int
    machine_id: str
    boot_id: str
    collector_id: str
    sequence: int
    sampled_at: float
    monotonic_seconds: float
    collection_seconds: float
    roles: list[str]
    records: list[metrics.SampledRecord]
    missing_sources: int
    failures: list[str]


class Sample(SampleCore, total=False):
    dropped_samples: int


class UpdaterStatus(TypedDict, total=False):
    deployment_revision: str
    intended_deployment_revision: str
    updater_phase: str
    updater_failure: str


def string(value: object) -> str:
    if not isinstance(value, str):
        raise ValueError("expected string")
    return value


def integer(value: object) -> int:
    if type(value) is not int:
        raise ValueError("expected integer")
    return value


def object_value(value: object) -> dict[str, object]:
    if not isinstance(value, dict):
        raise ValueError("expected object")
    return value


def object_list(value: object) -> list[object]:
    if not isinstance(value, list):
        raise ValueError("expected array")
    return value


def config_value(raw: object) -> Config:
    row = object_value(raw)
    ziggy = row.get("ziggy")
    return Config(
        port=integer(row["port"]),
        external_interfaces=[string(value) for value in object_list(row["external_interfaces"])],
        services=[string(value) for value in object_list(row["services"])],
        backups_enabled=bool(row["backups_enabled"]),
        roles=[string(value) for value in object_list(row["roles"])],
        lilly_host_id=(string(row["lilly_host_id"]) if row["lilly_host_id"] is not None else None),
        ziggy=(
            Ziggy(
                socket=string(object_value(ziggy)["socket"]),
                host_id=string(object_value(ziggy)["host_id"]),
            )
            if ziggy is not None
            else None
        ),
        galileo=(
            Ziggy(
                socket=string(object_value(row.get("galileo"))["socket"]),
                host_id=string(object_value(row.get("galileo"))["host_id"]),
            )
            if row.get("galileo") is not None
            else None
        ),
        curl=string(row["curl"]),
        systemctl=string(row["systemctl"]),
        ip=string(row["ip"]),
        zfs=string(row["zfs"]) if row["zfs"] is not None else None,
        zpool=string(row["zpool"]) if row["zpool"] is not None else None,
    )


def command(arguments: list[str], timeout: float = 1.5) -> str:
    """Bound output and elapsed time; discard stderr without logging command data."""
    with subprocess.Popen(
        arguments,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        stdin=subprocess.DEVNULL,
        start_new_session=True,
    ) as process:
        assert process.stdout is not None
        output = bytearray()
        deadline = time.monotonic() + timeout
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            try:
                while True:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0 or not selector.select(remaining):
                        raise TimeoutError("metric_command_timeout")
                    chunk = os.read(process.stdout.fileno(), 65536)
                    if not chunk:
                        if process.wait(timeout=max(0.01, deadline - time.monotonic())):
                            raise ValueError("metric_command_failed")
                        return output.decode("utf-8", errors="strict")
                    output.extend(chunk)
                    if len(output) > metrics.MAX_FILE:
                        raise ValueError("metric_output_limit")
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()


def parse_units(output: str, allowed_services: Sequence[str]) -> list[metrics.UnitRow]:
    result: list[metrics.UnitRow] = []
    for block in output.strip().split("\n\n")[:2048]:
        values: dict[str, str] = dict(
            line.split("=", 1) for line in block.splitlines() if "=" in line
        )
        unit = values.get("Id", "")
        invocation = values.get("InvocationID", "")
        if not metrics.UNIT.fullmatch(unit) or not re.fullmatch(r"[0-9a-f]{32}", invocation):
            continue
        base: metrics.UnitBase = {"unit": unit, "invocation_id": invocation}
        match = DESCRIPTION.fullmatch(values.get("Description", ""))
        if (
            match
            and unit == f"lilly-vm-{match[1]}.service"
            and values.get("ControlGroup") == f"/lilly.slice/{unit}"
        ):
            epoch, generation = int(match[2]), int(match[3])
            if epoch > metrics.MAX_INTEGER or generation > metrics.MAX_INTEGER:
                continue
            result.append(
                {
                    **base,
                    "kind": "vm",
                    "placement_id": match[1],
                    "execution_epoch": epoch,
                    "generation": generation,
                }
            )
        elif unit in allowed_services and values.get("ControlGroup") == f"/system.slice/{unit}":
            result.append(
                {
                    **base,
                    "kind": "service",
                    "active_state": values.get("ActiveState", "")[:32],
                    "sub_state": values.get("SubState", "")[:32],
                }
            )
    return result


def updater_status(reader: metrics.Reader) -> UpdaterStatus:
    """Read only allowlisted updater state; repository/configuration data stays private."""
    try:
        status: object = json.loads(reader.read("/var/lib/overalls-auto-update/status.json"))
        if not isinstance(status, dict):
            raise ValueError("invalid updater status")
        result: UpdaterStatus = {}
        healthy = object_value(status.get("lastHealthy") or {})
        candidate = object_value(status.get("candidate") or {})
        revision = healthy.get("revision")
        intended = candidate.get("revision")
        phase = status.get("phase")
        failure = status.get("failure")
        if isinstance(revision, str) and REVISION.fullmatch(revision):
            result["deployment_revision"] = revision
        if isinstance(intended, str) and REVISION.fullmatch(intended):
            result["intended_deployment_revision"] = intended
        if isinstance(phase, str) and phase in UPDATER_PHASES:
            result["updater_phase"] = phase
        if isinstance(failure, str) and re.fullmatch(r"[a-z_]{1,64}", failure):
            result["updater_failure"] = failure
        return result
    except (OSError, ValueError, TypeError, KeyError):
        return {}


def updater_observation(reader: metrics.Reader, now: float) -> metrics.SampledRecord:
    """Independent updater health survives inactive service/cgroup observation."""
    context: dict[str, object] = {"updater_phase": "unknown"}
    gauges: dict[str, metrics.Gauge] = {"status_valid": 0}
    try:
        value = object_value(json.loads(reader.read("/var/lib/overalls-auto-update/status.json")))
        phase = string(value["phase"])
        updated = integer(value["updatedAt"])
        failures = integer(value.get("failures", 0))
        failure = value.get("failure")
        if (
            phase not in UPDATER_PHASES
            or not 0 < updated <= now + 30
            or not 0 <= failures <= 16
            or (
                failure is not None
                and (not isinstance(failure, str) or not re.fullmatch(r"[a-z_]{1,64}", failure))
            )
        ):
            raise ValueError("invalid_updater_status")
        context["updater_phase"] = phase
        gauges.update(
            status_valid=int(now - updated <= 3600),
            status_updated_at_seconds=updated,
            failures=failures,
            failure_present=int(failure is not None),
        )
    except (OSError, ValueError, TypeError, KeyError):
        pass
    return metrics.record("updater", "updater", context, gauges=gauges)


ZIGGY_GAUGES = (
    "ziggy_active_requests",
    "ziggy_pending_receipts",
    "ziggy_spool_capacity",
    "ziggy_spool_available",
    "ziggy_models_openai",
    "ziggy_models_anthropic",
    "ziggy_catalog_ready",
)

GALILEO_GAUGES = (
    "galileo_active_requests",
    "galileo_total_requests",
)


def ziggy_metrics(config: Config) -> dict[str, int]:
    """@cc [owner:ghuntley,label:security] monitor-proxy-closed-projection
    Read only the configured local proxy socket, with bounded time/body and exact
    host identity. Only closed numeric measurements may leave the host. Failed
    observation MUST remain absent, never become measured zero or guest authority.
    """
    endpoint = config.get("ziggy")
    if not endpoint:
        return {}
    base = [
        config["curl"],
        "--silent",
        "--noproxy",
        "*",
        "--max-time",
        "0.8",
        "--max-filesize",
        "4096",
        "--unix-socket",
        endpoint["socket"],
    ]
    result: dict[str, int] = {}
    try:
        raw = command([*base, "--fail", "http://ziggy/metrics"], timeout=1)
        if len(raw) > 4096:
            return {}
        payload: object = json.loads(raw)
        if not isinstance(payload, dict):
            raise AttributeError("invalid ziggy payload")
        gauges = payload.get("gauges")
        if (
            set(payload) != {"version", "host_id", "gauges"}
            or payload["version"] != 1
            or payload["host_id"] != endpoint["host_id"]
            or not isinstance(gauges, dict)
            or set(gauges) != set(ZIGGY_GAUGES)
            or any(
                type(value) is not int or not 0 <= value <= 2**63 - 1 for value in gauges.values()
            )
            or any(
                gauges[key] not in (0, 1)
                for key in ("ziggy_spool_available", "ziggy_catalog_ready")
            )
        ):
            return {}
        result.update(gauges)
        raw = command([*base, "http://ziggy/health/ready"], timeout=1)
        if len(raw) <= 4096:
            health: object = json.loads(raw)
            if not isinstance(health, dict):
                raise TypeError("invalid ziggy health")
            if (
                set(health) == {"version", "host_id", "role", "ready"}
                and health["version"] == 1
                and health["host_id"] == endpoint["host_id"]
                and health["role"] == "ziggy"
                and type(health["ready"]) is bool
            ):
                result["ziggy_ready"] = int(health["ready"])
    except (OSError, ValueError, TypeError, KeyError, TimeoutError, subprocess.SubprocessError):
        pass
    return result


def galileo_metrics(config: Config) -> dict[str, int]:
    """@cc [owner:ghuntley,label:security] monitor-proxy-closed-projection
    Read only the configured local integration socket, with bounded time/body
    and exact host identity. Only closed numeric measurements may leave the
    host; failed observation MUST remain absent, never become measured zero.
    """
    endpoint = config.get("galileo")
    if not endpoint:
        return {}
    base = [
        config["curl"],
        "--silent",
        "--noproxy",
        "*",
        "--max-time",
        "0.8",
        "--max-filesize",
        "4096",
        "--unix-socket",
        endpoint["socket"],
    ]
    result: dict[str, int] = {}
    try:
        raw = command([*base, "--fail", "http://galileo/metrics"], timeout=1)
        if len(raw) > 4096:
            return {}
        payload: object = json.loads(raw)
        if not isinstance(payload, dict):
            raise AttributeError("invalid galileo payload")
        gauges = payload.get("gauges")
        if (
            set(payload) != {"version", "host_id", "gauges"}
            or payload["version"] != 1
            or payload["host_id"] != endpoint["host_id"]
            or not isinstance(gauges, dict)
            or set(gauges) != set(GALILEO_GAUGES)
            or any(
                type(value) is not int or not 0 <= value <= 2**63 - 1 for value in gauges.values()
            )
        ):
            return {}
        result.update(gauges)
        raw = command([*base, "http://galileo/health/ready"], timeout=1)
        if len(raw) <= 4096:
            health: object = json.loads(raw)
            if not isinstance(health, dict):
                raise TypeError("invalid galileo health")
            if (
                set(health) == {"version", "host_id", "role", "ready"}
                and health["version"] == 1
                and health["host_id"] == endpoint["host_id"]
                and health["role"] == "galileo"
                and type(health["ready"]) is bool
            ):
                result["galileo_ready"] = int(health["ready"])
    except (OSError, ValueError, TypeError, KeyError, TimeoutError, subprocess.SubprocessError):
        pass
    return result


def units(config: Config, updater: UpdaterStatus | None = None) -> list[metrics.UnitRow]:
    services = list(dict.fromkeys(config["services"] + ["overalls-auto-update.service"]))
    if not updater:
        updater = {}
    rows = parse_units(
        command(
            [
                config["systemctl"],
                "show",
                "--no-pager",
                f"--property={PROPERTIES}",
                "--",
                *services,
                "lilly-vm-*.service",
            ]
        ),
        services,
    )
    for index, row in enumerate(rows):
        if row["kind"] == "service" and row["unit"] == "overalls-auto-update.service":
            rows[index] = {**row, **updater}
    return rows


def vm_network(config: Config, workloads: Sequence[metrics.UnitRow]) -> list[metrics.SampledRecord]:
    host_id = config.get("lilly_host_id")
    if not host_id:
        return []
    if not metrics.UUID.fullmatch(host_id):
        raise ValueError("invalid_lilly_identity")
    namespace = "lilly-" + hashlib.sha256(host_id.encode()).hexdigest()[:12]
    namespace_inode = os.stat("/run/netns/" + namespace).st_ino
    links: object = json.loads(command([config["ip"], "-n", namespace, "-j", "-s", "link", "show"]))
    if not isinstance(links, list):
        raise TypeError("invalid_link_report")
    owners = {
        "lv" + hashlib.sha256(row["placement_id"].encode()).hexdigest()[:12]: row
        for row in workloads
        if row["kind"] == "vm"
    }
    result: list[metrics.SampledRecord] = []
    for link in links[:4096]:
        name, index = link.get("ifname"), metrics.number(link.get("ifindex"))
        if name not in owners or index is None:
            continue
        owner = owners[name]
        context: dict[str, object] = {
            "name": name,
            "scope": "vm",
            "namespace": namespace,
            "incarnation": f"{namespace_inode}:{index}:{owner['invocation_id']}",
            "placement_id": owner["placement_id"],
            "execution_epoch": owner["execution_epoch"],
        }
        stats = link.get("stats64", {})
        counters = {
            f"{side}_{key}": metrics.number(stats.get(side, {}).get(source))
            for side in ("rx", "tx")
            for key, source in (
                ("bytes", "bytes"),
                ("packets", "packets"),
                ("errors", "errors"),
                ("drops", "dropped"),
            )
        }
        result.append(
            metrics.record("interface", namespace + ":" + name, context, counters=counters)
        )
    return result


BRADY_COUNTERS = frozenset(
    [
        "requests",
        "errors",
        "cache_hits",
        "cache_misses",
        "cache_bypasses",
        "bytes_received",
        "bytes_sent",
        "duration_us",
    ]
)
BRADY_GAUGES = frozenset(
    [
        "cache_used_bytes",
        "cache_pending_bytes",
        "cache_objects",
        "cache_writers",
        "cache_readers",
        "cache_writable",
    ]
)


def brady_metrics(
    reader: metrics.Reader, workloads: Sequence[metrics.UnitRow], now: float
) -> metrics.SampledRecord:
    """@cc [owner:ghuntley,label:security;product] monitor-brady-fresh-aggregate
    Brady snapshots MUST match a currently active service invocation, be no more
    than forty-five seconds old and contain only fixed bounded numeric aggregates.
    Missing or invalid snapshots MUST remain unknown, never synthetic zeros.
    """
    unit = next((row for row in workloads if row["unit"] == "brady.service"), None)
    if unit is None or unit.get("active_state") != "active":
        raise ValueError("brady_collection_unavailable")
    data: object = json.loads(reader.read("/run/brady/metrics.json"))
    if (
        not isinstance(data, dict)
        or set(data)
        != {"version", "sampled_at", "incarnation", "invocation_id", "gauges", "counters"}
        or type(data["version"]) is not int
        or data["version"] != 1
        or type(data["sampled_at"]) is not int
        or not now - 45 <= data["sampled_at"] <= now + 1
        or data["invocation_id"] != unit["invocation_id"]
        or not isinstance(data["incarnation"], str)
        or not re.fullmatch(r"[0-9a-f]{32}", data["incarnation"])
    ):
        raise ValueError("brady_collection_unavailable")
    for family, allowed in (("gauges", BRADY_GAUGES), ("counters", BRADY_COUNTERS)):
        values = data[family]
        if (
            not isinstance(values, dict)
            or not set(values) <= allowed
            or any(
                type(value) is not int or not 0 <= value <= metrics.MAX_INTEGER
                for value in values.values()
            )
        ):
            raise ValueError("brady_collection_unavailable")
    if data["gauges"].get("cache_writable", 0) not in (0, 1):
        raise ValueError("brady_collection_unavailable")
    return metrics.record(
        "brady",
        "brady",
        {"unit": "brady.service", "incarnation": data["incarnation"]},
        gauges=data["gauges"],
        counters=data["counters"],
    )


def collect(
    config: Config,
    rates: metrics.Rates,
    session: str,
    sequence: int,
    include_zfs: bool = False,
) -> Sample:
    started = time.monotonic()
    reader = metrics.Reader()
    machine = metrics.host_identity(reader.read("/etc/machine-id"))
    boot = reader.read("/proc/sys/kernel/random/boot_id").strip()
    if not metrics.UUID.fullmatch(boot):
        raise ValueError("invalid_boot_identity")
    failures: list[str] = []
    rows = metrics.host_metrics(reader) + metrics.device_metrics(
        reader, config["external_interfaces"]
    )
    rows.append(updater_observation(reader, time.time()))
    status = backup_status(reader, config.get("backups_enabled", False), time.time())
    rows.append(
        metrics.record(
            status["kind"], status["id"], status["context"], status["gauges"], status["counters"]
        )
    )
    try:
        before = units(config, updater_status(reader))
        workload_rows = metrics.cgroup_metrics(reader, before)
        proxy = ziggy_metrics(config)
        terminals = terminal_metrics.collect(config.get("lilly_host_id"))
        guest_terminals = {
            (row["placement_id"], row["execution_epoch"], row["generation"]): row
            for row in terminals["vms"]
        }
        generations = {
            (row.get("placement_id"), row.get("execution_epoch")): row.get("generation")
            for row in before
            if row["kind"] == "vm"
        }
        integration = galileo_metrics(config)
        for row in workload_rows:
            if row["kind"] == "service" and row["id"] == "lilly.service":
                row["gauges"].update(terminals["gauges"])
                row["counters"].update(terminals["counters"])
            if row["kind"] == "vm":
                placement, epoch = (
                    row["context"].get("placement_id"),
                    row["context"].get("execution_epoch"),
                )
                observation = guest_terminals.get(
                    (placement, epoch, generations.get((placement, epoch)))
                )
                if observation:
                    row["gauges"]["terminal_reachable"] = observation["reachable"]
                    row["gauges"]["terminal_observation_age_ms"] = observation["age_ms"]
            if row["kind"] == "service" and row["id"] == "ziggy.service":
                row["gauges"].update(proxy)
            if row["kind"] == "service" and row["id"] == "galileo.service":
                row["gauges"].update(integration)
        try:
            network_rows = vm_network(config, before)
        except (OSError, ValueError, TimeoutError, subprocess.SubprocessError):
            network_rows = []
            failures.append("vm_network_unavailable")
        after = units(config, updater_status(reader))
        stable: set[tuple[object, object, object]] = {
            (row["unit"], row["invocation_id"], row.get("execution_epoch"))
            for row in before
            if row in after
        }
        rows.extend(
            row
            for row in workload_rows
            if (
                row["context"]["unit"],
                row["context"]["incarnation"],
                row["context"].get("execution_epoch"),
            )
            in stable
        )
        stable_placements: set[tuple[object, object]] = {
            (row.get("placement_id"), row.get("execution_epoch"))
            for row in before
            if row in after and row["kind"] == "vm"
        }
        rows.extend(
            row
            for row in network_rows
            if (row["context"]["placement_id"], row["context"]["execution_epoch"])
            in stable_placements
        )
        if "brady" in config["roles"]:
            try:
                rows.append(
                    brady_metrics(reader, [row for row in before if row in after], time.time())
                )
            except (OSError, ValueError, TypeError, KeyError):
                failures.append("brady_collection_unavailable")
        if len(stable) != len(before):
            failures.append("workload_identity_changed")
    except (OSError, ValueError, TimeoutError, subprocess.SubprocessError):
        failures.append("workload_collection_unavailable")
    if include_zfs and config["zfs"]:
        zpool = config["zpool"]
        if zpool is None:
            raise TypeError("invalid zfs tool configuration")
        try:
            pools = command(
                [
                    zpool,
                    "list",
                    "-Hp",
                    "-o",
                    "guid,name,size,allocated,free,fragmentation,capacity,health",
                ]
            )
            datasets = command(
                [
                    config["zfs"],
                    "list",
                    "-Hp",
                    "-t",
                    "filesystem,volume",
                    "-o",
                    "guid,name,used,available,referenced,logicalused,logicalreferenced,usedbysnapshots,usedbydataset,usedbychildren,usedbyrefreservation,quota,refquota,compressratio",
                ]
            )
            rows.extend(metrics.zfs_metrics(pools, datasets))
        except (OSError, ValueError, TimeoutError, subprocess.SubprocessError):
            failures.append("zfs_collection_unavailable")
    if len(rows) > metrics.MAX_ENTITIES:
        failures.append("entity_limit")
    sampled = time.monotonic()
    rows = rates.apply(rows[: metrics.MAX_ENTITIES], boot, sampled)
    return Sample(
        sample_id=str(uuid.uuid4()),
        version=1,
        machine_id=machine,
        boot_id=boot,
        collector_id=session,
        sequence=sequence,
        sampled_at=time.time(),
        monotonic_seconds=sampled,
        collection_seconds=sampled - started,
        roles=config["roles"],
        records=rows,
        missing_sources=len(reader.missing),
        failures=failures,
    )


def main(config: Config) -> None:
    from exporter import serve

    serve(config, collect)


if __name__ == "__main__":
    with open(sys.argv[1], encoding="utf-8") as stream:
        configuration = config_value(json.load(stream))
    main(configuration)
