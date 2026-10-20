"""Verify actual native transport behavior inside the isolated KVM test host."""

host.start()
host.wait_for_unit("multi-user.target")
host.succeed("test -c /dev/kvm")
host.succeed("mkfs.ext4 -F -q /dev/vdb && mkdir -p /work && mount /dev/vdb /work")
host.succeed(
    "python3 /etc/native-transport-tools/native_transport_runner.py"
    " --image /etc/overalls-native-probe-image"
    f" --vmm {vmm} --build-id {build_id} --os freebsd --work /work/native"
    + (" --fault-injection" if fault_injection else ""),
    timeout=300,
)
host.succeed(
    "jq -e '.guest_cid == 3 and .peer_cid == 2 and .native_admission == false"
    " and .malformed_length_refused and .disconnected_history_recovered"
    " and ([.exchanges[].size] == [0,1,44,4096,65535,65536,65537,262144,1048576])'"
    " /work/native/transport-receipt.json"
)
host.succeed(
    "jq -e '.fault_injection == $f and .wrong_cid_injection_refused == $f"
    " and .reset_race_fenced == $f'"
    f" --argjson f {'true' if fault_injection else 'false'}"
    " /work/native/transport-receipt.json"
)
host.copy_from_vm("/work/native/transport-receipt.json")
host.copy_from_vm("/work/native/serial.log")
