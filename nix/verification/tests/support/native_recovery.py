"""Observe an actual native daemon failure and supervisor recovery in one boot."""

from __future__ import annotations

import argparse
import json
import re
import shlex
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

import native_service_runner as runner
import native_services as services

DAEMON = "overalls-native-flushd"
RUN_DIRECTORY = "/var/run/overalls"
MARKER = f"{RUN_DIRECTORY}/{DAEMON}.pid"
SSH_LOGIN_EVENT = (
    b'{"service":"overalls-ssh-authorize","event":"ssh.login_recorded","severity":"info"}\n'
)
Mode = Literal["0555", "0755"]
CHECKS = (
    "real-daemon-killed-and-reaped",
    "live-readiness-channel-withheld-three-times",
    "supervisor-restarted-new-pid-with-exact-bytes-and-mode",
    "same-boot-identity-retained",
    "flush-current-boot-and-refusals-restored",
)


@dataclass(frozen=True)
class Snapshot:
    mode: Mode
    pid: int
    digest: str


def snapshot(body: bytes) -> Snapshot:
    """Narrow SSH output before a PID or saved permission enters a root command."""
    if len(body) > 128:
        raise services.ProtocolError("invalid native recovery process snapshot")
    try:
        fields = body.decode("ascii").splitlines()
    except UnicodeDecodeError:
        raise services.ProtocolError("invalid native recovery process snapshot") from None
    if len(fields) != 3 or not body.endswith(b"\n"):
        raise services.ProtocolError("invalid native recovery process snapshot")
    if fields[0] == "0555":
        mode: Mode = "0555"
    elif fields[0] == "0755":
        mode = "0755"
    else:
        raise services.ProtocolError("invalid native recovery executable permissions")
    if (
        re.fullmatch(r"[1-9][0-9]{0,9}", fields[1]) is None
        or not 1 < int(fields[1]) <= 0x7FFF_FFFF
        or not services.valid_hex(fields[2], 64)
    ):
        raise services.ProtocolError("invalid native recovery process snapshot")
    parsed = Snapshot(mode, int(fields[1]), fields[2])
    if body != f"{parsed.mode}\n{parsed.pid}\n{parsed.digest}\n".encode("ascii"):
        raise services.ProtocolError("invalid native recovery process framing")
    return parsed


def executable(platform: runner.Platform) -> str:
    directory = "/usr/local/libexec" if platform.name == "freebsd" else "/opt/overalls/libexec"
    return f"{directory}/{DAEMON}"


def command(context: runner.BootContext, script: str) -> bytes:
    """Run only this module's fixed, privileged scripts through real managed SSH."""
    result = runner.ssh(
        context.fixture,
        context.work / "known_hosts",
        f"{context.platform.sudo} -n {context.platform.bash} -c {shlex.quote(script)}",
        network=context.network,
    )
    return command_output(result)


def command_output(result: subprocess.CompletedProcess[bytes]) -> bytes:
    """Permit only the production forced-session login event on command stderr."""
    if result.returncode != 0 or result.stderr != SSH_LOGIN_EVENT:
        raise services.ProtocolError("native recovery guest command refused")
    return result.stdout


def process_snapshot(context: runner.BootContext) -> Snapshot:
    path = executable(context.platform)
    digest = (
        f"/sbin/sha256 -q {path}"
        if context.platform.name == "freebsd"
        else f"/usr/bin/digest -a sha256 {path}"
    )
    script = (
        f"set -eu; test -f {path}; test ! -L {path}; "
        f'if [ "$(/usr/bin/find {path} -prune -user root -perm 0555)" = {path} ]; then mode=0555; '
        f'elif [ "$(/usr/bin/find {path} -prune -user root -perm 0755)" = {path} ]; then mode=0755; '
        f"else exit 1; fi; test -d {RUN_DIRECTORY}; test ! -L {RUN_DIRECTORY}; "
        f'test "$(/usr/bin/find {RUN_DIRECTORY} -prune -user root ! -perm -0020 ! -perm -0002)" = {RUN_DIRECTORY}; '
        f"test -f {MARKER}; test ! -L {MARKER}; "
        f'test "$(/usr/bin/find {MARKER} -prune -user root ! -perm -0020 ! -perm -0002)" = {MARKER}; '
        f"pid=$(/bin/cat {MARKER}); "
        f'printf \'%s\\n\' "$mode" "$pid"; {digest}'
    )
    current = snapshot(command(context, script))
    # Validate the external marker before any field becomes a kill argument.
    live = command(
        context,
        f'set -eu; test "$(/bin/cat {MARKER})" = {current.pid}; '
        f"/bin/kill -0 {current.pid}; printf native-daemon-live",
    )
    if live != b"native-daemon-live":
        raise services.ProtocolError("native recovery daemon was not live")
    return current


def fail_daemon(context: runner.BootContext, before: Snapshot) -> None:
    path = executable(context.platform)
    script = (
        f'set -eu; test "$(/bin/cat {MARKER})" = {before.pid}; '
        f"/bin/chmod a-x {path}; /bin/kill -KILL {before.pid}; attempt=0; "
        f"while /bin/kill -0 {before.pid} 2>/dev/null; do "
        'test "$attempt" -lt 5; attempt=$((attempt + 1)); /bin/sleep 1; done; '
        "attempt=0; "
        f"while [ -e {MARKER} ]; do "
        'test "$attempt" -lt 5; attempt=$((attempt + 1)); /bin/sleep 1; done; '
        "printf native-daemon-exited"
    )
    if command(context, script) != b"native-daemon-exited":
        raise services.ProtocolError("native daemon failure was not observed")


def restore(context: runner.BootContext, before: Snapshot) -> None:
    path = executable(context.platform)
    script = (
        f"set -eu; test -f {path}; test ! -L {path}; /bin/chmod {before.mode} {path}; "
        f"test -x {path}; printf native-daemon-executable-restored"
    )
    if command(context, script) != b"native-daemon-executable-restored":
        raise services.ProtocolError("native daemon executable was not restored")


def verify(context: runner.BootContext) -> None:
    """@cc [owner:ghuntley,label:verification;recovery] native-daemon-recovery-evidence
    The oracle MUST kill a real running flush daemon, confirm its PID has been
    reaped, and observe three refusals over the still-live readiness channel
    while executable permission prevents restart. It MUST restore the exact
    saved mode even on failure, require a different supervised PID with the
    same bytes/mode and boot identity, then re-exercise actual flush framing.
    Only a successful complete sequence MAY publish the closed per-boot receipt.
    This MUST NOT establish VM-crash durability, fleet recovery or admission.
    """
    runner.alive(context.process)
    if services.readiness(context.uds, context.boot.binding) != context.boot:
        raise services.ProtocolError("native recovery baseline changed boot identity")
    services.flush(context.uds, context.boot)
    before = process_snapshot(context)
    try:
        fail_daemon(context, before)
        for _ in range(3):
            runner.alive(context.process)
            services.readiness_withheld(context.uds)
            time.sleep(0.2)
    finally:
        restore(context, before)
    runner.wait_readiness(context.process, context.uds, context.boot)
    after = process_snapshot(context)
    if after.pid == before.pid or (after.mode, after.digest) != (before.mode, before.digest):
        raise services.ProtocolError("native supervisor did not restore the exact daemon")
    services.flush(context.uds, context.boot)
    if services.readiness(context.uds, context.boot.binding) != context.boot:
        raise services.ProtocolError("native daemon recovery changed boot identity")
    receipt: dict[str, object] = {
        "version": 1,
        "os": context.platform.name,
        "boot_id": context.boot.boot_id,
        "daemon": DAEMON,
        "checks": list(CHECKS),
        "native_admission": False,
        "scope": "one daemon failure and supervisor restart; no VM crash, durability or fleet recovery",
    }
    directory = context.work / f"recovery-{context.boot.boot_id}"
    directory.mkdir(mode=0o700)
    target = directory / "receipt.json"
    target.write_text(json.dumps(receipt, sort_keys=True, indent=2) + "\n", encoding="utf-8")


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
    runner.run(
        arguments.image,
        arguments.vmm,
        arguments.fixture,
        arguments.tap,
        arguments.work,
        os_name=arguments.os_name,
        verify_boot=verify,
    )


if __name__ == "__main__":
    main()
