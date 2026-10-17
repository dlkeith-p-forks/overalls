"""Exercise generated sharded routing with the production Fluent Bit binary."""

from __future__ import annotations

import copy
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path


def object_value(value: object) -> dict[str, object]:
    if not isinstance(value, dict) or not all(isinstance(key, str) for key in value):
        raise ValueError("invalid configuration")
    return value


def rows(value: object) -> list[dict[str, object]]:
    if not isinstance(value, list):
        raise ValueError("invalid configuration list")
    return [object_value(row) for row in value]


def run(
    descriptor: dict[str, object], source: str, unit: str, *, transport: str = "journal"
) -> None:
    """@cc [owner:ghuntley,label:verification;security] sharded-destination-allowlist
    Every trusted source MUST reach its selected destination exactly once.
    A destination selecting only system MUST NOT receive sibling platform sources.
    """
    configuration = copy.deepcopy(object_value(descriptor["configuration"]))
    pipeline = object_value(configuration["pipeline"])
    inputs = rows(pipeline["inputs"])
    databases: set[str] = set()
    record = json.dumps(
        {
            "_SYSTEMD_UNIT": unit,
            "_TRANSPORT": transport,
            "__CURSOR": "routing-fixture",
            "MESSAGE": json.dumps(
                {
                    "event": "routing.fixture",
                    "source": "forged-source",
                    "trace_id": "1234567890abcdef1234567890abcdef",
                    "span_id": "1234567890abcdef",
                }
            ),
        }
    )
    for item in inputs:
        database = item["db"]
        assert isinstance(database, str) and database not in databases
        databases.add(database)
        route_rows = rows(object_value(item.get("routes", {})).get("logs", []))
        assert len(route_rows) <= 8
        item.update(name="dummy", samples=1, dummy=record)
        for key in ("db", "db.sync", "read_from_tail", "strip_underscores", "storage.type"):
            item.pop(key, None)
    outputs = rows(pipeline["outputs"])
    for output in outputs:
        output.pop("_credential_files", None)
        output.pop("storage.total_limit_size", None)
    pipeline["inputs"] = inputs
    configuration["pipeline"] = pipeline
    configuration["service"] = {"flush": 1, "grace": 1, "log_level": "warn"}
    with tempfile.TemporaryDirectory() as temporary:
        for output in outputs:
            alias = output["alias"]
            assert isinstance(alias, str)
            output.update(name="file", path=temporary, file=alias, format="plain")
        path = Path(temporary) / "config.yaml"
        path.write_text(json.dumps(configuration))
        executable = descriptor["executable"]
        assert isinstance(executable, str)
        env = dict(
            os.environ,
            OVERALLS_LOG_MACHINE="fixture-machine",
            OVERALLS_LOG_HOSTNAME="fixture-host",
            OVERALLS_LOG_ENVIRONMENT="fixture",
        )
        process = subprocess.Popen(
            [executable, "-c", str(path)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )
        try:
            _stdout, stderr = process.communicate(timeout=3)
        except subprocess.TimeoutExpired:
            process.terminate()
            _stdout, stderr = process.communicate(timeout=8)
        assert b"configuration error" not in stderr.lower(), stderr
        selected = (
            "platform"
            if source in {"auth", "kernel", "storage", "mail", "operations", "system"}
            else source
        )
        wide = Path(temporary) / f"fixture-{selected}"
        emitted = wide.read_bytes()
        assert emitted.count(b"fixture-machine:routing-fixture") == 1, (emitted, stderr)
        record_value: object = json.loads(emitted)
        envelope = object_value(record_value)
        assert envelope["source"] == source, envelope
        assert envelope["trace_id"] == "1234567890abcdef1234567890abcdef", envelope
        # A platform output may share a queue while authorizing only one source.
        # Globally selected sibling sources MUST NOT reach that destination.
        restricted = Path(temporary) / "restricted-platform"
        if source == "system":
            assert restricted.read_bytes().count(b"fixture-machine:routing-fixture") == 1
        else:
            assert not restricted.exists(), (source, restricted.read_bytes())


def main() -> None:
    raw: object = json.loads(Path(sys.argv[1]).read_text())
    descriptor = object_value(raw)
    for name in (
        "marshall",
        "lilly",
        "porsche",
        "audi",
        "ziggy",
        "enrico",
        "brady",
        "galileo",
        "underclass",
    ):
        run(
            descriptor,
            name,
            "marshall-overalls.service" if name == "marshall" else f"{name}.service",
        )
    for name, unit in {
        "haproxy": "haproxy.service",
        "auth": "sshd.service",
        "storage": "zfs-zed.service",
        "mail": "overalls-smtprelay.service",
        "operations": "overalls-auto-update.service",
        "system": "unclassified-fixture.service",
    }.items():
        run(descriptor, name, unit)
    run(descriptor, "kernel", "", transport="kernel")
    print("Generated source routing, trusted correlation and cursor isolation passed")


if __name__ == "__main__":
    main()
