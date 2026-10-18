"""Observe an actual reset after a complete OmniOS service baseline."""

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
    host.succeed(
        "python3 /etc/native-service-tools/native_omnios_reset_runner.py"
        " --image /etc/overalls-native-service-image"
        f" --vmm {vmm} --tap native0 --fixture /etc/native-service-fixture"
        " --work /work/native-services --probe /etc/native-transport-probe"
        f" --build-id {build_id}",
        timeout=800,
    )
    host.succeed("test ! -e /work/native-services/service-receipt.json")
    host.succeed(
        'jq -e \'.native_admission == false and .os == "illumos"'
        " and .api_statuses == [204,204,204] and .oracle.idle_error == 131"
        " and .oracle.accept_error == 0 and .oracle.read_error > 0"
        " and .oracle.write_error > 0 and .oracle.written_before_refusal >= 0"
        " and .oracle.written_before_refusal < 16777216"
        ' and .oracle.fresh_socket == "current-cid-revalidated"'
        "' /work/native-services/reset-receipt.json"
    )
    host.copy_from_vm("/work/native-services/reset-receipt.json")
    host.copy_from_vm("/work/native-services/control-0.json")
finally:
    status, serial = host.execute("tail -c 131072 /work/native-services/serial.log 2>/dev/null")
    if status == 0:
        print(serial, flush=True)
        host.copy_from_vm("/work/native-services/serial.log")
