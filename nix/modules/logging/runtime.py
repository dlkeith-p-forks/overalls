"""Prepare a private Fluent Bit configuration without exposing destination secrets."""

import configparser
import json
import os
import stat
import sys
import urllib.request
from pathlib import Path
from typing import TypedDict


class AwsConfiguration(TypedDict):
    mode: str
    credentialsFile: str | None


class Descriptor(TypedDict):
    configuration: dict[str, object]
    hostname: str
    environment: str
    aws: AwsConfiguration
    executable: str


def string(value: object) -> str:
    if not isinstance(value, str):
        raise ValueError("expected string")
    return value


def object_value(value: object) -> dict[str, object]:
    if not isinstance(value, dict):
        raise ValueError("expected object")
    return value


def descriptor_value(raw: object) -> Descriptor:
    row = object_value(raw)
    aws = object_value(row["aws"])
    return Descriptor(
        configuration=object_value(row["configuration"]),
        hostname=string(row["hostname"]),
        environment=string(row["environment"]),
        aws=AwsConfiguration(
            mode=string(aws["mode"]),
            credentialsFile=(
                string(aws["credentialsFile"]) if aws["credentialsFile"] is not None else None
            ),
        ),
        executable=string(row["executable"]),
    )


def private_read(path: object) -> str:
    if (
        not isinstance(path, str)
        or not path.startswith("/")
        or any(part in ("", ".", "..") for part in path.split("/")[1:])
    ):
        raise ValueError("invalid credential path")
    parent = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        for part in path.split("/")[1:-1]:
            child = os.open(
                part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent
            )
            os.close(parent)
            parent = child
            info = os.fstat(parent)
            if info.st_uid != 0 or (info.st_mode & 0o022 and not info.st_mode & stat.S_ISVTX):
                raise ValueError("invalid credential ancestry")
        fd = os.open(path.split("/")[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent)
    finally:
        os.close(parent)
    try:
        info = os.fstat(fd)
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != 0
            or (info.st_mode & 0o777) != 0o600
            or info.st_nlink != 1
        ):
            raise ValueError("invalid credential permissions")
        data = os.read(fd, 65537)
        if len(data) > 65536:
            raise ValueError("credential too large")
        return data.decode().rstrip("\n")
    finally:
        os.close(fd)


def aws_identity(mode: str) -> str:
    if mode != "ec2":
        return ""
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    base = "http://169.254.169.254/latest/"
    request = urllib.request.Request(
        base + "api/token", method="PUT", headers={"X-aws-ec2-metadata-token-ttl-seconds": "60"}
    )
    with opener.open(request, timeout=2) as response:
        token = response.read(2048).decode()
    request = urllib.request.Request(
        base + "meta-data/instance-id", headers={"X-aws-ec2-metadata-token": token}
    )
    with opener.open(request, timeout=2) as response:
        value = response.read(128).decode()
    if not value.startswith("i-") or not all(c in "0123456789abcdef" for c in value[2:]):
        raise ValueError("invalid instance identity")
    return value


def prepare(descriptor: Descriptor, runtime: Path) -> Path:
    config = descriptor["configuration"]
    pipeline = config["pipeline"]
    if not isinstance(pipeline, dict):
        raise TypeError("invalid pipeline")
    outputs = pipeline["outputs"]
    if not isinstance(outputs, list):
        raise TypeError("invalid outputs")
    for output in outputs:
        if not isinstance(output, dict):
            raise AttributeError("invalid output")
        secrets = output.pop("_credential_files", {})
        if not isinstance(secrets, dict):
            raise AttributeError("invalid output credentials")
        for key, path in secrets.items():
            value = private_read(path)
            if "\n" in value or "\r" in value or "${" in value:
                raise ValueError("multiline output credential")
            output[key] = value
    auth = descriptor["aws"]
    os.environ["OVERALLS_AWS_MODE"] = auth["mode"]
    # No ambient AWS identity, proxy, or web-identity fallback in the collector.
    for key in list(os.environ):
        if key.startswith("AWS_"):
            del os.environ[key]
    os.environ["AWS_CONFIG_FILE"] = "/dev/null"
    os.environ["AWS_SHARED_CREDENTIALS_FILE"] = "/dev/null"
    os.environ["AWS_EC2_METADATA_DISABLED"] = "false" if auth["mode"] == "ec2" else "true"
    if auth["mode"] == "file":
        value = private_read(auth["credentialsFile"])
        parser = configparser.ConfigParser(interpolation=None)
        parser.read_string(value)
        allowed = {"aws_access_key_id", "aws_secret_access_key", "aws_session_token"}
        if parser.sections() != ["default"] or parser.defaults():
            raise ValueError("invalid AWS profile")
        profile = dict(parser["default"])
        if not {"aws_access_key_id", "aws_secret_access_key"} <= profile.keys() <= allowed:
            raise ValueError("invalid AWS credentials")
        if any(not v or "\n" in v for v in profile.values()):
            raise ValueError("invalid AWS credentials")
        target = runtime / "aws-credentials"
        target.write_text(value)
        target.chmod(0o600)
        os.environ["AWS_SHARED_CREDENTIALS_FILE"] = str(target)
    os.environ["OVERALLS_LOG_MACHINE"] = Path("/etc/machine-id").read_text().strip()
    os.environ["OVERALLS_LOG_HOSTNAME"] = descriptor["hostname"]
    os.environ["OVERALLS_LOG_ENVIRONMENT"] = descriptor["environment"]
    os.environ["OVERALLS_JOURNAL_INITIAL_BOOT"] = "1"
    try:
        os.environ["OVERALLS_LOG_INSTANCE"] = aws_identity(auth["mode"])
    except Exception:
        # Stable machine identity still exists during temporary metadata failures.
        os.environ["OVERALLS_LOG_INSTANCE"] = ""
        print('{"event":"logging.identity_unavailable"}', file=sys.stderr)
    identity = os.environ["OVERALLS_LOG_INSTANCE"] or os.environ["OVERALLS_LOG_MACHINE"]
    for output in outputs:
        if not isinstance(output, dict):
            raise TypeError("invalid output")
        if output["name"] == "cloudwatch_logs":
            output["log_stream_prefix"] = descriptor["hostname"] + "/" + identity + "/"
    target = runtime / "fluent-bit.yaml"
    target.write_text(json.dumps(config))
    target.chmod(0o600)
    return target


def main() -> int:
    os.umask(0o077)
    try:
        descriptor = descriptor_value(json.loads(Path(sys.argv[1]).read_text()))
        target = prepare(descriptor, Path(os.environ["RUNTIME_DIRECTORY"]))
    except Exception:
        print('{"event":"logging.configuration_failed"}', file=sys.stderr)
        return 1
    os.execv(descriptor["executable"], [descriptor["executable"], "--config", str(target)])


if __name__ == "__main__":
    sys.exit(main())
