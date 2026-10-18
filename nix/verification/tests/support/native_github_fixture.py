"""Synthetic artifact and GitHub authority for actual native retained-tool tests.

This fixture exercises shipped guest programs; it does not replace Marshall's
SQL-backed owner/executor authorization tests or qualify production admission.
"""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Protocol
from urllib.parse import parse_qs, urlsplit

from native_git_fixture import PREFIX, Response

BOOTSTRAP = "dddddddd-dddd-4ddd-8ddd-000000000311"
MAINTENANCE = "dddddddd-dddd-4ddd-8ddd-000000000312"
HOST = "com-github.integration.internal"


class Authority(Protocol):
    executor_id: str
    fence_epoch: int

    def lease(self, request: dict[str, object]) -> None: ...
    def record(self, event: str) -> None: ...


def object_value(value: object) -> dict[str, object]:
    if not isinstance(value, dict) or any(not isinstance(key, str) for key in value):
        raise ValueError("invalid native GitHub fixture object")
    return {str(key): item for key, item in value.items()}


def digest(value: object) -> str:
    if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{64}", value) is None:
        raise ValueError("invalid native GitHub fixture digest")
    return value


def response(value: object) -> Response:
    return Response(b"application/json", json.dumps(value, allow_nan=False).encode())


@dataclass(frozen=True)
class Artifact:
    name: str
    path: Path
    sha256: str
    bytes: int

    @classmethod
    def load(cls, root: Path, value: object, name: str) -> Artifact:
        wire = object_value(value)
        path = wire.get("path")
        size = wire.get("bytes")
        sha = digest(wire.get("sha256"))
        if not isinstance(path, str) or Path(path).is_absolute() or ".." in Path(path).parts:
            raise ValueError("invalid native artifact path")
        selected = root / path
        if type(size) is not int or not 0 < size <= 104857600 or selected.stat().st_size != size:
            raise ValueError("invalid native artifact size")
        with selected.open("rb") as stream:
            if hashlib.file_digest(stream, "sha256").hexdigest() != sha:
                raise ValueError("invalid native artifact bytes")
        return cls(name, selected, sha, size)


@dataclass
class GitHub:
    tools: Path
    executors: Path
    platform: str
    enabled: bool = False
    started: bool = False
    completed: bool = False
    bootstrap_started: bool = False
    bootstrap_completed: bool = False
    outcome: str | None = None
    objects: dict[str, bytes] = field(default_factory=dict)
    generation: str = field(init=False)
    files: tuple[Artifact, ...] = field(init=False)
    executor: Artifact = field(init=False)

    def __post_init__(self) -> None:
        if self.platform not in {"freebsd-amd64", "illumos-amd64"}:
            raise ValueError("invalid native GitHub platform")
        release = object_value(json.loads((self.tools / "manifest.json").read_bytes()))
        self.generation = digest(release.get("generation"))
        platforms = object_value(release.get("platforms"))
        files = object_value(platforms.get(self.platform)).get("files")
        if not isinstance(files, list) or len(files) != 3:
            raise ValueError("invalid native GitHub tool inventory")
        parsed = tuple(
            Artifact.load(self.tools, value, str(object_value(value).get("name")))
            for value in files
        )
        if {artifact.name for artifact in parsed} != {"gh", "git-lfs", "github.gitconfig"}:
            raise ValueError("invalid native GitHub tool names")
        self.files = parsed
        inventory = object_value(json.loads((self.executors / "manifest.json").read_bytes()))
        self.executor = Artifact.load(
            self.executors, object_value(inventory.get("platforms")).get(self.platform), "executor"
        )

    def arm(self) -> None:
        self.enabled = True

    def command(self, authority: Authority) -> str:
        verifier = (
            "/sbin/sha256 -q" if self.platform == "freebsd-amd64" else "/usr/bin/digest -a sha256"
        )
        return (
            "set -eu; umask 077; root=/var/lib/overalls/native-github-bootstrap; "
            "test ! -L /var/lib/overalls; mkdir -p /var/lib/overalls; "
            "test \"$(ls -dn /var/lib/overalls | awk '{print $3}')\" = 0; "
            "chmod 0755 /var/lib/overalls; "
            'mkdir -p "$root"; chmod 0700 "$root"; '
            f'file="$root/{self.executor.sha256}"; '
            f'if [ ! -f "$file" ] || [ "$({verifier} "$file")" != {self.executor.sha256} ]; then '
            'stage=$(mktemp "$root/stage.XXXXXXXX"); '
            "curl -q --proxy '' --proto '=https' --connect-timeout 3 --max-time 8 --fail --silent "
            f'--max-filesize {self.executor.bytes} --output "$stage" '
            f"'https://llm.internal/agent/v1/bootstrap/artifacts/{self.executor.sha256}?executor_id={authority.executor_id}&fence_epoch={authority.fence_epoch}&bootstrap_id={BOOTSTRAP}'; "
            f'test "$({verifier} "$stage")" = {self.executor.sha256}; '
            'chmod 0700 "$stage"; mv "$stage" "$file"; fi; '
            f'exec "$file" __github-tools-bootstrap {authority.executor_id} {authority.fence_epoch}'
        )

    def file(self, method: str, host: str, target: str, authority: Authority) -> Artifact | None:
        url = urlsplit(target)
        if method != "GET" or host != "llm.internal" or not url.path.startswith("/agent/v1/"):
            return None
        query = parse_qs(url.query, strict_parsing=True)
        if "/artifacts/" not in url.path:
            return None
        selected = digest(url.path.rsplit("/", 1)[1])
        bootstrap = url.path.startswith("/agent/v1/bootstrap/artifacts/")
        key = "bootstrap_id" if bootstrap else "maintenance_id"
        if set(query) != {"executor_id", "fence_epoch", key} or any(
            len(value) != 1 for value in query.values()
        ):
            raise ValueError("invalid native artifact selector")
        if query[key] != [BOOTSTRAP if bootstrap else MAINTENANCE]:
            raise ValueError("invalid native artifact attempt")
        authority.lease(
            {"executor_id": query["executor_id"][0], "fence_epoch": int(query["fence_epoch"][0])}
        )
        if not self.enabled or not (self.bootstrap_started if bootstrap else self.started):
            raise ValueError("native artifact before start")
        files = (self.executor,) if bootstrap else self.files
        artifact = next((item for item in files if item.sha256 == selected), None)
        if artifact is None:
            raise ValueError("unknown native artifact")
        authority.record("github_bootstrap_artifact" if bootstrap else "github_tool_artifact")
        return artifact

    def route(
        self, method: str, host: str, target: str, body: bytes, authority: Authority
    ) -> Response | None:
        if host == HOST and target == "/api/user" and method == "GET" and self.enabled:
            authority.record("github_api_user")
            return response({"login": "native-fixture", "id": 200000, "type": "User"})
        lfs = PREFIX + "/info/lfs/objects/"
        if host == HOST and target.startswith("/git" + lfs) and self.enabled:
            suffix = target.removeprefix("/git" + lfs)
            if suffix == "batch" and method == "POST":
                request = object_value(json.loads(body))
                operation, objects = request.get("operation"), request.get("objects")
                if (
                    operation not in {"upload", "download"}
                    or not isinstance(objects, list)
                    or len(objects) > 16
                ):
                    raise ValueError("invalid native LFS batch")
                results: list[dict[str, object]] = []
                for value in objects:
                    item = object_value(value)
                    oid, size = digest(item.get("oid")), item.get("size")
                    if type(size) is not int or not 0 < size <= 4096:
                        raise ValueError("invalid native LFS size")
                    action = "upload" if operation == "upload" else "download"
                    results.append(
                        {
                            "oid": oid,
                            "size": size,
                            "actions": {action: {"href": f"https://{HOST}/git{lfs}{oid}"}},
                        }
                    )
                return response({"transfer": "basic", "objects": results})
            oid = digest(suffix)
            if (
                method == "PUT"
                and 0 < len(body) <= 4096
                and hashlib.sha256(body).hexdigest() == oid
            ):
                self.objects[oid] = body
                authority.record("github_lfs_uploaded")
                return response({})
            if method == "GET" and oid in self.objects:
                authority.record("github_lfs_downloaded")
                return Response(b"application/octet-stream", self.objects[oid])
            raise ValueError("invalid native LFS operation")
        if method != "POST" or host != "llm.internal":
            return None
        request = object_value(json.loads(body))
        if target == "/agent/v1/claim" and self.enabled and not self.bootstrap_completed:
            authority.lease(request)
            return response(
                {
                    "command": {
                        "id": BOOTSTRAP,
                        "call_id": "native-github-bootstrap",
                        "tool": "exec_command",
                        "arguments": {"cmd": self.command(authority)},
                    }
                }
            )
        if target == "/agent/v1/transition" and request.get("command_id") == BOOTSTRAP:
            authority.lease(request)
            status = request.get("status")
            if status == "started":
                self.bootstrap_started = True
            elif status == "completed" and self.completed:
                self.bootstrap_completed = True
                authority.record("github_bootstrap_completed")
            elif status != "failed":
                raise ValueError("invalid native bootstrap receipt")
            return response({"command_id": BOOTSTRAP, "status": status})
        if target == "/agent/v1/maintenance/claim":
            authority.lease(request)
            job: dict[str, object] | None = None
            if self.enabled and not self.completed:
                job = {
                    "id": MAINTENANCE,
                    "kind": "github-tools",
                    "generation": self.generation,
                    "platform": self.platform,
                    "files": [
                        {"name": file.name, "sha256": file.sha256, "bytes": file.bytes}
                        for file in self.files
                    ],
                }
            return response({"maintenance": job})
        if target == "/agent/v1/maintenance/transition":
            authority.lease(request)
            if request.get("maintenance_id") != MAINTENANCE or not self.enabled:
                raise ValueError("invalid native maintenance attempt")
            status = request.get("status")
            result = object_value(request.get("result"))
            if status == "started" and result == {}:
                self.started = True
            elif (
                status == "completed"
                and self.started
                and result.get("generation") == self.generation
                and result.get("outcome") in {"installed", "already_current"}
            ):
                self.completed = True
                self.outcome = str(result["outcome"])
                authority.record("github_tools_completed")
            elif status != "failed":
                raise ValueError("invalid native maintenance receipt")
            return response({"maintenance_id": MAINTENANCE, "status": status})
        return None
