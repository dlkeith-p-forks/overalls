"""Apply an inspected database capture behind a persistent GitHub restore fence."""

import argparse
import fcntl
import hashlib
import json
import os
import stat
import sys
import tempfile
from pathlib import Path
from uuid import UUID

import postgres
from common import BackupError, private_directory, run
from schema import config_value, object_value, string


def publish_epoch(path: Path, epoch: str) -> None:
    """@cc [owner:ghuntley,label:security;recovery] github-restore-before-database
    A canonical, operator-selected fleet epoch MUST be durably published before
    pg_restore starts. The public marker MUST remain after failure or success;
    each Marshall prestart MUST invalidate restored authority before serving.
    """
    parent = path.parent
    for directory in reversed([parent, *parent.parents]):
        directory.mkdir(mode=0o755, exist_ok=True)
        info = directory.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
            raise BackupError("configuration")
    descriptor, temporary = tempfile.mkstemp(prefix=".restore-epoch-", dir=parent)
    try:
        with os.fdopen(descriptor, "w", encoding="ascii") as stream:
            stream.write(epoch + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o644)
        os.replace(temporary, path)
        descriptor = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    finally:
        Path(temporary).unlink(missing_ok=True)


def require_fresh_epoch(path: Path, epoch: str) -> None:
    """Refuse reused or unreviewable authority before changing recovery markers."""
    try:
        info = path.lstat()
    except FileNotFoundError:
        return
    if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
        raise BackupError("configuration")
    previous = path.read_text(encoding="ascii")
    if previous not in {str(UUID(previous.strip())), str(UUID(previous.strip())) + "\n"}:
        raise BackupError("configuration")
    if previous.strip() == epoch:
        raise BackupError("configuration")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("config")
    parser.add_argument("--archive", required=True)
    parser.add_argument("--epoch", required=True)
    parser.add_argument("--epoch-file", required=True)
    parser.add_argument("--systemctl", required=True)
    parser.add_argument("--instance", action="append", default=[])
    args = parser.parse_args()
    try:
        os.umask(0o077)
        if os.geteuid() != 0 or str(UUID(args.epoch)) != args.epoch:
            raise BackupError("configuration")
        archive, marker = Path(args.archive), Path(args.epoch_file)
        if not archive.is_absolute() or not marker.is_absolute():
            raise BackupError("configuration")
        info = archive.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
            raise BackupError("configuration")
        with open(args.config, encoding="utf-8") as source:
            config = config_value(json.load(source))
        pg = config["postgres"]
        if pg is None:
            raise BackupError("configuration")
        state = private_directory(config["state_directory"])
        with open(state / "owner.lock", "a+b") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            metadata = object_value(json.loads(archive.with_name("database.json").read_text()))
            with archive.open("rb") as stream:
                digest = hashlib.file_digest(stream, "sha256").hexdigest()
            if metadata.get("format") != "postgres-custom" or string(metadata["sha256"]) != digest:
                raise BackupError("database")
            # The pending marker blocks every concurrent local prestart, including
            # Nix units whose /etc declaration outranks a runtime mask. Remote
            # replicas must receive the same pending/epoch pair before recovery.
            pending = marker.with_name(marker.name + ".pending")
            require_fresh_epoch(marker, args.epoch)
            try:
                pending.lstat()
            except FileNotFoundError:
                pass
            else:
                # A prior interrupted restore retains its fence. Never replace
                # that operator-visible intent with a second archive.
                raise BackupError("configuration")
            publish_epoch(pending, args.epoch)
            publish_epoch(marker, args.epoch)
            for instance in args.instance:
                run(
                    [args.systemctl, "mask", "--runtime", "--now", instance],
                    stage="database",
                    timeout=60,
                )
            identity = postgres.connection(os.environ.get("DATABASE_URL"))
            with tempfile.TemporaryDirectory(prefix="restore-auth-", dir=state) as temporary:
                environment = postgres.environment(
                    identity, pg["ca_file"], Path(temporary) / "pgpass"
                )
                run(
                    [
                        pg["pg_restore"],
                        "--no-password",
                        "--exit-on-error",
                        "--clean",
                        "--if-exists",
                        "--no-owner",
                        "--no-privileges",
                        "--dbname",
                        identity["database"],
                        str(archive),
                    ],
                    stage="database",
                    environment=environment,
                    timeout=pg["timeout"],
                )
            pending.unlink()
            directory = os.open(marker.parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        return 0
    except (BackupError, OSError, ValueError, KeyError):
        print(
            "Database restore failed; keep all Marshall replicas stopped and follow recovery guidance.",
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    sys.exit(main())
