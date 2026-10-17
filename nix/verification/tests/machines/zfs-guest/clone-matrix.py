"""Native same-pool block-copy clones: after resize, chained and discarded (ADR-0145)."""

import json

# @cc [owner:ghuntley,label:verification;storage] clone-matrix-native-oracles
# Sizes, origins and GUIDs MUST be read with `zfs get`/`stat` from the live
# pool, and guest contents MUST be read through the real guest console. No
# assertion may consult fixture-written driver state; every placement is
# created by the ordinary fixture driver actions and cloned by production
# effects. Marker assertions compare only the chosen generation labels. Every
# clone here is same-pool, so production always takes the block-copy path; each
# fixture run also discards a second copied clone (target + 50).


def guid(dataset: str) -> str:
    return storage.succeed(f"zfs get -Hpo value guid {dataset}").strip()


def origin(dataset: str) -> str:
    return storage.succeed(f"zfs get -Hpo value origin {dataset}").strip()


def placement(number: int) -> str:
    return "dddddddd-dddd-4ddd-8ddd-" + str(number).rjust(12, "0")


def dataset(number: int) -> str:
    return "tank/lilly/vm-" + placement(number)


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

with subtest("clone after resize captures the grown disk into an independent placement"):
    source = dataset(130)
    copy = dataset(131)
    storage.succeed(
        "zfs-guest start 1 130",
        "zfs-guest write 1 130",
        "zfs-guest resize-interrupt 2 130",
        "zfs-guest resize-publish-interrupt 2 130",
        "zfs-guest resize 3 130",
        "zfs-guest resized-start 4 130",
        "zfs-guest resized-read 1 130",
        "zfs-guest resized-check-shape 4 130",
        "zfs-guest resized-stop 5 130",
    )
    storage.succeed("zfs-guest resized-clone-matrix 5 130 131")
    assert storage.succeed(f"stat -c %s /pool/vms/{placement(131)}/rootfs.ext4").strip() == str(
        grown_disk_bytes
    )
    assert origin(source) == "-"
    assert origin(copy) == "-"
    assert guid(source) != guid(copy)
    # The captured marker and grown guest shape arrive with the copy.
    storage.succeed(
        "zfs-guest resized-start 7 131",
        "zfs-guest resized-read 1 131",
        "zfs-guest resized-check-shape 7 131",
    )
    # Divergent writes never cross between the copies.
    storage.succeed("zfs-guest resized-start 8 130", "zfs-guest resized-write 9 130")
    storage.succeed("zfs-guest resized-write 10 131")
    storage.succeed("zfs-guest resized-read 10 131")
    storage.succeed("zfs-guest resized-read 9 130")
    storage.succeed("zfs-guest resized-stop 11 130", "zfs-guest resized-stop 12 131")
    storage.succeed("zfs-guest resized-delete 13 130")
    storage.succeed("zfs-guest resized-start 14 131", "zfs-guest resized-read 10 131")
    storage.succeed("zfs-guest resized-stop 15 131", "zfs-guest resized-delete 16 131")
    storage.fail(f"test -e /pool/vms/{placement(130)}/rootfs.ext4")
    storage.fail(f"test -e /pool/vms/{placement(131)}/rootfs.ext4")
    storage.fail(f"zfs list -H {dataset(181)}")

with subtest("an adopted copy becomes the next clone's source"):
    first_source = dataset(132)
    first_copy = dataset(133)
    second_copy = dataset(134)
    storage.succeed(
        "zfs-guest start 1 132",
        "zfs-guest write 1 132",
        "zfs-guest stop 2 132",
        "zfs-guest clone-matrix 2 132 133",
    )
    assert origin(first_copy) == "-"
    assert guid(first_source) != guid(first_copy)
    storage.succeed("zfs-guest start 3 133", "zfs-guest read 1 133")
    storage.succeed("zfs-guest write 4 133", "zfs-guest stop 5 133")
    # The adopted copy is a real stopped source for the chained clone.
    storage.succeed("zfs-guest clone-matrix 5 133 134")
    assert origin(second_copy) == "-"
    chained = {guid(first_source), guid(first_copy), guid(second_copy)}
    assert len(chained) == 3
    # The second hop carries the first copy's divergent state, never the
    # original source's earlier or later contents.
    storage.succeed("zfs-guest start 6 134", "zfs-guest read 4 134")
    storage.succeed("zfs-guest start 7 132", "zfs-guest write 7 132")
    storage.succeed("zfs-guest read 4 134")
    storage.succeed("zfs-guest start 8 133", "zfs-guest read 4 133")
    storage.succeed("zfs-guest write 9 134")
    storage.succeed("zfs-guest read 7 132")
    # Deleting the chain's sources must not invalidate their independent copies.
    storage.succeed("zfs-guest stop 10 132", "zfs-guest delete 11 132")
    storage.succeed("zfs-guest read 4 133", "zfs-guest read 9 134")
    storage.succeed("zfs-guest stop 12 133", "zfs-guest delete 13 133")
    storage.succeed("zfs-guest read 9 134")
    storage.succeed("zfs-guest stop 14 134", "zfs-guest delete 15 134")
    for number in (132, 133, 134):
        storage.fail(f"test -e /pool/vms/{placement(number)}/rootfs.ext4")
    for number in (183, 184):
        storage.fail(f"zfs list -H {dataset(number)}")


def bclone_used() -> int:
    return int(storage.succeed("zpool get -Hpo value bcloneused tank").strip())


with subtest("same-pool block copies share blocks and stay independent"):
    source = dataset(135)
    copy = dataset(136)
    chained = dataset(137)
    storage.succeed(
        "zfs-guest start 1 135",
        "zfs-guest write 1 135",
        "zfs-guest stop 2 135",
    )
    before = bclone_used()
    # Copy, adopt, revoke and prune run through production effects; the
    # fixture also discards a second copied clone.
    storage.succeed("zfs-guest clone-matrix 2 135 136")
    # The copy is a real block clone: the pool's shared-block accounting grows
    # instead of the copy rewriting the source's data.
    assert bclone_used() > before
    assert origin(copy) == "-"
    assert guid(source) != guid(copy)
    storage.succeed("zfs-guest start 3 136", "zfs-guest read 1 136")
    storage.succeed("zfs-guest write 4 136", "zfs-guest stop 5 136")
    # A block copy is an ordinary source for the next block copy.
    storage.succeed("zfs-guest clone-matrix 5 136 137")
    assert origin(chained) == "-"
    assert len({guid(source), guid(copy), guid(chained)}) == 3
    storage.succeed("zfs-guest start 6 137", "zfs-guest read 4 137")
    storage.succeed("zfs-guest start 7 135", "zfs-guest write 7 135")
    storage.succeed("zfs-guest start 8 136", "zfs-guest read 4 136", "zfs-guest read 4 137")
    # Shared blocks never couple lifetimes: deleting sources keeps copies whole.
    storage.succeed("zfs-guest stop 9 135", "zfs-guest delete 10 135")
    storage.succeed("zfs-guest stop 11 136", "zfs-guest delete 12 136")
    storage.succeed("zfs-guest read 4 137")
    storage.succeed("zfs-guest stop 13 137", "zfs-guest delete 14 137")
    for number in (135, 136, 137, 186, 187):
        storage.fail(f"zfs list -H {dataset(number)}")

report = json.loads(storage.succeed("zfs-guest snapshot"))
assert not report["allocations"]
