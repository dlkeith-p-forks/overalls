"""Bound the fixture's complete local SSH process group, including proxy children."""

import contextlib
import os
import signal
import subprocess
import sys
import time

# @cc [owner:ghuntley,label:verification] openssh-fixture-process-lifetime
# Fixture SSH checks MUST retain the real client exit status, kill their own
# proxy descendants on completion or timeout, and fail a timed-out command.
# No production process or independently launched VM may be signalled.
process = subprocess.Popen(
    ["bash", "-c", sys.argv[1]],
    start_new_session=True,
    stdin=subprocess.DEVNULL,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
)
deadline = time.monotonic() + 60
status: int | None = None
try:
    while process.poll() is None:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            status = 124
            break
        with contextlib.suppress(subprocess.TimeoutExpired):
            process.communicate(timeout=min(1, remaining))
    if status is None:
        status = process.returncode
finally:
    with contextlib.suppress(ProcessLookupError):
        os.killpg(process.pid, signal.SIGKILL)
    output, errors = process.communicate(timeout=5)
sys.stdout.buffer.write(output)
sys.stderr.buffer.write(errors)
sys.exit(status)
