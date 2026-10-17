"""Repository operations and manifest-reference retention."""

import json
import os
import re
import stat
import subprocess
import uuid
from collections.abc import Callable, Sequence
from datetime import datetime
from pathlib import Path
from typing import TypedDict

from common import BackupError, run
from schema import JSON, Config, Failure, integer, object_value, string, strings

SNAPSHOT = re.compile(r"[0-9a-f]{64}")


class Snapshot(TypedDict):
    id: str
    time: str
    paths: list[str]
    tags: list[str]


class Manifest(TypedDict):
    version: int
    hostname: str
    run_id: str
    started_at: int
    completed_at: int
    revision: str | None
    complete: bool
    components: list[dict[str, JSON]]


class Repository:
    def __init__(self, config: Config) -> None:
        self.config = config
        self.environment = {
            key: value
            for key, value in os.environ.items()
            if key
            in {
                "PATH",
                "HOME",
                "SSL_CERT_FILE",
                "AWS_ACCESS_KEY_ID",
                "AWS_SECRET_ACCESS_KEY",
                "AWS_SESSION_TOKEN",
            }
        }
        self.environment.update(
            RESTIC_REPOSITORY=config["repository"],
            RESTIC_PASSWORD_FILE=config["password_file"],
            RESTIC_CACHE_DIR=config["cache_directory"],
            AWS_DEFAULT_REGION=config["region"],
            LC_ALL="C",
        )
        self.environment.setdefault("SSL_CERT_FILE", "/etc/ssl/certs/ca-certificates.crt")

    def ensure(self) -> None:
        self.credentials()
        try:
            result = subprocess.run(
                [self.config["restic"], "cat", "config"],
                env=self.environment,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=30,
            )
        except (OSError, subprocess.SubprocessError):
            raise BackupError("repository") from None
        if result.returncode == 10 and self.config["initialize"]:
            self.command(["init"])
        elif result.returncode:
            raise BackupError("repository")

    def credentials(self) -> None:
        try:
            descriptor = os.open(self.config["password_file"], os.O_RDONLY | os.O_NOFOLLOW)
            with os.fdopen(descriptor, "rb") as source:
                info = os.fstat(source.fileno())
                if (
                    not stat.S_ISREG(info.st_mode)
                    or info.st_uid != os.geteuid()
                    or info.st_mode & 0o077
                    or info.st_nlink != 1
                ):
                    raise BackupError("credentials")
                password = source.read(16385)
                if not password.strip() or len(password) > 16384:
                    raise BackupError("credentials")
            if self.config["repository"].startswith("s3:") and not all(
                self.environment.get(key) for key in ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY")
            ):
                raise BackupError("credentials")
        except OSError:
            raise BackupError("credentials") from None

    def command(
        self,
        arguments: Sequence[str],
        stage: Failure = "repository",
        maximum: int = 32 * 1024 * 1024,
        guard: Callable[[], None] | None = None,
    ) -> bytes:
        """@cc [owner:ghuntley,label:security;recovery] repository-commands-require-custody
        Every repository-touching command MUST pass credentials() custody
        validation immediately before execution. Capture is not the only gated
        path: operator list/inspect/restore/init and scheduled prune/check MUST
        close with a credentials failure on an insecure or missing password file
        or missing S3 credentials, before any repository access.
        """
        self.credentials()
        return run(
            [self.config["restic"], *arguments],
            stage=stage,
            environment=self.environment,
            timeout=self.config["command_timeout"],
            maximum=maximum,
            guard=guard,
        )

    def backup(
        self,
        paths: Sequence[str | Path],
        tag: str,
        run_id: str,
        *,
        excludes: Sequence[str] = (),
        guard: Callable[[], None] | None = None,
    ) -> str:
        args = [
            "backup",
            "--json",
            "--host",
            self.config["hostname"],
            "--tag",
            "overalls-backup",
            "--tag",
            tag,
            "--tag",
            "run:" + run_id,
        ]
        if self.config["upload_limit_kib"]:
            args.extend(["--limit-upload", str(self.config["upload_limit_kib"])])
        for path in excludes:
            args.extend(["--exclude", path])
        args.extend(["--", *map(str, paths)])
        # Exit 3 (partial backup) is a failure too, even if Restic created a snapshot.
        output = self.command(args, "upload", guard=guard)
        try:
            summaries = [
                value
                for line in output.splitlines()
                if line.strip()
                and (value := object_value(json.loads(line))).get("message_type") == "summary"
            ]
            short_id = string(summaries[-1]["snapshot_id"])
            if not re.fullmatch(r"[0-9a-f]{8,64}", short_id):
                raise ValueError()
            candidates = self.snapshots()
            matches = [
                row["id"]
                for row in candidates
                if row["id"].startswith(short_id)
                and tag in row.get("tags", [])
                and "run:" + run_id in row.get("tags", [])
            ]
            if len(matches) != 1 or not SNAPSHOT.fullmatch(matches[0]):
                raise ValueError()
            return matches[0]
        except (ValueError, KeyError, IndexError, TypeError):
            raise BackupError("upload") from None

    def snapshots(self) -> list[Snapshot]:
        values: object = json.loads(
            self.command(
                [
                    "snapshots",
                    "--json",
                    "--host",
                    self.config["hostname"],
                    "--tag",
                    "overalls-backup",
                ]
            )
        )
        if not isinstance(values, list) or len(values) > 65536:
            raise BackupError("repository")
        result: list[Snapshot] = []
        try:
            for value in values:
                row = object_value(value)
                identity = string(row["id"])
                if not SNAPSHOT.fullmatch(identity):
                    raise ValueError()
                result.append(
                    Snapshot(
                        id=identity,
                        time=string(row["time"]),
                        paths=strings(row["paths"]),
                        tags=strings(row.get("tags", [])),
                    )
                )
        except (ValueError, KeyError, TypeError):
            raise BackupError("repository") from None
        return result

    def manifest(self, row: Snapshot) -> dict[str, JSON]:
        if not SNAPSHOT.fullmatch(row["id"]):
            raise BackupError("repository")
        paths = row.get("paths", [])
        if len(paths) != 1 or Path(paths[0]).name != "manifest.json":
            raise BackupError("retention")
        manifest = object_value(
            json.loads(self.command(["dump", row["id"], paths[0]], maximum=4 * 1024 * 1024))
        )
        components = manifest.get("components")
        if (
            set(manifest) != set(Manifest.__annotations__)
            or type(manifest.get("version")) is not int
            or manifest.get("version") != 1
            or manifest.get("hostname") != self.config["hostname"]
            or manifest.get("complete") is not True
            or not isinstance(components, list)
            or not components
            or any(
                not SNAPSHOT.fullmatch(string(object_value(item).get("snapshot_id")))
                for item in components
            )
        ):
            raise BackupError("retention")
        try:
            run_id = string(manifest["run_id"])
            if str(uuid.UUID(run_id)) != run_id or not 0 <= integer(
                manifest["started_at"]
            ) <= integer(manifest["completed_at"]):
                raise ValueError()
            kinds = [string(object_value(item)["kind"]) for item in components]
            if (
                kinds.count("host-state") != 1
                or kinds.count("postgres") > 1
                or not set(kinds) <= {"host-state", "postgres", "guest"}
            ):
                raise ValueError()
            if manifest["revision"] is not None:
                string(manifest["revision"])
        except (ValueError, TypeError, KeyError):
            raise BackupError("retention") from None
        return manifest

    def retain(self, now: float) -> None:
        """@cc [owner:ghuntley,label:recovery] retention-validates-all-references-first
        Retention MUST verify every retained manifest and referenced snapshot
        before forgetting anything. Only managed snapshots unreferenced by the
        latest completed host points may be removed when their completed point
        expires, or when an unreferenced orphan exceeds the grace period.
        """
        rows = self.snapshots()
        manifests = sorted(
            [row for row in rows if "host-manifest" in row.get("tags", [])],
            key=lambda row: row["time"],
            reverse=True,
        )
        keep = {row["id"] for row in manifests[: self.config["keep_last"]]}
        all_ids = {row["id"] for row in rows}
        expired_references: set[str] = set()
        for index, row in enumerate(manifests):
            manifest = self.manifest(row)
            components = manifest["components"]
            if not isinstance(components, list):
                raise BackupError("retention")
            references = {string(object_value(item)["snapshot_id"]) for item in components}
            if index < self.config["keep_last"]:
                if not references <= all_ids:
                    raise BackupError("retention")
                keep.update(references)
            else:
                expired_references.update(references)
        expired_manifests = {row["id"] for row in manifests[self.config["keep_last"] :]}
        remove = []
        for row in rows:
            stamp = datetime.fromisoformat(row["time"].replace("Z", "+00:00")).timestamp()
            if row["id"] not in keep and (
                row["id"] in expired_manifests
                or row["id"] in expired_references
                or now - stamp > 86400
            ):
                remove.append(row["id"])
        for offset in range(0, len(remove), 128):
            self.command(["forget", *remove[offset : offset + 128]], "retention")
