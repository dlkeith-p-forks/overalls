"""Bounded passive terminal observations from Lilly's private local socket."""

import json
import socket
import time
from typing import TypedDict


class GuestObservation(TypedDict):
    placement_id: str
    execution_epoch: int
    generation: int
    reachable: int
    age_ms: int


class TerminalMetrics(TypedDict):
    gauges: dict[str, int]
    counters: dict[str, int]
    vms: list[GuestObservation]


def object_value(value: object) -> dict[str, object]:
    if not isinstance(value, dict):
        raise ValueError("invalid terminal metrics")
    return value


def number(value: object, maximum: int = 2**63 - 1) -> int:
    if type(value) is not int or not 0 <= value <= maximum:
        raise ValueError("invalid terminal metric")
    return value


def decode(value: object, host_id: str) -> TerminalMetrics:
    """Validate the exact numeric projection without exposing rejected values."""
    body = object_value(value)
    if set(body) != {"version", "host_id", "gauges", "counters", "vms"}:
        raise ValueError("invalid terminal fields")
    if body["version"] != 1 or body["host_id"] != host_id:
        raise ValueError("invalid terminal identity")
    raw_gauges = object_value(body["gauges"])
    if (
        not {"terminal_stream_ready"}
        <= set(raw_gauges)
        <= {"terminal_stream_ready", "terminal_live_channels"}
    ):
        raise ValueError("invalid terminal gauges")
    gauges = {
        key: number(value, 1 if key == "terminal_stream_ready" else 4096)
        for key, value in raw_gauges.items()
    }
    raw_counters = object_value(body["counters"])
    if set(raw_counters) != {"terminal_dial_failures", "terminal_proxy_errors"}:
        raise ValueError("invalid terminal counters")
    counters = {key: number(value) for key, value in raw_counters.items()}
    raw_vms: object = body["vms"]
    if not isinstance(raw_vms, list) or len(raw_vms) > 512:
        raise ValueError("invalid terminal observations")
    vms: list[GuestObservation] = []
    import uuid

    for raw in raw_vms:
        row = object_value(raw)
        if set(row) != {"placement_id", "execution_epoch", "generation", "reachable", "age_ms"}:
            raise ValueError("invalid terminal observation")
        placement = row["placement_id"]
        if not isinstance(placement, str) or str(uuid.UUID(placement)) != placement:
            raise ValueError("invalid terminal placement")
        epoch, generation = number(row["execution_epoch"]), number(row["generation"])
        if epoch == 0 or generation == 0:
            raise ValueError("invalid terminal execution")
        vms.append(
            GuestObservation(
                placement_id=placement,
                execution_epoch=epoch,
                generation=generation,
                reachable=number(row["reachable"], 1),
                age_ms=number(row["age_ms"], 300_000),
            )
        )
    return TerminalMetrics(gauges=gauges, counters=counters, vms=vms)


def collect(
    host_id: str | None, path: str = "/run/lilly-release/terminal-metrics.sock"
) -> TerminalMetrics:
    """@cc [owner:ghuntley,label:security] terminal-monitor-passive-bounded-read
    Only passive numeric observations from the configured local socket may be
    returned. The read MUST be bounded by time and bytes, match host identity,
    and return absent metrics on failure; it MUST NOT issue guest controls.
    """
    empty = TerminalMetrics(gauges={}, counters={}, vms=[])
    if host_id is None:
        return empty
    try:
        deadline = time.monotonic() + 0.8
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(0.8)
            client.connect(path)
            body = bytearray()
            while b"\n" not in body and len(body) <= 131_072:
                client.settimeout(max(0.001, deadline - time.monotonic()))
                if time.monotonic() >= deadline:
                    return empty
                chunk = client.recv(min(4096, 131_073 - len(body)))
                if not chunk:
                    return empty
                body.extend(chunk)
            if len(body) > 131_072 or not body.endswith(b"\n"):
                return empty
            value: object = json.loads(body)
            return decode(value, host_id)
    except (OSError, ValueError, TypeError, KeyError):
        return empty
