import json as guest_shape_json


def create_guest_pool() -> tuple[int, int, int, int, int]:
    """@cc [owner:ghuntley,label:verification;storage] guest-fixture-manifest-sizing
    Fixture root-disk and pool budgets MUST follow the exact image's advertised
    minimum. Resize MUST add one GiB to the original disk, and the quota MUST
    equal two base disks so two grown disks still overpromise the pool. Sparse
    allocation assertions remain below that quota; its backing mirror is bounded.
    RAM MUST satisfy the manifest minimum and resize MUST add 256 MiB.
    """
    parsed: object = guest_shape_json.loads(storage.succeed("cat /etc/zfs-guest-manifest.json"))
    assert isinstance(parsed, dict)
    manifest: dict[str, object] = {}
    for key, value in parsed.items():
        assert isinstance(key, str)
        manifest[key] = value
    minimum: object = manifest.get("minimum_disk_bytes")
    assert isinstance(minimum, int) and not isinstance(minimum, bool) and minimum > 0
    minimum_memory: object = manifest.get("minimum_memory_bytes")
    assert (
        isinstance(minimum_memory, int)
        and not isinstance(minimum_memory, bool)
        and minimum_memory > 0
    )
    base = max(minimum, 3 * 1024**3)
    grown = base + 1024**3
    quota = 2 * base
    if android_fixture:
        # Android's SDK closure advertises a 32 GiB minimum disk. Keep the
        # fixture bounded while allowing the two-disk mirror to hold it.
        assert quota < 95 * 1024**3, (
            "Android image fixture exceeds the bounded 96 GiB backing mirror"
        )
    else:
        assert quota < 31 * 1024**3, "image fixture exceeds the bounded 32 GiB backing mirror"
    storage.succeed(f"zfs create -o mountpoint=/pool -o quota={quota} tank/lilly")
    # Lilly runs as `lilly` (ADR-0182): hand the new pool over, as the
    # boot-time ownership unit does for pools that exist at boot.
    storage.succeed("systemctl restart lilly-ownership.service")
    memory = max(minimum_memory, 512 * 1024**2)
    return base, grown, quota, memory, memory + 256 * 1024**2
