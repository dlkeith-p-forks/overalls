import json as relocation_json

prepare(host)
prepare(destination)
pool(host, "/dev/vdc")
pool(destination, "/dev/vdc", image=False)
run(host, "relocation-source", "/work/source")
state = host.succeed("cat /work/source/prior.json")
relocation_json.loads(state)
# Lilly's transfer moves a stopped placement's dataset by ZFS send/receive.
host.succeed("zfs snapshot tank/vm@relocate")
destination.succeed(
    "systemd-run --unit relocation-receive --property=Type=exec"
    " --setenv=PATH=/run/current-system/sw/bin /run/current-system/sw/bin/sh -c "
    "'socat -u TCP4-LISTEN:9000,reuseaddr - | zfs receive -u tank/vm'"
)
destination.wait_for_unit("relocation-receive.service")
destination.wait_until_succeeds("ss -ltn | grep -q ':9000 '")
host.succeed("zfs send -c tank/vm@relocate | socat -u - TCP4:destination:9000", timeout=1800)
destination.succeed(
    "for attempt in $(seq 1 600); do "
    "systemctl is-active -q relocation-receive.service || break; sleep 1; done; "
    "! systemctl is-failed -q relocation-receive.service"
)
source_guid = host.succeed("zfs get -H -o value guid tank/vm@relocate").strip()
received_guid = destination.succeed("zfs get -H -o value guid tank/vm@relocate").strip()
assert source_guid == received_guid, "received snapshot identity differs"
# The source copy is reclaimed only after the destination holds the snapshot.
host.succeed("zfs destroy -r tank/vm")
destination.succeed(
    "zfs set mountpoint=/vms tank/vm && mountpoint -q /vms && test -f /vms/rootfs.raw"
)
destination.succeed(
    "install -d -m 0700 /work/transfer && cat > /work/transfer/prior.json <<'EOF'\n"
    + state.strip()
    + "\nEOF"
)
run(
    destination,
    "relocation-destination",
    "/work/destination",
    " --prior /work/transfer/prior.json",
)
destination.succeed(
    "jq -e '.version == 1 and .native_admission == false"
    f' and .os == "{os_name}"'
    " and (.checks | length == 7) and (.boot_ids | unique | length == 2)"
    " and (.placements | unique | length == 2)'"
    " /work/destination/relocation-receipt.json"
)
print(destination.succeed("cat /work/destination/relocation-receipt.json"), flush=True)
destination.copy_from_vm("/work/destination/relocation-receipt.json")
