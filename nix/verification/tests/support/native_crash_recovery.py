"""Observe one native Firecracker SIGKILL and same-disk recovery, without admission."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import secrets
import shlex
import signal
import subprocess
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

import native_service_runner as runner
import native_services as services

POOL = "overalls_native_candidate"
DATASET = f"{POOL}/ROOT/overalls-native-candidate"
MARKER = '"$HOME/native-crash-retained"'
TRANSIENT = '"$HOME/native-crash-transient"'
RETAINED = b"native-crash-durable-bytes-v1\n"
SSH_LOGIN_EVENT = (
    b'{"service":"overalls-ssh-authorize","event":"ssh.login_recorded","severity":"info"}\n'
)
SERVICE_CHECKS = (
    "mmdsv2-current-boot-kernel",
    "assigned-address-reachable",
    "readiness-withheld-without-ssh-authority",
    "trust-installed-and-stale-refused",
    "flush-current-boot-and-refusals",
    "workspace-stale-foreign-malformed-refused",
    "workspace-native-https-shallow-checkout-and-exact-bytes",
    "workspace-exact-git-ownership-and-unrelated-root-refusal",
    "terminal-hello-ping-and-refusals",
    "terminal-managed-pty-input-resize-replay-and-token-refusal",
    "kernel-current-boot-rechecked",
    "complete-readiness-after-isolated-authority",
    "ssh-certified-host-and-foreign-ca-refusal",
    "ssh-managed-uid-gid-bash-and-passwordless-sudo",
    "ssh-foreign-key-root-foreign-user-and-password-refusals",
    "ssh-login-receipt-before-startup-and-client-environment",
    "executor-private-https-fixed-command-completed",
    "executor-current-heartbeat-withdrawal-before-command-deadline",
    "executor-whole-group-death-no-result-and-fresh-fence-completion",
    "first-boot-sigkill-and-final-clean-shutdown",
    "new-mmds-epoch-challenge-and-boot-id",
    "previous-boot-protocol-refused",
    "home-bytes-retained-across-abrupt-restart",
    "ssh-host-key-rotated-across-abrupt-restart",
    "all-boots-complete-service-oracles",
)
SERVICE_SCOPE = (
    "native services with synthetic HTTPS/SSH/Git/DNS authority and an observed first-boot "
    "SIGKILL; separate crash oracle required for recovery acceptance; no native isolation or admission"
)
CHECKS = (
    "complete-real-service-oracles-before-and-after-crash",
    "synced-home-marker-read-back-before-crash",
    "first-firecracker-exit-observed-sigkill",
    "same-disk-new-mmds-epoch-challenge-and-boot-id",
    "previous-boot-flush-workspace-and-terminal-refused",
    "native-filesystem-integrity-check-after-recovery",
    "exact-retained-home-bytes-after-recovery",
    "final-clean-shutdown-observed",
)
Integrity = Literal["ufs-snapshot-background-fsck", "zfs-completed-zero-error-scrub"]
Scrub = Literal["running", "complete"]


@dataclass(frozen=True)
class Observation:
    boot: services.Boot
    process: subprocess.Popen[bytes]
    os_name: services.Os


@dataclass(frozen=True)
class Artifacts:
    kernel: str
    image: str
    firmware: str
    vmm: str


def command_output(result: subprocess.CompletedProcess[bytes]) -> bytes:
    """Accept only the exact successful production login event, with bounded output."""
    if result.returncode != 0 or result.stderr != SSH_LOGIN_EVENT or len(result.stdout) > 4096:
        raise services.ProtocolError("native crash recovery guest command refused")
    return result.stdout


def command(context: runner.BootContext, script: str, *, root: bool = False) -> bytes:
    body = "set -eu; LC_ALL=C; export LC_ALL; " + script
    if root:
        body = f"{context.platform.sudo} -n {context.platform.bash} -c {shlex.quote(body)}"
    return command_output(
        runner.ssh(
            context.fixture,
            context.work / "known_hosts",
            body,
            network=context.network,
        )
    )


def root_mount(body: bytes, os_name: services.Os) -> None:
    """Bind integrity commands to the actual pinned root, never an injected target."""
    if len(body) > 4096:
        raise services.ProtocolError("invalid native crash root mount")
    try:
        rows = body.decode("ascii").splitlines()
    except UnicodeDecodeError:
        raise services.ProtocolError("invalid native crash root mount") from None
    roots = 0
    for row in rows:
        fields = row.split()
        if os_name == "freebsd" and len(fields) == 6:
            source, mountpoint, fstype = fields[:3]
            if mountpoint == "/":
                if (
                    source != "/dev/gpt/rootfs"
                    or fstype != "ufs"
                    or "rw" not in fields[3].split(",")
                ):
                    raise services.ProtocolError("invalid native crash root mount")
                roots += 1
        elif os_name == "illumos" and len(fields) in (6, 7):
            if fields[2] == "/":
                if fields[0] != DATASET or fields[3] != "zfs":
                    raise services.ProtocolError("invalid native crash root mount")
                roots += 1
        else:
            raise services.ProtocolError("invalid native crash root mount")
    if roots != 1:
        raise services.ProtocolError("invalid native crash root mount")


def check_root(context: runner.BootContext) -> None:
    tool = "/sbin/mount" if context.platform.name == "freebsd" else "/usr/sbin/mount"
    root_mount(command(context, f"{tool} -p", root=True), context.platform.name)


def scrub_status(body: bytes) -> Scrub:
    """Narrow pinned zpool status output; repairs, error counters and other vdevs fail."""
    if len(body) > 4096 or not body.endswith(b"\n"):
        raise services.ProtocolError("invalid native crash scrub status")
    try:
        lines = body.decode("ascii").splitlines()
    except UnicodeDecodeError:
        raise services.ProtocolError("invalid native crash scrub status") from None
    fields: dict[str, str] = {}
    entries: list[list[str]] = []
    configuration = False
    for line in lines:
        stripped = line.strip()
        if not stripped:
            continue
        if stripped == "config:":
            if configuration:
                raise services.ProtocolError("invalid native crash scrub status")
            configuration = True
            continue
        key, separator, value = stripped.partition(":")
        if separator and key in ("pool", "state", "scan", "errors"):
            if key in fields:
                raise services.ProtocolError("invalid native crash scrub status")
            fields[key] = value.strip()
            if key == "errors":
                configuration = False
        elif configuration:
            columns = stripped.split()
            if columns != ["NAME", "STATE", "READ", "WRITE", "CKSUM"]:
                entries.append(columns)
    if (
        fields.get("pool") != POOL
        or fields.get("state") != "ONLINE"
        or fields.get("errors") != "No known data errors"
        or len(entries) != 2
        or entries[0] != [POOL, "ONLINE", "0", "0", "0"]
        or len(entries[1]) != 5
        or re.fullmatch(r"c[0-9]{1,8}t[0-9]{1,8}d[0-9]{1,8}(?:s1)?", entries[1][0]) is None
        or entries[1][1:] != ["ONLINE", "0", "0", "0"]
    ):
        raise services.ProtocolError("invalid native crash scrub status")
    scan = fields.get("scan", "")
    if re.fullmatch(
        r"scrub repaired 0B in [0-9]+ days [0-9]{2}:[0-9]{2}:[0-9]{2} with 0 errors on [ -~]+",
        scan,
    ):
        return "complete"
    if re.fullmatch(r"scrub in progress since [ -~]+", scan):
        return "running"
    raise services.ProtocolError("invalid native crash scrub status")


def ufs_integrity_status(body: bytes) -> int:
    """Parse only the bounded decimal fsck exit status, never arbitrary output."""
    if re.fullmatch(rb"0|[1-9][0-9]{0,2}", body) is None or int(body) > 255:
        raise services.ProtocolError("invalid native crash UFS exit status")
    return int(body)


def integrity(context: runner.BootContext) -> Integrity:
    print("native crash phase=integrity-root-mount", flush=True)
    check_root(context)
    if context.platform.name == "freebsd":
        # Pinned fsck_ufs -B creates a snapshot for a supported active-filesystem
        # check; -f prevents the clean-superblock shortcut. Never run live -n.
        print("native crash phase=ufs-integrity-command", flush=True)
        body = command(
            context,
            "if /sbin/fsck_ufs -B -f /dev/gpt/rootfs >/dev/null 2>&1; "
            'then printf 0; else status=$?; printf "%s" "$status"; fi',
            root=True,
        )
        status = ufs_integrity_status(body)
        print(f"native crash ufs-fsck-exit={status}", flush=True)
        if status != 0:
            raise services.ProtocolError("native crash UFS integrity check failed")
        return "ufs-snapshot-background-fsck"
    if (
        command(
            context,
            f"/usr/sbin/zpool scrub {POOL} >/dev/null 2>&1; printf native-zfs-scrub-started",
            root=True,
        )
        != b"native-zfs-scrub-started"
    ):
        raise services.ProtocolError("native crash ZFS scrub did not start")
    deadline = time.monotonic() + 90
    while True:
        runner.alive(context.process)
        if (
            scrub_status(command(context, f"/usr/sbin/zpool status -p {POOL}", root=True))
            == "complete"
        ):
            return "zfs-completed-zero-error-scrub"
        if time.monotonic() >= deadline:
            raise services.ProtocolError("native crash ZFS scrub deadline exceeded")
        time.sleep(0.5)


def observed_crash(process: subprocess.Popen[bytes]) -> None:
    if process.poll() != -signal.SIGKILL:
        raise services.ProtocolError("native crash did not observe Firecracker SIGKILL")


def new_authority(before: services.Boot, after: services.Boot) -> None:
    if (
        before.boot_id == after.boot_id
        or before.binding.placement_id != after.binding.placement_id
        or before.binding.execution_epoch + 1 != after.binding.execution_epoch
        or before.binding.boot_challenge == after.binding.boot_challenge
    ):
        raise services.ProtocolError("native crash restart retained stale authority")


def stale_refusals(context: runner.BootContext, before: services.Boot) -> None:
    request = {"version": 1, "nonce": secrets.token_hex(32), **before.binding.fields()}
    services.refused(context.uds, 1026, services.encode({**request, "operation": "sync"}) + b"\n")
    services.refused(
        context.uds,
        1031,
        services.encode(
            {
                **request,
                "source": {
                    "version": 2,
                    "provider": "github",
                    "namespace": ["overalls-native-fixture"],
                    "repository": "unpublished-fixture",
                    "revision": {"kind": "default"},
                },
            }
        )
        + b"\n",
    )
    with services.connect(context.uds, 1075) as channel:
        services.terminal_send(
            channel, 1, services.terminal_hello(before.binding, secrets.token_bytes(16))
        )
        if channel.terminal_frame() != (0x81, b"\x01") or channel.receive(1):
            raise services.ProtocolError("native crash terminal accepted prior-boot proof")


def hash_value(value: object) -> str:
    if not isinstance(value, str) or not services.valid_hex(value, 64):
        raise services.ProtocolError("invalid native crash service artifact identity")
    return value


def service_evidence(body: bytes, before: Observation, after: Observation) -> Artifacts:
    """Reject incomplete or clean-reboot receipts before a crash claim is published."""
    new_authority(before.boot, after.boot)
    if before.os_name != after.os_name:
        raise services.ProtocolError("native crash restart changed platform")
    if len(body) > 16_384:
        raise services.ProtocolError("invalid native crash service receipt")
    value = services.decode_object(body)
    artifacts = Artifacts(
        hash_value(value.get("kernel_sha256")),
        hash_value(value.get("image_sha256")),
        hash_value(value.get("firmware_sha256")),
        hash_value(value.get("vmm_sha256")),
    )
    trust = hash_value(value.get("trust_bundle_digest"))
    if type(value.get("version")) is not int or value.get("native_admission") is not False:
        raise services.ProtocolError("invalid native crash service receipt")
    services.expect(
        value,
        {
            "version": 1,
            "os": before.os_name,
            "boot_ids": [before.boot.boot_id, after.boot.boot_id],
            "boot_endings": ["sigkill", "clean"],
            "kernel_sha256": artifacts.kernel,
            "trust_bundle_digest": trust,
            "image_sha256": artifacts.image,
            "firmware_sha256": artifacts.firmware,
            "vmm_sha256": artifacts.vmm,
            "checks": list(SERVICE_CHECKS),
            "native_admission": False,
            "scope": SERVICE_SCOPE,
        },
    )
    return artifacts


class Oracle:
    def __init__(self, work: Path) -> None:
        self.work = work
        self.before: Observation | None = None
        self.after: Observation | None = None
        self.checked_integrity: Integrity | None = None

    def verify(self, context: runner.BootContext) -> None:
        """@cc [owner:ghuntley,label:verification;security;recovery] native-crash-same-disk-evidence
        Before first-boot SIGKILL, the oracle MUST flush and read back fixed home
        bytes through real native services. The next boot MUST follow observed
        Firecracker SIGKILL, change MMDS epoch/challenge and boot ID, pass native
        filesystem integrity and exact retained-byte checks, and refuse previous
        flush, workspace and terminal authority over established live channels.
        Failed observations MUST NOT publish a recovery receipt. This sequence
        MUST NOT establish physical power-loss durability or fleet recovery.
        """
        if context.work != self.work or self.after is not None:
            raise services.ProtocolError("invalid native crash observation sequence")
        runner.alive(context.process)
        if services.readiness(context.uds, context.boot.binding) != context.boot:
            raise services.ProtocolError("native crash readiness changed authority")
        observation = Observation(context.boot, context.process, context.platform.name)
        if self.before is None:
            check_root(context)
            if (
                command(
                    context,
                    f"test ! -e {MARKER}; test ! -L {MARKER}; "
                    f"test ! -e {TRANSIENT}; test ! -L {TRANSIENT}; "
                    f"umask 077; printf 'native-crash-durable-bytes-v1\\n' > {MARKER}; "
                    "printf native-crash-marker-created",
                )
                != b"native-crash-marker-created"
            ):
                raise services.ProtocolError("native crash marker was not created")
            services.flush(context.uds, context.boot)
            if (
                command(context, f"test -f {MARKER}; test ! -L {MARKER}; /bin/cat {MARKER}")
                != RETAINED
            ):
                raise services.ProtocolError("native crash durable marker readback failed")
            # Deliberately leave additional fixture writes unsynced immediately
            # before the runner kills Firecracker; their retention is not claimed.
            if (
                command(
                    context,
                    f"umask 077; for ((index=0; index<2048; index++)); do "
                    f"printf 'native-unsynced-crash-churn\\n'; done > {TRANSIENT}; "
                    "printf native-crash-dirty-writes-completed",
                )
                != b"native-crash-dirty-writes-completed"
            ):
                raise services.ProtocolError("native crash dirty writes failed")
            self.before = observation
            return
        print("native crash phase=observed-sigkill", flush=True)
        observed_crash(self.before.process)
        if observation.os_name != self.before.os_name:
            raise services.ProtocolError("native crash restart changed platform")
        print("native crash phase=new-boot-authority", flush=True)
        new_authority(self.before.boot, context.boot)
        print("native crash phase=filesystem-integrity", flush=True)
        checked = integrity(context)
        print("native crash phase=retained-home-bytes", flush=True)
        if command(context, f"test -f {MARKER}; test ! -L {MARKER}; /bin/cat {MARKER}") != RETAINED:
            raise services.ProtocolError("native crash lost retained home bytes")
        print("native crash phase=stale-authority-refusal", flush=True)
        stale_refusals(context, self.before.boot)
        print("native crash phase=restored-flush-readiness", flush=True)
        services.flush(context.uds, context.boot)
        if services.readiness(context.uds, context.boot.binding) != context.boot:
            raise services.ProtocolError("native crash restored services changed authority")
        self.checked_integrity = checked
        self.after = observation

    def finish(self) -> None:
        """Publish only after the shared runner observes the final clean process exit."""
        if self.before is None or self.after is None or self.checked_integrity is None:
            raise services.ProtocolError("native crash recovery sequence is incomplete")
        observed_crash(self.before.process)
        if self.after.process.poll() != 0:
            raise services.ProtocolError("native crash final clean exit was not observed")
        artifacts = service_evidence(
            (self.work / "service-receipt.json").read_bytes(), self.before, self.after
        )
        receipt: dict[str, object] = {
            "version": 1,
            "os": self.before.os_name,
            "boot_ids": [self.before.boot.boot_id, self.after.boot.boot_id],
            "boot_endings": ["sigkill", "clean"],
            "kernel_sha256": artifacts.kernel,
            "image_sha256": artifacts.image,
            "firmware_sha256": artifacts.firmware,
            "vmm_sha256": artifacts.vmm,
            "marker_sha256": hashlib.sha256(RETAINED).hexdigest(),
            "native_integrity": self.checked_integrity,
            "checks": list(CHECKS),
            "native_admission": False,
            "scope": "one native Firecracker process crash and same-disk restart with synthetic authority; no host power-loss, physical isolation, fleet recovery or admission",
        }
        with tempfile.NamedTemporaryFile(
            mode="w", dir=self.work, prefix=".crash-", delete=False
        ) as output:
            temporary = Path(output.name)
            try:
                json.dump(receipt, output, sort_keys=True, indent=2)
                output.write("\n")
                output.flush()
                os.fsync(output.fileno())
                temporary.replace(self.work / "crash-recovery-receipt.json")
            finally:
                temporary.unlink(missing_ok=True)


class Options(argparse.Namespace):
    image: Path
    vmm: Path
    fixture: Path
    tap: str
    work: Path
    os_name: services.Os


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", type=Path, required=True)
    parser.add_argument("--vmm", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--tap", required=True)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--os-name", choices=("freebsd", "illumos"), default="freebsd")
    arguments = parser.parse_args(namespace=Options())
    oracle = Oracle(arguments.work)
    runner.run(
        arguments.image,
        arguments.vmm,
        arguments.fixture,
        arguments.tap,
        arguments.work,
        os_name=arguments.os_name,
        verify_boot=oracle.verify,
        crash_first_boot=True,
    )
    oracle.finish()


if __name__ == "__main__":
    main()
