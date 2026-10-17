"""Run the pinned ACME client with explicit credentials and fixed diagnostics."""

import configparser
import contextlib
import json
import os
import signal
import subprocess
import sys
from pathlib import Path
from typing import TypedDict


class Route53(TypedDict):
    region: str
    hostedZoneId: str
    endpoint: str | None


class ClientCore(TypedDict):
    challengeType: str
    caFile: str
    lego: str
    timeoutSeconds: int


class ClientConfiguration(ClientCore, total=False):
    route53: Route53


def string(value: object) -> str:
    if not isinstance(value, str):
        raise ValueError("expected string")
    return value


def integer(value: object) -> int:
    if type(value) is not int:
        raise ValueError("expected integer")
    return value


def object_value(value: object) -> dict[str, object]:
    if not isinstance(value, dict):
        raise ValueError("expected object")
    return value


def configuration_value(raw: object) -> ClientConfiguration:
    if not isinstance(raw, dict):
        raise ValueError("invalid client configuration")
    route53 = raw.get("route53")
    result = ClientConfiguration(
        challengeType=string(raw["challengeType"]),
        caFile=string(raw["caFile"]),
        lego=string(raw["lego"]),
        timeoutSeconds=integer(raw["timeoutSeconds"]),
    )
    if route53 is not None:
        row = object_value(route53)
        result["route53"] = Route53(
            region=string(row["region"]),
            hostedZoneId=string(row["hostedZoneId"]),
            endpoint=string(row["endpoint"]) if row["endpoint"] is not None else None,
        )
    return result


# @cc [owner:ghuntley,label:security] acme-selected-credential-source
# The AWS SDK MUST use only the validated default profile delivered by systemd.
# Environment credentials, external processes and instance metadata are excluded.
def dns_environment(configuration: ClientConfiguration) -> dict[str, str]:
    credential = Path(os.environ["AWS_SHARED_CREDENTIALS_FILE"])
    with credential.open("rb") as stream:
        raw = stream.read(65537)
    if not 0 < len(raw) <= 65536:
        raise ValueError("invalid credential file")
    profiles = configparser.ConfigParser(interpolation=None)
    profiles.read_string(raw.decode())
    required = {"aws_access_key_id", "aws_secret_access_key"}
    if profiles.sections() != ["default"] or profiles.defaults():
        raise ValueError("invalid credential profile")
    values = dict(profiles["default"])
    if not required <= values.keys() <= required | {"aws_session_token"}:
        raise ValueError("invalid credential selection")
    if any(not value or len(value) > 4096 for value in values.values()):
        raise ValueError("invalid credential value")
    route53 = configuration.get("route53")
    if route53 is None:
        raise ValueError("invalid challenge configuration")
    environment = {
        "AWS_SHARED_CREDENTIALS_FILE": str(credential),
        "AWS_CONFIG_FILE": "/dev/null",
        "AWS_PROFILE": "default",
        "AWS_EC2_METADATA_DISABLED": "true",
        "AWS_REGION": route53["region"],
        "AWS_HOSTED_ZONE_ID": route53["hostedZoneId"],
        "AWS_CA_BUNDLE": configuration["caFile"],
    }
    if route53["endpoint"] is not None:
        environment["AWS_ENDPOINT_URL"] = route53["endpoint"]
    return environment


# @cc [owner:ghuntley,label:security] acme-method-isolation
# HTTP validation MUST NOT load AWS credentials or inherit ambient client settings.
# Both methods MUST discard raw diagnostics and terminate the entire client group
# on timeout before reporting a fixed failure event.
def main(configuration: ClientConfiguration, arguments: list[str]) -> None:
    environment = {
        "LEGO_CA_CERTIFICATES": configuration["caFile"],
        "SSL_CERT_FILE": configuration["caFile"],
    }
    if configuration["challengeType"] == "dns-01":
        environment.update(dns_environment(configuration))
    elif configuration["challengeType"] != "http-01":
        raise ValueError("invalid challenge type")
    print('{"event":"acme.client_started","severity":"info"}', flush=True)
    with subprocess.Popen(
        [configuration["lego"], *arguments],
        env=environment,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    ) as process:
        try:
            if process.wait(timeout=configuration["timeoutSeconds"]) != 0:
                raise ValueError("ACME client failed")
        except BaseException:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            raise
    print('{"event":"acme.client_succeeded","severity":"info"}')


if __name__ == "__main__":
    try:
        main(configuration_value(json.loads(Path(sys.argv[1]).read_text())), sys.argv[2:])
    except Exception:
        print('{"event":"acme.client_failed","severity":"error"}', file=sys.stderr)
        sys.exit(1)
