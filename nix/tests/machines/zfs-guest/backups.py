"""Actual Firecracker flush, owned snapshots, transfer coexistence and disk restore."""

import json
import shlex
import uuid

storage.start()
storage.wait_for_unit("multi-user.target")
storage.succeed("test -c /dev/kvm", "systemctl is-active lilly.slice")
storage.succeed(
    "zpool create -f -O compression=lz4 -O mountpoint=/tank tank mirror /dev/vdb /dev/vdc"
)
(
    base_disk_bytes,
    grown_disk_bytes,
    pool_quota_bytes,
    base_memory_bytes,
    grown_memory_bytes,
) = create_guest_pool()
storage.succeed("zfs-guest start 1", "zfs-guest write", "zfs-guest backup-config")
vm = "dddddddd-dddd-4ddd-8ddd-000000000101"
pool = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
child = "tank/lilly/vm-" + vm
request: dict[str, object] = {"id": vm, "pool_id": pool, "run_id": str(uuid.uuid4())}


def backup(operation: str, value: dict[str, object]) -> dict[str, object]:
    body = shlex.quote(json.dumps(value))
    storage.succeed("umask 077; printf '%s' " + body + " > /run/backup-request.json")
    response: object = json.loads(
        storage.succeed("zfs-backup " + operation + " /run/backup-request.json", timeout=60)
    )
    assert isinstance(response, dict)
    result: dict[str, object] = {}
    for key, item in response.items():
        assert isinstance(key, str)
        result[key] = item
    return result


def snapshot_audit(phase: str) -> str:
    """@cc [owner:ghuntley,label:verification] backup-native-state-and-audit
    Each observed native backup phase MUST have the matching durable Ash envelope
    and placement-bound events; private nonce and payload fields MUST stay absent
    from events. This assertion supplements, never replaces, native data checks.
    """
    value: object = json.loads(
        storage.succeed("cat /pool/.lilly-zfs/active/" + vm + "/backup.json")
    )
    assert isinstance(value, dict) and value.get("phase") == phase
    metadata: object = value.get("_lifecycle")
    assert isinstance(metadata, dict)
    assert metadata.get("resource") == "BackupSnapshot" and metadata.get("state") == phase
    identifier: object = metadata.get("id")
    assert isinstance(identifier, str) and str(uuid.UUID(identifier)) == identifier
    events: object = metadata.get("events")
    assert isinstance(events, list) and len(events) > 0
    for event in events:
        assert isinstance(event, dict) and event.get("placement_id") == vm
        assert event.get("workflow_id") is None
        assert not any(key in event for key in ("nonce", "payload", "run_id", "snapshot_guid"))
    return identifier


with subtest("real guest sync preserves development process and native ownership"):
    before = storage.succeed("zfs-guest-processes " + vm)
    captured = backup("capture", request)
    first_producer = snapshot_audit("ready")
    assert captured["flush"] == "confirmed", captured
    assert storage.succeed("zfs-guest-processes " + vm) == before
    storage.succeed("zfs-guest read", "zfs-guest observe 1")
    report = json.loads(storage.succeed("zfs-guest snapshot"))
    assert report["allocations"][vm] > 0
    storage.succeed("install -d -m 0700 /tank/backup-fixture")
    storage.succeed("printf '%s' isolated-guest-test > /tank/backup-fixture/password")
    restic = "RESTIC_PASSWORD_FILE=/tank/backup-fixture/password restic -r /tank/backup-fixture/repository "
    storage.succeed(restic + "init")
    paths = captured["paths"]
    assert isinstance(paths, list) and len(paths) == 1 and isinstance(paths[0], str)
    disk = paths[0]
    storage.succeed(restic + "backup -- " + shlex.quote(disk), timeout=180)
    # Transfer has separate ownership; neither operation owns the other's snapshot.
    # The transfer snapshot needs the physically stopped source (ADR-0155).
    storage.succeed(
        "zfs-guest stop 2", "zfs-guest source-full 2", "zfs-guest source-renew 2", timeout=90
    )
    assert backup("release", captured)["pending"] == 0
    assert snapshot_audit("cleaned") == first_producer
    storage.succeed("zfs list " + child + "@lilly-b")
    storage.fail("zfs list " + child + "@lilly-backup")
    storage.succeed("zfs-guest source-cleanup 2")
    storage.succeed(
        restic + "restore latest --sparse --verify --target /tank/backup-fixture/restored",
        timeout=180,
    )
    restored = "/tank/backup-fixture/restored" + disk
    # A running guest's ext4 image requires normal crash recovery before a
    # read-only inspection; repair only the isolated restored copy.
    storage.succeed("e2fsck -p " + shlex.quote(restored) + '; result=$?; test "$result" -le 1')
    storage.succeed(
        "mkdir -p /run/backup-fixture-restored; mount -o loop,ro "
        + shlex.quote(restored)
        + " /run/backup-fixture-restored"
    )
    assert (
        storage.succeed("cat /run/backup-fixture-restored/root/zfs-marker").strip()
        == "zfs-guest-flushed-1"
    )
    storage.succeed("umount /run/backup-fixture-restored")

with subtest("stopped guest disks are captured without booting the guest"):
    request["run_id"] = str(uuid.uuid4())
    captured = backup("capture", request)
    assert snapshot_audit("ready") != first_producer
    storage.succeed(
        "test -f /pool/.lilly-zfs/active/" + vm + "/backup-*-" + first_producer + ".json"
    )
    assert captured["flush"] in ("stopped", "unconfirmed")
    storage.fail("systemctl is-active --quiet lilly-vm-" + vm + ".service")
    assert backup("release", captured)["pending"] == 0

with subtest("missing guest helper degrades capture without stopping development"):
    storage.succeed("zfs-guest start 3", "zfs-guest backup-flush-off")
    before = storage.succeed("zfs-guest-processes " + vm)
    request["run_id"] = str(uuid.uuid4())
    captured = backup("capture", request)
    assert captured["flush"] == "unconfirmed"
    assert storage.succeed("zfs-guest-processes " + vm) == before
    assert backup("release", captured)["pending"] == 0
    storage.succeed("zfs-guest backup-flush-on")

with subtest("a foreign marker never authorizes destruction"):
    request["run_id"] = str(uuid.uuid4())
    captured = backup("capture", request)
    nonce = storage.succeed(
        "zfs get -Hpo value lilly:backup_nonce " + child + "@lilly-backup"
    ).strip()
    storage.succeed("zfs set lilly:backup_nonce=foreign " + child + "@lilly-backup")
    assert backup("cleanup", {})["pending"] == 1
    storage.succeed("zfs list " + child + "@lilly-backup")
    storage.succeed(
        "zfs set lilly:backup_nonce=" + shlex.quote(nonce) + " " + child + "@lilly-backup"
    )
    assert backup("cleanup", {})["pending"] == 0
    storage.fail("zfs list " + child + "@lilly-backup")

with subtest("process loss after actual native creation retains cleanup authority"):
    request["run_id"] = str(uuid.uuid4())
    body = shlex.quote(json.dumps(request))
    storage.succeed("umask 077; printf '%s' " + body + " > /run/backup-request.json")
    storage.succeed("install -Dm0755 /etc/backup-zfs-fault /run/backup-fault/bin/zfs")
    storage.succeed(
        "systemd-run --unit=backup-crash --setenv=BACKUP_FAULT=1 zfs-backup capture /run/backup-request.json"
    )
    storage.wait_for_file("/run/backup-native-created", timeout=60)
    storage.succeed("systemctl kill --kill-whom=main --signal=KILL backup-crash.service")
    storage.wait_until_fails("systemctl is-active --quiet backup-crash.service")
    storage.succeed("zfs list " + child + "@lilly-backup")
    state = json.loads(storage.succeed("cat /pool/.lilly-zfs/active/" + vm + "/backup.json"))
    assert state["phase"] == "creating" and state["snapshot_guid"] is None
    interrupted_producer = snapshot_audit("creating")
    assert backup("cleanup", {})["pending"] == 0
    assert snapshot_audit("cleaned") == interrupted_producer
    storage.fail("zfs list " + child + "@lilly-backup")
    storage.succeed("zfs-guest observe 3")
