"""Independent bounded logging health; never reads journal records or secrets."""

from __future__ import annotations

import json
import math
import os
import re
import socket
import stat
import sys
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from itertools import islice
from pathlib import Path
from typing import TypedDict

COUNTERS = ("errors_total", "retries_total", "dropped_records_total")
METRIC = re.compile(r"^fluentbit_output_([a-z_]+)\{([^\n]*)\}\s+([0-9.eE+-]+)$")
NAME = re.compile(r'(?:^|,)\s*name="([a-zA-Z0-9_-]+)"(?:,|$)')
CHUNK = re.compile(r"[0-9]+-([0-9]+)\.[0-9]+\.flb")
TRACE_FIELDS = frozenset(
    {
        "accepted_total",
        "refused_total",
        "storage_failures_total",
        "export_failed_total",
        "exported_total",
        "pending_batches",
        "pending_bytes",
        "oldest_pending_seconds",
        "retained_batches",
        "retained_bytes",
        "quota_bytes",
        "pending_quota_bytes",
        "poisoned",
        "sample_time",
    }
)
TRACE_METRIC = re.compile(r"overalls_trace_spool_([a-z_]+) ([0-9]+)")


class Settings(TypedDict):
    outputs: dict[str, int]
    shards: list[str]
    traces: dict[str, str]


def settings(value: object) -> Settings:
    if not isinstance(value, dict):
        raise ValueError("invalid health settings")
    raw: object = value.get("queueBudgets")
    if not isinstance(raw, dict):
        raise ValueError("invalid budgets")
    outputs: dict[str, int] = {}
    for name, budget in raw.items():
        if (
            not isinstance(name, str)
            or not re.fullmatch(r"[a-zA-Z0-9_-]+", name)
            or type(budget) is not int
            or not 0 < budget < 2**63
        ):
            raise ValueError("invalid output")
        outputs[name] = budget
    raw_shards: object = value.get("journalShards")
    if not isinstance(raw_shards, list):
        raise ValueError("invalid shards")
    shards: list[str] = []
    for shard in raw_shards:
        if (
            not isinstance(shard, str)
            or shard not in {"applications-a", "applications-b", "platform", "edge"}
            or shard in shards
        ):
            raise ValueError("invalid shard")
        shards.append(shard)
    raw_traces: object = value.get("traceSnapshots", {})
    if not isinstance(raw_traces, dict) or len(raw_traces) > 128:
        raise ValueError("invalid trace sources")
    traces: dict[str, str] = {}
    for producer, path in raw_traces.items():
        if (
            not isinstance(producer, str)
            or not re.fullmatch(r"[a-zA-Z0-9_-]{1,128}", producer)
            or not isinstance(path, str)
            or not Path(path).is_absolute()
        ):
            raise ValueError("invalid trace source")
        traces[producer] = path
    return Settings(outputs=outputs, shards=shards, traces=traces)


def trace_snapshot(path: str) -> dict[str, int]:
    """Read only an enrolled bounded numeric snapshot, never the trace archive."""
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as source:
        info = os.fstat(source.fileno())
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_nlink != 1
            or info.st_mode & 0o007
            or info.st_size > 8192
        ):
            raise ValueError("invalid trace snapshot")
        raw = source.read(8193)
    if len(raw) > 8192:
        raise ValueError("oversize trace snapshot")
    result: dict[str, int] = {}
    for line in raw.decode().splitlines():
        match = TRACE_METRIC.fullmatch(line)
        if not match or match[1] not in TRACE_FIELDS or match[1] in result:
            raise ValueError("invalid trace metric")
        number = int(match[2])
        if number >= 2**64 or (match[1] == "poisoned" and number > 1):
            raise ValueError("invalid trace number")
        result[match[1]] = number
    if result.keys() != TRACE_FIELDS:
        raise ValueError("incomplete trace snapshot")
    return result


def output_counters(body: str, outputs: dict[str, int]) -> dict[str, dict[str, float]]:
    result: dict[str, dict[str, float]] = {}
    for line in body.splitlines():
        metric = METRIC.fullmatch(line)
        if not metric or metric[1] not in COUNTERS:
            continue
        label = NAME.search(metric[2])
        if not label or label[1] not in outputs:
            continue
        value = float(metric[3])
        if not math.isfinite(value) or value < 0:
            raise ValueError("invalid counter")
        row = result.setdefault(label[1], {})
        if metric[1] in row:
            raise ValueError("duplicate counter")
        row[metric[1]] = value
    return result


def read_counters(port: int, outputs: dict[str, int]) -> dict[str, dict[str, float]]:
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(f"http://127.0.0.1:{port}/api/v1/metrics/prometheus", timeout=2) as reply:
        raw = reply.read(1024 * 1024 + 1)
    if len(raw) > 1024 * 1024:
        raise ValueError("oversize metrics")
    return output_counters(raw.decode(), outputs)


def measure(state: Path, cfg: Settings, port: int, now: float) -> str:
    """@cc [owner:ghuntley,label:reliability] logging-independent-health
    Filesystem queue health MUST remain observable when Fluent Bit is down.
    Failed counter reads MUST expose unavailable state, never fabricated zero
    errors/drops. Output labels MUST come only from the evaluated configuration.
    """
    lines = [f"overalls_logging_health_sample_time_seconds {now}"]
    try:
        chunks = list(islice((state / "chunks").rglob("*.flb"), 100_001))
        if len(chunks) > 100_000:
            raise ValueError("queue scan bound")
        stats = [path.stat() for path in chunks]
        stamps = [int(match[1]) for path in chunks if (match := CHUNK.fullmatch(path.name))]
        disk = os.statvfs(state)
        lines.extend(
            [
                "overalls_logging_filesystem_valid 1",
                f"overalls_logging_queue_bytes {sum(info.st_size for info in stats)}",
                f"overalls_logging_oldest_chunk_seconds {max((max(0, now - stamp) for stamp in stamps), default=0)}",
                f"overalls_logging_free_bytes {disk.f_bavail * disk.f_frsize}",
            ]
        )
        for shard in cfg["shards"]:
            cursor = state / f"journal-{shard}.db"
            lines.append(
                f'overalls_logging_shard_cursor_present{{shard="{shard}"}} {int(cursor.is_file() and not cursor.is_symlink())}'
            )
    except (OSError, ValueError):
        lines.append("overalls_logging_filesystem_valid 0")
    try:
        counters = read_counters(port, cfg["outputs"])
        lines.append("overalls_logging_collector_metrics_valid 1")
    except (OSError, ValueError, UnicodeError):
        counters = {}
        lines.append("overalls_logging_collector_metrics_valid 0")
    for name, budget in cfg["outputs"].items():
        labels = f'output="{name}"'
        lines.append(f"overalls_logging_output_budget_bytes{{{labels}}} {budget}")
        row = counters.get(name, {})
        lines.append(
            f"overalls_logging_output_counters_valid{{{labels}}} {int(all(key in row for key in COUNTERS))}"
        )
        for key, value in row.items():
            lines.append(f"overalls_logging_output_{key}{{{labels}}} {value}")
    for producer, path in cfg["traces"].items():
        labels = f'producer="{producer}"'
        try:
            snapshot = trace_snapshot(path)
            lines.append(f"overalls_trace_spool_snapshot_valid{{{labels}}} 1")
            lines.extend(
                f"overalls_trace_spool_{name}{{{labels}}} {value}"
                for name, value in snapshot.items()
            )
        except (OSError, ValueError, UnicodeError):
            lines.append(f"overalls_trace_spool_snapshot_valid{{{labels}}} 0")
    return "\n".join(lines) + "\n"


def serve(cfg: Settings, address: str, health_port: int, collector_port: int) -> None:
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            if self.path != "/metrics":
                self.send_error(404)
                return
            payload = measure(
                Path("/var/lib/overalls-logging"), cfg, collector_port, time.time()
            ).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def log_message(self, format: str, *args: object) -> None:
            pass

    class Server(HTTPServer):
        def get_request(self) -> tuple[socket.socket, tuple[str, int]]:
            connection, peer = super().get_request()
            connection.settimeout(3)
            return connection, peer

    Server((address, health_port), Handler).serve_forever()


def main() -> int:
    try:
        if sys.argv[1] == "--measure":
            raw_measure: object = json.loads(Path(sys.argv[2]).read_text())
            print(
                measure(Path(sys.argv[3]), settings(raw_measure), int(sys.argv[4]), time.time()),
                end="",
            )
            return 0
        raw: object = json.loads(Path(sys.argv[1]).read_text())
        cfg = settings(raw)
        serve(cfg, sys.argv[2], int(sys.argv[3]), int(sys.argv[4]))
    except (OSError, ValueError):
        print('{"event":"logging.health_unavailable"}', file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
