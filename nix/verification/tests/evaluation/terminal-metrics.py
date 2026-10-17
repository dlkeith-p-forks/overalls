"""Validate passive terminal metric decoding independently of guest access."""

import importlib.util
import sys
from pathlib import Path

source = (
    Path(sys.argv[1])
    if len(sys.argv) == 2
    else Path(__file__).resolve().parents[2] / "modules/fleet-exporter/terminal_metrics.py"
)
spec = importlib.util.spec_from_file_location("terminal_metrics", source)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)


def main() -> None:
    host = "11111111-1111-4111-8111-111111111111"
    payload: dict[str, object] = {
        "version": 1,
        "host_id": host,
        "gauges": {"terminal_stream_ready": 0},
        "counters": {"terminal_dial_failures": 3, "terminal_proxy_errors": 2},
        "vms": [
            {
                "placement_id": host,
                "execution_epoch": 1,
                "generation": 2,
                "reachable": 0,
                "age_ms": 100,
            }
        ],
    }
    assert module.decode(payload, host)["gauges"] == {"terminal_stream_ready": 0}
    for change in (
        {"host_id": "foreign"},
        {"gauges": {"terminal_stream_ready": True}},
        {"payload": "forbidden"},
        {"vms": [{}]},
        {"counters": {}},
    ):
        try:
            module.decode({**payload, **change}, host)
        except ValueError:
            pass
        else:
            raise AssertionError("invalid observation accepted")
    assert module.collect(host, "/nonexistent-terminal-monitor.sock") == {
        "gauges": {},
        "counters": {},
        "vms": [],
    }


if __name__ == "__main__":
    main()
