# @cc [owner:ghuntley,label:verification;capacity] invalid-bundle-retains-owned-storage-only
# Real ZFS observations MUST recognize an exactly owned disk with an invalid
# launch bundle without crediting it or making its neighbor unavailable. Invalid
# disk metadata, owner tags and unexpected files MUST still withhold the pool.
storage.start()
storage.wait_for_unit("multi-user.target")
storage.succeed(
    "zpool create -f -O compression=lz4 -O mountpoint=/tank tank mirror /dev/vdb /dev/vdc"
)
storage.succeed("zfs create -o mountpoint=/pool -o quota=6G tank/lilly")


def placement(number: int) -> str:
    return f"dddddddd-dddd-4ddd-8ddd-{number:012d}"


with subtest("invalid launch metadata preserves owned capacity without allocation credit"):
    storage.succeed("zfs-lifecycle prepare 1", "zfs-lifecycle prepare 2")
    first = placement(1)
    bundle = f"/pool/vms/{first}/boot-bundle.json"
    metadata = f"/pool/.lilly-zfs/active/{first}/disk.json"
    storage.succeed(f"cp {bundle} /run/retained-bundle.json")
    storage.succeed(f"printf '%s' '{{\"version\":999}}' > {bundle}")
    storage.succeed(f"sha256sum {bundle} > /run/retained-bundle.sha256")
    for _ in range(2):
        storage.succeed(
            "zpool sync tank",
            "zfs-lifecycle no-credit 1",
            "zfs-lifecycle credit 2",
            "zfs-lifecycle reject-ready 1",
            "sha256sum -c /run/retained-bundle.sha256",
        )

    storage.succeed(f"cp {metadata} /run/retained-disk.json")
    storage.succeed(f"printf '%s' '{{}}' > {metadata}")
    storage.succeed("zfs-lifecycle reject-snapshot")
    storage.succeed(f"cp /run/retained-disk.json {metadata}")

    storage.succeed(f"chmod 600 /pool/vms/{first}/kernel")
    storage.succeed("zfs-lifecycle reject-snapshot")
    storage.succeed(f"chmod 444 /pool/vms/{first}/kernel")

    storage.succeed(f"zfs set lilly:nonce=00000000000000000000000000000000 tank/lilly/vm-{first}")
    storage.succeed("zfs-lifecycle reject-snapshot", "zfs-lifecycle reject-ready 1")
    storage.succeed(
        f'zfs set lilly:nonce="$(jq -er .nonce /pool/.lilly-zfs/active/{first}/claim.json)" tank/lilly/vm-{first}'
    )
    storage.succeed(f"touch /pool/vms/{first}/unexpected")
    storage.succeed("zfs-lifecycle reject-snapshot")
    storage.succeed(f"rm /pool/vms/{first}/unexpected")
    storage.succeed("zfs-lifecycle no-credit 1", "zfs-lifecycle credit 2")
    storage.succeed(f"cp /run/retained-bundle.json {bundle}")
    storage.succeed("zfs-lifecycle credit 1", "zfs-lifecycle credit 2")
    storage.succeed("zfs-lifecycle delete 1", "zfs-lifecycle delete 2")
