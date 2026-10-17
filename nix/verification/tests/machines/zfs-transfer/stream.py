"""Exercise the production native stream helper with real ZFS and interruption."""

import os
import shutil
import signal
import subprocess
import sys
import time
from collections.abc import Sequence
from pathlib import Path

ZFS = shutil.which("zfs")
HELPER = shutil.which("lilly-transfer-stream")
TOKEN_HELPER = shutil.which("lilly-resume-token")
assert ZFS is not None and HELPER is not None and TOKEN_HELPER is not None
MARKER = Path("/run/native-stream-paused")


def value(dataset: str, name: str) -> str:
    result = subprocess.run([ZFS, "get", "-Hp", "-o", "value", name, dataset], capture_output=True)
    assert result.returncode == 0
    return result.stdout.strip().decode()


# @cc [owner:ghuntley,label:verification] native-resume-token-real-lineage
# The production token helper MUST accept real interrupted-receive tokens only
# for their exact snapshot name and GUID (every transfer is one full stream with
# no parent GUID, ADR-0155), reject altered checksum/name/GUID or the retired
# parent-GUID argument and return no token or diagnostic bytes. This proves token validation,
# not coordinator delivery, source ownership or permission to export.
def validate_token(token: str, snapshot: str) -> None:
    to_guid = value(snapshot, "guid")
    result = subprocess.run([TOKEN_HELPER, snapshot, to_guid, token], capture_output=True)
    assert result.returncode == 0 and result.stdout == b"ok\n" and result.stderr == b""
    damaged = token[:-1] + ("0" if token[-1] != "0" else "1")
    for arguments in [
        ["source/neighbor@lilly-b", to_guid, token],
        [snapshot, str(int(to_guid) + 1), token],
        [snapshot, to_guid, "0", token],
        [snapshot, to_guid, damaged],
    ]:
        result = subprocess.run([TOKEN_HELPER, *arguments], capture_output=True)
        assert result.returncode != 0 and result.stdout == b"" and result.stderr == b""


def run(producer: Sequence[str], consumer: Sequence[str], interrupt: bool = False) -> None:
    """Run the helper as hostd does: 30 s deadline, unthrottled, no progress
    file, both sides as root, own process group, no stdin. Interruption kills
    that group as hostd's lease release does; the sides die with the helper."""
    child = subprocess.Popen(
        [HELPER, "30000", "0", "-", "-", "-", str(len(producer)), *producer, *consumer],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        process_group=0,
    )
    try:
        if interrupt:
            deadline = time.monotonic() + 10
            while not MARKER.exists():
                assert child.poll() is None and time.monotonic() < deadline
                time.sleep(0.01)
            os.killpg(child.pid, signal.SIGKILL)
        try:
            status = child.wait(timeout=35)
        except subprocess.TimeoutExpired:
            raise AssertionError("native stream did not finish") from None
        assert status == (-signal.SIGKILL if interrupt else 0)
        assert child.stdout.read() == b""
        if interrupt:
            # The receive dies by its parent-death signal; wait for its exit.
            deadline = time.monotonic() + 10
            while subprocess.run(["pgrep", "-f", "^" + ZFS + " receive"]).returncode == 0:
                assert time.monotonic() < deadline, "receive outlived the helper"
                time.sleep(0.05)
    finally:
        if child.poll() is None:
            child.kill()
            child.wait()
        child.stdout.close()


def receiver(name: str) -> list[str]:
    return [
        ZFS,
        "receive",
        "-u",
        "-s",
        "-o",
        "readonly=on",
        "-o",
        "canmount=noauto",
        "-o",
        "mountpoint=/" + name,
        "target/" + name,
    ]


if sys.argv[1:] == ["slow-send"]:
    # Bounded fixture forwarding deliberately pauses a real send after 4 MiB.
    # The production helper still connects stdout directly to native receive.
    sending = subprocess.Popen([ZFS, "send", "source/workload@lilly-b"], stdout=subprocess.PIPE)
    remaining = 4 * 1024 * 1024
    while remaining:
        block = sending.stdout.read(min(65536, remaining))
        assert block
        sys.stdout.buffer.write(block)
        sys.stdout.buffer.flush()
        remaining -= len(block)
    MARKER.write_text(str(os.getpid()))
    time.sleep(60)
    raise AssertionError("fixture was not revoked")
elif sys.argv[1:] == ["validate-full"]:
    validate_token(value("target/workload", "receive_resume_token"), "source/workload@lilly-b")
elif __name__ == "__main__":
    run([ZFS, "send", "source/workload@lilly-b"], receiver("native-stream"))
    MARKER.unlink(missing_ok=True)
    run([sys.executable, __file__, "slow-send"], receiver("native-abort"), interrupt=True)
    token = value("target/native-abort", "receive_resume_token")
    assert token != "-"
    validate_token(token, "source/workload@lilly-b")
    # Token stays in this isolated machine; no arguments or data are printed.
    run([ZFS, "send", "-t", token], [ZFS, "receive", "-u", "-s", "target/native-abort"])
    for name in ["native-stream", "native-abort"]:
        assert value("target/" + name, "receive_resume_token") == "-"
        assert value("target/" + name, "mounted") == "no"
        assert value("target/" + name, "readonly") == "on"
        assert value("target/" + name + "@lilly-b", "guid") == value(
            "source/workload@lilly-b", "guid"
        )
