#!/usr/bin/env python3
"""Opt-in production Galileo acceptance; run.json and evidence stay outside Git."""

import argparse
import base64
import datetime
import hashlib
import json
import os
import re
import shlex
import subprocess
import urllib.request
import uuid
from pathlib import Path
from typing import TypedDict


class RunConfig(TypedDict):
    run: str
    host: str
    account: str
    identity: str
    known_hosts: str


def fields(value: object) -> dict[str, object]:
    if not isinstance(value, dict) or not all(isinstance(key, str) for key in value):
        raise ValueError("Expected a JSON object")
    return {key: item for key, item in value.items()}


def text(value: object) -> str:
    if not isinstance(value, str) or not value:
        raise ValueError("Expected nonempty text")
    return value


def read(path: Path) -> dict[str, object]:
    value: object = json.loads(path.read_text())
    return fields(value)


class Acceptance:
    """@cc [owner:ghuntley,label:verification;security] galileo-live-fixture-ownership
    Guest access, lifecycle changes and deletion MUST use UUIDs from this run's
    persisted create receipts and verify the current account, owner and exact
    fixture name. Unknown create outcomes MUST retain their original request IDs.
    Only explicitly named run integrations may be removed. SSH transport failures
    MUST NOT count as successful policy refusals.
    """

    def __init__(self, directory: Path) -> None:
        self.directory = directory.resolve()
        if self.directory.stat().st_mode & 0o077:
            raise ValueError("Evidence directory must be private (0700)")
        config = read(self.directory / "run.json")
        self.config: RunConfig = {
            "run": text(config.get("run")),
            "host": text(config.get("host")),
            "account": text(config.get("account")),
            "identity": text(config.get("identity")),
            "known_hosts": text(config.get("known_hosts")),
        }
        self.prefix = self.config["run"]
        if not re.fullmatch(r"galileo-[a-z0-9-]{1,19}[a-z0-9]", self.prefix):
            raise ValueError("Expected a bounded unique galileo- run prefix")
        if not re.fullmatch(r"[a-z0-9.-]+", self.config["host"]):
            raise ValueError("Invalid host")
        for key in ("identity", "known_hosts"):
            if not Path(self.config[key]).is_absolute():
                raise ValueError("SSH paths must be absolute")

    def save(self, name: str, value: object) -> None:
        path = self.directory / name
        temporary = path.with_suffix(".tmp")
        with temporary.open("w") as stream:
            json.dump(value, stream, indent=2)
            stream.flush()
            os.fsync(stream.fileno())
        temporary.replace(path)
        descriptor = os.open(self.directory, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)

    def ssh(self) -> list[str]:
        return [
            "ssh",
            "-F",
            "/dev/null",
            "-T",
            "-i",
            self.config["identity"],
            "-o",
            "IdentitiesOnly=yes",
            "-o",
            "BatchMode=yes",
            "-o",
            "StrictHostKeyChecking=yes",
            "-o",
            "ConnectTimeout=10",
            "-o",
            "UserKnownHostsFile=" + self.config["known_hosts"],
        ]

    def execute(
        self,
        label: str,
        arguments: list[str],
        *,
        stdin: str | None = None,
        expected: int | tuple[int, ...] = 0,
        timeout: int = 180,
    ) -> str:
        result = subprocess.run(
            arguments, input=stdin, capture_output=True, text=True, timeout=timeout
        )
        output = re.sub(
            r"https://[^\s\"<>]+/(?:ssh/)?approv[^\s\"<>]*", "[REDACTED]", result.stdout
        )
        with (self.directory / "commands.jsonl").open("a") as stream:
            json.dump(
                {
                    "label": label,
                    "exit": result.returncode,
                    "stdout": output.replace("galileo-synthetic", "[REDACTED]"),
                    "stderr": result.stderr.replace("galileo-synthetic", "[REDACTED]"),
                    "at": datetime.datetime.now(datetime.UTC).isoformat(),
                },
                stream,
            )
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        accepted_exits = (expected,) if isinstance(expected, int) else expected
        if result.returncode == 255 or result.returncode not in accepted_exits:
            raise RuntimeError(
                f"{label}: unexpected exit {result.returncode}; see private evidence"
            )
        return output

    def command(
        self, line: str, *, secret: str | None = None, expected: int | tuple[int, ...] = 0
    ) -> dict[str, object]:
        output = self.execute(
            line.split(" --", 1)[0],
            [*self.ssh(), self.config["host"], line],
            stdin=None if secret is None else secret + "\n",
            expected=expected,
            timeout=210,
        )
        value: object = json.loads(output)
        result = fields(value)
        if result.get("version") != 1:
            raise ValueError("Unsupported command response")
        accepted_exits = (expected,) if isinstance(expected, int) else expected
        if 0 in accepted_exits and result.get("status") not in {"succeeded", "accepted"}:
            raise RuntimeError("Command did not succeed")
        return result

    def inventory(self) -> None:
        identity = self.command("whoami --json")
        if fields(identity["result"])["email"] != self.config["account"]:
            raise ValueError("Unexpected authenticated account")
        self.save("identity.json", identity)
        self.save("images.json", self.command("images --json"))
        self.save("integration-inventory.json", self.command("integration list --json"))

    def owned(self, role: str) -> dict[str, object]:
        if role not in {"source", "target", "customer", "ubuntu"}:
            raise ValueError("Unknown fixture role")
        receipt = read(self.directory / (role + "-receipt.json"))
        created = fields(receipt["result"])
        vm_id = text(created["id"])
        uuid.UUID(vm_id)
        machine = fields(self.command("show " + vm_id + " --json")["result"])
        if machine.get("owner") is not True or machine.get("name") != self.prefix + "-" + role:
            raise ValueError("Fixture ownership or name changed")
        if created.get("name") != machine["name"]:
            raise ValueError("Receipt does not identify this fixture")
        return machine

    def create(self, role: str, image: str) -> None:
        if role not in {"source", "target", "customer", "ubuntu"}:
            raise ValueError("Unknown fixture role")
        if not re.fullmatch(r"sha256:[0-9a-f]{64}", image):
            raise ValueError("Expected an immutable image digest")
        receipt = self.directory / (role + "-receipt.json")
        if receipt.exists():
            self.owned(role)
            return
        intent = self.directory / (role + "-intent.json")
        line = (
            "new --name "
            + self.prefix
            + "-"
            + role
            + " --image "
            + image
            + " --profile oss --cpu 1 --memory 512 --disk 4 --request-id "
            + self.prefix
            + "-"
            + role
            + " --no-wait --json"
        )
        if intent.exists():
            if read(intent).get("command") != line:
                raise ValueError("Creation intent changed; preserve the original request")
        else:
            self.save(intent.name, {"command": line})
        # Replay the immutable request after an unknown outcome; never mint a new ID.
        self.save(receipt.name, self.command(line))
        self.owned(role)

    def guest(self, role: str, command: str, *, expected: int = 0, timeout: int = 60) -> str:
        machine = self.owned(role)
        host = text(machine["ssh_host"])
        policy = read(self.directory / "ssh-trust.json")
        zone = text(policy["zone"])
        if not host.endswith("." + zone) or not re.fullmatch(r"[a-z0-9.-]+", host):
            raise ValueError("Unexpected guest hostname")
        label = host.removesuffix("." + zone)
        with urllib.request.urlopen(
            "https://" + self.config["host"] + "/api/audi/v1/known-hosts/" + label, timeout=10
        ) as response:
            wire = response.read(1025)
        parts = wire.decode().split()
        if len(wire) > 1024 or len(parts) != 3 or parts[:2] != [host, "ssh-ed25519"]:
            raise ValueError("Invalid current gateway key")
        digest = hashlib.sha256(base64.b64decode(parts[2], validate=True)).digest()
        alias = (
            "audi-"
            + base64.b32encode(digest).decode().rstrip("=").lower()
            + ".ssh."
            + self.config["host"]
        )
        key_path = self.directory / (role + "-gateway-known-hosts")
        key_path.write_text("@cert-authority " + alias + " " + text(policy["ca"]) + "\n")
        gateway = self.ssh()
        gateway[-1] = "UserKnownHostsFile=" + str(key_path)
        proxy = shlex.join(
            [*gateway, "-l", "audi", "-o", "HostKeyAlias=" + alias, host, "connect", label]
        )
        username = text(fields(read(self.directory / "identity.json")["result"])["guest_username"])
        return self.execute(
            "guest-" + role,
            [*self.ssh(), "-o", "ProxyCommand=" + proxy, username + "@" + host, command],
            expected=expected,
            timeout=timeout,
        )

    def probe(self, role: str, integration: str, path: str, flag: str) -> None:
        if not integration.startswith(self.prefix + "-"):
            raise ValueError("Integration is outside this run")
        url = "https://" + integration + ".integration.internal/" + path
        output = self.guest(
            role, "curl --fail --silent --show-error --max-time 20 " + shlex.quote(url)
        )
        value: object = json.loads(output)
        if fields(value).get(flag) is not True:
            raise RuntimeError("Origin verification flag failed")

    def cleanup(self) -> bool:
        """@cc [owner:ghuntley,label:verification;security] galileo-cleanup-pending-receipts
        Cleanup MUST retain accepted timed-out receipts under their original
        request IDs, wait longer at the transport layer than the server's
        180-second deadline, and report success only for terminal deletions.
        Replayed terminal receipts MUST match the run's original UUID/name;
        already deleted guests MUST NOT require a new live-VM lookup.
        """
        complete = True
        for role in ("source", "target", "customer", "ubuntu"):
            if (self.directory / (role + "-receipt.json")).exists():
                created = fields(read(self.directory / (role + "-receipt.json"))["result"])
                vm_id = text(created["id"])
                uuid.UUID(vm_id)
                if created.get("name") != self.prefix + "-" + role:
                    raise ValueError("Create receipt does not identify this fixture")
                request = self.prefix + "-delete-" + role
                line = "rm " + vm_id + " --request-id " + request + " --timeout 180 --json"
                intent = self.directory / (role + "-delete-intent.json")
                if intent.exists():
                    if read(intent).get("command") != line:
                        raise ValueError("Deletion intent changed; preserve original request")
                    observed = self.command("request show " + request + " --json")
                    resource = fields(observed["result"])
                    if (
                        observed.get("request_id") != request
                        or resource.get("id") != vm_id
                        or resource.get("name") != created["name"]
                    ):
                        raise ValueError("Deletion receipt does not identify this fixture")
                    self.save(role + "-delete.json", observed)
                    if observed.get("status") == "succeeded":
                        continue
                self.owned(role)
                if not intent.exists():
                    self.save(intent.name, {"command": line})
                result = self.command(line, expected=(0, 4))
                self.save(role + "-delete.json", result)
                if result.get("status") != "succeeded":
                    if result.get("wait_status") != "timed_out":
                        raise RuntimeError("Unknown deletion outcome; retain original request")
                    complete = False
        return complete


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("phase", choices=["inventory", "create", "probe", "cleanup"])
    parser.add_argument(
        "--role", choices=["source", "target", "customer", "ubuntu"], default="source"
    )
    parser.add_argument("--image")
    parser.add_argument("--integration")
    parser.add_argument("--path", default="probe")
    parser.add_argument("--flag", default="bearer")
    arguments = parser.parse_args()
    acceptance = Acceptance(arguments.directory)
    if arguments.phase == "inventory":
        acceptance.inventory()
    elif arguments.phase == "cleanup":
        if not acceptance.cleanup():
            print("cleanup pending; replay original request IDs")
            raise SystemExit(4)
    elif arguments.phase == "create":
        if arguments.image is None:
            parser.error("create requires --image")
        acceptance.create(arguments.role, arguments.image)
    else:
        if arguments.integration is None:
            parser.error("probe requires --integration")
        acceptance.probe(arguments.role, arguments.integration, arguments.path, arguments.flag)
    print(arguments.phase + " passed")


if __name__ == "__main__":
    main()
