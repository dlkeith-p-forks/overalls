"""Bounded loopback infrastructure metrics, independent of application authority."""

from __future__ import annotations

import json
import math
import re
import signal
import socket
import threading
import time
import uuid
from collections.abc import Callable
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import TYPE_CHECKING

import metrics

if TYPE_CHECKING:
    from runtime import Config, Sample

type Collector = Callable[[Config, metrics.Rates, str, int, bool], Sample]

KINDS = frozenset(
    {
        "host",
        "cpu",
        "disk",
        "interface",
        "zpool",
        "dataset",
        "vm",
        "service",
        "backup",
        "brady",
        "updater",
    }
)
STATES = {
    "backup_state": frozenset(
        {"disabled", "unknown", "never-run", "running", "healthy", "degraded", "failed", "stale"}
    ),
    "backup_failure": frozenset(
        {
            "none",
            "capture",
            "database",
            "upload",
            "cleanup",
            "retention",
            "credentials",
            "repository",
            "interrupted",
            "configuration",
        }
    ),
    "updater_phase": frozenset(
        {
            "unknown",
            "fetch",
            "build",
            "stage",
            "preflight",
            "migrate",
            "activate",
            "verify",
            "healthy",
            "never-run",
        }
    ),
    "health": frozenset(
        {"ONLINE", "DEGRADED", "FAULTED", "OFFLINE", "UNAVAIL", "REMOVED", "SUSPENDED", "UNKNOWN"}
    ),
}
SAFE_NAME = re.compile(r"[a-zA-Z0-9_.:/!-]{1,255}")
SAFE_MEASURE = re.compile(r"[a-z][a-z0-9_]{0,95}")
MAX_RESPONSE = 8 * 1024 * 1024


def numeric(value: object) -> bool:
    return (
        type(value) in (int, float)
        and isinstance(value, int | float)
        and math.isfinite(value)
        and 0 <= value <= metrics.MAX_INTEGER
    )


def quoted(value: str) -> str:
    return json.dumps(value, ensure_ascii=True)


class Snapshot:
    """@cc [owner:ghuntley,label:observability;security] fleet-export-no-authority
    Resource collection MUST export only bounded numeric values and closed states
    over loopback. Request, placement, epoch, revision and invocation identifiers
    MUST NOT become metric labels. Failed/stale collection MUST suppress resource
    values and expose validity independently; it MUST NOT call Marshall or mutate
    guests. VM consumption is a bounded aggregate, not schedulable capacity.
    """

    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.sample: Sample | None = None
        self.failure = True
        self.failures = 0
        self.storage: list[metrics.SampledRecord] = []
        self.storage_time = 0.0

    def update(self, sample: Sample, storage_attempt: bool) -> None:
        with self.lock:
            self.sample = sample
            self.failure = False
            # Failed ZFS collection retains its original age until it expires.
            if storage_attempt and "zfs_collection_unavailable" not in sample["failures"]:
                self.storage = [
                    row for row in sample["records"] if row["kind"] in {"zpool", "dataset"}
                ]
                self.storage_time = sample["sampled_at"]

    def failed(self) -> None:
        with self.lock:
            self.failure = True
            self.failures += 1

    def render(self, now: float) -> bytes:
        with self.lock:
            sample, failure, failures = self.sample, self.failure, self.failures
            storage, storage_time = self.storage, self.storage_time
        valid = sample is not None and not failure and 0 <= now - sample["sampled_at"] <= 15
        lines = [
            f"overalls_fleet_collection_valid {int(valid)}",
            f"overalls_fleet_collection_failures_total {failures}",
        ]
        if sample is not None:
            lines.append(f"overalls_fleet_sampled_at_seconds {sample['sampled_at']}")
        if not valid or sample is None:
            return ("\n".join(lines) + "\n").encode()
        lines.extend(
            [
                f"overalls_fleet_collection_duration_seconds {sample['collection_seconds']}",
                f"overalls_fleet_missing_sources {sample['missing_sources']}",
                f"overalls_fleet_collection_partial {int(bool(sample['failures']))}",
            ]
        )
        rows = [
            (row, sample["sampled_at"])
            for row in sample["records"]
            if row["kind"] not in {"zpool", "dataset"}
        ]
        if 0 <= now - storage_time <= 90:
            rows.extend((row, storage_time) for row in storage)
        values: dict[tuple[str, str, str, str], int | float] = {}
        counts: dict[tuple[str, str, str, str], int] = {}
        observed: dict[tuple[str, str], float] = {}
        # Do not sum recursive parent dataset usage with its children.
        parents = {row["context"].get("parent") for row, _ in rows if row["kind"] == "dataset"}
        for row, sampled_at in rows[: metrics.MAX_ENTITIES]:
            if row["kind"] == "dataset" and row["context"].get("name") in parents:
                continue
            kind, entity = row["kind"], row["id"]
            if kind not in KINDS or not SAFE_NAME.fullmatch(entity):
                continue
            # Diagnostic metrics have a finite cardinality independent of VM churn.
            if (
                kind == "vm"
                or kind == "dataset"
                or (kind == "interface" and row["context"].get("scope") == "vm")
            ):
                entity = "all"
            observed[kind, entity] = sampled_at
            for family in ("gauges", "rates"):
                for measure, value in row.get(family, {}).items():
                    if SAFE_MEASURE.fullmatch(measure) and numeric(value):
                        key = (family, kind, entity, measure)
                        values[key] = values.get(key, 0) + value
                        counts[key] = counts.get(key, 0) + 1
            for key, allowed in STATES.items():
                state = row["context"].get(key)
                if isinstance(state, str) and state in allowed:
                    labels = f"kind={quoted(kind)},entity={quoted(entity)},field={quoted(key)},state={quoted(state)}"
                    lines.append(f"overalls_fleet_state_info{{{labels}}} 1")
        for (kind, entity), sampled_at in sorted(observed.items()):
            lines.append(
                f"overalls_fleet_observed_at_seconds{{kind={quoted(kind)},entity={quoted(entity)}}} {sampled_at}"
            )
        for (family, kind, entity, measure), value in sorted(values.items()):
            labels = f"kind={quoted(kind)},entity={quoted(entity)},measure={quoted(measure)}"
            name = "rate" if family == "rates" else "gauge"
            lines.append(f"overalls_fleet_{name}{{{labels}}} {value}")
            lines.append(
                f"overalls_fleet_known_entities{{family={quoted(name)},{labels}}} {counts[family, kind, entity, measure]}"
            )
        output = ("\n".join(lines) + "\n").encode()
        if len(output) > MAX_RESPONSE:
            return b"overalls_fleet_collection_valid 0\noveralls_fleet_response_refused 1\n"
        return output


def serve(config: Config, collect: Collector) -> None:
    snapshot, stop = Snapshot(), threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGINT, lambda *_: stop.set())

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            self.connection.settimeout(2)
            if self.path != "/metrics":
                self.send_error(404)
                return
            body = snapshot.render(time.time())
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, format: str, *args: object) -> None:
            pass

    class Server(ThreadingHTTPServer):
        # Bound local callers before starting a handler, including incomplete headers.
        slots = threading.BoundedSemaphore(8)

        def get_request(self) -> tuple[socket.socket, tuple[str, int]]:
            connection, address = super().get_request()
            connection.settimeout(2)
            return connection, address

        def process_request(self, request: object, client_address: tuple[str, int]) -> None:
            if not isinstance(request, socket.socket):
                raise TypeError("invalid_exporter_socket")
            if not self.slots.acquire(blocking=False):
                self.shutdown_request(request)
                return
            try:
                super().process_request(request, client_address)
            except Exception:
                self.slots.release()
                raise

        def process_request_thread(self, request: object, client_address: tuple[str, int]) -> None:
            if not isinstance(request, socket.socket):
                raise TypeError("invalid_exporter_socket")
            try:
                super().process_request_thread(request, client_address)
            finally:
                self.slots.release()

    server = Server(("127.0.0.1", config["port"]), Handler)
    server.timeout = 0.5
    server.daemon_threads = True

    def worker() -> None:
        rates, session, sequence = metrics.Rates(), str(uuid.uuid4()), 0
        while not stop.is_set():
            sequence += 1
            started = time.monotonic()
            try:
                storage = sequence % 6 == 1
                snapshot.update(collect(config, rates, session, sequence, storage), storage)
            except Exception:
                snapshot.failed()
            stop.wait(max(0, 5 - (time.monotonic() - started)))

    producer = threading.Thread(target=worker, daemon=True)
    producer.start()
    try:
        while not stop.is_set():
            server.handle_request()
    finally:
        server.server_close()
        producer.join(timeout=2)
