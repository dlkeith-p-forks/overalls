"""Native reflink feasibility and independent disk materialization."""

storage.start()
storage.wait_for_unit("multi-user.target")
storage.succeed("zpool create -f -O compression=lz4 -O mountpoint=/tank tank /dev/vdb")
storage.succeed("zfs create tank/template", "zfs create tank/vm")
storage.succeed(
    "dd if=/dev/urandom of=/tank/template/root bs=1M count=8 status=none",
    "truncate -s 16777216 /tank/template/root",
    "chmod 0444 /tank/template/root",
    "sync /tank/template/root",
    "zfs set readonly=on tank/template",
)

# @cc [owner:ghuntley,label:verification;storage] image-copy-native-dataset-boundary
# Record the actual cross-dataset method; an active block-cloning pool feature
# MUST NOT be reported as successful cross-dataset reflinking. VM bytes and
# lifetime MUST remain independent after writes and template destruction.
with subtest("sealed cross-dataset source and independent writable VM file"):
    method: str = storage.succeed(
        "lilly-image-copy auto /tank/template/root /tank/vm/root 16777216"
    ).strip()
    assert method in {"reflink", "offload", "copy"}
    print(f"cross_dataset_materialization={method}")
    storage.succeed("cmp /tank/template/root /tank/vm/root")
    storage.succeed("cp --reflink=never /tank/template/root /run/reference")
    storage.succeed("printf modified | dd of=/tank/vm/root conv=notrunc,fsync status=none")
    storage.succeed("cmp /tank/template/root /run/reference")
    storage.fail("cmp /tank/template/root /tank/vm/root")
    storage.succeed("zfs destroy tank/template", "test -s /tank/vm/root")

# @cc [owner:ghuntley,label:verification;storage] image-copy-cross-mount-offload
# Production images sit behind a separate mount of the same pool as VM datasets,
# where FICLONE returns EXDEV. The helper MUST then offload through the kernel,
# and on a block-cloning pool the bytes MUST be shared (bcloneused grows) while
# the destination stays independent of later source-side changes.
with subtest("cross-mount same-pool source offloads into shared blocks"):
    storage.succeed(
        "zfs create tank/store",
        "dd if=/dev/urandom of=/tank/store/image bs=1M count=8 status=none",
        "chmod 0444 /tank/store/image",
        "sync /tank/store/image",
        "mkdir -p /store-bind",
        "mount --bind -o ro /tank/store /store-bind",
        "zpool sync tank",
    )
    storage.fail("cp --reflink=always /store-bind/image /tank/vm/ficlone-probe")
    before = int(storage.succeed("zpool get -Hpo value bcloneused tank").strip())
    offloaded: str = storage.succeed(
        "lilly-image-copy auto /store-bind/image /tank/vm/offloaded 8388608"
    ).strip()
    storage.succeed("zpool sync tank")
    after = int(storage.succeed("zpool get -Hpo value bcloneused tank").strip())
    print(f"cross_mount_materialization={offloaded} bcloneused_delta={after - before}")
    assert offloaded == "offload", offloaded
    assert after - before >= 8 * 1024 * 1024, (before, after)
    storage.succeed("cmp /store-bind/image /tank/vm/offloaded")
    storage.succeed("printf changed | dd of=/tank/vm/offloaded conv=notrunc,fsync status=none")
    storage.fail("cmp /store-bind/image /tank/vm/offloaded")
    storage.succeed("umount /store-bind", "zfs destroy tank/store", "test -s /tank/vm/offloaded")

with subtest("explicit sparse fallback and refusal to replace initialized disks"):
    storage.succeed("chmod 0444 /run/reference")
    assert (
        storage.succeed("lilly-image-copy copy /run/reference /tank/vm/fallback 16777216").strip()
        == "copy"
    )
    storage.succeed("cmp /run/reference /tank/vm/fallback")
    storage.fail("lilly-image-copy copy /run/reference /tank/vm/root 16777216")
    storage.succeed("test $(head -c 8 /tank/vm/root) = modified")

with subtest("space exhaustion remains a materialization failure"):
    storage.succeed("zfs create -o quota=1M tank/full")
    storage.fail("lilly-image-copy auto /run/reference /tank/full/root 16777216")
    storage.succeed("cmp /run/reference /tank/vm/fallback")
