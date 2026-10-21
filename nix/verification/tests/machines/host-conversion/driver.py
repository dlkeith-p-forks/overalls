import json
import os
import pathlib
import shlex
import shutil
import socket
import subprocess
import tempfile
import time
from collections.abc import Sequence
from typing import Protocol


class MachineProcess(Protocol):
    def wait(self, timeout: float | None = None) -> int: ...


class MachineLike(Protocol):
    # Read-only, so the driver's `subprocess.Popen | None` attribute satisfies
    # it; the NixOS test driver leaves it None until the machine starts.
    @property
    def process(self) -> MachineProcess | None: ...

    def succeed(self, *commands: str, timeout: int | None = None) -> str: ...

    def wait_for_unit(self, unit: str) -> None: ...

    def wait_for_shutdown(self) -> None: ...


work = pathlib.Path(tempfile.mkdtemp(prefix="host-conversion-"))
key = work / "operator"
shutil.copyfile(operator_key, key)
key.chmod(0o600)
tarball = str(next(pathlib.Path(kexec_image).glob("*.tar.gz")))


def call(args: Sequence[str], input: str | None = None) -> str:
    try:
        return subprocess.run(
            args, check=True, capture_output=True, text=True, timeout=1200, input=input
        ).stdout.strip()
    except subprocess.CalledProcessError as error:
        print(error.stderr[-8000:])
        raise


# nixos-anywhere copies closures from a local store. The test builder has a
# read-only host store, so give its Nix client a private registered database.
os.environ["NIX_STATE_DIR"] = str(work / "nix-state")
os.environ["NIX_LOG_DIR"] = str(work / "nix-log")
os.environ["NIX_REMOTE"] = "local"
os.environ["NIX_CONFIG"] = "substituters =\nexperimental-features = nix-command flakes\n"
call([nix_store, "--load-db"], input=pathlib.Path(registration).read_text())


for source in sources:
    with subtest(source + " through authenticated kexec and installed boot"):
        directory = work / source
        directory.mkdir()
        disks = [directory / f"disk{i}.qcow2" for i in range(2)]
        if source == "ubuntu":
            call(
                [
                    qemu_img,
                    "create",
                    "-f",
                    "qcow2",
                    "-F",
                    "qcow2",
                    "-b",
                    ubuntu_image,
                    str(disks[0]),
                ]
            )
            call([qemu_img, "resize", str(disks[0]), "12G"])
        else:
            call([qemu_img, "create", "-f", "qcow2", str(disks[0]), "12G"])
        call([qemu_img, "create", "-f", "qcow2", str(disks[1]), "12G"])
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        known = directory / "known-hosts"
        host_key = directory / "host-key"
        call([keygen, "-q", "-t", "ed25519", "-N", "", "-f", str(host_key)])
        if source == "ubuntu":
            (directory / "meta-data").write_text(
                "instance-id: overalls-conversion\nlocal-hostname: conversion\n"
            )
            (directory / "user-data").write_text(
                "#cloud-config\n"
                + json.dumps(
                    {
                        "users": [
                            {
                                "name": "tester",
                                "sudo": "ALL=(ALL) NOPASSWD:ALL",
                                "shell": "/bin/bash",
                                "ssh_authorized_keys": [operator_public.strip()],
                            }
                        ],
                        "ssh_keys": {
                            "ed25519_private": host_key.read_text(),
                            "ed25519_public": host_key.with_suffix(".pub").read_text(),
                        },
                        "ssh_deletekeys": False,
                    }
                )
            )
            seed = directory / "seed.iso"
            call(
                [
                    geniso,
                    "-output",
                    str(seed),
                    "-volid",
                    "cidata",
                    "-joliet",
                    "-rock",
                    str(directory / "user-data"),
                    str(directory / "meta-data"),
                ]
            )

        def machine(
            name: str,
            media: str | pathlib.Path | None,
            *,
            port: int = port,
            disks: list[pathlib.Path] = disks,
            source: str = source,
        ) -> MachineLike:
            command = [
                qemu,
                "-enable-kvm",
                "-cpu",
                "host",
                "-m",
                "4096",
                "-smp",
                "2",
                "-uuid",
                "11111111-1111-4111-8111-111111111111",
                "-netdev",
                f"user,id=net,hostfwd=tcp:127.0.0.1:{port}-:22",
                "-device",
                "virtio-net-pci,netdev=net",
            ]
            for i, disk in enumerate(disks):
                command += [
                    "-drive",
                    f"file={disk},if=none,id=d{i},format=qcow2",
                    "-device",
                    f"virtio-blk-pci,drive=d{i},serial=member{i}",
                ]
            if media:
                command += ["-cdrom", str(media)]
                if source == "recovery":
                    command += ["-boot", "order=d"]
            vm = create_machine(name=name, start_command=shlex.join(command))
            driver.machines_qemu.append(vm)
            vm.start()
            return vm

        vm = machine(source, recovery_iso if source == "recovery" else seed)
        if source == "recovery":
            vm.wait_for_unit("sshd.service")
            original = vm.succeed("cat /etc/ssh/ssh_host_ed25519_key.pub").strip()
        else:
            original = host_key.with_suffix(".pub").read_text().strip()
        known.write_text(f"[127.0.0.1]:{port} {original}\n")

        def ssh(
            command: Sequence[str],
            user: str = "tester",
            data: str | None = None,
            *,
            known: pathlib.Path = known,
            port: int = port,
        ) -> str:
            return call(
                [
                    ssh_bin,
                    "-F",
                    "/dev/null",
                    "-o",
                    "BatchMode=yes",
                    "-o",
                    "StrictHostKeyChecking=yes",
                    "-o",
                    "GlobalKnownHostsFile=/dev/null",
                    "-o",
                    "UserKnownHostsFile=" + str(known),
                    "-o",
                    "ConnectTimeout=3",
                    "-p",
                    str(port),
                    "-i",
                    str(key),
                    user + "@127.0.0.1",
                    shlex.join(command),
                ],
                input=data,
            )

        def wait_ssh(user: str) -> str:
            deadline = time.monotonic() + 240
            while True:
                try:
                    return ssh(["true"], user)
                except subprocess.CalledProcessError:
                    assert time.monotonic() < deadline, "SSH failed after conversion"
                    time.sleep(2)

        wait_ssh("tester")
        ssh(["sudo", "-n", "touch", "/run/before-kexec"])
        arguments = [
            anywhere,
            "--no-substitute-on-destination",
            "-i",
            str(key),
            "--ssh-option",
            "UserKnownHostsFile=" + str(known),
            "--ssh-option",
            "GlobalKnownHostsFile=/dev/null",
            "--ssh-option",
            f"Port={port}",
            "--store-paths",
            formatter,
            system,
            "--kexec",
            tarball,
        ]
        # The packaged kexec phase always enters the pinned installer.
        call([*arguments, "--phases", "kexec", "--target-host", "tester@127.0.0.1"])
        wait_ssh("root")
        ssh(["test", "!", "-e", "/run/before-kexec"], "root")
        observed = ssh(["cat", "/etc/ssh/ssh_host_ed25519_key.pub"], "root")
        assert observed.split()[:2] == original.split()[:2]
        assert ssh(["hostname"], "root") == "nixos-installer"
        # Run the real complete-inventory guard after entering the RAM installer.
        discovery_code = pathlib.Path(remote_script).read_text()
        facts = json.loads(ssh(["python3", "-", "discover"], "root", discovery_code))
        guard = (
            pathlib.Path(remote_script)
            .read_text()
            .replace(
                "    try:\n        main()",
                "    try:\n        import io\n        sys.stdin = io.StringIO("
                + repr(
                    json.dumps(
                        {
                            "inventory": facts["inventory"],
                            "firmware": facts["firmware"],
                            "platform": platform,
                        }
                    )
                )
                + ")\n        main()",
            )
        )
        ssh(["python3", "-", "guard"], "root", guard)
        call([*arguments, "--phases", "disko,install", "--target-host", "root@127.0.0.1"])
        ssh(
            [
                "sh",
                "-eu",
                "-c",
                "umask 077; install -d -m 755 /mnt/etc/ssh; test ! -e /mnt/etc/ssh/ssh_host_ed25519_key; ssh-keygen -q -t ed25519 -N '' -f /mnt/etc/ssh/ssh_host_ed25519_key",
            ],
            "root",
        )
        installed_key = ssh(["cat", "/mnt/etc/ssh/ssh_host_ed25519_key.pub"], "root")
        assert installed_key.split()[:2] != original.split()[:2]
        payload = {
            "host": json.loads((pathlib.Path(system) / "etc/overalls-host.json").read_text()),
            "binding": json.loads(
                (pathlib.Path(system) / "etc/overalls-installation.json").read_text()
            ),
        }
        baseline_code = (
            pathlib.Path(remote_script)
            .read_text()
            .replace(
                "    try:\n        main()",
                "    try:\n        import io\n        sys.stdin = io.StringIO("
                + repr(json.dumps(payload))
                + ")\n        main()",
            )
        )
        baseline = json.loads(ssh(["python3", "-", "install-baseline"], "root", baseline_code))
        # Match the real installer: retain only this authenticated SSH source
        # for administrative access through the installed fleet firewall.
        assert json.loads(ssh(["python3", "-", "install-base-source"], "root", discovery_code)) == {
            "sources": 1
        }
        ssh(
            [
                "sh",
                "-eu",
                "-c",
                "umount -R /mnt; zpool export zroot; systemctl poweroff --no-block",
            ],
            "root",
        )
        assert vm.process is not None
        vm.process.wait(timeout=120)
        vm.wait_for_shutdown()
        known.write_text(f"[127.0.0.1]:{port} {installed_key}\n")
        installed = machine(source + "-installed", None)
        wait_ssh("tester")
        assert ssh(["sudo", "-n", "findmnt", "-n", "-o", "SOURCE", "/"]) == "zroot/root"
        assert (
            ssh(["sudo", "-n", "cat", "/etc/ssh/ssh_host_ed25519_key.pub"]).split()[:2]
            == installed_key.split()[:2]
        )
        ssh(["sudo", "-n", "systemctl", "start", "overalls-host-ready.service"])
        persisted = json.loads(ssh(["sudo", "-n", "cat", "/var/lib/overalls-host/storage.json"]))
        assert persisted == baseline
        try:
            ssh(["sudo", "-n", "systemctl", "poweroff", "--no-block"])
        except subprocess.CalledProcessError as error:
            # Shutdown may close SSH before its exit-status packet arrives.
            # The process wait below must still prove that poweroff completed.
            if error.returncode != 255:
                raise
        assert installed.process is not None
        installed.process.wait(timeout=120)
        installed.wait_for_shutdown()
