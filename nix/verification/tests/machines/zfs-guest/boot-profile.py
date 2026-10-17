# @cc [owner:ghuntley,label:verification] zfs-guest-boot-profile-only
# The boot-profile variant MUST boot the real confined guest through Lilly's
# trust delivery exactly like the first storage journey step, then assert and
# print the bounded boot profile. Its restarts rotate the delivered root set
# (add, then retire a root) and verify the guest trust store after each boot.
# It measures boot and trust; it does not replace the storage journey.
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
profiled = "dddddddd-dddd-4ddd-8ddd-000000000101"
fixture_root = "/etc/zfs-trust/fixture-root.pem"
rotation_root = "/etc/zfs-trust/rotation-root.pem"
rotated = f"ZFS_GUEST_TRUST_ROOTS_OVERRIDE={fixture_root},{rotation_root}"
retired = f"ZFS_GUEST_TRUST_ABSENT={rotation_root}"

with subtest("first boot reports its profile and holds the image's platform root"):
    storage.succeed("zfs-guest start 1")
    assert_boot_profile(profiled, finished=False)
    storage.succeed(f"{retired} zfs-guest trust-verify 1")

with subtest("a restart delivering an added root rebuilds the guest trust store"):
    storage.succeed("zfs-guest stop 2", f"{rotated} zfs-guest start 3")
    assert_boot_profile(profiled, finished=False)
    storage.succeed(f"{rotated} zfs-guest trust-verify 3")

with subtest("a restart retiring that root removes it from the guest trust store"):
    storage.succeed("zfs-guest stop 4", "zfs-guest start 5")
    assert_boot_profile(profiled, finished=False)
    storage.succeed(f"{retired} zfs-guest trust-verify 5")
    storage.succeed("zfs-guest delete 6")
