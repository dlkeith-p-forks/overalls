"""Real Firecracker deletion with late mount namespaces and a busy file holder."""

import json
import random

type NamespaceInventory = dict[int, tuple[int, int]]


def fields(value: object) -> dict[str, object]:
    assert isinstance(value, dict)
    result: dict[str, object] = {}
    for key, item in value.items():
        assert isinstance(key, str)
        result[key] = item
    return result


def descriptor_inventory(pid: int) -> NamespaceInventory:
    parsed: object = json.loads(
        storage.succeed(f"python3 /etc/namespace-inventory.py inventory {pid}")
    )
    assert isinstance(parsed, list)
    result: NamespaceInventory = {}
    for entry in parsed:
        row = fields(entry)
        assert set(row) == {"fd", "device", "inode"}
        numbers: list[int] = []
        for key in ("fd", "device", "inode"):
            number = row[key]
            assert type(number) is int and number >= 0
            numbers.append(number)
        descriptor, device, inode = numbers
        assert descriptor > 0 and inode > 0 and descriptor not in result
        result[descriptor] = (device, inode)
    return result


def held_inventory(
    namespace_count: int, duplicate_count: int, originals_closed: bool
) -> tuple[int, NamespaceInventory]:
    parsed: object = json.loads(storage.succeed("cat /run/zfs-fd-history.json"))
    value = fields(parsed)
    assert set(value) == {"pid", "namespaces"}
    pid = value["pid"]
    assert type(pid) is int and pid > 0
    assert storage.succeed("systemctl show -P MainPID zfs-history-holder.service").strip() == str(
        pid
    )
    records = value["namespaces"]
    assert isinstance(records, list) and len(records) == namespace_count
    expected: NamespaceInventory = {}
    identities: set[tuple[int, int]] = set()
    for entry in records:
        row = fields(entry)
        assert set(row) == {"child_pid", "device", "inode", "descriptors"}
        child, device, inode = row["child_pid"], row["device"], row["inode"]
        assert type(child) is int and child > 0
        assert type(device) is int and device >= 0
        assert type(inode) is int and inode > 0
        identity = (device, inode)
        assert identity not in identities
        identities.add(identity)
        storage.succeed(f"test ! -e /proc/{child}/ns/mnt")
        descriptors = row["descriptors"]
        assert isinstance(descriptors, list)
        assert len(descriptors) == duplicate_count + (0 if originals_closed else 1)
        for descriptor in descriptors:
            assert type(descriptor) is int and descriptor > 0 and descriptor not in expected
            expected[descriptor] = identity
    assert descriptor_inventory(pid) == expected
    return pid, expected


def retained_mounts(pid: int, descriptor: int, vm_id: str) -> list[str]:
    parsed: object = json.loads(
        storage.succeed(f"python3 /etc/namespace-inventory.py mounts {pid} {descriptor} {vm_id}")
    )
    assert isinstance(parsed, list)
    result: list[str] = []
    for value in parsed:
        assert isinstance(value, str)
        result.append(value)
    return result


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

first = "dddddddd-dddd-4ddd-8ddd-000000000101"
survivor = "dddddddd-dddd-4ddd-8ddd-000000000102"
busy = "dddddddd-dddd-4ddd-8ddd-000000000103"
descriptor_only = "dddddddd-dddd-4ddd-8ddd-000000000104"
hidden_proc = "dddddddd-dddd-4ddd-8ddd-000000000105"
sandboxed = "dddddddd-dddd-4ddd-8ddd-000000000119"


# @cc [owner:ghuntley,label:verification;recovery] nix-sandbox-never-holds-guest-dataset
# A real sandboxed Nix build running while a guest dataset is mounted MUST NOT
# hold a (user-namespace locked) copy of it: the fenced delete MUST complete
# while the build is still alive, and the build MUST survive (ADR-0144).
with subtest("a running Nix sandbox build never holds a guest dataset"):
    storage.succeed("zfs-guest start 1 119")
    storage.succeed(
        "systemd-run --unit=zfs-nix-build --setenv=NIX_REMOTE=daemon nix-build --no-out-link -E "
        + '\'derivation { name = "overalls-sandbox-holder"; system = builtins.currentSystem; '
        + 'builder = "/bin/sh"; args = [ "-c" '
        + '"i=0; while [ $i -lt 2000000000 ]; do i=$((i+1)); done" ]; }\''
    )
    storage.wait_until_succeeds("pgrep -f '^sh -c i=0'", timeout=180)
    # The daemon's own namespace MUST hold no pool mount, so sandboxes cannot copy one.
    storage.fail("grep -F ' /pool' /proc/$(systemctl show -P MainPID nix-daemon.service)/mountinfo")
    storage.succeed("zfs-guest delete 2 119")
    storage.fail(f"zfs list tank/lilly/vm-{sandboxed}")
    storage.succeed("pgrep -f '^sh -c i=0'", "systemctl is-active zfs-nix-build.service")
    storage.succeed("systemctl stop zfs-nix-build.service")


def retained_guest_processes(vm_id: str) -> object:
    snapshot: object = json.loads(storage.succeed(f"zfs-guest-processes {vm_id}"))
    return snapshot


with subtest("late sandbox mount copy does not strand an owned guest disk"):
    storage.succeed("zfs-guest start 1 101", "zfs-guest start 1 102", "zfs-guest write 1 102")
    before = retained_guest_processes(survivor)
    storage.succeed(
        "systemd-run --unit=zfs-copy --property=ProtectSystem=strict "
        "--property=PrivateTmp=yes /run/current-system/sw/bin/sleep 300",
        "systemd-run --unit=zfs-copy-second --property=ProtectSystem=strict "
        "--property=PrivateTmp=yes /run/current-system/sw/bin/sleep 300",
    )
    storage.wait_for_unit("zfs-copy.service")
    storage.wait_for_unit("zfs-copy-second.service")
    storage.succeed(
        "pid=$(systemctl show -P MainPID zfs-copy.service); "
        f"grep -F 'tank/lilly/vm-{first} ' /proc/$pid/mountinfo"
    )
    storage.succeed(
        "pid=$(systemctl show -P MainPID zfs-copy-second.service); "
        f"grep -F 'tank/lilly/vm-{first} ' /proc/$pid/mountinfo"
    )
    storage.succeed("zfs-guest delete 2 101")
    storage.fail(f"zfs list tank/lilly/vm-{first}")
    storage.succeed("systemctl is-active zfs-copy.service")
    storage.succeed("systemctl is-active zfs-copy-second.service")
    storage.fail(
        "pid=$(systemctl show -P MainPID zfs-copy.service); "
        f"grep -F 'tank/lilly/vm-{first} ' /proc/$pid/mountinfo"
    )
    storage.succeed("zfs-guest observe 1 102", "zfs-guest read 1 102")
    assert retained_guest_processes(survivor) == before
    storage.succeed("systemctl stop zfs-copy.service")
    storage.succeed("systemctl stop zfs-copy-second.service")

# @cc [owner:ghuntley,label:verification;recovery] fd-pinned-namespace-native-delete
# A namespace with no inhabitant but a live descriptor MUST NOT strand an owned
# stopped disk. The holder and the unrelated guest MUST survive exact cleanup.
with subtest("a descriptor pins an empty builder namespace without stranding deletion"):
    storage.succeed("zfs-guest start 1 104")
    storage.succeed("systemd-run --unit=zfs-fd-holder python3 /etc/hold-namespace.py")
    storage.wait_until_succeeds("test -f /run/zfs-fd-held")
    storage.succeed("zfs-guest delete 2 104")
    storage.fail(f"zfs list tank/lilly/vm-{descriptor_only}")
    storage.succeed("systemctl is-active zfs-fd-holder.service")
    storage.succeed("zfs-guest observe 1 102", "zfs-guest read 1 102")
    assert retained_guest_processes(survivor) == before
    storage.succeed("systemctl stop zfs-fd-holder.service")

# @cc [owner:ghuntley,label:verification;recovery] proc-less-namespace-native-delete
# Exact cleanup MUST work in a descriptor-pinned namespace with hidden /proc,
# while preserving its descriptor holder and the unrelated running guest.
with subtest("a retained namespace without proc still permits exact fenced deletion"):
    storage.succeed("zfs-guest start 1 105")
    storage.succeed(
        "systemd-run --unit=zfs-hidden-proc-holder python3 /etc/hold-namespace.py --hide-proc"
    )
    storage.wait_until_succeeds("test -f /run/zfs-fd-hidden-proc")
    storage.succeed("zfs-guest delete 2 105")
    storage.fail(f"zfs list tank/lilly/vm-{hidden_proc}")
    storage.succeed("systemctl is-active zfs-hidden-proc-holder.service")
    storage.succeed("zfs-guest observe 1 102", "zfs-guest read 1 102")
    assert retained_guest_processes(survivor) == before
    storage.succeed("systemctl stop zfs-hidden-proc-holder.service")

# @cc [owner:ghuntley,label:verification;recovery] generated-namespace-descriptor-histories
# Histories copy stopped disks after normal stop removes jail bindings.
# Every generated namespace MUST expose the exact owned root before deletion
# and none afterward through every retained descriptor. Duplicate/original
# closure MUST NOT lose cleanup targets or alter the holder's descriptor set;
# the unrelated guest MUST retain exact processes and readable data. This checks
# closure before cleanup, not arbitrary descriptor races during a sweep.
histories = [
    (1, 1, False, False),
    (1, 4, True, True),
    (2, 4, False, True),
    (2, 1, True, False),
    (4, 1, False, True),
    (4, 4, True, False),
]
random.Random(135).shuffle(histories)
for index, (namespace_count, duplicate_count, originals_closed, hide_proc) in enumerate(histories):
    number = 106 + index
    vm_id = f"dddddddd-dddd-4ddd-8ddd-{number:012d}"
    with subtest(f"generated namespace history {index}, seed 135"):
        print(
            "Namespace history:",
            namespace_count,
            duplicate_count,
            originals_closed,
            hide_proc,
            flush=True,
        )
        storage.succeed(f"zfs-guest start 1 {number}", f"zfs-guest stop 2 {number}")
        storage.succeed("rm -f /run/zfs-fd-history.json")
        command = (
            "systemd-run --unit=zfs-history-holder python3 /etc/hold-namespace.py --history "
            f"--namespaces {namespace_count} --duplicates {duplicate_count}"
        )
        if originals_closed:
            command += " --close-original"
        if hide_proc:
            command += " --hide-proc"
        storage.succeed(command)
        storage.wait_until_succeeds("test -f /run/zfs-fd-history.json")
        holder_pid, inventory = held_inventory(namespace_count, duplicate_count, originals_closed)
        for descriptor in inventory:
            observed = retained_mounts(holder_pid, descriptor, vm_id)
            assert observed == [f"/pool/vms/{vm_id}"], observed
        storage.succeed(f"zfs-guest delete 3 {number}")
        storage.fail(f"zfs list tank/lilly/vm-{vm_id}")
        storage.succeed("systemctl is-active zfs-history-holder.service")
        assert descriptor_inventory(holder_pid) == inventory
        for descriptor in inventory:
            assert retained_mounts(holder_pid, descriptor, vm_id) == []
        storage.succeed("zfs-guest observe 1 102", "zfs-guest read 1 102")
        assert retained_guest_processes(survivor) == before
        storage.succeed("systemctl stop zfs-history-holder.service")


with subtest("an open guest file holds the deletion fence until released"):
    storage.succeed("zfs-guest start 1 103")
    storage.succeed(
        "cat >/run/hold-zfs-file <<'EOF'\n"
        "#!/bin/sh\n"
        'exec 9<"$1"\n'
        "/run/current-system/sw/bin/sleep 300\n"
        "EOF\n"
        "chmod 0700 /run/hold-zfs-file"
    )
    storage.succeed(
        "systemd-run --unit=zfs-busy --property=ProtectSystem=strict "
        f"/run/hold-zfs-file /pool/vms/{busy}/rootfs.ext4"
    )
    storage.wait_for_unit("zfs-busy.service")
    storage.succeed("systemctl is-active zfs-busy.service")
    blocked = storage.fail("zfs-guest delete 2 103 2>&1")
    assert '"event":"lilly.zfs_namespace_cleanup_unconfirmed"' in blocked
    assert '"reason":"busy"' in blocked
    assert (
        storage.succeed(f"jq -r .state /pool/.lilly-zfs/active/{busy}/claim.json").strip()
        == "deleting"
    )
    storage.succeed(f"zfs list tank/lilly/vm-{busy}")
    storage.succeed("zfs-guest observe 1 102", "zfs-guest read 1 102")
    storage.succeed("systemctl stop zfs-busy.service")
    storage.succeed("zfs-guest delete 2 103", "zfs-guest delete 2 102")
    storage.fail(f"zfs list tank/lilly/vm-{busy}")
    assert not json.loads(storage.succeed("zfs-guest snapshot"))["allocations"]
