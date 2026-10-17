"""Root-prepared configuration for the independent inner inference service."""

import json
import sys
import uuid
from pathlib import Path
from typing import TypedDict

from runtime import SetupError, encode, publish, read_private


class ZiggyConfig(TypedDict):
    version: int
    host_id: str
    control_plane: str
    ca_file: str
    credential_file: str
    openai_key_file: str
    anthropic_key_file: str
    socket: str
    spool: str
    max_requests: int
    enabled_providers: list[str]


def configuration(host: object, selection: object) -> ZiggyConfig:
    """@cc [owner:ghuntley,label:security] inception-ziggy-fixed-local-authority
    Configuration MUST bind the enrolled inner host and verified loopback fleet
    endpoint. Operator selection may choose only a nonempty unique subset of
    supported providers, never credential paths, endpoints or listener sockets.
    No provider or parent credential may enter the generated configuration.
    """
    if not isinstance(host, str) or str(uuid.UUID(host)) != host:
        raise SetupError("inner inference host invalid")
    if (
        not isinstance(selection, dict)
        or set(selection) != {"version", "enabled_providers"}
        or type(selection["version"]) is not int
        or selection["version"] != 1
    ):
        raise SetupError("inner inference provider selection invalid")
    providers = selection["enabled_providers"]
    if (
        not isinstance(providers, list)
        or not providers
        or any(
            not isinstance(item, str) or item not in ("openai", "anthropic") for item in providers
        )
        or len(set(providers)) != len(providers)
    ):
        raise SetupError("inner inference provider selection invalid")
    return ZiggyConfig(
        version=1,
        host_id=host,
        control_plane="https://localhost:5443",
        ca_file="/run/ziggy/credentials/ca.pem",
        credential_file="/run/ziggy/credentials/control.token",
        openai_key_file="/run/ziggy/credentials/openai.key",
        anthropic_key_file="/run/ziggy/credentials/anthropic.key",
        socket="/run/ziggy/proxy.sock",
        spool="/var/lib/ziggy/spool",
        max_requests=65536,
        enabled_providers=providers,
    )


def prepare(
    state: Path = Path("/var/lib/inception"), runtime: Path = Path("/run/inception")
) -> None:
    host = json.loads(read_private(state / "lilly.json"))["host_id"]
    try:
        selection = json.loads(read_private(state / "ziggy-providers.json"))
    except FileNotFoundError:
        selection = {"version": 1, "enabled_providers": ["openai", "anthropic"]}
    value = configuration(host, selection)
    publish(runtime / "ziggy.json", encode(value))


if __name__ == "__main__":
    try:
        prepare()
    except (OSError, ValueError, KeyError, TypeError, SetupError):
        sys.exit("Inner inference configuration unavailable")
