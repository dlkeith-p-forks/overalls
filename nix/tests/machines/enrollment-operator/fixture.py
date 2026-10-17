"""Declare this native test host and capture its installed storage baseline."""

import importlib.util
import json
import os
import shutil
import subprocess
from functools import partial
from pathlib import Path

# The console file descriptor is held open for the lifetime of the process.
print = partial(print, file=open("/dev/console", "w"), flush=True)  # noqa: SIM115

os.umask(0o077)
spec = importlib.util.spec_from_file_location("host_remote", "/etc/enrollment-remote.py")
if spec is None or spec.loader is None:
    raise RuntimeError("enrollment remote helper unavailable")
remote = importlib.util.module_from_spec(spec)
spec.loader.exec_module(remote)
print("Discovering native fixture identities", flush=True)
facts = remote.discover()
assert len(facts["inventory"]["disks"]) == 2
host = {
    "name": "example",
    "reviewed": True,
    "platform": "hetzner",
    "firmware": facts["firmware"],
    "inventory": facts["inventory"],
    "identity": {"hostId": "45454545", "sshKeys": []},
    "network": {"10-test": {"matchConfig": {"Name": "eth1"}, "networkConfig": {"DHCP": "yes"}}},
    "storage": {
        "system": [disk["id"] for disk in facts["inventory"]["disks"]],
        "guests": [],
        "quotaBytes": 536870912,
        "ashift": 12,
    },
    "budgets": {"guestMemoryMiB": 256, "guestCpuCores": 1, "arcMaxMiB": 512},
    "credentials": [],
    "git": {"repository": "ssh://git@github.com/antithesishq/kittens", "knownHosts": "fixture"},
    "lilly": {
        "controlPlane": "https://control.example.test:5443",
        "egressInterface": "eth1",
        "overheads": {"cores": 1, "memoryBytes": 1024, "storageBytes": 100},
    },
}
root = Path("/root/enrollment/repo")
(root / "fleet/hosts/example").mkdir(parents=True)
(root / "nix/hosts").mkdir(parents=True)
(root / "secrets").mkdir()
(root / "fleet/hosts/example/host.json").write_text(json.dumps(host))
Path("/etc/overalls-host.json").write_text(json.dumps(host))
binding = {k: host[k] for k in ("platform", "firmware", "identity", "inventory", "storage")}
binding["effective"] = {}
Path("/etc/overalls-installation.json").write_text(json.dumps(binding))
print("Capturing storage baseline", flush=True)
observed = remote.storage(host)
remote.atomic(Path("/var/lib/overalls-host/storage.json"), observed)
Path("/root/enrollment/installed.json").write_text(
    json.dumps({"host": "example", "hostKey": facts["hostKey"], "storage": observed})
)
key = Path("/root/enrollment/key.pub").read_text().strip()
(root / "nix/users.nix").write_text(
    "{ recovery = { secretRecovery = true; sshKeys = [ " + json.dumps(key) + " ]; }; }"
)
shutil.copyfile("/etc/enrollment-inventory.nix", root / "nix/hosts/inventory.nix")
(
    root / "nix/secrets.nix"
).write_text("""{ lib }: let inventory = (import ./hosts/inventory.nix { inherit lib; }).secrets;
in inventory // { documents = inventory.documents // {
  git-bootstrap = { path = "secrets/git-bootstrap.enc.json"; hosts = []; recoveryOnly = true; };
}; }""")
nixpkgs = Path("/etc/enrollment-nixpkgs").read_text()
# Manifest evaluation only requires the exact pinned library. A tiny local
# input avoids copying/hash-scanning the entire nixpkgs tree inside the VM.
input_root = Path("/root/enrollment/nixpkgs-library")
input_root.mkdir()
(input_root / "flake.nix").write_text("{ outputs = _: { lib = import " + nixpkgs + "/lib; }; }")
(root / "flake.nix").write_text(
    "{ inputs.nixpkgs.url = "
    + json.dumps("path:" + str(input_root))
    + "; outputs = { self, nixpkgs }: {}; }"
)
print("Encrypting synthetic bootstrap", flush=True)
recipient = subprocess.check_output(["ssh-to-age"], input=(key + "\n").encode()).decode().strip()
bootstrap = json.dumps(
    {"overalls-git": {"production": {"GIT_DEPLOY_KEY": Path("/root/enrollment/key").read_text()}}}
).encode()
sealed = subprocess.check_output(
    [
        "sops",
        "--encrypt",
        "--age",
        recipient,
        "--input-type",
        "json",
        "--output-type",
        "json",
        "/dev/stdin",
    ],
    input=bootstrap,
    stderr=subprocess.DEVNULL,
)
(root / "secrets/git-bootstrap.enc.json").write_bytes(sealed)
subprocess.run(
    ["git", "init", str(root)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
)
subprocess.run(["git", "-C", str(root), "add", "."], check=True)
print("Locking local fixture flake", flush=True)
subprocess.run(
    ["nix", "--extra-experimental-features", "nix-command flakes", "flake", "lock", str(root)],
    check=True,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
)
subprocess.run(["git", "-C", str(root), "add", "flake.lock"], check=True)
subprocess.run(
    [
        "git",
        "-C",
        str(root),
        "-c",
        "user.name=Fixture",
        "-c",
        "user.email=fixture@example.test",
        "commit",
        "-qm",
        "Public fixture declaration",
    ],
    check=True,
)

print("Fixture declaration ready", flush=True)
