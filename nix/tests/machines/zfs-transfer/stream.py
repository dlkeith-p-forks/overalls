"""Exercise the production native stream helper with real ZFS and caller EOF."""

import os
import select
import shutil
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
LOCK = Path("/run/native-stream-owner")


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
    LOCK.mkdir(mode=0o700, exist_ok=True)
    child = subprocess.Popen(
        [HELPER, str(LOCK / "owner.lock"), "30000", str(len(producer)), *producer, *consumer],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    try:
        nonce = b"native-stream-fixture\n"
        child.stdin.write(nonce)
        child.stdin.flush()
        assert select.select([child.stdout], [], [], 5)[0]
        assert child.stdout.readline() == nonce
        if interrupt:
            deadline = time.monotonic() + 10
            while not MARKER.exists():
                assert child.poll() is None and time.monotonic() < deadline
                time.sleep(0.01)
            child.stdin.close()
        try:
            status = child.wait(timeout=35)
        except subprocess.TimeoutExpired:
            raise AssertionError("native stream did not finish") from None
        assert status == (4 if interrupt else 0)
        assert child.stdout.read() == b""
    finally:
        if not child.stdin.closed:
            child.stdin.close()
        if child.poll() is None:
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
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
