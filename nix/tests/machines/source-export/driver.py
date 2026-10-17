import json
import shlex

storage.start()
storage.wait_for_unit("multi-user.target")
storage.succeed(
    "zpool create -f -O compression=lz4 -O mountpoint=/tank tank mirror /dev/vdb /dev/vdc",
    "zfs create -o mountpoint=/pool -o quota=6G tank/lilly",
    "zfs-lifecycle prepare 1",
)
# Real changed guest-disk blocks make the full send large enough that a stalled
# reader's kernel pipe cannot absorb it before revocation is exercised. The
# fixture has no VMM: the source disk is physically stopped (ADR-0155).
disk = "/pool/vms/dddddddd-dddd-4ddd-8ddd-000000000001/rootfs.ext4"
storage.succeed(
    "head -c 4194304 /dev/urandom > /run/relocation-delta",
    f"debugfs -w -R 'write /run/relocation-delta /relocation-delta' {disk}",
    "rm /run/relocation-delta",
    "zfs-lifecycle transfer-final 1",
    "zfs-lifecycle export-descriptor 1",
    "zfs-lifecycle export 1",
    "zfs-lifecycle permit-issue 1",
    "zfs-lifecycle permit-lookup 1",
)
child = "tank/lilly/vm-dddddddd-dddd-4ddd-8ddd-000000000001"
original = json.loads(storage.succeed("cat /run/export-descriptor.json"))
assert set(original["stream"]) == {"source_dataset_guid", "to_guid"}

with subtest("authorized full sender produces a valid native stream without control bytes"):
    storage.succeed(
        "bash -o pipefail -c 'source-export-control run | zfs receive -u -o mountpoint=none tank/received'"
    )
    received = storage.succeed("zfs get -Hp -o value guid tank/received@lilly-b").strip()
    assert received == original["stream"]["to_guid"]


def write_descriptor(value: dict[str, object]) -> None:
    storage.succeed(
        "printf %s " + shlex.quote(json.dumps(value)) + " > /run/export-descriptor.json"
    )


with subtest("export refuses stale authority, wrong lineage and missing ownership without repair"):
    for field, value in [
        ("source_epoch", 2),
        ("relocation_id", "ffffffff-ffff-4fff-8fff-000000000099"),
    ]:
        changed = dict(original)
        changed[field] = value
        if field == "source_epoch":
            changed["destination_epoch"] = 3
        write_descriptor(changed)
        storage.succeed("zfs-lifecycle reject-export 1")
    for stream in [
        dict(original["stream"], to_guid="999"),
        # Removed pre-copy lineage fields make the descriptor foreign (ADR-0155).
        dict(original["stream"], kind="full", from_guid=None),
    ]:
        changed = dict(original)
        changed["stream"] = stream
        write_descriptor(changed)
        storage.succeed("zfs-lifecycle reject-export 1")
    write_descriptor(original)
    storage.succeed(
        "mv /pool/.lilly-zfs/owner.json /run/parent-owner.json",
        "zfs-lifecycle reject-export 1",
        "PERMIT_REVISION=2 zfs-lifecycle reject-permit-issue 1",
    )
    storage.fail("test -e /pool/.lilly-zfs/owner.json")
    storage.succeed(
        "mv /run/parent-owner.json /pool/.lilly-zfs/owner.json",
        f"zfs snapshot {child}@foreign",
        "zfs-lifecycle reject-export 1",
        f"zfs destroy {child}@foreign",
        "zfs-lifecycle export 1",
    )

with subtest("revocation reaps a blocked full sender and fences every later grant"):
    storage.succeed(
        "PERMIT_REVISION=2 zfs-lifecycle permit-issue 1",
        "zfs-lifecycle permit-lookup 1",
    )

    # A FIFO reader that never drains backpressures the real ZFS sender. Native
    # revocation must kill/reap that blocked process before confirming quiescence.
    storage.succeed(
        "mkfifo /run/export-stall",
        "systemd-run --unit=stalled-export sh -c '/run/current-system/sw/bin/source-export-control run > /run/export-stall'",
        'systemd-run --unit=stalled-reader python3 -c \'import time; f=open("/run/export-stall", "rb"); time.sleep(120)\'',
    )
    storage.wait_until_succeeds(
        "pgrep -f '^/[^ ]*/lilly-source-export /run/source-permits/exports/'"
    )
    storage.wait_until_succeeds("pgrep -f '^/[^ ]*/zfs send '")
    senders = storage.succeed("pgrep -f '^/[^ ]*/zfs send '").split()
    storage.succeed("zfs-lifecycle snapshot 1")
    for pid in senders:
        storage.succeed(f"kill -0 {pid}")
    storage.wait_until_succeeds("source-export-control revoke")
    for pid in senders:
        storage.fail(f"test -e /proc/{pid}")
    storage.fail("source-export-control run > /run/revoked.stream")
    storage.succeed("test ! -s /run/revoked.stream", "systemctl stop stalled-export stalled-reader")
    storage.succeed(
        "zfs-lifecycle permit-fence 1",
        "zfs-lifecycle reject-permit-lookup 1",
        "PERMIT_REVISION=3 zfs-lifecycle reject-permit-issue 1",
        "zfs-lifecycle transfer-cleanup 1",
        "zfs-lifecycle reject-export 1",
        "zfs-lifecycle delete 1",
        "zfs-lifecycle prepare 2",
        "ZFS_RELOCATION=ffffffff-ffff-4fff-8fff-000000000002 zfs-lifecycle transfer-final 2",
        "ZFS_RELOCATION=ffffffff-ffff-4fff-8fff-000000000002 zfs-lifecycle export-descriptor 2",
        "zfs-lifecycle export 2",
        "zfs-lifecycle permit-fence 2",
        "zfs-lifecycle reject-permit-issue 2",
    )
    storage.succeed(
        "ZFS_RELOCATION=ffffffff-ffff-4fff-8fff-000000000002 zfs-lifecycle transfer-cleanup 2",
        "zfs-lifecycle reject-export 2",
        "zfs-lifecycle delete 2",
    )
