"""Boot native agents inside a router with actual Lilly policy and closed sinks."""

host.start()
host.wait_for_unit("multi-user.target")
host.succeed("test -c /dev/kvm")
host.succeed("mkfs.ext4 -F -q /dev/vdb && mkdir -p /work && mount /dev/vdb /work")
host.succeed("native-isolation-prepare")
namespace = "lilly-bd7662a5eeb4"
tap = "lvbd7662a5eeb4"
peer = "native-isolation-peer"
host.succeed(f"ip netns add {namespace}")
host.succeed(f"ip netns add {peer}")
host.succeed(f"ip -n {namespace} link set lo up")
host.succeed(f"ip -n {peer} link set lo up")
host.succeed(f"ip netns exec {namespace} ip tuntap add {tap} mode tap")
host.succeed(f"ip -n {namespace} link set {tap} up")
host.succeed(f"ip -n {namespace} address add 10.20.0.1/32 dev {tap}")
for address in ("10.20.0.203", "10.20.0.205"):
    host.succeed(f"ip -n {namespace} route add {address}/32 dev {tap} src 10.20.0.1")
for address in ("169.254.254.1", "1.1.1.1"):
    host.succeed(f"ip -n {namespace} address add {address}/32 dev lo")
host.succeed(f"ip link add uplink netns {namespace} type veth peer name uplink netns {peer}")
host.succeed(f"ip -n {namespace} address add 169.254.255.2/30 dev uplink")
host.succeed(f"ip -n {peer} address add 169.254.255.1/30 dev uplink")
for name in (namespace, peer):
    host.succeed(f"ip -n {name} link set uplink up")
host.succeed(f"ip -n {namespace} route add default via 169.254.255.1 dev uplink")
host.succeed(f"ip -n {peer} route add 10.20.0.0/16 via 169.254.255.2 dev uplink")
host.succeed(f"ip netns exec {namespace} sysctl -w net.ipv4.ip_forward=1")
for address in ("8.8.8.8", "8.8.4.5", "10.20.0.204", "172.16.20.1"):
    host.succeed(f"ip -n {peer} address add {address}/32 dev lo")
try:
    host.succeed(
        f"ip netns exec {namespace} python3 /etc/native-service-tools/native_isolation.py"
        " --image /etc/overalls-native-service-image"
        f" --vmm {vmm} --fixture /etc/native-service-fixture"
        f" --work /work/native-services --os {os_name}",
        timeout=800,
    )
    host.succeed(
        "jq -e '.native_admission == false and (.checks | length == 22)"
        " and (.boot_ids | unique | length == 2)' /work/native-services/service-receipt.json"
    )
    host.succeed(
        "test $(find /work/native-services -path '*/isolation-*/receipt.json' | wc -l) -eq 2"
    )
    host.copy_from_vm("/work/native-services/service-receipt.json")
    host.succeed("mkdir /work/isolation-receipts")
    host.succeed(
        "for receipt in /work/native-services/isolation-*/receipt.json; do "
        'directory=$(basename "$(dirname "$receipt")"); '
        "jq -e '(.checks | length == 5) and .native_admission == false' \"$receipt\"; "
        'cp "$receipt" "/work/isolation-receipts/$directory.json"; done'
    )
    host.copy_from_vm("/work/isolation-receipts")
finally:
    status, serial = host.execute("tail -c 131072 /work/native-services/serial.log 2>/dev/null")
    if status == 0:
        print(serial, flush=True)
        host.copy_from_vm("/work/native-services/serial.log")
