"""Exercise independent health and shard cursor checks through their real CLIs."""

from __future__ import annotations

import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

MODULE = Path(sys.argv[1])


def run(script: str, *args: str, success: bool = True) -> str:
    result = subprocess.run(
        [sys.executable, str(MODULE / script), *args], capture_output=True, text=True, check=False
    )
    assert (result.returncode == 0) == success, result.stderr
    return result.stdout if success else result.stderr


def cursor(path: Path) -> str:
    with sqlite3.connect(path) as connection:
        row = connection.execute("SELECT cursor FROM checkpoint").fetchone()
    assert row is not None and isinstance(row[0], str)
    return row[0]


class Metrics(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        payload = (
            b'fluentbit_output_errors_total{name="fixture-platform"} 2\n'
            b'fluentbit_output_retries_total{name="fixture-platform"} 3\n'
            b'fluentbit_output_dropped_records_total{name="fixture-platform"} 4\n'
            b'fluentbit_output_errors_total{name="foreign-private-sentinel"} 999\n'
        )
        self.send_response(200)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, format: str, *args: object) -> None:
        pass


def main() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        directory = Path(temporary)
        trace = directory / "metrics.prom"
        trace.write_text(
            "\n".join(
                f"overalls_trace_spool_{name} {value}"
                for name, value in {
                    "accepted_total": 5,
                    "refused_total": 1,
                    "storage_failures_total": 0,
                    "export_failed_total": 2,
                    "exported_total": 3,
                    "pending_batches": 2,
                    "pending_bytes": 2048,
                    "oldest_pending_seconds": 10,
                    "retained_batches": 5,
                    "retained_bytes": 4096,
                    "quota_bytes": 1048576,
                    "pending_quota_bytes": 131072,
                    "poisoned": 0,
                    "sample_time": 100,
                }.items()
            )
            + "\n"
        )
        trace.chmod(0o640)
        descriptor = directory / "descriptor.json"
        descriptor.write_text(
            json.dumps(
                {
                    "journalShards": ["applications-a", "applications-b", "platform"],
                    "queueBudgets": {"fixture-platform": 1048576},
                    "traceSnapshots": {"lilly": str(trace)},
                }
            )
        )
        state = directory / "state"
        state.mkdir(mode=0o700)
        # Missing shard cursors start fresh; existing ones must pass quick_check.
        run("check_cursors.py", str(descriptor), str(state))
        target = state / "journal-applications-a.db"
        with sqlite3.connect(target) as connection:
            connection.execute("CREATE TABLE checkpoint (cursor TEXT)")
            connection.execute("INSERT INTO checkpoint VALUES ('advanced-shard-checkpoint')")
        target.chmod(0o600)
        run("check_cursors.py", str(descriptor), str(state))
        assert cursor(target) == "advanced-shard-checkpoint"
        assert target.stat().st_mode & 0o777 == 0o600
        # A retired single-cursor database is neither read nor converted.
        retired = state / "journal.db"
        retired.write_bytes(b"private-retired-checkpoint-sentinel")
        retired.chmod(0o600)
        run("check_cursors.py", str(descriptor), str(state))
        assert not (state / "journal-platform.db").exists()
        assert retired.read_bytes() == b"private-retired-checkpoint-sentinel"
        retired.unlink()
        # Untrusted custody fails closed and leaves the cursor unchanged.
        target.chmod(0o640)
        assert "logging.cursor_check_refused" in run(
            "check_cursors.py", str(descriptor), str(state), success=False
        )
        target.chmod(0o600)
        alias = state / "journal-applications-b.db"
        alias.hardlink_to(target)
        assert "logging.cursor_check_refused" in run(
            "check_cursors.py", str(descriptor), str(state), success=False
        )
        alias.unlink()
        alias.symlink_to(target)
        assert "logging.cursor_check_refused" in run(
            "check_cursors.py", str(descriptor), str(state), success=False
        )
        alias.unlink()
        assert cursor(target) == "advanced-shard-checkpoint"
        target.write_bytes(b"private-corrupt-shard-sentinel")
        failure = run("check_cursors.py", str(descriptor), str(state), success=False)
        assert "logging.cursor_check_refused" in failure
        assert "private-corrupt" not in failure
        assert target.read_bytes() == b"private-corrupt-shard-sentinel"
        chunks = state / "chunks"
        chunks.mkdir()
        (chunks / "1-100.0.flb").write_bytes(b"private-record-sentinel")
        server = HTTPServer(("127.0.0.1", 0), Metrics)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        port = str(server.server_port)
        healthy = run("health.py", "--measure", str(descriptor), str(state), port)
        assert "overalls_logging_filesystem_valid 1" in healthy
        assert "overalls_logging_collector_metrics_valid 1" in healthy
        assert 'overalls_logging_output_counters_valid{output="fixture-platform"} 1' in healthy
        assert 'overalls_logging_output_errors_total{output="fixture-platform"} 2.0' in healthy
        assert "foreign-private" not in healthy and "private-record" not in healthy
        assert 'overalls_trace_spool_snapshot_valid{producer="lilly"} 1' in healthy
        assert 'overalls_trace_spool_pending_bytes{producer="lilly"} 2048' in healthy
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
        unavailable = run("health.py", "--measure", str(descriptor), str(state), port)
        assert "overalls_logging_filesystem_valid 1" in unavailable
        assert "overalls_logging_collector_metrics_valid 0" in unavailable
        assert "overalls_logging_output_errors_total" not in unavailable
        assert 'overalls_logging_output_counters_valid{output="fixture-platform"} 0' in unavailable
        assert 'overalls_trace_spool_pending_bytes{producer="lilly"} 2048' in unavailable
        trace.write_text("private-trace-payload-sentinel")
        invalid_trace = run("health.py", "--measure", str(descriptor), str(state), port)
        assert 'overalls_trace_spool_snapshot_valid{producer="lilly"} 0' in invalid_trace
        assert "private-trace" not in invalid_trace
        assert "overalls_trace_spool_pending_bytes" not in invalid_trace
        trace.unlink()
        trace.symlink_to(target)
        invalid_link = run("health.py", "--measure", str(descriptor), str(state), port)
        assert 'overalls_trace_spool_snapshot_valid{producer="lilly"} 0' in invalid_link
        missing = run("health.py", "--measure", str(descriptor), str(directory / "missing"), port)
        assert "overalls_logging_filesystem_valid 0" in missing
    print("Independent logging health and read-only shard cursor checks passed")


if __name__ == "__main__":
    os.umask(0o077)
    main()
