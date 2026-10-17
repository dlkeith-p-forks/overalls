# Boots the Windows image under the patched Firecracker inside the test host and
# waits for the Windows Special Administration Console on the serial console.
# `image` and `probe` (whether the image carries overalls-winprobe) are defined
# by the Nix wrapper before this fragment.

import json

host.start()
host.wait_for_unit("multi-user.target")
host.succeed("test -c /dev/kvm")
host.succeed("mkfs.ext4 -F -q /dev/vdb && mkdir -p /work && mount /dev/vdb /work")
host.succeed(
    f"test -e {image}/firmware && test -e {image}/disk.raw && test -e {image}/manifest.json"
)

host.succeed(
    "systemd-run --unit overalls-windows --collect"
    " -p StandardOutput=file:/work/serial.log -p StandardError=file:/work/launcher.log"
    f" overalls-windows-boot {image} /work 4096 2"
)

# Firmware banner proves the PVH firmware entry, PM timer and ACPI hand-off.
host.wait_until_succeeds(
    "grep -a -q -i -E 'BdsDxe|UEFI|Boot Manager|Windows Boot Manager' /work/serial.log",
    timeout=600,
)
# The SAC prompt proves Windows booted from the virtio-blk-pci disk with EMS.
host.wait_until_succeeds("grep -a -q 'SAC>' /work/serial.log", timeout=2400)
host.succeed("systemctl is-active overalls-windows.service")

if probe:
    # The viosock driver binds through PnP at first boot and its Winsock
    # provider service starts afterwards; the probe then listens on port 1099.
    # Firecracker answers "OK <port>" on the Unix socket and relays the probe's
    # JSON line. The writer side must stay open until the answer arrives: a
    # half-close after the request makes the muxer shut the guest connection
    # before the guest's reply (Lilly's own poller keeps its socket open).
    dial = "(printf 'CONNECT 1099\\n'; sleep 3) | socat -t 3 - UNIX-CONNECT:/work/v.sock"
    host.wait_until_succeeds(dial + " | grep -q overalls-winprobe", timeout=1800)
    answer = host.succeed(dial)
    print("vsock answer:\n" + answer)
    assert answer.startswith("OK "), answer
    assert '"peer_cid":2' in answer, answer
    # The probe publishes its log on the EFI system partition (first GPT
    # partition), readable from the live disk with mtools like the bootstrap log.
    table = json.loads(host.succeed("sfdisk --json /work/disk.raw"))
    offset = int(table["partitiontable"]["partitions"][0]["start"]) * 512
    log_text = host.succeed(
        f"MTOOLS_SKIP_CHECK=1 mcopy -n -i /work/disk.raw@@{offset} ::/overalls/logs/winprobe.log -"
    )
    print("probe log:\n" + log_text)
    assert "listening on vsock port 1099" in log_text, log_text
    assert "answered connection" in log_text, log_text

host.copy_from_vm("/work/serial.log")
host.copy_from_vm("/work/launcher.log")
