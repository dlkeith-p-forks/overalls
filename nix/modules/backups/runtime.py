"""Serialized host recovery capture. Status contains only public operational fields."""

import argparse
import fcntl
import json
import os
import shutil
import signal
import sys
import tempfile
import threading
import time
from pathlib import Path
from types import FrameType

import postgres
from common import BackupError, atomic_json, private_directory, read_json, run
from host import HostCapture, exclusions
from journal import Journal
from restic import SNAPSHOT, Manifest, Repository
from schema import JSON, Config, Failure, config_value, integer, object_value, string, strings


class Runner:
    def __init__(self, config: Config) -> None:
        self.config = config
        self.root = private_directory(config["state_directory"])
        self.repository = Repository(config)
        self.host = HostCapture(config)
        self.status: dict[str, JSON] = {"version": 1, "state": "never-run", "failure": "none"}
        self.status_lock = threading.Lock()
        try:
            previous = object_value(read_json(self.root / "status.json"))
            if previous.get("version") == 1 and previous.get("state") in (
                "never-run",
                "running",
                "healthy",
                "degraded",
                "failed",
            ):
                self.status = previous
        except (OSError, ValueError, BackupError):
            pass

    def publish(self, **fields: JSON) -> None:
        with self.status_lock:
            self.status.update(fields, updated_at=int(time.time()))
            atomic_json(self.root / "status.json", self.status)

    def lilly(self, operation: str, value: object = None) -> dict[str, JSON]:
        if self.config["lilly"] is None:
            return {"guests": [], "pending": 0, "paths": []}
        request = self.root / "lilly-request.json"
        atomic_json(request, value or {})
        result = run(
            [self.config["lilly"]["tool"], operation, str(request)],
            stage="cleanup" if operation in {"cleanup", "release"} else "capture",
            timeout=180,
        )
        return object_value(json.loads(result))

    def count(self, field: str) -> int:
        return integer(self.status.get(field, 0))

    def headroom(self, pool_id: str) -> None:
        if self.lilly("pressure", {"pool_id": pool_id}).get("available") is not True:
            raise BackupError("capture")

    def cleanup(self) -> int:
        pending = self.host.cleanup()
        try:
            pending += integer(self.lilly("cleanup")["pending"])
        except (BackupError, OSError, ValueError, KeyError):
            pending += 1
        self.publish(cleanup_pending=pending)
        return pending

    def recover(self) -> None:
        path = self.root / "run.json"
        journal = Journal.load(path) if path.exists() else None
        if journal is not None and journal.value["phase"] not in {"completed", "failed"}:
            journal.failed("interrupted")
            if journal.value["phase"] != "cleaning":
                journal.transition("cleaning")
        pending = self.cleanup()
        if pending:
            self.publish(state="failed", failure="cleanup")
            raise BackupError("cleanup")
        if journal is not None and journal.value["phase"] == "cleaning":
            journal.save(cleanup_confirmed=True)
            journal.transition("failed")
            self.publish(state="failed", failure="interrupted")

    def capture(self) -> None:
        self.recover()
        journal = Journal.create(
            self.root / "run.json", self.config["hostname"], self.config["revision"]
        )
        identity, started = journal.value["run_id"], journal.value["started_at"]
        self.publish(
            state="running",
            failure="none",
            started_at=started,
            guests_total=0,
            guests_completed=0,
            guests_failed=0,
            flush_unconfirmed=0,
            cleanup_pending=0,
        )
        stop = threading.Event()

        def heartbeat() -> None:
            while not stop.wait(30):
                self.publish()

        thread = threading.Thread(target=heartbeat, daemon=True)
        thread.start()
        try:
            self.repository.ensure()
            journal.transition("capturing")
            try:
                inventory = self.lilly("inventory")["guests"]
                if not isinstance(inventory, list):
                    raise ValueError()
                guests = [object_value(guest) for guest in inventory]
            except (BackupError, OSError, ValueError, KeyError):
                journal.failed("capture")
                guests = []
            self.publish(guests_total=len(guests))
            with tempfile.TemporaryDirectory(prefix="capture-", dir=self.root) as working:
                work = Path(working)
                for guest in guests:
                    captured: dict[str, JSON] | None = None
                    try:
                        guest_id = string(guest["id"])
                        captured = self.lilly("capture", {"run_id": identity, **guest})
                        if captured["flush"] == "unconfirmed":
                            self.publish(flush_unconfirmed=self.count("flush_unconfirmed") + 1)
                        metadata = private_directory(work / guest_id)
                        atomic_json(metadata / "guest.json", captured)
                        snapshot_id = self.repository.backup(
                            [*strings(captured["paths"]), metadata],
                            "guest:" + guest_id,
                            identity,
                            guard=lambda guest=guest: self.headroom(string(guest["pool_id"])),
                        )
                        journal.component(
                            {
                                "kind": "guest",
                                "id": guest_id,
                                "snapshot_id": snapshot_id,
                                "capture": captured,
                            }
                        )
                        self.publish(guests_completed=self.count("guests_completed") + 1)
                    except (BackupError, OSError, ValueError, KeyError) as error:
                        journal.failed(error.stage if isinstance(error, BackupError) else "capture")
                        self.publish(guests_failed=self.count("guests_failed") + 1)
                    finally:
                        if captured is not None:
                            try:
                                self.lilly("release", captured)
                            except (BackupError, OSError, ValueError):
                                journal.failed("cleanup")

                # Database unavailability must not suppress guest capture attempts.
                if self.config["postgres"] is not None:
                    directory = work / "postgres"
                    try:
                        metadata_pg = postgres.capture(
                            self.config["postgres"], directory, os.environ.get("DATABASE_URL")
                        )
                        snapshot_id = self.repository.backup([directory], "postgres", identity)
                        journal.component(
                            {
                                "kind": "postgres",
                                "snapshot_id": snapshot_id,
                                "metadata": object_value(metadata_pg),
                            }
                        )
                    except (BackupError, OSError, ValueError) as error:
                        journal.failed(
                            error.stage if isinstance(error, BackupError) else "database"
                        )
                    finally:
                        shutil.rmtree(directory, ignore_errors=True)

                try:
                    paths, mappings = self.host.prepare(work)
                    paths.extend(strings(self.lilly("metadata")["paths"]))
                    snapshot_id = self.repository.backup(
                        paths,
                        "host-state",
                        identity,
                        excludes=exclusions(self.config["excludes"], mappings),
                    )
                    journal.component({"kind": "host-state", "snapshot_id": snapshot_id})
                except (BackupError, OSError, ValueError, KeyError) as error:
                    journal.failed(error.stage if isinstance(error, BackupError) else "capture")
                journal.transition("cleaning")
                if self.cleanup():
                    raise BackupError("cleanup")
                journal.save(cleanup_confirmed=True)
                if journal.value["failures"]:
                    journal.transition("failed")
                    raise BackupError(journal.value["failures"][0])
                journal.transition("publishing")
                manifest = Manifest(
                    version=1,
                    hostname=self.config["hostname"],
                    run_id=identity,
                    started_at=started,
                    completed_at=int(time.time()),
                    revision=self.config["revision"],
                    complete=True,
                    components=journal.value["components"],
                )
                atomic_json(work / "manifest.json", manifest)
                manifest_id = self.repository.backup(
                    [work / "manifest.json"], "host-manifest", identity
                )
                journal.save(manifest_id=manifest_id)
                journal.transition("completed")
                self.publish(last_success_at=int(time.time()))
                self.repository.retain(time.time())
            self.publish(
                state="degraded" if self.count("flush_unconfirmed") else "healthy", failure="none"
            )
        except (BackupError, OSError, ValueError, KeyError) as error:
            failure: Failure = error.stage if isinstance(error, BackupError) else "capture"
            if journal.value["phase"] not in {"completed", "failed"}:
                journal.failed(failure)
                if journal.value["phase"] != "cleaning":
                    journal.transition("cleaning")
                if self.cleanup() == 0:
                    journal.save(cleanup_confirmed=True)
                    journal.transition("failed")
            self.publish(state="failed", failure=failure)
            raise BackupError(failure) from None
        finally:
            stop.set()
            thread.join()
            self.publish(
                completed_at=int(time.time()), duration_seconds=max(0, int(time.time()) - started)
            )


def interrupted(_signal: int, _frame: FrameType | None) -> None:
    raise BackupError("interrupted")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("config")
    parser.add_argument(
        "operation",
        choices=[
            "backup",
            "init",
            "cleanup",
            "prune",
            "check",
            "read-check",
            "list",
            "inspect",
            "restore",
        ],
    )
    parser.add_argument("--snapshot")
    parser.add_argument("--target")
    args = parser.parse_args()
    os.umask(0o077)
    # Nix-store descriptor contains public paths and options only.
    with open(args.config, encoding="utf-8") as source:
        config = config_value(json.load(source))
    runner = Runner(config)
    lock = os.open(runner.root / "owner.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(lock)
        if args.operation in {"list", "inspect", "restore", "init"}:
            print("Another backup operation is active; retry after it finishes.", file=sys.stderr)
            return 75
        return 0
    try:
        signal.signal(signal.SIGTERM, interrupted)
        signal.signal(signal.SIGINT, interrupted)
        repo = runner.repository
        if args.operation == "backup":
            runner.capture()
        elif args.operation == "cleanup":
            runner.recover()
        elif args.operation == "init":
            repo.command(["init"])
        elif args.operation == "prune":
            repo.retain(time.time())
            repo.command(["prune"], "retention")
            repo.command(["check"])
        elif args.operation in {"check", "read-check"}:
            subset = int(time.time() // 604800) % 4 + 1
            repo.command(
                [
                    "check",
                    *(
                        ["--read-data-subset", f"{subset}/4"]
                        if args.operation == "read-check"
                        else []
                    ),
                ]
            )
        else:
            rows = [row for row in repo.snapshots() if "host-manifest" in row.get("tags", [])]
            if args.operation == "list":
                print(json.dumps([{"id": row["id"], "time": row["time"]} for row in rows]))
                return 0
            if not args.snapshot or not SNAPSHOT.fullmatch(args.snapshot):
                raise BackupError("configuration")
            row = next((row for row in rows if row["id"] == args.snapshot), None)
            if row is None:
                raise BackupError("repository")
            manifest = repo.manifest(row)
            if args.operation == "inspect":
                print(json.dumps(manifest))
            else:
                if not args.target or not Path(args.target).is_absolute():
                    raise BackupError("configuration")
                target = private_directory(args.target)
                if any(target.iterdir()):
                    raise BackupError("configuration")
                components = manifest["components"]
                if not isinstance(components, list):
                    raise BackupError("repository")
                for index, component in enumerate(components):
                    repo.command(
                        [
                            "restore",
                            string(object_value(component)["snapshot_id"]),
                            "--sparse",
                            "--verify",
                            "--target",
                            str(target / str(index)),
                        ]
                    )
                atomic_json(target / "manifest.json", manifest)
        return 0
    except (BackupError, OSError, ValueError, KeyError) as error:
        if args.operation in {"backup", "cleanup", "prune", "check", "read-check"}:
            runner.publish(
                state="failed",
                failure=error.stage if isinstance(error, BackupError) else "configuration",
            )
        print(
            "Backup operation failed; inspect backup status and recovery guidance.", file=sys.stderr
        )
        return 1
    finally:
        os.close(lock)


if __name__ == "__main__":
    sys.exit(main())
