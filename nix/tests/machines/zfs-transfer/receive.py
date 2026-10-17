"""Controlled native receive fixture using pre-existing local journal intent."""

import json
import runpy
import shutil
import subprocess
import sys
from pathlib import Path

stream = runpy.run_path("/etc/native-stream-probe.py", run_name="fixture_library")
cancel_adoption = sys.argv[1:] == ["adoption-cancel"]
inception_adoption = sys.argv[1:] == ["adoption-inception"]
adoption = sys.argv[1:] == ["adoption"] or cancel_adoption or inception_adoption
placement = (
    "dddddddd-dddd-4ddd-8ddd-000000000010"
    if inception_adoption
    else "dddddddd-dddd-4ddd-8ddd-000000000009"
    if cancel_adoption
    else "dddddddd-dddd-4ddd-8ddd-000000000006"
    if sys.argv[1:] == ["partial"]
    else "dddddddd-dddd-4ddd-8ddd-000000000004"
    if adoption
    else "dddddddd-dddd-4ddd-8ddd-000000000002"
)
pool_path = "/adoption-pool" if adoption else "/import-pool"
root = Path(pool_path + "/.lilly-zfs/imports") / placement
journal = json.loads((root / "import.json").read_text())
endpoint = journal["binding"]["destination"]
properties = {
    "mountpoint": pool_path + "/vms/" + placement,
    "canmount": "noauto",
    "readonly": "on",
    "exec": "off",
    "setuid": "off",
    "devices": "off",
    "compression": "lz4",
    "reservation": "none",
    "refreservation": "none",
    "dedup": "off",
    "sync": "standard",
    "quota": "none",
    "refquota": "none",
    "lilly:host": endpoint["host_id"],
    "lilly:pool": endpoint["pool_id"],
    "lilly:vm": placement,
    "lilly:nonce": journal["nonce"],
}
zfs = shutil.which("zfs")
arguments = [zfs, "receive", "-u", "-s"]
for key, value in properties.items():
    arguments += ["-o", key + "=" + value]
arguments += [("target/adoptions/vm-" if adoption else "target/imports/vm-") + placement]
# Replacement injection deliberately bypasses the production boundary after the
# driver proves that boundary refuses to recreate the retained filesystem.
replacement = sys.argv[1:] == ["--replace"]
if not adoption and not replacement:
    mode = sys.argv[1] if sys.argv[1:] else "full"
    subprocess.run(["received-check", "receiver", mode], check=True)
    arguments = json.loads(Path("/run/receiver-" + mode + ".json").read_text())
source = (
    "source/adoption-inception"
    if inception_adoption
    else "source/adoption"
    if adoption
    else "source/workload"
)
# Every relocation stream is one full send of the single transfer snapshot.
producer = [zfs, "send", source + "@lilly-b"]
interrupt = sys.argv[1:] == ["partial"]
if interrupt:
    stream["MARKER"].unlink(missing_ok=True)
    producer = [sys.executable, "/etc/native-stream-probe.py", "slow-send"]
stream["run"](producer, arguments, interrupt=interrupt)
