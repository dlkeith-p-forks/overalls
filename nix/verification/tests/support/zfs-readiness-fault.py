"""Deterministic read-only observation fault for the disposable ZFS guest fixture."""

import subprocess
import sys
from pathlib import Path


def main() -> None:
    """@cc [owner:ghuntley,label:verification] readiness-fault-only-observes
    Only explicitly armed fixture property reads may be altered. Preserve native
    identities and policies. The armed mode varies logical usage between two
    coherent recursive observations; parent-incoherent mode changes only parent
    used bytes to violate decomposition. Never mutate ZFS or install this wrapper
    in an enrolled service.
    """
    executable, *arguments = sys.argv[1:]
    root = Path("/run/zfs-readiness-fault")
    parent_incoherent = (root / "parent-incoherent").exists()
    target = (
        ((root / "armed").exists() or parent_incoherent)
        and arguments[0] == "list"
        and ("-r" in arguments or parent_incoherent)
        and "-o" in arguments
        and arguments[-1] == "tank/lilly"
        and "logicalused" in arguments[arguments.index("-o") + 1].split(",")
    )
    if not target:
        result = subprocess.run([executable, *arguments], check=False)
        sys.exit(result.returncode)

    if parent_incoherent:
        result = subprocess.run(
            [executable, *arguments], capture_output=True, text=True, check=True
        )
        columns = arguments[arguments.index("-o") + 1].split(",")
        rows = [
            dict(zip(columns, line.split("\t"), strict=True)) for line in result.stdout.splitlines()
        ]
        parent = next(row for row in rows if row["name"] == "tank/lilly")
        parent["used"] = str(
            sum(int(parent[key]) for key in ("usedbychildren", "usedbydataset", "usedbysnapshots"))
            + 1
        )
        sys.stdout.write(
            "".join("\t".join(row[column] for column in columns) + "\n" for row in rows)
        )
        return

    count_file = root / "count"
    count = int(count_file.read_text()) if count_file.exists() else 0
    baseline = root / "baseline"
    if count == 0:
        result = subprocess.run(
            [executable, *arguments], capture_output=True, text=True, check=True
        )
        baseline.write_text(result.stdout)
    columns = arguments[arguments.index("-o") + 1].split(",")
    rows = [
        dict(zip(columns, line.split("\t"), strict=True))
        for line in baseline.read_text().splitlines()
    ]
    parent = next(row for row in rows if row["name"] == "tank/lilly")
    parent["logicalused"] = str(int(parent["logicalused"]) + count)
    count_file.write_text(str(count + 1))
    sys.stdout.write("".join("\t".join(row[column] for column in columns) + "\n" for row in rows))


if __name__ == "__main__":
    main()
