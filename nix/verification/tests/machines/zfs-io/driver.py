import json
import time
from typing import TypedDict


class Capacity(TypedDict):
    id: str
    total_bytes: int
    free_bytes: int
    allocations: dict[str, object]


class PoolObservation(TypedDict):
    capacity: Capacity
    io: dict[str, object]


def object_fields(value: object) -> dict[str, object]:
    assert isinstance(value, dict)
    assert all(isinstance(key, str) for key in value)
    return {key: item for key, item in value.items() if isinstance(key, str)}


def integer(value: object) -> int:
    assert isinstance(value, int) and not isinstance(value, bool)
    return value


def text(value: object) -> str:
    assert isinstance(value, str)
    return value


def observation(value: object) -> PoolObservation:
    fields = object_fields(value)
    assert set(fields) == {"capacity", "io"}
    capacity = object_fields(fields["capacity"])
    assert set(capacity) == {"id", "total_bytes", "free_bytes", "allocations"}
    io = object_fields(fields["io"])
    assert all(item is None or isinstance(item, str | int | float) for item in io.values())
    return {
        "capacity": {
            "id": text(capacity["id"]),
            "total_bytes": integer(capacity["total_bytes"]),
            "free_bytes": integer(capacity["free_bytes"]),
            "allocations": object_fields(capacity["allocations"]),
        },
        "io": io,
    }


# @cc [owner:ghuntley,label:verification] zfs-io-native-interval
# Pool I/O checks MUST use actual ZFS virtual disks and the source-built Lilly
# Collector and independent ZFSIO sampler. Pool-wide logical operations MUST NOT
# be labeled VM/device operations or enter the control capacity report. A real
# reload MUST invalidate rates while independently measured capacity remains usable.
storage.start()
storage.wait_for_unit("multi-user.target")
storage.succeed(
    "zpool create -f -O compression=lz4 -O mountpoint=/tank tank mirror /dev/vdb /dev/vdc"
)
storage.succeed("zpool create -f -O compression=lz4 -O mountpoint=/archive archive /dev/vdd")
storage.succeed("zfs create -o mountpoint=/pool -o quota=512M tank/lilly")
storage.succeed("zfs create -o mountpoint=/otherpool -o quota=512M archive/lilly")
storage.succeed(
    "mkdir -p /run/zfs-io-fault/bin && ln -s /etc/zfs-io-fault /run/zfs-io-fault/bin/zpool"
)


def sample(fault: str = "") -> dict[str, PoolObservation]:
    command = "zfs-io" if not fault else f"ZFS_IO_FAULT={fault} zfs-io"
    raw: object = json.loads(storage.succeed(command))
    assert isinstance(raw, list)
    pools = [observation(value) for value in raw]
    assert len(pools) == 2
    result = {text(pool["io"]["zpool_name"]): pool for pool in pools}
    assert set(result) == {"tank", "archive"}
    return result


def measured(pools: dict[str, PoolObservation]) -> None:
    for name in ["tank", "archive"]:
        pool = pools[name]
        io = pool["io"]
        assert io["status"] == "measured", io
        assert io["source"] == "openzfs_zpool_iostat"
        assert io["scope"] == "zpool" and io["kind"] == "logical"
        assert io["requested_interval_ms"] == 1000
        assert io["sample_interval_ms"] is None
        assert integer(io["collection_elapsed_ms"]) >= 1000
        assert io["rate_clock"] == "openzfs_vdev_timestamp"
        assert (
            io["zpool_load_guid"]
            == storage.succeed(f"zpool get -Hp -o value load_guid {name}").strip()
        )
        for key in ["read_iops", "write_iops", "read_bytes_per_second", "write_bytes_per_second"]:
            assert integer(io[key]) >= 0
        for key in [
            "read_latency_ms",
            "write_latency_ms",
            "average_queue_depth",
            "busy_percent",
        ]:
            assert io[key] is None
        assert "max_iops" not in io
        capacity = pool["capacity"]
        assert 0 < capacity["free_bytes"] <= capacity["total_bytes"] <= 512 * 1024 * 1024
        assert capacity["allocations"] == {}


measured(sample())
# Deliberately write outside Lilly's dataset. This proves the claimed pool scope.
# Disabling data cache is only a fixture workload control, not a deployment default.
storage.succeed("zfs create -o mountpoint=/outside -o primarycache=metadata tank/workload")
storage.succeed("dd if=/dev/urandom of=/outside/read bs=1M count=8 conv=fsync status=none")
storage.succeed("systemctl start io-workload.service io-reader.service")
storage.wait_until_succeeds("test -s /outside/io && test -f /run/zfs-io-read-completed")
pools = sample()
measured(pools)
for metric in ["read_iops", "write_iops", "read_bytes_per_second", "write_bytes_per_second"]:
    assert integer(pools["tank"]["io"][metric]) > 0, pools["tank"]["io"]
storage.succeed("systemctl stop io-workload.service io-reader.service")

for fault in ["malformed", "timeout", "reload"]:
    old_guid = storage.succeed("zpool get -Hp -o value guid tank").strip()
    old_load = storage.succeed("zpool get -Hp -o value load_guid tank").strip()
    started = time.monotonic()
    pools = sample(fault)
    assert time.monotonic() - started < 30
    for pool in pools.values():
        io = pool["io"]
        assert io["status"] == "unavailable"
        for key in [
            "read_iops",
            "write_iops",
            "read_bytes_per_second",
            "write_bytes_per_second",
            "zpool_load_guid",
        ]:
            assert io[key] is None
        assert pool["capacity"]["free_bytes"] > 0 and pool["capacity"]["allocations"] == {}
    if fault == "reload":
        assert storage.succeed("zpool get -Hp -o value guid tank").strip() == old_guid
        assert storage.succeed("zpool get -Hp -o value load_guid tank").strip() != old_load
    measured(sample())
