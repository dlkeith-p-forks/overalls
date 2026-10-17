"""Typed boundaries for the public descriptor and private backup records."""

from __future__ import annotations

from typing import Literal, TypedDict

type JSON = bool | int | float | str | list["JSON"] | dict[str, "JSON"] | None
type Failure = Literal[
    "capture",
    "database",
    "upload",
    "cleanup",
    "retention",
    "credentials",
    "repository",
    "interrupted",
    "configuration",
]
type Phase = Literal["preparing", "capturing", "cleaning", "publishing", "completed", "failed"]


class PostgresConfig(TypedDict):
    ca_file: str
    pg_dump: str
    pg_restore: str
    psql: str
    timeout: int


class LillyConfig(TypedDict):
    tool: str


class Config(TypedDict):
    hostname: str
    repository: str
    region: str
    password_file: str
    cache_directory: str
    state_directory: str
    revision: str | None
    restic: str
    zfs: str
    findmnt: str
    mount: str
    umount: str
    command_timeout: int
    upload_limit_kib: int
    keep_last: int
    initialize: bool
    paths: list[str]
    materialize: list[str]
    images: list[str]
    protected_datasets: list[str]
    excludes: list[str]
    lilly: LillyConfig | None
    postgres: PostgresConfig | None


def object_value(value: object) -> dict[str, JSON]:
    if not isinstance(value, dict):
        raise ValueError("expected object")
    result: dict[str, JSON] = {}
    for key, item in value.items():
        if not isinstance(key, str):
            raise ValueError("expected string key")
        result[key] = json_value(item)
    return result


def json_value(value: object) -> JSON:
    if value is None or isinstance(value, (bool, int, float, str)):
        return value
    if isinstance(value, list):
        return [json_value(item) for item in value]
    return object_value(value)


def string(value: object) -> str:
    if not isinstance(value, str):
        raise ValueError("expected string")
    return value


def integer(value: object) -> int:
    if type(value) is not int:
        raise ValueError("expected integer")
    return value


def strings(value: object) -> list[str]:
    if not isinstance(value, list):
        raise ValueError("expected array")
    return [string(item) for item in value]


def boolean(value: object) -> bool:
    if not isinstance(value, bool):
        raise ValueError("expected boolean")
    return value


def config_value(value: object) -> Config:
    row = object_value(value)
    pg = object_value(row["postgres"]) if row["postgres"] is not None else None
    lilly = object_value(row["lilly"]) if row["lilly"] is not None else None
    return Config(
        hostname=string(row["hostname"]),
        repository=string(row["repository"]),
        region=string(row["region"]),
        password_file=string(row["password_file"]),
        cache_directory=string(row["cache_directory"]),
        state_directory=string(row["state_directory"]),
        revision=string(row["revision"]) if row["revision"] is not None else None,
        restic=string(row["restic"]),
        zfs=string(row["zfs"]),
        findmnt=string(row["findmnt"]),
        mount=string(row["mount"]),
        umount=string(row["umount"]),
        command_timeout=integer(row["command_timeout"]),
        upload_limit_kib=integer(row["upload_limit_kib"]),
        keep_last=integer(row["keep_last"]),
        initialize=boolean(row["initialize"]),
        paths=strings(row["paths"]),
        materialize=strings(row["materialize"]),
        images=strings(row["images"]),
        excludes=strings(row["excludes"]),
        protected_datasets=strings(row["protected_datasets"]),
        lilly=LillyConfig(tool=string(lilly["tool"])) if lilly is not None else None,
        postgres=PostgresConfig(
            ca_file=string(pg["ca_file"]),
            pg_dump=string(pg["pg_dump"]),
            pg_restore=string(pg["pg_restore"]),
            psql=string(pg["psql"]),
            timeout=integer(pg["timeout"]),
        )
        if pg is not None
        else None,
    )
