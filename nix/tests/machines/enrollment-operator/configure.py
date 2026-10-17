"""Bind runtime-generated public fixture IDs to the real module's runtime config."""

import json
from pathlib import Path

path = Path("/run/lilly-release/config.json")
config = json.loads(path.read_bytes())
metadata = json.loads(Path("/run/enrollment-metadata.json").read_bytes())
config["host_id"] = metadata["host_id"]
config["pools"] = [
    {
        **{k: p[k] for k in ("id", "filesystem_id", "storage")},
        "path": "/var/lib/lilly/pool",
        "max_iops": None,
        "max_iops_source": None,
    }
    for p in metadata["pools"]
]
path.write_text(json.dumps(config))
