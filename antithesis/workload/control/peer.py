"""Typed invocation and closed result parser for the real BEAM Control client peer."""

import os
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

from core.outcome import Observation

Mode = Literal["capacity", "pending", "delivery"]


@dataclass(frozen=True)
class PeerResult:
    fields: dict[str, bool | int]

    def flag(self, key: str) -> bool | None:
        value = self.fields.get(key)
        return value if type(value) is bool else None

    def count(self, key: str) -> int | None:
        value = self.fields.get(key)
        return value if type(value) is int else None


def parse_result(output: str) -> Observation[PeerResult]:
    """@cc [owner:ghuntley,label:verification] control-peer-closed-result
    Only a single complete observed record with unique, typed fields may
    produce a verdict. Process failure, malformed output and missing fields
    MUST remain unavailable; they MUST NOT be inferred as a passing result.
    """
    lines = output.splitlines()
    if len(lines) != 1:
        return Observation.unavailable()
    parts = lines[0].split("\t")
    if len(parts) < 2 or parts[0] != "RESULT" or parts[1] != "observed":
        return Observation.unavailable()
    fields: dict[str, bool | int] = {}
    for item in parts[2:]:
        key, sep, raw = item.partition("=")
        if not sep or not key.isidentifier() or key in fields:
            return Observation.unavailable()
        if raw == "true":
            fields[key] = True
        elif raw == "false":
            fields[key] = False
        elif raw.isdecimal():
            fields[key] = int(raw)
        else:
            return Observation.unavailable()
    return Observation.observed(PeerResult(fields))


def run_peer(mode: Mode, limit: int, timeout_ms: int) -> Observation[PeerResult]:
    """Run compiled OverallsProtocol.Control.Client without passing credentials."""
    if (
        mode not in ("capacity", "pending", "delivery")
        or limit
        not in (
            0,
            1,
            8,
            64,
            255,
            256,
            257,
        )
        or timeout_ms not in (50, 500, 5_000)
    ):
        raise ValueError("invalid Control peer draw")
    script = Path(
        os.getenv(
            "ANTITHESIS_CONTROL_PEER_SCRIPT", "/opt/overalls-antithesis/control-peer/runner.exs"
        )
    )
    ebin = Path(os.getenv("ANTITHESIS_CONTROL_PEER_EBIN", "/opt/overalls/control-peer/ebin"))
    try:
        completed = subprocess.run(
            ["elixir", "-pa", str(ebin), str(script), mode, str(limit), str(timeout_ms)],
            capture_output=True,
            text=True,
            timeout=90,
            check=False,
        )
    except (OSError, subprocess.SubprocessError, UnicodeError):
        return Observation.unavailable()
    if completed.returncode != 0 or len(completed.stdout) > 8_192:
        return Observation.unavailable()
    return parse_result(completed.stdout)
