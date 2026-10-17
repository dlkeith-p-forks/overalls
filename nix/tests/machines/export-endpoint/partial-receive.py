"""Feed a bounded real SSH stream prefix to native receive, then close its input."""

import subprocess
import sys

receiver = subprocess.Popen(sys.argv[1:], stdin=subprocess.PIPE, stderr=subprocess.DEVNULL)
try:
    remaining = 1024 * 1024
    while remaining:
        chunk = sys.stdin.buffer.read(min(65536, remaining))
        if not chunk:
            raise RuntimeError("Fixture stream ended before interruption")
        receiver.stdin.write(chunk)
        remaining -= len(chunk)
    receiver.stdin.close()
    receiver.wait(timeout=30)
finally:
    if receiver.poll() is None:
        receiver.kill()
        receiver.wait()
sys.exit(1)
