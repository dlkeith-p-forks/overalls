import json
import shlex

start_all()
source.wait_for_unit("multi-user.target")
destination.wait_for_unit("multi-user.target")
source.succeed(
    "zpool create -f -O compression=lz4 -O mountpoint=/tank tank mirror /dev/vdb /dev/vdc",
    "zfs create -o mountpoint=/pool -o quota=6G tank/lilly",
    "zfs-lifecycle prepare 1",
    "mkdir -p /run/export-root",
    "mount -o loop /pool/vms/dddddddd-dddd-4ddd-8ddd-000000000001/rootfs.ext4 /run/export-root",
    "dd if=/dev/urandom of=/run/export-root/export-fixture bs=1M count=16 status=none",
    "umount /run/export-root",
    "sync",
    "zfs-lifecycle transfer-final 1",
    "zfs-lifecycle export-descriptor 1",
)
wire = json.loads(source.succeed("cat /run/export-descriptor.json"))
destination.succeed(
    "zpool create -f -O compression=lz4 -O mountpoint=/tank tank mirror /dev/vdb /dev/vdc",
    "zfs create -o mountpoint=/import-pool tank/imports",
    "printf %s " + shlex.quote(json.dumps(wire)) + " > /run/export-descriptor.json",
    "endpoint-control key",
)
public = destination.succeed("cat /run/peer-public")
source.succeed(
    "printf %s " + shlex.quote(public) + " > /run/peer-public",
    "mkdir -p /etc/ssh",
    "ssh-keygen -q -t ed25519 -N '' -f /etc/ssh/ssh_host_ed25519_key",
    "endpoint-control configure",
    "systemctl start lilly-transfer-sshd.service",
)
source.wait_for_unit("lilly-transfer-sshd.service")
host_key = source.succeed("cat /etc/ssh/ssh_host_ed25519_key.pub")
destination.succeed("printf %s " + shlex.quote(host_key) + " > /run/source-host.pub")

with subtest("receiver retries an interrupted SSH full stream through validated native resume"):
    destination.succeed("endpoint-control partial")
    source.succeed("endpoint-control renew")
    destination.succeed("endpoint-control pull")
    target = "tank/imports/vm-" + wire["destination"]["placement_id"]
    received = destination.succeed(f"zfs get -Hp -o value guid {target}@lilly-b").strip()
    assert received == wire["stream"]["to_guid"]
    assert destination.succeed(f"zfs get -Hp -o value receive_resume_token {target}").strip() == "-"

final_guid = wire["stream"]["to_guid"]
with subtest("an authenticated key cannot select an arbitrary source command"):
    destination.succeed("endpoint-control bad-command")
    source.fail("test -e /run/export-injection")
    destination.succeed("test ! -s /run/rejected")

with subtest("listener shutdown cancels a blocked native sender before release"):
    source.succeed("endpoint-control renew")
    destination.succeed(
        "systemd-run --unit=blocked-pull /run/current-system/sw/bin/endpoint-control blocked"
    )
    source.wait_until_succeeds("pgrep -f '^/[^ ]*/zfs send '")
    senders = source.succeed("pgrep -f '^/[^ ]*/zfs send '").split()
    source.succeed("systemctl stop lilly-transfer-sshd.service", "endpoint-control revoke")
    for pid in senders:
        source.fail(f"test -e /proc/{pid}")
    destination.wait_until_succeeds("test -e /run/client-cancelled")
    source.succeed("systemctl start lilly-transfer-sshd.service")
    destination.succeed("endpoint-control refused", "test ! -s /run/refused")
    source.succeed("zfs-lifecycle transfer-cleanup 1", "zfs-lifecycle delete 1")
    destination.succeed(
        f"test $(zfs get -Hp -o value guid {target}@lilly-b) = " + shlex.quote(final_guid)
    )


with subtest("authenticated revocation stops a live sender while the listener stays available"):
    source.succeed(
        "zfs-lifecycle prepare 2",
        "ZFS_RELOCATION=ffffffff-ffff-4fff-8fff-000000000002 zfs-lifecycle transfer-final 2",
        "ZFS_RELOCATION=ffffffff-ffff-4fff-8fff-000000000002 zfs-lifecycle export-descriptor 2",
    )
    second = json.loads(source.succeed("cat /run/export-descriptor.json"))
    second["destination"]["placement_id"] = "dddddddd-dddd-4ddd-8ddd-000000000098"
    source.succeed(
        "printf %s " + shlex.quote(json.dumps(second)) + " > /run/export-descriptor.json"
    )
    destination.succeed(
        "printf %s " + shlex.quote(json.dumps(second)) + " > /run/export-descriptor.json",
        "endpoint-control key",
    )
    second_public = destination.succeed("cat /run/peer-public")
    source.succeed(
        "printf %s " + shlex.quote(second_public) + " > /run/peer-public",
        "endpoint-control configure",
    )
    destination.succeed(
        "systemd-run --unit=revoked-pull /run/current-system/sw/bin/endpoint-control blocked"
    )
    source.wait_until_succeeds("pgrep -f '^/[^ ]*/zfs send '")
    senders = source.succeed("pgrep -f '^/[^ ]*/zfs send '").split()
    source.succeed("endpoint-control revoke", "systemctl is-active lilly-transfer-sshd.service")
    for pid in senders:
        source.fail(f"test -e /proc/{pid}")
    destination.wait_until_succeeds(
        "systemctl is-failed revoked-pull.service || ! systemctl is-active --quiet revoked-pull.service"
    )
    destination.succeed("endpoint-control refused", "test ! -s /run/refused")
    source.succeed(
        "ZFS_RELOCATION=ffffffff-ffff-4fff-8fff-000000000002 zfs-lifecycle transfer-cleanup 2",
        "zfs-lifecycle delete 2",
    )

with subtest("destination cancellation fences its key before blocked native work is quiescent"):
    relocation = "ffffffff-ffff-4fff-8fff-000000000003"
    source.succeed(
        "zfs-lifecycle prepare 3",
        f"ZFS_RELOCATION={relocation} zfs-lifecycle transfer-final 3",
        f"ZFS_RELOCATION={relocation} zfs-lifecycle export-descriptor 3",
    )
    third = json.loads(source.succeed("cat /run/export-descriptor.json"))
    third["destination"]["placement_id"] = "dddddddd-dddd-4ddd-8ddd-000000000097"
    source.succeed("printf %s " + shlex.quote(json.dumps(third)) + " > /run/export-descriptor.json")
    destination.succeed(
        "printf %s " + shlex.quote(json.dumps(third)) + " > /run/export-descriptor.json",
        "endpoint-control key",
        "rm -f /run/client-cancelled",
    )
    public = destination.succeed("cat /run/peer-public")
    source.succeed(
        "printf %s " + shlex.quote(public) + " > /run/peer-public", "endpoint-control configure"
    )
    destination.succeed(
        "systemd-run --unit=destination-cancel-pull /run/current-system/sw/bin/endpoint-control blocked"
    )
    source.wait_until_succeeds("pgrep -f '^/[^ ]*/zfs send '")
    senders = source.succeed("pgrep -f '^/[^ ]*/zfs send '").split()
    destination.succeed("endpoint-control cancel-busy")
    for pid in senders:
        source.succeed(f"test -e /proc/{pid}")
    source.succeed("endpoint-control revoke")
    for pid in senders:
        source.fail(f"test -e /proc/{pid}")
    destination.wait_until_succeeds("test -e /run/client-cancelled")
    destination.succeed("endpoint-control cancel")
    source.succeed(
        f"ZFS_RELOCATION={relocation} zfs-lifecycle transfer-cleanup 3", "zfs-lifecycle delete 3"
    )

with subtest("probe-only credentials prove pinned SSH connectivity without export access"):
    probe = dict(wire)
    probe["relocation_id"] = "ffffffff-ffff-4fff-8fff-000000000099"
    probe["destination"] = dict(wire["destination"])
    probe["destination"]["placement_id"] = "dddddddd-dddd-4ddd-8ddd-000000000099"
    payload = "printf %s " + shlex.quote(json.dumps(probe)) + " > /run/export-descriptor.json"
    source.succeed(payload)
    destination.succeed(payload, "endpoint-control key")
    public = destination.succeed("cat /run/peer-public")
    source.succeed(
        "printf %s " + shlex.quote(public) + " > /run/peer-public",
        "endpoint-control configure-probe",
    )
    destination.succeed(
        "endpoint-control probe", "endpoint-control refused", "test ! -s /run/refused"
    )
    source.fail("pgrep -f '^/[^ ]*/zfs send '")
    source.succeed("endpoint-control revoke")
    destination.succeed("endpoint-control probe-refused")
