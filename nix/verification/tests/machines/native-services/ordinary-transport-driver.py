"""Replay test-only ordinary transport on two complete native service boots."""

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
        "python3 /etc/native-service-tools/native_ordinary_transport.py"
        " --image /etc/overalls-native-service-image"
        f" --vmm {vmm} --tap native0 --fixture /etc/native-service-fixture"
        " --work /work/native-services --probe /etc/native-transport-probe"
        f" --build-id {build_id}",
        timeout=800,
    )
    host.succeed(
        "jq -e '.native_admission == false and (.checks | length == 22)"
        ' and (.boot_ids | unique | length == 2) and .boot_endings == ["clean","clean"]\''
        " /work/native-services/service-receipt.json"
    )
    host.succeed("mkdir /work/transport-receipts")
    host.succeed("test $(find /work/native-services -name 'transport-*.json' | wc -l) -eq 2")
    host.succeed(
        "for receipt in /work/native-services/transport-*.json; do "
        "jq -e '.native_admission == false and .guest_cid == 3 and .peer_cid == 2"
        " and .malformed_length_refused and .disconnected_history_recovered"
        " and .production_same_boot_restored"
        " and ([.exchanges[].size] == [0,1,44,4096,65535,65536,65537,262144,1048576])'"
        ' "$receipt"; cp "$receipt" /work/transport-receipts/; done'
    )
    host.copy_from_vm("/work/transport-receipts")
    host.copy_from_vm("/work/native-services/service-receipt.json")
    host.copy_from_vm("/work/native-services/control-0.json")
    host.copy_from_vm("/work/native-services/control-1.json")
finally:
    status, serial = host.execute("tail -c 131072 /work/native-services/serial.log 2>/dev/null")
    if status == 0:
        print(serial, flush=True)
        host.copy_from_vm("/work/native-services/serial.log")
