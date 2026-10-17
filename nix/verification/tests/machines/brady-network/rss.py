"""Bounded native Brady RSS sampler; no arguments, payloads or environment logs."""

import subprocess
import time
from pathlib import Path


def main() -> None:
    pid = int(
        subprocess.check_output(
            [
                "/run/current-system/sw/bin/systemctl",
                "show",
                "brady-network-test",
                "-p",
                "MainPID",
                "--value",
            ],
            text=True,
        ).strip()
    )
    peak = 0
    while True:
        try:
            lines = Path(f"/proc/{pid}/status").read_text().splitlines()
        except FileNotFoundError:
            return
        for line in lines:
            if line.startswith("VmRSS:"):
                peak = max(peak, int(line.split()[1]) * 1024)
        Path("/run/brady-rss-peak").write_text(str(peak))
        time.sleep(0.05)


if __name__ == "__main__":
    main()
