import base64
import pathlib
import shlex
import shutil
import subprocess
import tempfile
from collections.abc import Sequence
from typing import Protocol


class MachineLike(Protocol):
    def start(self) -> None: ...

    def shutdown(self) -> None: ...

    def wait_for_unit(self, unit: str) -> None: ...

    def succeed(self, *commands: str, timeout: int | None = None) -> str: ...

    def fail(self, *commands: str, timeout: int | None = None) -> str: ...


# @cc [owner:ghuntley,label:verification] installed-mirror-firmware-proof
# Installation tests MUST boot the real installer and installed disks through
# the declared firmware with KVM, no direct kernel or shared host store. Each mirror survivor
# MUST retain SSH, identity/data and a degraded pool. EC2 MUST retain SSH on its
# system disk after all guest disks disappear without creating a replacement pool.
# Test instrumentation belongs only to these test variants of the real modules.
work = pathlib.Path(tempfile.mkdtemp(prefix="overalls-install-"))
disks = [work / f"member-{i}.qcow2" for i in range(2 if platform == "hetzner" else 3)]
pool = "zroot" if platform == "hetzner" else "guests"
firmware_check = (
    "test -d /sys/firmware/efi" if firmware_mode == "uefi" else "test ! -d /sys/firmware/efi"
)
for disk in disks:
    subprocess.run([qemu_img, "create", "-f", "qcow2", str(disk), "12G"], check=True)


def machine(name: str, attached: Sequence[pathlib.Path], iso: str | None = None) -> MachineLike:
    nvram = work / f"{name}-nvram.fd"
    if firmware_mode == "uefi":
        shutil.copyfile(variables, nvram)
    command = [
        qemu,
        "-enable-kvm",
        "-cpu",
        "host",
        "-m",
        "2048",
        "-smp",
        "2",
        "-netdev",
        "user,id=network",
        "-device",
        "virtio-net-pci,netdev=network",
    ]
    if firmware_mode == "uefi":
        command += [
            "-drive",
            f"if=pflash,format=raw,unit=0,readonly=on,file={firmware}",
            "-drive",
            f"if=pflash,format=raw,unit=1,file={nvram}",
        ]
    for number, disk in enumerate(attached):
        command += [
            "-drive",
            f"file={disk},if=none,id=member{number},format=qcow2,cache=writeback,werror=report",
            "-device",
            f"virtio-blk-pci,drive=member{number},serial=member{number}",
        ]
    if iso:
        command += ["-cdrom", iso, "-boot", "order=d"]
    vm = create_machine(name=name, start_command=shlex.join(command))
    driver.machines_qemu.append(vm)
    return vm


def assert_keyed_ssh(vm: MachineLike) -> None:
    # OpenSSH versions differ in the casing of effective configuration keys.
    # Check the daemon's actual file and command status before parsing output.
    settings = vm.succeed("sshd -T -f /etc/ssh/sshd_config").lower().splitlines()
    assert "passwordauthentication no" in settings
    assert "kbdinteractiveauthentication no" in settings
    assert "permitrootlogin no" in settings


installer = machine("installer", disks, installer_iso)
installer.start()
installer.wait_for_unit("multi-user.target")
installer.wait_for_unit("sshd.service")
assert_keyed_ssh(installer)
installer.succeed(firmware_check)
installer.succeed("test ! -e /dev/disk/by-partlabel/disk-system0-ESP")
installer.fail("host-test-install")
installer.succeed("test ! -e /dev/disk/by-partlabel/disk-system0-ESP")
installer.succeed("host-test-install --erase-fixture-disks", timeout=900)
if firmware_mode == "uefi":
    installer.succeed("test -s /mnt/boot/EFI/BOOT/BOOTX64.EFI")
    if platform == "hetzner":
        installer.succeed("test -s /mnt/boot-mirror/EFI/BOOT/BOOTX64.EFI")
installer.succeed("test ! -e /mnt/etc/ssh/ssh_host_ed25519_key")
installer.succeed(f"zpool status -x {pool} | grep -F 'is healthy'")
installer.succeed(f"test $(zfs get -Hp -o value compression {pool}) = lz4")
installer.succeed(f"test $(zfs get -Hp -o value reservation {pool}/lilly) = 0")
installer.succeed(f"test $(zfs get -Hp -o value refreservation {pool}/lilly) = 0")
installer.succeed("printf persistent-install-marker >/mnt/root/install-marker && sync")
installer.succeed(f"umount -R /mnt && zpool export {pool}")
installer.shutdown()

installed = machine("installed", disks)
installed.start()
installed.wait_for_unit("sshd.service")
assert_keyed_ssh(installed)
installed.succeed(firmware_check)
if platform == "hetzner":
    installed.succeed("test $(findmnt -n -o SOURCE /) = zroot/root")
else:
    installed.succeed("test $(findmnt -n -o FSTYPE /) = ext4")
installed.succeed(f"zpool status -x {pool} | grep -F 'is healthy'")
installed.succeed(f"test $(zfs get -Hp -o value compression {pool}/lilly) = lz4")
installed.succeed(
    f"test $(zfs get -Hp -o value quota {pool}/lilly) = {536870912 if platform == 'hetzner' else 0}"
)
installed.succeed("test $(cat /sys/module/zfs/parameters/zfs_arc_max) = 536870912")
installed.succeed("systemctl is-active var-lib-lilly-pool.mount")
installed.succeed("nix-store --verify --check-contents", timeout=180)
host_key = installed.succeed("cat /etc/ssh/ssh_host_ed25519_key.pub").strip()
assert host_key.startswith("ssh-ed25519 ")
installed.succeed("test $(cat /root/install-marker) = persistent-install-marker")
# The fixture operator key is part of the test-only declared access registry,
# so authoritative activation preserves it across reboot and disk-loss branches.
installed.succeed("install -d -m 700 /root/.ssh")
fixture_key = base64.b64encode(pathlib.Path(test_key).read_bytes()).decode()
installed.succeed(
    "umask 077; printf %s " + shlex.quote(fixture_key) + " | base64 -d >/root/.ssh/install-test"
)
installed.succeed("chmod 600 /root/.ssh/install-test")
installed.succeed(
    "printf '127.0.0.1 ' >/root/.ssh/install-known-hosts && cat /etc/ssh/ssh_host_ed25519_key.pub >>/root/.ssh/install-known-hosts"
)
ssh_check = "ssh -n -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/root/.ssh/install-known-hosts -i /root/.ssh/install-test ghuntley@127.0.0.1 sudo -n test -f /root/install-marker"
installed.succeed(ssh_check)
installed.shutdown()

# Branch from the same clean shutdown. Never rejoin independently written forks.
for number, disk in enumerate(disks if platform == "hetzner" else disks[:1]):
    survivor = work / f"survivor-{number}.qcow2"
    subprocess.run(
        [qemu_img, "create", "-f", "qcow2", "-F", "qcow2", "-b", str(disk), str(survivor)],
        check=True,
    )
    vm = machine(f"survivor-{number}", [survivor])
    vm.start()
    vm.wait_for_unit("sshd.service")
    vm.succeed(firmware_check)
    if platform == "hetzner":
        vm.succeed("test $(findmnt -n -o SOURCE /) = zroot/root")
        vm.succeed("zpool status zroot | grep -F DEGRADED")
    else:
        vm.succeed("test $(findmnt -n -o FSTYPE /) = ext4")
        vm.fail("zpool list guests")
        vm.fail("systemctl start overalls-host-ready.service")
        vm.succeed("test ! -e /var/lib/overalls-host/enrollment.json")
        vm.fail("systemctl is-active lilly.service")
    vm.succeed("test $(cat /root/install-marker) = persistent-install-marker")
    assert vm.succeed("cat /etc/ssh/ssh_host_ed25519_key.pub").strip() == host_key
    assert_keyed_ssh(vm)
    vm.succeed(ssh_check)
    vm.shutdown()
