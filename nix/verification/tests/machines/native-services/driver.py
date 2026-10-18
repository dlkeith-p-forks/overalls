"""Exercise a closed native image's production daemons on an isolated test host."""

host.start()
host.wait_for_unit("multi-user.target")
host.succeed("test -c /dev/kvm")
host.succeed("mkfs.ext4 -F -q /dev/vdb && mkdir -p /work && mount /dev/vdb /work")
host.succeed("ip tuntap add native0 mode tap")
host.succeed("ip link set native0 up")
host.succeed("ip address add 10.10.0.1/32 dev native0")
host.succeed("ip route add 10.10.0.203/32 dev native0 src 10.10.0.1")
host.succeed("ip address add 169.254.254.1/32 dev lo")
host.succeed("ip address add 1.1.1.1/32 dev lo")
try:
    extra = f" --os-name {os_name}" + (" --growth" if growth else "")
    host.succeed(
        f"python3 /etc/native-service-tools/{service_runner}"
        " --image /etc/overalls-native-service-image"
        f" --vmm {vmm} --tap native0 --fixture /etc/native-service-fixture"
        f" --work /work/native-services{extra}",
        timeout=1400 if growth or crash else 800,
    )
    boot_count = 3 if growth else 2
    host.succeed(
        "jq -e '.native_admission == false and (.checks | length == 25)"
        f" and (.boot_ids | unique | length == {boot_count})'"
        " /work/native-services/service-receipt.json"
    )
    host.copy_from_vm("/work/native-services/service-receipt.json")
    host.copy_from_vm("/work/native-services/control-0.json")
    host.copy_from_vm("/work/native-services/control-1.json")
    if growth:
        growth_checks = 5 if os_name == "freebsd" else 8
        host.copy_from_vm("/work/native-services/control-2.json")
        host.succeed(
            f"jq -e '.native_admission == false and (.checks | length == {growth_checks})"
            " and (.boot_ids | unique | length == 3) and (.root_bytes | length == 3)"
            " and .root_bytes[1] > .root_bytes[0] and .root_bytes[2] > .root_bytes[1]'"
            " /work/native-services/growth-receipt.json"
        )
        host.copy_from_vm("/work/native-services/growth-receipt.json")
    if recovery:
        host.succeed(
            "test $(find /work/native-services -path '*/recovery-*/receipt.json' | wc -l) -eq 2"
        )
        host.succeed("mkdir /work/recovery-receipts")
        host.succeed(
            "for receipt in /work/native-services/recovery-*/receipt.json; do "
            'directory=$(basename "$(dirname "$receipt")"); '
            "jq -e '(.checks | length == 5) and .native_admission == false' \"$receipt\"; "
            'cp "$receipt" "/work/recovery-receipts/$directory.json"; done'
        )
        host.copy_from_vm("/work/recovery-receipts")
    if crash:
        integrity = (
            "ufs-snapshot-background-fsck"
            if os_name == "freebsd"
            else "zfs-completed-zero-error-scrub"
        )
        host.succeed(
            f'jq -e \'.version == 1 and .os == "{os_name}" and .native_admission == false'
            " and (.checks | length == 8)"
            ' and .boot_endings == ["sigkill", "clean"]'
            " and (.boot_ids | unique | length == 2)"
            f' and .native_integrity == "{integrity}"\''
            " /work/native-services/crash-recovery-receipt.json"
        )
        host.copy_from_vm("/work/native-services/crash-recovery-receipt.json")
finally:
    status, serial = host.execute("tail -c 131072 /work/native-services/serial.log 2>/dev/null")
    if status == 0:
        print(serial, flush=True)
        host.copy_from_vm("/work/native-services/serial.log")
