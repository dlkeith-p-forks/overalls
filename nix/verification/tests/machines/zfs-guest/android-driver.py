"""Boot the production Android image through Lilly and patched Firecracker."""

import json

storage.start()
storage.wait_for_unit("multi-user.target")
storage.succeed("test -c /dev/kvm", "systemctl is-active lilly-hostd.service")
storage.succeed(
    "zpool create -f -O compression=lz4 -O mountpoint=/tank tank mirror /dev/vdb /dev/vdc"
)
create_guest_pool()
vm = "dddddddd-dddd-4ddd-8ddd-000000000201"

with subtest("the production Android image boots through Lilly and Firecracker"):
    exit_code, diagnostic = storage.execute("zfs-guest android-start 1", timeout=1800)
    if exit_code != 0:
        _, status = storage.execute(
            "systemctl --no-pager --full status "
            "lilly-vm-dddddddd-dddd-4ddd-8ddd-000000000101.service || true"
        )
        _, journal = storage.execute(
            "journalctl --no-pager -u "
            "lilly-vm-dddddddd-dddd-4ddd-8ddd-000000000101.service -n 80 || true"
        )
        print("android-firecracker-command-output:\n" + diagnostic)
        print("android-firecracker-service-status:\n" + status)
        print("android-firecracker-service-journal:\n" + journal)
        raise AssertionError("Android guest did not report readiness")
    result = json.loads(diagnostic.splitlines()[-1])
    assert result["image_id"]
    storage.succeed("zfs-guest observe 1", timeout=300)
    storage.succeed("zfs-guest android-stop 2", timeout=600)
    storage.succeed("zfs-guest android-delete 3", timeout=600)
