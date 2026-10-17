"""Inspect only encrypted artifact headers, custody and fixed journal metadata."""

import json
import pwd
import subprocess
import sys
from pathlib import Path

if sys.argv[1:] == ["running"]:
    pid = subprocess.check_output(
        ["systemctl", "show", "porsche.service", "-p", "MainPID", "--value"], text=True
    ).strip()
    environment = dict(
        item.split(b"=", 1)
        for item in Path("/proc/" + pid + "/environ").read_bytes().split(b"\0")
        if b"=" in item
    )
    assert environment[b"ERL_CRASH_DUMP_SECONDS"] == b"10"
    assert environment[b"ERL_CRASH_DUMP_BYTES"] == b"268435456"
    assert environment[b"ERL_CRASH_DUMP_PUBLIC_KEY"] == b"/run/porsche-fixture/public.pem"
    assert environment[b"ERL_CRASH_DUMP"].startswith(b"/var/lib/porsche-crash-dumps/")
    sys.exit(0)

root = Path("/var/lib/porsche-crash-dumps")
uid = pwd.getpwnam("porsche").pw_uid
files = list(root.glob("*.dump"))
assert 1 <= len(files) <= 3
for path in files:
    info = path.stat()
    assert info.st_uid == uid and info.st_mode & 0o777 == 0o600 and info.st_nlink == 1
    assert 4 < info.st_size <= 268435456
    with path.open("rb") as stream:
        assert stream.read(4) == b"ENC0"

lines = subprocess.check_output(
    ["journalctl", "-u", "porsche.service", "-o", "cat", "--no-pager"], text=True
)
assert "=erl_crash_dump" not in lines
assert "BEGIN PRIVATE KEY" not in lines
assert "porsche_gateway_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" not in lines
reports = []
for line in lines.splitlines():
    try:
        value = json.loads(line)
    except ValueError:
        continue
    if isinstance(value, dict) and value.get("event") == "runtime.crash_dump":
        assert set(value) == {"event", "artifact", "bytes", "encrypted"}
        assert value["encrypted"] is True
        assert 4 < value["bytes"] <= 268435456
        reports.append(value)
assert reports
assert not list(Path("/var/lib/systemd/coredump").glob("core.*"))
