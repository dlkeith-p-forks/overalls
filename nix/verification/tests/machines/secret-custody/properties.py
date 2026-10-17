"""Probe secret publication and process boundaries of the module inside a VM.

These are the fixed one-shot checks of the secrets preparation module:
invalid renders are rejected, failed publication preserves the previous
bundle, interrupted staging is durable and cleaned up, symlink and unsafe
parents are refused, resolver output stays bounded and descendants are
killed. The generated EnvironmentFile roundtrip through real systemd units
moved to the driver-side Hegel property in driver.py (see the
environment-parser-roundtrip contract comment there).
"""

import importlib.util
import os
import signal
import stat
import sys
import tempfile
import time
import traceback
import types
from collections.abc import Callable
from pathlib import Path


def rejected(function: Callable[..., object], *arguments: object) -> None:
    try:
        function(*arguments)
    except (ValueError, UnicodeError, OSError):
        return
    raise AssertionError("invalid input accepted")


def check(module: types.ModuleType, root: Path) -> None:
    for invalid in ("", "x\0y", "\ufeff", "\ud800", "\ufdd0", "\uffff", "\U0010fffe", "a" * 65536):
        rejected(module.render, {"VALUE": invalid}, {"format": "environment", "secrets": ["VALUE"]})

    destination = root / "bundle"
    previous = {"one": b"previous one", "two": b"previous two"}
    module.publish(destination, previous, "root")
    rejected(module.publish, destination, {"one": b"new one", "../escape": b"invalid"}, "root")
    assert {path.name: path.read_bytes() for path in destination.iterdir()} == previous
    assert not list(root.glob(module.pending_prefix(destination) + "*"))

    # Terminate after the first staged file is durable, before publication.
    child = os.fork()
    if child == 0:
        module.os.fsync = lambda _: os.kill(os.getpid(), signal.SIGKILL)
        module.publish(destination, {"one": b"interrupted one", "two": b"interrupted two"}, "root")
        os._exit(2)
    _, status = os.waitpid(child, 0)
    assert os.WIFSIGNALED(status) and os.WTERMSIG(status) == signal.SIGKILL
    assert {path.name: path.read_bytes() for path in destination.iterdir()} == previous
    assert list(root.glob(module.pending_prefix(destination) + "*"))
    runtime = root / "runtime"
    runtime.mkdir(mode=0o700)
    other = root / (module.pending_prefix(root / "bundle-other") + "fixture")
    other.mkdir(mode=0o700)
    module.cleanup({"runtime": str(runtime), "destination": str(destination)})
    assert not list(root.glob(module.pending_prefix(destination) + "*"))
    assert other.is_dir()
    replacement = {"one": b"replacement one", "two": b"replacement two"}
    module.publish(destination, replacement, "root")
    assert {path.name: path.read_bytes() for path in destination.iterdir()} == replacement
    assert not destination.is_symlink()

    linked = root / "linked"
    linked.symlink_to(destination, target_is_directory=True)
    rejected(module.publish, linked, previous, "root")
    unsafe = root / "unsafe"
    unsafe.mkdir(mode=0o777)
    unsafe.chmod(0o777)
    rejected(module.publish, unsafe / "bundle", previous, "root")

    started = time.monotonic()
    rejected(module.capture, [sys.executable, "-c", "import os; os.write(1, b'x' * 5000000)"], {})
    assert time.monotonic() - started < 10
    child_pid = root / "descendant.pid"
    program = (
        "import os,time; from pathlib import Path; pid=os.fork(); "
        f"Path({str(child_pid)!r}).write_text(str(pid)) if pid else None; time.sleep(30)"
    )
    rejected(module.capture, [sys.executable, "-c", program], {}, 1)
    state = Path("/proc") / child_pid.read_text() / "stat"

    def running() -> bool:
        try:
            return state.read_bytes().split()[2] not in (b"Z", b"X")
        except (FileNotFoundError, ProcessLookupError):
            return False

    deadline = time.monotonic() + 2
    while running() and time.monotonic() < deadline:
        time.sleep(0.01)
    assert not running()
    assert stat.S_IMODE(destination.stat().st_mode) == 0o700


if __name__ == "__main__":
    try:
        os.umask(0o077)
        spec = importlib.util.spec_from_file_location("preparation", sys.argv[1])
        if spec is None or spec.loader is None:
            raise RuntimeError("preparation helper unavailable")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory(
            prefix="overalls-secret-boundaries-", dir="/run"
        ) as temporary:
            check(module, Path(temporary))
    except Exception as error:
        frames = traceback.extract_tb(error.__traceback__)[-4:]
        # Source location only: never the exception message, values or locals.
        locations = ", ".join(f"{Path(frame.filename).name}:{frame.lineno}" for frame in frames)
        print(
            f"Secret boundary verification failed ({type(error).__name__}) at {locations}",
            file=sys.stderr,
        )
        sys.exit(1)
