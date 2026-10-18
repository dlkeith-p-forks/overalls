#!/usr/bin/env python3
"""Opt-in live Porsche acceptance. Credentials and resumable evidence stay outside Git.

Usage: porsche_acceptance.py PRIVATE_RUN_DIRECTORY PHASE [--os OS] [--stage LABEL]
The directory must contain run.json (run, host, account), primary and known_hosts.
The opt-in matrix-* phases also require matrix.json with explicit image pins,
the Overalls executable and its managed SSH configuration and pinned guest trust.
Sharing commands are deliberately excluded. This runs real billable workloads.
"""

import argparse
import contextlib
import datetime
import hashlib
import json
import os
import re
import select
import shlex
import signal
import subprocess
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Literal, NotRequired, TypedDict

GuestOS = Literal["nixos", "ubuntu", "arch", "almalinux", "freebsd", "omnios", "windows"]
GUEST_OSES: tuple[GuestOS, ...] = (
    "nixos",
    "ubuntu",
    "arch",
    "almalinux",
    "freebsd",
    "omnios",
    "windows",
)
IMAGE_NAMES: dict[GuestOS, str] = {
    "nixos": "NixOS",
    "ubuntu": "Ubuntu 26.04 LTS",
    "arch": "Arch Linux",
    "almalinux": "AlmaLinux",
    "freebsd": "FreeBSD 14.3",
    "omnios": "OmniOS r151050",
    "windows": "Windows Server 2025",
}
SSH_LOGIN_EVENT = (
    '{"service":"overalls-ssh-authorize","event":"ssh.login_recorded","severity":"info"}\n'
)
SSH_WINDOWS_PQ_WARNING = (
    "** WARNING: connection is not using a post-quantum key exchange algorithm.\n"
    '** This session may be vulnerable to "store now, decrypt later" attacks.\n'
    "** The server may need to be upgraded. See https://openssh.com/pq.html\n"
)


def object_map(value: object) -> dict[str, object]:
    if not isinstance(value, dict) or not all(isinstance(key, str) for key in value):
        raise ValueError("Expected a JSON object")
    return {key: item for key, item in value.items()}


def nonempty_text(value: object) -> str:
    if not isinstance(value, str) or not value or any(ord(char) < 32 for char in value):
        raise ValueError("Expected nonempty text without control characters")
    return value


def read_object(path: Path) -> dict[str, object]:
    value: object = json.loads(path.read_text())
    return object_map(value)


def canonical_uuid(value: object) -> str:
    text = nonempty_text(value)
    if str(uuid.UUID(text)) != text:
        raise ValueError("Expected a canonical VM UUID")
    return text


@dataclass(frozen=True)
class MatrixConfig:
    cli: Path
    ssh_config: Path
    known_hosts: Path
    images: dict[GuestOS, str | None]

    @classmethod
    def parse(cls, value: object) -> "MatrixConfig":
        row = object_map(value)
        if set(row) != {"cli", "ssh_config", "known_hosts", "images"}:
            raise ValueError("Unexpected matrix configuration fields")
        paths: dict[str, Path] = {}
        for key in ("cli", "ssh_config", "known_hosts"):
            path = Path(nonempty_text(row[key]))
            if not path.is_absolute() or not path.is_file() or path.stat().st_mode & 0o022:
                raise ValueError(
                    "Matrix paths must be absolute, existing and not publicly writable"
                )
            paths[key] = path
        if not os.access(paths["cli"], os.X_OK):
            raise ValueError("Matrix CLI must be executable")
        raw_images = object_map(row["images"])
        if set(raw_images) != set(GUEST_OSES):
            raise ValueError("Matrix must explicitly configure all seven operating systems")
        images: dict[GuestOS, str | None] = {}
        for kind in GUEST_OSES:
            image = raw_images[kind]
            if image is not None and (
                not isinstance(image, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", image)
            ):
                raise ValueError("Matrix images must be immutable IDs or explicit null")
            images[kind] = image
        pinned = [image for image in images.values() if image is not None]
        if len(pinned) != len(set(pinned)):
            raise ValueError("Distinct operating systems require distinct image IDs")
        return cls(paths["cli"], paths["ssh_config"], paths["known_hosts"], images)


@dataclass(frozen=True)
class MatrixFixture:
    kind: GuestOS
    id: str
    name: str
    image_id: str
    ssh_host: str
    request_id: str

    @classmethod
    def parse(
        cls, kind: GuestOS, receipt: object, prefix: str, host: str, image_id: str | None
    ) -> "MatrixFixture":
        envelope = object_map(receipt)
        result = object_map(envelope["result"])
        identifier = canonical_uuid(result["id"])
        name = prefix + "-" + kind
        request = name + "-create"
        label = "v-" + name[:22].rstrip("-") + "-" + identifier.replace("-", "")
        if (
            image_id is None
            or envelope.get("status") not in ("accepted", "succeeded", "failed", "superseded")
            or envelope.get("request_id") != request
            or result.get("name") != name
            or result.get("image_id") != image_id
            or result.get("profile") != "oss"
            or (envelope.get("status") == "succeeded" and result.get("outcome") != "running")
            or result.get("ssh_host") != label + ".apps." + host
        ):
            raise ValueError("Matrix receipt does not bind this run's exact fixture")
        return cls(kind, identifier, name, image_id, label + ".apps." + host, request)


class RunConfig(TypedDict):
    """run.json: identifies the private run, target host and account."""

    run: str
    host: str
    account: str


class CommandOutcome(TypedDict):
    """A porsche CLI `--json` payload or a durable commands.jsonl record.

    Any single response carries only a subset of these keys: evidence records
    carry the command/exit/stdout fields, while CLI payloads carry the
    status/result envelope whose nested `result` shapes vary per command.
    """

    status: NotRequired[str]
    error: NotRequired[str]
    result: NotRequired["CommandOutcome"]
    request_id: NotRequired[str]
    id: NotRequired[str]
    name: NotRequired[str]
    outcome: NotRequired[str]
    reason: NotRequired[str]
    owner: NotRequired[bool]
    email: NotRequired[str]
    observed_state: NotRequired[str]
    desired_state: NotRequired[str]
    profile: NotRequired[str]
    vcpu: NotRequired[int]
    memory_bytes: NotRequired[int]
    disk_bytes: NotRequired[int]
    commands: NotRequired[list["CommandOutcome"]]
    items: NotRequired[list["CommandOutcome"]]
    next_cursor: NotRequired[str | None]
    images: NotRequired[list["CommandOutcome"]]
    keys: NotRequired[list["CommandOutcome"]]
    fingerprint: NotRequired[str]
    image_id: NotRequired[str]
    ssh_host: NotRequired[str]
    guest_username: NotRequired[str]
    command: NotRequired[str]
    key: NotRequired[str]
    exit: NotRequired[int | None]
    timeout: NotRequired[bool]
    seconds: NotRequired[float]
    stdout: NotRequired[str]
    stderr: NotRequired[str]
    at: NotRequired[str]


class PhysicalRow(TypedDict):
    """One row of the physical-evidence SQL join (psql json_agg output)."""

    id: str
    name: str
    observed_state: str
    archived_at: str | None
    placement: str
    compute_held: float | None
    disk_held: float | None


class PhysicalEvidence(PhysicalRow):
    """A physical row enriched with local systemd, ZFS and process evidence."""

    unit_active: bool
    firecracker_pids: list[int]
    dataset_guid: str | None


class Acceptance:
    """@cc [owner:ghuntley,label:safety] porsche-fixture-ledger
    Lifecycle mutations MUST use UUIDs recovered from this run's durable create
    receipts and verify their current names and ownership before mutation.
    Unknown outcomes MUST retain their original request IDs for reconciliation.
    """

    def __init__(self, directory: str | Path) -> None:
        if not __debug__:
            raise RuntimeError("Acceptance assertions require Python without -O")
        self.directory: Path = Path(directory).resolve()
        if self.directory.stat().st_mode & 0o077:
            raise ValueError("Run directory must be private (0700)")
        raw_config = read_object(self.directory / "run.json")
        self.config: RunConfig = {
            "run": nonempty_text(raw_config["run"]),
            "host": nonempty_text(raw_config["host"]),
            "account": nonempty_text(raw_config["account"]),
        }
        if not re.fullmatch(r"[a-z0-9][a-z0-9.-]{0,252}", self.config["host"]):
            raise ValueError("Expected a DNS management host")
        self.prefix: str = self.config["run"]
        if not re.fullmatch(r"porsche-[0-9]{8}-[0-9]{6}", self.prefix):
            raise ValueError("Expected unique porsche-YYYYMMDD-HHMMSS run prefix")
        self.lock: threading.Lock = threading.Lock()

    def ssh(self, key: str = "primary") -> list[str]:
        return [
            "ssh",
            "-F",
            "/dev/null",
            "-T",
            "-i",
            str(self.directory / key),
            "-o",
            "IdentitiesOnly=yes",
            "-o",
            "BatchMode=yes",
            "-o",
            "StrictHostKeyChecking=yes",
            "-o",
            "ConnectTimeout=10",
            "-o",
            "UserKnownHostsFile=" + str(self.directory / "known_hosts"),
            "-p",
            "22",
            self.config["host"],
        ]

    def save(self, name: str, value: object) -> None:
        with self.lock:
            target = self.directory / name
            temporary = target.with_suffix(".tmp")
            with open(temporary, "w") as stream:
                json.dump(value, stream, indent=2)
                stream.flush()
                os.fsync(stream.fileno())
            temporary.replace(target)
            descriptor = os.open(self.directory, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(descriptor)
            finally:
                os.close(descriptor)

    def command(
        self,
        command: str,
        *,
        expect: int | None = 0,
        key: str = "primary",
        timeout: int | float = 160,
        terminal_receipts: bool = False,
    ) -> CommandOutcome:
        """@cc [owner:ghuntley,label:verification] porsche-command-evidence
        Successful JSON commands MUST have exit status zero and valid JSON.
        Expected rejections MUST NOT accept SSH transport failure as proof;
        evidence MUST retain failed and timed-out attempts.
        Explicit terminal-receipt polling MAY return failed/superseded envelopes
        with a nonzero command exit for reconciliation, never as success. It
        MUST still reject transport failure and mismatched exit/status pairs.
        """
        if terminal_receipts and (expect != 0 or "--json" not in shlex.split(command)):
            raise ValueError("Terminal receipts require JSON receipt polling")
        if shlex.split(command)[:1] == ["share"]:
            raise ValueError("Sharing is excluded from this acceptance run")
        started = time.monotonic()
        process = subprocess.Popen(
            [*self.ssh(key), command], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )
        timed_out = False
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            process.kill()
            stdout, stderr = process.communicate()
            timed_out = True
        # Unknown/revoked keys can receive approval URLs. Never persist those.
        stdout = re.sub(r'https://[^\s"<>]+/(?:ssh/)?approv[^\s"<>]*', "[REDACTED]", stdout)
        record: CommandOutcome = dict(
            command=command,
            key=key,
            exit=process.returncode,
            timeout=timed_out,
            seconds=round(time.monotonic() - started, 3),
            stdout=stdout,
            stderr=stderr,
            at=datetime.datetime.now(datetime.UTC).isoformat(),
        )
        with self.lock, open(self.directory / "commands.jsonl", "a") as stream:
            stream.write(json.dumps(record) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        if terminal_receipts and (
            timed_out or process.returncode is None or not 0 <= process.returncode < 255
        ):
            raise RuntimeError("Matrix receipt transport failed; see private commands.jsonl")
        if expect is not None and not terminal_receipts:
            assert not timed_out, record
            assert (process.returncode == 0) == (expect == 0), record
            assert process.returncode != 255, (
                record
            )  # Transport failure is not a negative test pass.
        if "--json" in shlex.split(command) and stdout.strip():
            try:
                result = json.loads(stdout)
            except json.JSONDecodeError:
                if terminal_receipts:
                    raise RuntimeError(
                        "Malformed matrix receipt; see private commands.jsonl"
                    ) from None
                if expect == 1 and process.returncode != 0:
                    return record  # Parser errors occur before output-mode selection.
                raise
            if terminal_receipts:
                if (
                    not isinstance(result, dict)
                    or result.get("status") not in ("accepted", "succeeded", "failed", "superseded")
                    or (process.returncode == 0)
                    != (result.get("status") in ("accepted", "succeeded"))
                ):
                    raise RuntimeError("Invalid matrix receipt outcome; see private commands.jsonl")
            elif expect == 0:
                assert result.get("status") in ("succeeded", "accepted"), result
            return result
        if terminal_receipts:
            raise RuntimeError("Missing matrix receipt; see private commands.jsonl")
        return record

    def request(self, request_id: str, seconds: int = 600) -> CommandOutcome:
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            result = self.command(f"request show {request_id} --json")
            if result["status"] != "accepted":
                assert result["status"] == "succeeded", result
                return result
            time.sleep(2)
        raise TimeoutError(request_id)

    def name(self, number: int) -> str:
        return f"{self.prefix}-{number:03}"

    def create(self, number: int) -> None:
        request_id = f"{self.prefix}-create-{number:03}"
        command = f"new --name {self.name(number)} --request-id {request_id} --no-wait --json"
        self.save(f"intent-{number:03}.json", dict(command=command, request_id=request_id))
        result = self.admit(command)
        self.save(f"vm-{number:03}.json", result)
        result = self.request(request_id)
        assert result["result"]["outcome"] == "running", result
        self.save(f"vm-{number:03}.json", result)
        print(f"created {number:03}: {result['result']['id']}", flush=True)

    def admit(self, command: str) -> CommandOutcome:
        # Capacity observations can temporarily withhold admission during startup.
        # Preserve the exact semantic command and request ID on every retry.
        for attempt in range(60):
            result = self.command(command, expect=None)
            if result.get("status") in ("accepted", "succeeded"):
                return result
            if result.get("error") != "conflict":
                raise RuntimeError(result)
            time.sleep(min(2 + attempt, 10))
        raise TimeoutError(f"Admission remained in conflict: {command}")

    def fixtures(self) -> list[CommandOutcome]:
        return [json.loads(path.read_text()) for path in sorted(self.directory.glob("vm-*.json"))]

    def owned(self, receipt: CommandOutcome) -> CommandOutcome:
        machine = self.command(f"show {receipt['result']['id']} --json")["result"]
        assert machine["owner"] is True, machine
        assert machine["name"] == receipt["result"]["name"], machine
        if not machine["name"].startswith(self.prefix + "-"):
            generated = json.loads((self.directory / "generated.json").read_text())
            assert generated["request_id"] == self.prefix + "-generated", generated
            assert generated["result"]["id"] == machine["id"], machine
        return machine

    def lifecycle(self, receipt: CommandOutcome, verb: str, stage: str) -> None:
        completed = self.directory / f"{stage}-{receipt['result']['id']}.json"
        if completed.exists():
            self.request(json.loads(completed.read_text())["request_id"])
            return
        machine = self.owned(receipt)
        request_id = f"{self.prefix}-{stage}-{machine['id']}"
        result = self.admit(f"{verb} {machine['id']} --request-id {request_id} --no-wait --json")
        result = self.request(request_id)
        self.save(f"{stage}-{machine['id']}.json", result)
        print(f"{stage}: {machine['id']} {result['status']}", flush=True)

    def inventory(self) -> None:
        for command in ["help", "whoami", "images", "ls", "ssh-key list"]:
            result = self.command(command + " --json")
            filename = command.replace(" ", "-") + "-baseline.json"
            if not (self.directory / filename).exists():
                self.save(filename, result)
            self.command(command)
        assert self.command("whoami --json")["result"]["email"] == self.config["account"]
        catalog = self.command("help --json")["result"]["commands"]
        for item in catalog:
            if not item["name"].startswith("share "):
                self.command("help " + item["name"] + " --json")
                self.command("help " + item["name"])
        for command in [
            "nonsense",
            "help nonsense",
            "new --cpu 0",
            "new --name BAD",
            "new --memory 1",
            "new --disk 1",
            "new --profile nonsense",
            "new --image sha256:" + "0" * 64,
            "show absent-test-machine",
            "request show absent-test-request",
            "ls --after invalid",
            "stop",
            "start",
            "rm",
            "ssh-key remove invalid",
        ]:
            self.command(command + " --json", expect=1)

    def running(self) -> None:
        fixtures = self.fixtures()
        assert len(fixtures) == 50, len(fixtures)
        machines = [self.owned(receipt) for receipt in fixtures]
        assert len({vm["id"] for vm in machines}) == 50
        assert all(vm["observed_state"] == vm["desired_state"] == "running" for vm in machines)
        pages: list[CommandOutcome] = []
        cursor: str | None = None
        while True:
            page = self.command("ls --json" + (f" --after {cursor}" if cursor else ""))["result"]
            pages.extend(page["items"])
            cursor = page["next_cursor"]
            if cursor is None:
                break
        assert {vm["id"] for vm in machines} <= {vm["id"] for vm in pages}
        self.save("running.json", machines)
        print("50 distinct test VMs running and visible through ls", flush=True)

    def physical(self, stage: str) -> None:
        """Read-only local sudo evidence, bound to receipt UUIDs rather than names."""
        ids = [str(uuid.UUID(r["result"]["id"])) for r in self.fixtures()]
        assert len(ids) == 50
        literals = ",".join("'" + value + "'" for value in ids)
        sql = f"""SELECT json_agg(t) FROM (
          SELECT v.id, v.name, v.observed_state, v.archived_at,
                 p.id AS placement, r.compute_held, r.disk_held
          FROM compute_virtual_machines v
          JOIN compute_workload_placements p ON p.vm_id=v.id
          LEFT JOIN compute_reservations r ON r.placement_id=p.id
          WHERE v.id IN ({literals}) ORDER BY v.id,p.id) t;"""
        rows: list[PhysicalRow] = json.loads(
            subprocess.check_output(
                ["sudo", "-u", "postgres", "psql", "-X", "-d", "marshall", "-At", "-c", sql],
                text=True,
            )
        )
        datasets = dict(
            line.split("\t")
            for line in subprocess.check_output(
                ["sudo", "zfs", "list", "-H", "-o", "name,guid"], text=True
            ).splitlines()
        )
        processes = subprocess.check_output(["sudo", "ps", "-eo", "pid,comm,args"], text=True)
        evidence: list[PhysicalEvidence] = []
        for row in rows:
            placement = str(uuid.UUID(row["placement"]))
            unit = f"lilly-vm-{placement}.service"
            active = (
                subprocess.run(
                    ["systemctl", "is-active", unit], capture_output=True, text=True
                ).stdout.strip()
                == "active"
            )
            pids = [
                int(line.split()[0])
                for line in processes.splitlines()
                if len(line.split()) > 2
                and line.split()[1] == "firecracker"
                and f"--id {placement} " in line
            ]
            dataset = datasets.get("zroot/lilly/vm-" + placement)
            evidence.append(
                dict(**row, unit_active=active, firecracker_pids=pids, dataset_guid=dataset)
            )
        self.save(f"physical-{stage}.json", evidence)
        assert len(evidence) == 50
        for row in evidence:
            if stage in ("running", "restarted"):
                assert (
                    row["unit_active"] and len(row["firecracker_pids"]) == 1 and row["dataset_guid"]
                ), row
            elif stage == "stopped":
                assert (
                    not row["unit_active"] and not row["firecracker_pids"] and row["dataset_guid"]
                ), row
            elif stage == "deleted":
                assert (
                    not row["unit_active"]
                    and not row["firecracker_pids"]
                    and not row["dataset_guid"]
                ), row
                assert row["archived_at"] and not row["compute_held"] and not row["disk_held"], row
        if stage in ("stopped", "restarted"):
            original = json.loads((self.directory / "physical-running.json").read_text())
            assert {x["id"]: x["dataset_guid"] for x in original} == {
                x["id"]: x["dataset_guid"] for x in evidence
            }
        print(f"Physical {stage}: {len(evidence)} verified", flush=True)

    def interactive(self) -> None:
        process = subprocess.Popen(
            self.ssh(), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )
        assert (
            process.stdin is not None and process.stdout is not None and process.stderr is not None
        )
        transcript = b""

        def prompt() -> None:
            nonlocal transcript
            stream = process.stdout
            assert stream is not None
            chunk = b""
            deadline = time.monotonic() + 20
            while not chunk.endswith(b"porsche> "):
                assert time.monotonic() < deadline, chunk
                ready, _, _ = select.select([stream], [], [], 1)
                if ready:
                    data = os.read(stream.fileno(), 4096)
                    assert data, chunk
                    chunk += data
            transcript += chunk

        try:
            prompt()
            for command in ["whoami --json", "images", "ls --json", "help new"]:
                process.stdin.write((command + "\n").encode())
                process.stdin.flush()
                prompt()
            process.stdin.write(b"exit\n")
            process.stdin.flush()
            stdout, stderr = process.communicate(timeout=20)
            transcript += stdout
            self.save(
                "interactive.json",
                dict(exit=process.returncode, stdout=transcript.decode(), stderr=stderr.decode()),
            )
            assert process.returncode == 0
            assert self.config["account"] in transcript.decode()
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()

    def scenarios(self) -> None:
        receipt = self.fixtures()[0]
        vm = self.owned(receipt)
        for ref in [vm["id"], vm["name"]]:
            assert self.command(f"show {ref} --json")["result"]["id"] == vm["id"]
            self.command(f"show {ref}")
        self.command(f"request show {receipt['request_id']}")
        replay = self.command(
            f"new --name {vm['name']} --request-id {receipt['request_id']} --json"
        )
        assert replay["result"]["id"] == vm["id"]
        self.command(
            f"new --name {vm['name']} --cpu 2 --request-id {receipt['request_id']} --json", expect=1
        )
        self.command(
            f"new --name {vm['name']} --request-id {self.prefix}-duplicate --json", expect=1
        )
        self.command("exit --json")
        self.command("exit")
        self.interactive()
        self.save("scenarios.json", {"lookup_replay_conflict_interactive": "passed"})

    def automation(self) -> None:
        if (self.directory / "automation.json").exists():
            return
        image = self.command("images --json")["result"]["images"][0]
        request_id = self.prefix + "-generated"
        command = (
            f"new --image {image['id']} --profile oss --cpu 1 --memory 512 --disk 2 "
            f"--request-id {request_id} --json --no-wait"
        )
        extra = self.admit(command)
        self.save("generated.json", extra)
        extra = self.request(request_id)
        self.save("generated.json", extra)
        vm = self.owned(extra)
        assert vm["profile"] == "oss" and vm["vcpu"] == 1
        assert vm["memory_bytes"] == 512 * 1024**2 and vm["disk_bytes"] == 2 * 1024**3
        # Replaying in text mode also checks presentation options are nonsemantic.
        self.command(command.replace(" --json", ""))
        timeout_id = self.prefix + "-timeout-stop"
        result = self.command(
            f"stop {vm['id']} --request-id {timeout_id} --timeout 1 --json", expect=None
        )
        self.save("timeout.json", result)
        assert result["status"] in ("accepted", "succeeded"), result
        self.request(timeout_id)
        self.command(f"stop {vm['id']} --request-id {timeout_id}")

        # Kill the local client only after seeing server-side acceptance/waiting.
        disconnected_id = self.prefix + "-disconnected-start"
        command = f"start {vm['id']} --request-id {disconnected_id} --json"
        self.save("disconnect-intent.json", dict(command=command, request_id=disconnected_id))
        process = subprocess.Popen(
            [*self.ssh(), command], stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )
        assert process.stderr is not None
        progress = b""
        deadline = time.monotonic() + 20
        try:
            while b"waiting for completion" not in progress:
                assert time.monotonic() < deadline, progress
                ready, _, _ = select.select([process.stderr], [], [], 1)
                if ready:
                    chunk = os.read(process.stderr.fileno(), 4096)
                    assert chunk, progress
                    progress += chunk
        finally:
            process.kill()
            process.communicate()
        completed = self.request(disconnected_id)
        assert completed["result"]["outcome"] == "running"
        self.command(command.replace(" --json", ""))
        self.save(
            "disconnect.json",
            dict(request_id=disconnected_id, progress=progress.decode(), completed=completed),
        )

        keys = self.command("ssh-key list --json")["result"]["keys"]
        fingerprint = subprocess.check_output(
            ["ssh-keygen", "-lf", str(self.directory / "disposable.pub")], text=True
        ).split()[1]
        key = next(k for k in keys if k["fingerprint"] == fingerprint)
        self.command("whoami --json", key="disposable")
        stop_id = self.prefix + "-revoked-stop"
        accepted = self.command(
            f"stop {vm['id']} --request-id {stop_id} --no-wait --json", key="disposable"
        )
        assert accepted["status"] == "accepted", accepted
        removal_id = self.prefix + "-remove-key"
        self.command(f"ssh-key remove {key['id']} --request-id {removal_id} --json")
        self.command(f"ssh-key remove {key['id']} --request-id {removal_id}")
        self.command("whoami --json", key="disposable", expect=1)
        self.command(f"request show {stop_id} --json", key="disposable", expect=1)
        assert self.request(stop_id)["result"]["outcome"] == "stopped"
        assert key["id"] not in [
            k["id"] for k in self.command("ssh-key list --json")["result"]["keys"]
        ]
        self.owned(extra)
        delete_id = self.prefix + "-generated-delete"
        self.command(f"rm {vm['id']} --request-id {delete_id} --timeout 120")
        assert self.request(delete_id)["result"]["outcome"] == "deleted"
        self.command(f"rm {vm['id']} --request-id {delete_id} --json")
        self.save(
            "automation.json", {"generated_explicit_shape_timeout_disconnect_revocation": "passed"}
        )

    def reuse(self) -> None:
        original = self.fixtures()[0]
        name = original["result"]["name"]
        creation_id = self.prefix + "-reuse"
        replacement = self.admit(f"new --name {name} --request-id {creation_id} --no-wait --json")
        self.save("replacement.json", replacement)
        replacement = self.request(creation_id)
        self.save("replacement.json", replacement)
        assert replacement["result"]["id"] != original["result"]["id"]
        replay = self.command(f"new --name {name} --request-id {original['request_id']} --json")
        assert replay["result"]["id"] == original["result"]["id"]
        deletion_id = f"{self.prefix}-cleanup-{original['result']['id']}"
        self.command(f"rm {original['result']['id']} --request-id {deletion_id} --json")
        assert self.owned(replacement)["observed_state"] == "running"
        self.lifecycle(replacement, "rm", "replacement-cleanup")
        self.command(f"show {name} --json", expect=1)
        self.request(original["request_id"])
        self.save("reuse.json", {"archived_requests_pinned_after_name_reuse": "passed"})

    def matrix_config(self) -> MatrixConfig:
        return MatrixConfig.parse(read_object(self.directory / "matrix.json"))

    def matrix_fixture(self, kind: GuestOS, config: MatrixConfig) -> MatrixFixture:
        return MatrixFixture.parse(
            kind,
            read_object(self.directory / f"matrix-vm-{kind}.json"),
            self.prefix,
            self.config["host"],
            config.images[kind],
        )

    def matrix_inventory(self, kinds: tuple[GuestOS, ...]) -> None:
        """@cc [owner:ghuntley,label:verification;security] porsche-matrix-explicit-images
        Every selected OS MUST have its own pinned catalog ID with the exact
        expected display name before any matrix creation. Missing/unadmitted
        images MUST fail preflight, never fall back to another OS or disappear
        from a seven-OS result. Explicit subsets MUST retain their scope.
        """
        config = self.matrix_config()
        account = object_map(self.command("whoami --json")["result"])
        if account.get("email") != self.config["account"]:
            raise ValueError("Matrix account differs from this run")
        catalog = object_map(self.command("images --json")["result"])
        raw_images = catalog.get("images")
        if not isinstance(raw_images, list):
            raise ValueError("Expected an image catalog")
        images = [object_map(image) for image in raw_images]
        rows: list[dict[str, object]] = []
        for kind in kinds:
            matches = [image for image in images if image.get("id") == config.images[kind]]
            available = (
                config.images[kind] is not None
                and len(matches) == 1
                and matches[0].get("name") == IMAGE_NAMES[kind]
            )
            rows.append(
                dict(
                    os=kind,
                    image_id=config.images[kind],
                    name=IMAGE_NAMES[kind],
                    available=available,
                )
            )
        self.save("matrix-inventory.json", dict(selected=list(kinds), images=rows))
        if not all(row["available"] for row in rows):
            raise RuntimeError("Selected OS images unavailable; see private matrix-inventory.json")

    def matrix_poll(self, request_id: str, seconds: int = 900) -> CommandOutcome:
        """@cc [owner:ghuntley,label:verification;recovery] porsche-matrix-bounded-receipts
        Matrix polling MUST retain the original request ID, reject a different
        receipt and cap every SSH call and sleep by one bounded deadline. An
        unknown result MUST NOT submit a new lifecycle request.
        Failed/superseded terminal receipts MUST return to the caller so its
        fixture ledger can retain the original UUID before reporting failure.
        """
        if (
            not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,127}", request_id)
            or type(seconds) is not int
            or not 1 <= seconds <= 2400
        ):
            raise ValueError("Invalid matrix receipt request or bounded deadline")
        deadline = time.monotonic() + seconds
        while (remaining := deadline - time.monotonic()) > 0:
            result = self.command(
                f"request show {request_id} --json",
                timeout=min(160, remaining),
                terminal_receipts=True,
            )
            if result.get("request_id") != request_id:
                raise ValueError("Matrix polling returned a different request")
            if time.monotonic() >= deadline:
                break
            if result.get("status") in ("succeeded", "failed", "superseded"):
                return result
            if result.get("status") != "accepted":
                raise RuntimeError("Matrix request did not succeed")
            time.sleep(min(2, max(0, deadline - time.monotonic())))
        raise TimeoutError(request_id)

    def matrix_create(self, kinds: tuple[GuestOS, ...]) -> None:
        self.matrix_inventory(kinds)
        config = self.matrix_config()
        for kind in kinds:
            name = self.prefix + "-" + kind
            request_id = name + "-create"
            command = (
                f"new --name {name} --image {config.images[kind]} --profile oss "
                f"--request-id {request_id} --no-wait --json"
            )
            intent = dict(command=command, request_id=request_id)
            path = self.directory / f"matrix-intent-{kind}.json"
            if path.exists() and read_object(path) != intent:
                raise ValueError("Matrix create intent changed; reconcile the original request")
            self.save(path.name, intent)
            receipt_path = self.directory / f"matrix-vm-{kind}.json"
            original = self.matrix_fixture(kind, config) if receipt_path.exists() else None
            if original is None:
                admission_path = self.directory / f"matrix-admission-{kind}.json"
                admission = (
                    read_object(admission_path) if admission_path.exists() else self.admit(command)
                )
                original = MatrixFixture.parse(
                    kind, admission, self.prefix, self.config["host"], config.images[kind]
                )
                self.save(admission_path.name, admission)
                self.save(receipt_path.name, admission)
            result = self.matrix_poll(request_id)
            fixture = MatrixFixture.parse(
                kind, result, self.prefix, self.config["host"], config.images[kind]
            )
            if original is not None and fixture != original:
                raise ValueError("Replayed matrix create changed fixture identity")
            self.save(receipt_path.name, result)
            if result.get("status") != "succeeded":
                raise RuntimeError(
                    f"Matrix {kind} create {result.get('status')}; original VM {fixture.id} "
                    f"and request {request_id} retained for reconciliation/cleanup"
                )
            self.matrix_owned(fixture)
            print(f"matrix created {kind}: {fixture.id}", flush=True)

    def matrix_owned(self, fixture: MatrixFixture) -> dict[str, object]:
        """@cc [owner:ghuntley,label:security] porsche-matrix-current-ownership
        Matrix lifecycle and guest probes MUST use a receipt-bound canonical
        UUID and recheck its current owner, name, image, profile and SSH endpoint.
        A changed binding MUST refuse before any guest access or mutation.
        """
        machine = object_map(self.command(f"show {fixture.id} --json")["result"])
        if (
            machine.get("id") != fixture.id
            or machine.get("owner") is not True
            or machine.get("name") != fixture.name
            or machine.get("image_id") != fixture.image_id
            or machine.get("profile") != "oss"
            or machine.get("ssh_host") != fixture.ssh_host
        ):
            raise ValueError("Current machine no longer matches the owned matrix fixture")
        return machine

    def matrix_lifecycle(self, kinds: tuple[GuestOS, ...], verb: str, stage: str) -> None:
        if verb not in ("stop", "start", "rm") or not re.fullmatch(r"[a-z][a-z0-9-]{0,30}", stage):
            raise ValueError("Invalid matrix lifecycle phase")
        config = self.matrix_config()
        fixtures = [self.matrix_fixture(kind, config) for kind in kinds]
        if len({fixture.id for fixture in fixtures}) != len(fixtures):
            raise ValueError("Matrix fixtures share a UUID")
        expected = {"stop": "stopped", "start": "running", "rm": "deleted"}[verb]
        for fixture in fixtures:
            request_id = f"{self.prefix}-matrix-{stage}-{fixture.id}"
            path = self.directory / f"matrix-{stage}-{fixture.kind}.json"
            command = f"{verb} {fixture.id} --request-id {request_id} --no-wait --json"
            intent = dict(command=command, request_id=request_id)
            intent_path = self.directory / f"matrix-{stage}-{fixture.kind}-intent.json"
            if intent_path.exists() and read_object(intent_path) != intent:
                raise ValueError("Matrix lifecycle intent changed")
            resuming = intent_path.exists()
            if path.exists():
                if read_object(path).get("request_id") != request_id:
                    raise ValueError("Saved matrix lifecycle receipt changed request")
            elif not resuming:
                self.matrix_owned(fixture)
                self.save(intent_path.name, intent)
                self.save(f"matrix-{stage}-{fixture.kind}-admission.json", self.admit(command))
            result = self.matrix_poll(request_id)
            self.save(path.name, result)
            row = object_map(result["result"])
            if row.get("id") != fixture.id or row.get("name") != fixture.name:
                raise ValueError("Matrix lifecycle receipt changed identity")
            if result.get("status") != "succeeded":
                raise RuntimeError(
                    f"Matrix {fixture.kind} {stage} {result.get('status')}; original VM "
                    f"{fixture.id} and request {request_id} retained for reconciliation"
                )
            if row.get("outcome") != expected:
                raise ValueError("Matrix lifecycle receipt changed identity or outcome")
            print(f"matrix {stage} {fixture.kind}: {expected}", flush=True)

    @staticmethod
    def matrix_probe(kind: GuestOS) -> str:
        """@cc [owner:ghuntley,label:verification] porsche-matrix-release-probe
        The OmniOS probe MUST normalize the pinned v11 release label while
        retaining its numeric r revision for the independent exact OS oracle.
        """
        if kind in ("nixos", "ubuntu", "arch", "almalinux"):
            return shlex.join(
                [
                    "sh",
                    "-c",
                    'set -eu; . /etc/os-release; printf "kernel=%s\\ndistribution=%s\\n" "$(uname -s)" "$ID"',
                ]
            )
        if kind == "freebsd":
            return shlex.join(
                [
                    "sh",
                    "-c",
                    'set -eu; printf "kernel=%s\\nrelease=%s\\n" "$(uname -s)" "$(uname -r)"',
                ]
            )
        if kind == "omnios":
            return shlex.join(
                [
                    "sh",
                    "-c",
                    'set -eu; uname -s; sed -n "s/.*OmniOS v11 \\(r[0-9][0-9]*\\).*/OmniOS \\1/p" /etc/release',
                ]
            )
        return (
            'powershell.exe -NoProfile -NonInteractive -Command "'
            "$ErrorActionPreference = 'Stop'; $os = Get-CimInstance Win32_OperatingSystem; "
            "[ordered]@{family=[Environment]::OSVersion.Platform.ToString(); "
            'caption=$os.Caption; build=$os.BuildNumber} | ConvertTo-Json -Compress"'
        )

    @staticmethod
    def matrix_verify_os(kind: GuestOS, stdout: str) -> None:
        """@cc [owner:ghuntley,label:verification] porsche-matrix-guest-os-oracle
        Zero SSH status or a catalog label alone MUST NOT prove the guest OS.
        Linux requires its exact distribution ID, FreeBSD its 14.3 release,
        OmniOS both SunOS and r151050, and Windows the pinned Server 2025 edition
        and build. Extra or malformed output MUST fail the selected row.
        """
        output = stdout.replace("\r\n", "\n")
        valid = False
        if kind in ("nixos", "ubuntu", "arch", "almalinux"):
            valid = output == f"kernel=Linux\ndistribution={kind}\n"
        elif kind == "freebsd":
            valid = (
                re.fullmatch(r"kernel=FreeBSD\nrelease=14\.3-RELEASE(?:-p[0-9]+)?\n", output)
                is not None
            )
        elif kind == "omnios":
            valid = output == "SunOS\nOmniOS r151050\n"
        else:
            value: object = json.loads(output)
            valid = object_map(value) == {
                "family": "Win32NT",
                "caption": "Microsoft Windows Server 2025 Standard Evaluation",
                "build": "26100",
            }
        if not valid:
            raise ValueError(f"Guest OS differs from the expected {kind} image")

    def matrix_ssh(self, kinds: tuple[GuestOS, ...], stage: str = "initial") -> None:
        """@cc [owner:ghuntley,label:security;verification] porsche-windows-known-kex-warning
        Windows MAY emit only the exact stock three-line OpenSSH post-quantum
        warning with LF or CRLF endings. Other stderr, nonzero exit, timeout or
        a failed exact OS oracle MUST fail. SSH trust and algorithms MUST remain
        unchanged; the warning MUST NOT be accepted for another guest family.
        """
        if not re.fullmatch(r"[a-z][a-z0-9-]{0,30}", stage):
            raise ValueError("Invalid matrix SSH evidence stage")
        config = self.matrix_config()
        account = object_map(self.command("whoami --json")["result"])
        username = nonempty_text(account.get("guest_username"))
        if (
            account.get("email") != self.config["account"]
            or not re.fullmatch(r"[a-z_][a-z0-9_.-]{0,30}", username)
            or username == "root"
        ):
            raise ValueError("Unexpected matrix guest account")
        fixtures = [self.matrix_fixture(kind, config) for kind in kinds]
        if len({fixture.id for fixture in fixtures}) != len(fixtures):
            raise ValueError("Matrix fixtures share a UUID")
        for fixture in fixtures:
            machine = self.matrix_owned(fixture)
            if (
                machine.get("observed_state") != "running"
                or machine.get("desired_state") != "running"
            ):
                raise ValueError("Matrix SSH requires a currently running fixture")
            argv = [
                str(config.cli),
                "ssh",
                "-F",
                str(config.ssh_config),
                "-T",
                "-i",
                str(self.directory / "primary"),
                "-o",
                "BatchMode=yes",
                "-o",
                "IdentitiesOnly=yes",
                "-o",
                "StrictHostKeyChecking=yes",
                "-o",
                "GlobalKnownHostsFile=/dev/null",
                "-o",
                "UserKnownHostsFile=" + str(config.known_hosts),
                "-o",
                "ConnectTimeout=10",
                "-o",
                "ServerAliveInterval=5",
                "-o",
                "ServerAliveCountMax=3",
                username + "@" + fixture.ssh_host,
                self.matrix_probe(fixture.kind),
            ]
            process = subprocess.Popen(
                argv,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                start_new_session=True,
            )
            timed_out = False
            started = time.monotonic()
            try:
                stdout, stderr = process.communicate(timeout=120)
            except subprocess.TimeoutExpired:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(process.pid, signal.SIGKILL)
                stdout, stderr = process.communicate()
                timed_out = True
            stderr_classification: Literal[
                "none", "native-ssh-login-event", "windows-openssh-pq-warning", "unexpected"
            ] = "unexpected"
            if stderr == "":
                stderr_classification = "none"
            elif fixture.kind in ("freebsd", "omnios") and stderr == SSH_LOGIN_EVENT:
                stderr_classification = "native-ssh-login-event"
            elif fixture.kind == "windows" and stderr in (
                SSH_WINDOWS_PQ_WARNING,
                SSH_WINDOWS_PQ_WARNING.replace("\n", "\r\n"),
            ):
                stderr_classification = "windows-openssh-pq-warning"
            attempt = dict(
                fixture=asdict(fixture),
                probe="os-identity",
                exit=process.returncode,
                timeout=timed_out,
                seconds=round(time.monotonic() - started, 3),
                stdout_bytes=len(stdout.encode()),
                stderr_bytes=len(stderr.encode()),
                stdout_sha256=hashlib.sha256(stdout.encode()).hexdigest(),
                stderr_sha256=hashlib.sha256(stderr.encode()).hexdigest(),
                stderr_classification=stderr_classification,
            )
            self.save(f"matrix-ssh-{stage}-{fixture.kind}-attempt-{uuid.uuid4()}.json", attempt)
            self.save(f"matrix-ssh-{stage}-{fixture.kind}.json", dict(**attempt, verified=False))
            if timed_out or process.returncode != 0 or stderr_classification == "unexpected":
                raise RuntimeError(f"Matrix {fixture.kind} guest SSH failed; see private evidence")
            self.matrix_verify_os(fixture.kind, stdout)
            self.save(f"matrix-ssh-{stage}-{fixture.kind}.json", dict(**attempt, verified=True))
            print(f"matrix SSH {fixture.kind}: verified", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory")
    parser.add_argument(
        "phase",
        choices=[
            "inventory",
            "create",
            "running",
            "stop",
            "start",
            "cleanup",
            "scenarios",
            "automation",
            "reuse",
            "physical-running",
            "physical-stopped",
            "physical-restarted",
            "physical-deleted",
            "matrix-inventory",
            "matrix-create",
            "matrix-ssh",
            "matrix-stop",
            "matrix-start",
            "matrix-cleanup",
        ],
    )
    parser.add_argument(
        "--stage", help="Unique lifecycle request namespace for an intentional new cycle"
    )
    parser.add_argument(
        "--os",
        action="append",
        choices=GUEST_OSES,
        help="Explicit matrix subset (repeatable); default requires all seven OSes",
    )
    args = parser.parse_args()
    acceptance = Acceptance(args.directory)
    if args.stage and not re.fullmatch(r"[a-z][a-z0-9-]{0,30}", args.stage):
        parser.error("stage must be a short lowercase identifier")
    if args.phase.startswith("matrix-"):
        kinds = tuple(kind for kind in GUEST_OSES if args.os is None or kind in args.os)
        try:
            if args.phase == "matrix-inventory":
                acceptance.matrix_inventory(kinds)
            elif args.phase == "matrix-create":
                acceptance.matrix_create(kinds)
            elif args.phase == "matrix-ssh":
                acceptance.matrix_ssh(kinds, args.stage or "initial")
            else:
                phase = args.phase.removeprefix("matrix-")
                acceptance.matrix_lifecycle(
                    kinds, "rm" if phase == "cleanup" else phase, args.stage or phase
                )
        except (ValueError, RuntimeError, TimeoutError) as error:
            parser.exit(1, f"{error}\n")
    elif args.os is not None:
        parser.error("--os is only valid for matrix phases")
    elif args.phase == "create":
        with ThreadPoolExecutor(max_workers=5) as pool:
            list(pool.map(acceptance.create, range(1, 51)))
    elif args.phase in ("stop", "start", "cleanup"):
        verb = "rm" if args.phase == "cleanup" else args.phase
        with ThreadPoolExecutor(max_workers=5) as pool:
            futures = [
                pool.submit(acceptance.lifecycle, receipt, verb, args.stage or args.phase)
                for receipt in acceptance.fixtures()
            ]
            failures = []
            for future in as_completed(futures):
                try:
                    future.result()
                except (AssertionError, RuntimeError, TimeoutError) as error:
                    failures.append(str(error))
            if failures:
                acceptance.save(f"failures-{args.stage or args.phase}.json", failures)
                raise RuntimeError(
                    f"{len(failures)} lifecycle requests failed; see private evidence"
                )
    elif args.phase.startswith("physical-"):
        acceptance.physical(args.phase.removeprefix("physical-"))
    else:
        getattr(acceptance, args.phase)()


if __name__ == "__main__":
    main()
