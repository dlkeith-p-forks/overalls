#!/usr/bin/env python3
"""Opt-in live Porsche acceptance. Credentials and resumable evidence stay outside Git.

Usage: porsche_acceptance.py PRIVATE_RUN_DIRECTORY {inventory,create,running,stop,start,cleanup}
The directory must contain run.json (run, host, account), primary and known_hosts.
Sharing commands are deliberately excluded. This runs real billable workloads.
"""

import argparse
import datetime
import json
import os
import re
import select
import shlex
import subprocess
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import NotRequired, TypedDict


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
        self.config: RunConfig = json.loads((self.directory / "run.json").read_text())
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
        timeout: int = 160,
    ) -> CommandOutcome:
        """@cc [owner:ghuntley,label:verification] porsche-command-evidence
        Successful JSON commands MUST have exit status zero and valid JSON.
        Expected rejections MUST NOT accept SSH transport failure as proof;
        evidence MUST retain failed and timed-out attempts.
        """
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
        if expect is not None:
            assert not timed_out, record
            assert (process.returncode == 0) == (expect == 0), record
            assert process.returncode != 255, (
                record
            )  # Transport failure is not a negative test pass.
        if "--json" in shlex.split(command) and stdout.strip():
            try:
                result = json.loads(stdout)
            except json.JSONDecodeError:
                if expect == 1 and process.returncode != 0:
                    return record  # Parser errors occur before output-mode selection.
                raise
            if expect == 0:
                assert result.get("status") in ("succeeded", "accepted"), result
            return result
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
        ],
    )
    parser.add_argument(
        "--stage", help="Unique lifecycle request namespace for an intentional new cycle"
    )
    args = parser.parse_args()
    acceptance = Acceptance(args.directory)
    if args.stage and not re.fullmatch(r"[a-z][a-z0-9-]{0,30}", args.stage):
        parser.error("stage must be a short lowercase identifier")
    if args.phase == "create":
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
