prepare(host)
# Log every write the host pool issues from its creation: the replay base is the
# all-zero data disk, so the journal prefix alone reconstructs the device.
host.succeed("modprobe dm-log-writes")
host.succeed(
    'dmsetup create lw --table "0 $(blockdev --getsz /dev/vdc) log-writes /dev/vdc /dev/vdd"'
)
pool(host, "/dev/mapper/lw")
# Keep every non-ZIL change volatile until the cut: only an explicit guest flush
# (virtio flush -> VMM fsync -> ZIL commit -> device flush) can make bytes durable.
# The canary lives in its own dataset, so the guest file's ZIL commits cannot
# carry it; only a transaction-group sync could make it durable.
host.succeed("zfs create -o mountpoint=/canary tank/canary && zpool sync tank")
host.succeed(
    "echo 3600 > /sys/module/zfs/parameters/zfs_txg_timeout"
    " && echo 100 > /sys/module/zfs/parameters/zfs_dirty_data_sync_percent"
)
run(
    host,
    "power-loss-before",
    "/work/before",
    " --cut-device lw --canary /canary/host-canary",
)
host.succeed(
    "echo 5 > /sys/module/zfs/parameters/zfs_txg_timeout"
    " && echo 20 > /sys/module/zfs/parameters/zfs_dirty_data_sync_percent"
)
# Writes after the mark (export, removal) are excluded by the replay.
host.succeed("zpool export tank")
host.succeed("dmsetup remove lw")
host.succeed("blockdev --flushbufs /dev/vdd")
# Remove the live data disk's labels so only the replayed device can supply the pool.
host.succeed("zpool labelclear -f /dev/vdc || zpool labelclear -f /dev/vdc1")
host.succeed(
    f"python3 {TOOLS}/native_write_log.py --log /dev/vdd --target /dev/vde"
    " --cut power-cut --receipt /work/replay.json",
    timeout=1800,
)
print(host.succeed("cat /work/replay.json"), flush=True)
host.succeed(
    "blockdev --flushbufs /dev/vde && (blockdev --rereadpt /dev/vde || true) && udevadm settle"
)
host.succeed(
    "zpool import -o cachefile=none -d /dev/vde $(test -e /dev/vde1 && echo -d /dev/vde1) tank"
)
host.succeed("zpool status -P tank | grep -q /dev/vde")
host.succeed("zpool status -x tank")
run(
    host,
    "power-loss-after",
    "/work/after",
    " --prior /work/before/prior.json --replay /work/replay.json --canary /canary/host-canary",
)
host.succeed(
    "jq -e '.version == 1 and .native_admission == false"
    f' and .os == "{os_name}"'
    ' and .boot_endings == ["power-cut", "clean"]'
    " and (.checks | length == 9) and (.boot_ids | unique | length == 2)"
    " and .replay.writes_applied > 0 and .replay.flushes_before_cut > 0"
    ' and ([.replay.segments[] | select(.mark == "guest-flush-requested") | .flushes][0] > 0)\''
    " /work/after/power-loss-receipt.json"
)
print(host.succeed("cat /work/after/power-loss-receipt.json"), flush=True)
host.copy_from_vm("/work/after/power-loss-receipt.json")
